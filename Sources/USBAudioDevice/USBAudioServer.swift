import Foundation

/// Serves one `UAC1AudioDevice` over USB/IP.
///
/// Hand it each client connection with `serve(_:)`, on a thread of its own: a TCP connection, or a
/// virtio-vsock connection from Virtualization.framework. Rules it keeps:
/// - **One session per device.** A second OP_REQ_IMPORT is refused while a session is alive, so a
///   client that re-attaches twice can't present the device to the guest twice. After a VM is
///   restored its old connections are dead without anyone noticing: call `disconnectAll()` first.
///   It resets the device before it returns, so the guest's streams (and the Mac's microphone) stop
///   then, not when the session's thread notices.
/// - **Isochronous URBs complete in submission order**, paced by an `EndpointPacer` per endpoint.
/// - **Unlink as Linux defines it.** A pending URB that is unlinked gets USBIP_RET_UNLINK
///   (-ECONNRESET) and never a USBIP_RET_SUBMIT; one that already completed gets RET_UNLINK status 0,
///   after its RET_SUBMIT (Linux's vhci drops a connection whose RET_UNLINK comes first).
/// - **Bounded by the device, not the host.** Transfers longer than `UAC1AudioDevice.maxTransferLength`
///   end the session; isochronous packets longer than `packetLimit`, or summing past their buffer,
///   stall; and URBs beyond what a pacer queues stall at once. Whatever the host sends, the server
///   holds a few seconds of audio at most.
public final class USBAudioServer: @unchecked Sendable {
    public let busID: String
    public let device: UAC1AudioDevice
    public let playback: PlaybackSink
    public let capture: CaptureSource

    /// Diagnostics, one line at a time.
    public var log: (@Sendable (String) -> Void)? {
        get { settingsLock.withLock { logHandler } }
        set { settingsLock.withLock { logHandler = newValue } }
    }

    /// How long a connection may take to import the device (or ask for the device list) before it is
    /// closed, so idle connections can't hold the server's places; nil waits forever. Counted from
    /// the start of `serve(_:)`, for all its reads together.
    public var importTimeout: TimeInterval? {
        get { settingsLock.withLock { importTimeoutSetting } }
        set { settingsLock.withLock { importTimeoutSetting = newValue } }
    }

    private let lead: TimeInterval
    private let mostLead: TimeInterval
    /// What a stream starts with (`AdaptiveLead.start`): the lead itself where it doesn't change.
    private let startLead: TimeInterval
    private let clock: PacerClock
    private let lock = NSLock()
    private var session: Session?
    /// The settings above: set on one thread, read on the sessions'.
    private let settingsLock = NSLock()
    private var logHandler: (@Sendable (String) -> Void)?
    private var importTimeoutSetting: TimeInterval?

    /// - Parameters:
    ///   - lead: how far ahead of real time playback URBs complete (absorbs transport jitter).
    ///   - mostLead: how far the lead may grow while the guest's audio comes late (`AdaptiveLead`);
    ///     one no more than `lead`, or a `lead` of zero, keeps the lead as it is.
    public init(device: UAC1AudioDevice = UAC1AudioDevice(), playback: PlaybackSink, capture: CaptureSource,
                busID: String = "1-1", lead: TimeInterval = 0.04, mostLead: TimeInterval = 0.2,
                clock: PacerClock = DispatchClock()) {
        self.device = device
        self.playback = playback
        self.capture = capture
        self.busID = busID
        self.lead = lead
        self.mostLead = lead > 0 ? max(lead, mostLead) : 0
        startLead = lead > 0 ? min(max(lead, mostLead), max(lead, Self.streamStartLead)) : lead
        self.clock = clock
        device.onStreamEvent = { [weak self, playback, capture] event in
            switch event {
            case .playbackStarted:
                // A stream's first URB is no late one of the stream before it.
                self?.lock.withLock { self?.session }?.playbackPacer.newStream()
                playback.playbackStarted()
            case .playbackStopped: playback.playbackStopped()
            case .captureStarted: capture.captureStarted()
            case .captureStopped: capture.captureStopped()
            }
        }
    }

