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
    private let clock: PacerClock
    private let lock = NSLock()
    private var session: Session?
    /// The settings above: set on one thread, read on the sessions'.
    private let settingsLock = NSLock()
    private var logHandler: (@Sendable (String) -> Void)?
    private var importTimeoutSetting: TimeInterval?

    /// - Parameters:
    ///   - lead: how far ahead of real time playback URBs complete (absorbs transport jitter).
    public init(device: UAC1AudioDevice = UAC1AudioDevice(), playback: PlaybackSink, capture: CaptureSource,
                busID: String = "1-1", lead: TimeInterval = 0.04, clock: PacerClock = DispatchClock()) {
        self.device = device
        self.playback = playback
        self.capture = capture
        self.busID = busID
        self.lead = lead
        self.clock = clock
        device.onStreamEvent = { [playback, capture] event in
            switch event {
            case .playbackStarted: playback.playbackStarted()
            case .playbackStopped: playback.playbackStopped()
            case .captureStarted: capture.captureStarted()
            case .captureStopped: capture.captureStopped()
            }
        }
    }

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
        let s = Session(stream: stream, lead: lead, clock: clock)
        session = s
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
        log?("device \(busID) detached (playback: \(p.completedURBs) URBs, \(p.lateURBs) late, \(p.timelineRestarts) restarts; capture: \(c.completedURBs) URBs, \(c.lateURBs) late)")
    }

    /// Locks the playback timeline to the sink's clock, holding the sink's buffer at the lead
    /// (`PlaybackSteering`), every quarter of a second.
    private func startSteering(_ s: Session) {
        guard playback.bufferedSeconds != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "usb-audio.steering", qos: .utility))
        var steering = PlaybackSteering(setPoint: lead)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [device, playback] in
            let level = device.isPlaybackActive ? playback.bufferedSeconds : nil
            s.playbackPacer.setRateAdjustment(ppm: steering.adjustment(level: level))
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
/// The set point is fixed: the server's lead, which is what the guest keeps queued and what a sink
/// holds (`CoreAudioPlayback` does). One learned from the first two seconds of a stream learned the
/// half second an output engine took to start, and held it (5 Nov 2026). The first two seconds still
/// only follow the level, without steering: an output engine starts in them.
struct PlaybackSteering {
    let setPoint: Double
    private var average: Double?
    private var samples = 0

    init(setPoint: Double) {
        self.setPoint = setPoint
    }

    /// The pacer's rate adjustment, in ppm, for the sink's level sampled every quarter of a second;
    /// nil while nothing plays, which starts over.
    mutating func adjustment(level: Double?) -> Double {
        guard let level else {
            average = nil
            samples = 0
            return 0
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