    /// What a stream starts with where the lead fits itself to the guest (`AdaptiveLead`).
    static let streamStartLead: TimeInterval = 0.1

    /// Whether a client has the device imported.
    public var isAttached: Bool {
        lock.lock()
        defer { lock.unlock() }
        return session != nil
    }

    /// Statistics of the current session's playback and capture pacers.
    public var statistics: (playback: EndpointPacer.Statistics, capture: EndpointPacer.Statistics)? {
        lock.lock()
        defer { lock.unlock() }
        guard let s = session else { return nil }
        return (s.playbackPacer.statistics, s.capturePacer.statistics)
    }

    /// Ends the current session, if any (for instance after the VM was restored, or when the device
    /// goes): its connection closes, and the device resets before this returns, so the guest's
    /// streams stop, and with them the Mac's microphone, without waiting for the session's thread to
    /// notice the closed connection.
    public func disconnectAll() {
        let s = lock.withLock { session }
        guard let s else { return }
        s.stream.close()
        release(s)
    }

    /// Serves one connection until it closes. Blocks.
    public func serve(_ stream: ByteStream) {
        defer { stream.close() }
        // Until the device is imported, the connection has `importTimeout` from now, all its reads
        // together: a timeout per read let a client sending a byte at a time hold its place for
        // minutes (5 Nov 2026). An imported device's stream is idle whenever nothing plays, so the
        // timeout ends with the import.
        let timeout = importTimeout
        let deadline = timeout.map { DispatchTime.now().uptimeNanoseconds &+ UInt64(min($0, 1e9) * 1e9) }
        func beforeRead() throws {
            guard let deadline else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw StreamError.timedOut }
            stream.setReadTimeout(Double(deadline - now) / 1e9)
        }
        do {
            try beforeRead()
            switch try USBIP.readOperation(from: stream) {
            case USBIP.OpCode.requestDeviceList.rawValue:
                try stream.write(USBIP.encodeDeviceList([device.exportedDevice(busID: busID)]))
            case USBIP.OpCode.requestImport.rawValue:
                try beforeRead()
                let requested = try USBIP.readImportBusID(from: stream)
                guard requested == busID else {
                    // The guest's bytes, escaped: a newline in them would forge log lines.
                    log?("import of unknown bus ID \"\(Self.printable(requested))\" refused")
                    try stream.write(USBIP.encodeImportReply(nil))
                    return
                }
                guard let s = claim(stream) else {
                    log?("import refused: the device is already attached")
                    try stream.write(USBIP.encodeImportReply(nil))
                    return
                }
                defer { release(s) } // registered before any write that could fail
                stream.setReadTimeout(nil)
                try stream.write(USBIP.encodeImportReply(device.exportedDevice(busID: busID)))
                log?("device \(busID) attached")
                try run(s)
            case let other:
                throw USBIP.ProtocolError.unexpectedOperation(other)
            }
        } catch StreamError.closed {
        } catch StreamError.timedOut {
            log?("connection closed: nothing imported within \(timeout ?? 0) s")
        } catch {
            log?("connection ended: \(error)")
        }
    }

    // MARK: Session

    final class Session: @unchecked Sendable {
        let stream: ByteStream
        let playbackPacer: EndpointPacer
        let capturePacer: EndpointPacer
        private let writeLock = NSLock()
        /// Held while a control transfer reaches the device, and to end the session.
        private let gate = NSLock()
        private var ended = false

        init(stream: ByteStream, lead: TimeInterval, clock: PacerClock) {
            self.stream = stream
            playbackPacer = EndpointPacer(lead: lead, clock: clock, label: "usb-audio.playback")
            capturePacer = EndpointPacer(lead: 0, clock: clock, label: "usb-audio.capture")
        }

        var steering: DispatchSourceTimer?
        /// Whether this session already logged a refused URB (the first is said, not the rest).
        var saidRefused = false
        /// Whether this session already logged a stalled control request (the first is said, not the
        /// rest): a host asking for something the device doesn't declare, such as a volume control on a
        /// channel other than the master, would otherwise go unseen.
        var saidStalled = false

        func send(_ data: Data) {
            writeLock.lock()
            defer { writeLock.unlock() }
            try? stream.write(data)
        }

        /// Runs `body` unless the session has ended, which waits for it: once a session has ended,
        /// nothing of it reaches the device (a control transfer its thread already read can't start
        /// a stream on a device that was reset, or that another session has since).
        func ifLive<T>(_ body: () -> T) -> T? {
            gate.withLock { ended ? nil : body() }
        }

        /// Ends the session; false if it had ended already.
        func end() -> Bool {
            gate.withLock {
                defer { ended = true }
                return !ended
            }
        }
    }

    private func claim(_ stream: ByteStream) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        guard session == nil else { return nil }
        let s = Session(stream: stream, lead: startLead, clock: clock)
        session = s
        // A session starts as a stream does, whatever the last one grew to. (A server made with no
        // lead holds none, and says nothing.)
        if lead > 0 { playback.playbackLead(startLead) }
        startSteering(s)
        return s
    }

    /// Ends a session, once: `disconnectAll` and the session's own thread may both get here. The
    /// device resets before the session lets it go, so a new one starts with it unconfigured.
    private func release(_ s: Session) {
        guard s.end() else { return }
        s.steering?.cancel()
        s.playbackPacer.cancelAll()
        s.capturePacer.cancelAll()
        device.reset()
        lock.withLock {
            if session === s { session = nil }
        }
        let p = s.playbackPacer.statistics, c = s.capturePacer.statistics
        let worst = p.lateURBs > 0 ? String(format: " (by %.0f ms at most)", p.worstLateness * 1000) : ""
        let spare = p.leastSlack.map { String(format: ", %.0f ms ahead at the least", $0 * 1000) } ?? ""
        log?("device \(busID) detached (playback: \(p.completedURBs) URBs, \(p.lateURBs) late\(worst), \(p.timelineRestarts) restarts\(spare); capture: \(c.completedURBs) URBs, \(c.lateURBs) late)")
    }

    /// Every quarter of a second: fits the lead to how the guest's URBs arrive (`AdaptiveLead`), and
    /// locks the playback timeline to the sink's clock, holding the sink's buffer at the lead
    /// (`PlaybackSteering`), where the sink says what it holds.
    private func startSteering(_ s: Session) {
        let steers = playback.bufferedSeconds != nil
        let adapts = mostLead > lead
        guard steers || adapts else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "usb-audio.steering", qos: .utility))
        var steering = PlaybackSteering(setPoint: startLead)
        var adaptive = AdaptiveLead(base: lead, most: mostLead, start: startLead)
        var wasActive = false
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self, device, playback] in
            if adapts {
                // The sink first: it holds the new level before the guest's audio comes that much
                // sooner (or later).
                func apply(_ lead: TimeInterval) {
                    playback.playbackLead(lead)
                    s.playbackPacer.setLead(lead)
                    steering.setPoint = lead
                }
                // A stream that has stopped says nothing about the next one: its last URBs come as
                // the guest winds it down (the last one of a 43 s stream came 7 ms late).
                let arrivals = s.playbackPacer.takeArrivals()
                let active = device.isPlaybackActive
                defer { wasActive = active }
                if !active {
                    if wasActive, let lead = adaptive.streamEnded() { apply(lead) }
                } else {
                    let before = adaptive.lead
                    let grown = adaptive.grewForLateness
                    if let lead = adaptive.tick(arrivals) {
                        apply(lead)
                        if lead > before {
                            self?.log?(String(format: "playback: the guest's audio came %.0f ms late; keeping %.0f ms of it ahead now (it was %.0f ms)",
                                              arrivals.worstLateness * 1000, lead * 1000, before * 1000))
                        } else if grown, !adaptive.grewForLateness {
                            self?.log?(String(format: "playback: the guest's audio has come on time for a while; keeping %.0f ms of it ahead again", lead * 1000))
                        }
                    }
                }
            }
            guard steers else { return }
            let level = device.isPlaybackActive ? playback.bufferedSeconds : nil
            s.playbackPacer.setRateAdjustment(ppm: steering.adjustment(level: level, backlog: playback.startBacklog))
        }
        s.steering = timer
        timer.resume()
    }

    private func run(_ s: Session) throws {
        while true {
            switch try USBIP.readCommand(from: s.stream, maxTransferLength: UAC1AudioDevice.maxTransferLength) {
            case .submit(let urb):
                submit(urb, in: s)
            case .unlink(let u):
                if s.playbackPacer.cancel(id: u.unlinkSequence) || s.capturePacer.cancel(id: u.unlinkSequence) {
                    s.send(USBIP.encodeUnlinkReply(sequence: u.sequence, status: USBIP.Status.connectionReset))
                } else {
                    // Completed, or completing in a pacer's job right now, whose RET_SUBMIT may not
                    // be out yet: the answer goes through both pacers' queues, after any job that
                    // runs (5 Nov 2026).
                    let reply = USBIP.encodeUnlinkReply(sequence: u.sequence, status: USBIP.Status.ok)
                    s.playbackPacer.afterRunningJob {
                        s.capturePacer.afterRunningJob { s.send(reply) }
                    }
                }
            }
        }
    }

    private func submit(_ urb: SubmitRequest, in s: Session) {
        let playbackEndpoint = UInt32(UAC1AudioDevice.playbackEndpoint & 0x0F)
        let captureEndpoint = UInt32(UAC1AudioDevice.captureEndpoint & 0x0F)

        if urb.endpoint == 0 {
            // Control transfers complete at once, in order (the host serialises them); a session that
            // has ended stalls them.
            let setup = SetupPacket(urb.setup)
            switch s.ifLive({ device.handleControl(setup, outData: urb.outData) }) ?? .stall {
            case .data(let bytes):
                // IN data: at most wLength (the device cut it there) and the host's buffer.
                let isIn = urb.direction == .in
                let data = isIn ? Data(bytes.prefix(Int(urb.transferBufferLength))) : Data()
                s.send(USBIP.encodeSubmitReply(sequence: urb.sequence, status: USBIP.Status.ok,
                                               actualLength: isIn ? UInt32(data.count) : UInt32(urb.outData.count),
                                               startFrame: 0, isoPackets: nil, data: data))
            case .stall:
                // Hosts probe for what a device lacks (a qualifier descriptor, say), so a stall is no
                // error: the first one is said, for when a control (volume, mute) stops working.
                if !s.saidStalled {
                    s.saidStalled = true
                    log?(String(format: "stalled a control request the device doesn't support: bmRequestType 0x%02X bRequest 0x%02X wValue 0x%04X wIndex 0x%04X (later ones aren't logged)",
                                setup.requestType, setup.request, setup.value, setup.index))
                }
                s.send(USBIP.encodeSubmitReply(sequence: urb.sequence, status: USBIP.Status.stall, actualLength: 0,
                                               startFrame: 0, isoPackets: nil))
            }
            return
        }

        if urb.isIsochronous, urb.endpoint == playbackEndpoint, urb.direction == .out {
            guard urb.isoPackets.allSatisfy({ Int($0.length) <= UAC1AudioDevice.packetLimit }) else {
                return refuse(urb, in: s, "a playback packet longer than \(UAC1AudioDevice.packetLimit) bytes")
            }
            guard let pcm = Self.playbackAudio(of: urb) else {
                return refuse(urb, in: s, "playback packets summing past their buffer")
            }
            let frames = pcm.count / UAC1AudioDevice.bytesPerFrame
            let queued = s.playbackPacer.enqueue(id: urb.sequence, frameCount: frames) { [device, playback] in
                // Windows may send the first URB around SET_INTERFACE: accept it either way.
                if device.isPlaybackActive { playback.play(device.applyGain(.playback, to: pcm)) }
                let packets = urb.isoPackets.map { IsoPacket(offset: $0.offset, length: $0.length, actualLength: $0.length) }
                s.send(USBIP.encodeSubmitReply(sequence: urb.sequence, status: USBIP.Status.ok,
                                               actualLength: UInt32(urb.outData.count), startFrame: urb.startFrame,
                                               isoPackets: packets))
            }
            if !queued { refuse(urb, in: s, "more playback queued than the device holds") }
            return
        }

        if urb.isIsochronous, urb.endpoint == captureEndpoint, urb.direction == .in {
            // Each packet within the device's limit, and all of them within the buffer: the reply's
            // data is the packets back to back, so their sum is what the server allocates.
            let total = urb.isoPackets.reduce(0) { $0 + Int($1.length) }
            guard urb.isoPackets.allSatisfy({ Int($0.length) <= UAC1AudioDevice.packetLimit }),
                  total <= Int(urb.transferBufferLength) else {
                return refuse(urb, in: s, "capture packets past the device's limit or their buffer")
            }
            // Whole frames in each packet (Windows asks for 192 bytes, 48 frames): a packet asked for in
            // another length gets the frames that fit, so left and right never swap; the packed data
            // is the packets back to back, and as long as the reply says.
            let bytesPerFrame = UInt32(UAC1AudioDevice.bytesPerFrame)
            let packets = urb.isoPackets.map { IsoPacket(offset: $0.offset, length: $0.length, actualLength: $0.length / bytesPerFrame * bytesPerFrame) }
            let actual = packets.reduce(0) { $0 + Int($1.actualLength) }
            let queued = s.capturePacer.enqueue(id: urb.sequence, frameCount: actual / UAC1AudioDevice.bytesPerFrame) { [device, capture] in
                var audio = device.isCaptureActive ? device.applyGain(.capture, to: capture.captureAudio(byteCount: actual)) : Data(count: actual)
                // Exactly the bytes the reply claims, whatever the source returned: the host reads
                // that many, and anything else would put the stream out of step.
                if audio.count > actual { audio = Data(audio.prefix(actual)) }
                if audio.count < actual { audio.append(Data(count: actual - audio.count)) }
                s.send(USBIP.encodeSubmitReply(sequence: urb.sequence, status: USBIP.Status.ok, actualLength: UInt32(actual),
                                               startFrame: urb.startFrame, isoPackets: packets, data: audio))
            }
            if !queued { refuse(urb, in: s, "more capture queued than the device holds") }
            return
        }

        // Anything else: stall.
        stall(urb, in: s)
    }

    /// A playback URB's audio: each packet's whole frames, back to back (Windows sends 192-byte packets
    /// back to back, which is the URB's data as it is). A packet that isn't whole frames loses its odd
    /// bytes, so left and right never swap for the rest of the stream; packets summing past their
    /// buffer (the same bytes counted twice) give nil.
    static func playbackAudio(of urb: SubmitRequest) -> Data? {
        let bytesPerFrame = UAC1AudioDevice.bytesPerFrame
        var total = 0
        var backToBack = true
        for p in urb.isoPackets {
            if Int(p.offset) != total || Int(p.length) % bytesPerFrame != 0 { backToBack = false }
            total += Int(p.length)
        }
        guard total <= urb.outData.count else { return nil }
        if backToBack, total == urb.outData.count { return urb.outData }
        var pcm = Data(capacity: total)
        for p in urb.isoPackets {
            let start = urb.outData.startIndex + Int(p.offset)
            let end = start + Int(p.length) / bytesPerFrame * bytesPerFrame
            guard end <= urb.outData.endIndex else { return nil } // the protocol reader checked this already
            pcm.append(urb.outData[start ..< end])
        }
        return pcm
    }

    /// `text` with anything but printable ASCII escaped, for a log line.
    static func printable(_ text: String) -> String {
        text.unicodeScalars.map { $0.value >= 0x20 && $0.value < 0x7F && $0 != "\\" ? String($0) : "\\u{\(String($0.value, radix: 16))}" }.joined()
    }

    /// Stalls a URB the device won't take, saying why the first time in a session.
    private func refuse(_ urb: SubmitRequest, in s: Session, _ reason: String) {
        if !s.saidRefused {
            s.saidRefused = true
            log?("refused a URB from the host: \(reason) (later ones aren't logged)")
        }
        stall(urb, in: s)
    }

    private func stall(_ urb: SubmitRequest, in s: Session) {
        let packets = urb.isIsochronous ? urb.isoPackets.map { IsoPacket(offset: $0.offset, length: $0.length, actualLength: 0, status: USBIP.Status.stall) } : nil
        s.send(USBIP.encodeSubmitReply(sequence: urb.sequence, status: USBIP.Status.stall, actualLength: 0,
                                       startFrame: urb.startFrame, isoPackets: packets, errorCount: UInt32(packets?.count ?? 0)))
    }
}

/// Locks the playback timeline to the sink's clock: when the sink's buffer grows the pacer slows, when
/// it drains the pacer speeds up (a few hundred ppm at most; clock drift is tens of ppm).
///
/// A sink whose output started late with the stream's beginning kept for it says how much more than
/// the set point it holds for that (`PlaybackSink.startBacklog`, `CoreAudioPlayback`): while it holds
/// more than `backlogFloor` the pacer runs up to a tenth slow, half a second in five, so the guest
/// sends that much less than the output plays and nothing is skipped. The guest's audio clock is the
/// pacer, so what it plays keeps time with it. The drift correction rests meanwhile, and starts over
/// after. It goes by what the sink holds at each look, not by a count kept here: a count ran on
/// when the sink's audio went another way (an output started twice, a guest that stalled), and the
/// lead drained after it.
///
/// The set point is the server's lead, which is what the guest keeps queued and what a sink holds
/// (`CoreAudioPlayback` does); it changes only as the lead does (`AdaptiveLead`). One learned from the
/// first two seconds of a stream learned the half second an output engine took to start, and held it
/// (5 Nov 2026). The first two seconds still only follow the level, without steering: an output
/// engine starts in them.
struct PlaybackSteering {
    var setPoint: Double
    /// How slow the pacer runs while a backlog is played down: a tenth.
    static let backlogSlowing = 0.1
    /// A backlog below this is left to the drift correction.
    static let backlogFloor = 0.003
    private var average: Double?
    private var samples = 0

    init(setPoint: Double) {
        self.setPoint = setPoint
    }

    /// The pacer's rate adjustment, in ppm, for the sink's level sampled every `interval` (a quarter
    /// of a second); nil while nothing plays, which starts over (what the sink still holds plays
    /// out, and there is no one to slow). `backlog`: what the sink holds above the set point now for
    /// an output that started late.
    mutating func adjustment(level: Double?, backlog: Double = 0, interval: Double = 0.25) -> Double {
        guard let level else {
            average = nil
            samples = 0
            return 0
        }
        if backlog > Self.backlogFloor {
            // Half of what is there at the most: what the sink says is an interval old, and part of
            // it has been played since, so the whole of it would run past the set point.
            let played = min((backlog - Self.backlogFloor) / 2, Self.backlogSlowing * interval)
            average = nil
            samples = 0
            return -played / interval * 1_000_000
        }
        samples += 1
        guard samples > 8, let previous = average else {
            average = level
            return 0
        }
        let a = previous * 0.9 + level * 0.1
        average = a
        let error = a - setPoint // seconds; positive: too much buffered
        return max(-500, min(500, -error * 20_000))
    }
}

/// Fits the playback lead to how the guest's audio arrives (11 Nov 2026).
///
/// The lead is the audio the guest keeps queued on the Mac: 40 ms of it absorbs a guest that submits
/// its URBs up to 50 ms late (the lead and the URB in flight). A guest that is busier than that, or
/// one whose vCPUs wait for a busy Mac's cores, submits later: the output runs dry, and the listener
/// hears a gap, then a skip as the late audio is caught up with. Measured in a Windows 11 guest:
/// - a minute of a video in a browser while the Mac ran other VMs: 124 of 6,581 URBs late;
/// - the sound Windows plays as it signs in, the guest still starting: URBs up to 193 ms late;
/// - a video in a browser while the Mac built an app: the worst arrival 63 ms behind the steady
///   ones, so 40 ms would not have held, where a quiet Mac had none late in 4,165.
///
/// So:
/// - **A stream starts with `start`** (100 ms): a guest is busiest as it starts to play (the browser
///   starting a video), and what a stream's start needs can't be learned from it in time.
/// - **Late URBs grow the lead** by how late they came and `margin`, in steps of 10 ms up to `most`,
///   which trades that much more delay for sound without gaps.
/// - **It comes down** after `calm` (30 s of playing) with no URB late: at once to where `keep` of
///   queued audio would have been left at the worst arrival, when more than `roomy` was; else by
///   10 ms while `spare` was. So a stream that needs its lead keeps it: one that stalls 80 ms every
///   so often settles where 30 to 40 ms are left at each stall, and a calm one is at the base after
///   a minute or two.
/// - While nothing plays it stays as it is, but for the start of the next stream.
///
/// A change either way is seamless: the pacer completes the next URBs that much sooner or later, the
/// guest follows, and no audio is dropped or made up.
struct AdaptiveLead {
    let base: TimeInterval
    let most: TimeInterval
    /// What a stream starts with, at the least.
    let start: TimeInterval
    private(set) var lead: TimeInterval
    /// Whether late URBs grew the lead since it was last at the base (for the log).
    private(set) var grewForLateness = false
    /// Quarter seconds since the lead last changed or a URB came late, with URBs arriving.
    private var calmTicks = 0
    /// The least queued audio left at an arrival in those.
    private var leastSlack: TimeInterval?

    static let step: TimeInterval = 0.01
    /// What a late URB adds beyond how late it came.
    static let margin: TimeInterval = 0.02
    /// The queued audio that has to have been left, at the worst, for the lead to come down a step.
    static let spare: TimeInterval = 0.04
    /// More than this left at the worst, and the lead comes down at once to where `keep` would be.
    static let roomy: TimeInterval = 0.08
    static let keep: TimeInterval = 0.06
    /// How long that has to have held, in ticks (30 s).
    static let calm = 120

    /// - Parameter start: what a stream starts with; nil: the base.
    init(base: TimeInterval, most: TimeInterval, start: TimeInterval? = nil) {
        self.base = base
        self.most = max(base, most)
        self.start = min(self.most, max(base, start ?? base))
        lead = self.start
    }

    /// A stream ended: the next one starts with `start` at the least. Returns the new lead when it
    /// changes.
    mutating func streamEnded() -> TimeInterval? {
        calmTicks = 0
        leastSlack = nil
        guard lead < start - Self.step / 2 else { return nil }
        lead = start
        return lead
    }

    /// A quarter second's arrivals; returns the new lead when it changes.
    mutating func tick(_ arrivals: EndpointPacer.Arrivals) -> TimeInterval? {
        if arrivals.late > 0 {
            calmTicks = 0
            leastSlack = nil
            let wanted = lead + arrivals.worstLateness + Self.margin
            let stepped = (wanted / Self.step - 0.001).rounded(.up) * Self.step
            let next = min(most, max(lead, stepped))
            guard next > lead + Self.step / 2 else { return nil }
            lead = next
            grewForLateness = true
            return lead
        }
        // Nothing arrived: nothing plays, and nothing is learned.
        guard let slack = arrivals.leastSlack else { return nil }
        leastSlack = min(leastSlack ?? slack, slack)
        calmTicks += 1
        guard calmTicks >= Self.calm else { return nil }
        let spare = leastSlack ?? 0
        calmTicks = 0
        leastSlack = nil
        guard lead > base + Self.step / 2, spare >= Self.spare else { return nil }
        let down = spare > Self.roomy ? ((spare - Self.keep) / Self.step + 0.001).rounded(.down) * Self.step : Self.step
        lead = max(base, ((lead - max(Self.step, down)) / Self.step).rounded() * Self.step)
        if lead <= base + Self.step / 2 { grewForLateness = false }
        return lead
    }
}
