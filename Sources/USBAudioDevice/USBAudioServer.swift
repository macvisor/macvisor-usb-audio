import Foundation

/// Serves one `UAC1AudioDevice` over USB/IP.
///
/// Hand it each client connection with `serve(_:)`, on a thread of its own: a TCP connection, or a
/// virtio-vsock connection from Virtualization.framework. Rules it keeps:
/// - **One session per device.** A second OP_REQ_IMPORT is refused while a session is alive, so a
///   client that re-attaches twice can't present the device to the guest twice. After a VM is
///   restored its old connections are dead without anyone noticing: call `disconnectAll()` first.
/// - **Isochronous URBs complete in submission order**, paced by an `EndpointPacer` per endpoint.
/// - **Unlink as Linux defines it.** A pending URB that is unlinked gets USBIP_RET_UNLINK
///   (-ECONNRESET) and never a USBIP_RET_SUBMIT; one that already completed gets RET_UNLINK status 0.
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
    public var log: (@Sendable (String) -> Void)?

    private let lead: TimeInterval
    private let clock: PacerClock
    private let lock = NSLock()
    private var session: Session?

    /// How long a connection may take to import the device (or ask for the device list) before it is
    /// closed, so idle connections can't hold the server's places; nil waits forever.
    public var importTimeout: TimeInterval?

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

    /// Closes the current session, if any (for instance after the VM was restored).
    public func disconnectAll() {
        lock.lock()
        let s = session
        lock.unlock()
        s?.stream.close()
    }

    /// Serves one connection until it closes. Blocks.
    public func serve(_ stream: ByteStream) {
        defer { stream.close() }
        do {
            // Until the device is imported, a silent connection ends at `importTimeout`; an imported
            // device's stream is idle whenever nothing plays, so the timeout ends with the import.
            stream.setReadTimeout(importTimeout)
            switch try USBIP.readOperation(from: stream) {
            case USBIP.OpCode.requestDeviceList.rawValue:
                try stream.write(USBIP.encodeDeviceList([device.exportedDevice(busID: busID)]))
            case USBIP.OpCode.requestImport.rawValue:
                let requested = try USBIP.readImportBusID(from: stream)
                guard requested == busID else {
                    log?("import of unknown bus ID \(requested) refused")
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
            log?("connection closed: nothing imported within \(importTimeout ?? 0) s")
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

        init(stream: ByteStream, lead: TimeInterval, clock: PacerClock) {
            self.stream = stream
            playbackPacer = EndpointPacer(lead: lead, clock: clock, label: "usb-audio.playback")
            capturePacer = EndpointPacer(lead: 0, clock: clock, label: "usb-audio.capture")
        }

        var steering: DispatchSourceTimer?
        /// Whether this session already logged a refused URB (the first is said, not the rest).
        var saidRefused = false

        func send(_ data: Data) {
            writeLock.lock()
            defer { writeLock.unlock() }
            try? stream.write(data)
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

    private func release(_ s: Session) {
        s.steering?.cancel()
        s.playbackPacer.cancelAll()
        s.capturePacer.cancelAll()
        device.reset()
        lock.lock()
        if session === s { session = nil }
        lock.unlock()
        let p = s.playbackPacer.statistics, c = s.capturePacer.statistics
        log?("device \(busID) detached (playback: \(p.completedURBs) URBs, \(p.lateURBs) late, \(p.timelineRestarts) restarts; capture: \(c.completedURBs) URBs, \(c.lateURBs) late)")
    }

    /// Locks the playback timeline to the sink's clock: when the sink's buffer grows the pacer slows,
    /// when it drains the pacer speeds up (a few hundred ppm at most; clock drift is tens of ppm). The
    /// set point is the level the buffer settles at in the first two seconds of a stream.
    private func startSteering(_ s: Session) {
        guard playback.bufferedSeconds != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "usb-audio.steering", qos: .utility))
        var average: Double?, setPoint: Double?, samples = 0
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [device, playback] in
            guard device.isPlaybackActive, let level = playback.bufferedSeconds else {
                average = nil; setPoint = nil; samples = 0
                s.playbackPacer.setRateAdjustment(ppm: 0)
                return
            }
            let a = average.map { $0 * 0.9 + level * 0.1 } ?? level
            average = a
            samples += 1
            guard samples > 8 else { setPoint = a; return }
            let error = a - (setPoint ?? a) // seconds; positive: too much buffered
            s.playbackPacer.setRateAdjustment(ppm: max(-500, min(500, -error * 20_000)))
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
                let removed = s.playbackPacer.cancel(id: u.unlinkSequence) || s.capturePacer.cancel(id: u.unlinkSequence)
                s.send(USBIP.encodeUnlinkReply(sequence: u.sequence, status: removed ? USBIP.Status.connectionReset : USBIP.Status.ok))
            }
        }
    }

    private func submit(_ urb: SubmitRequest, in s: Session) {
        let playbackEndpoint = UInt32(UAC1AudioDevice.playbackEndpoint & 0x0F)
        let captureEndpoint = UInt32(UAC1AudioDevice.captureEndpoint & 0x0F)

        if urb.endpoint == 0 {
            // Control transfers complete at once, in order (the host serialises them).
            switch device.handleControl(SetupPacket(urb.setup), outData: urb.outData) {
            case .data(let bytes):
                let isIn = urb.direction == .in
                s.send(USBIP.encodeSubmitReply(sequence: urb.sequence, status: USBIP.Status.ok,
                                               actualLength: isIn ? UInt32(bytes.count) : UInt32(urb.outData.count),
                                               startFrame: 0, isoPackets: nil, data: isIn ? Data(bytes) : Data()))
            case .stall:
                s.send(USBIP.encodeSubmitReply(sequence: urb.sequence, status: USBIP.Status.stall, actualLength: 0,
                                               startFrame: 0, isoPackets: nil))
            }
            return
        }

        if urb.isIsochronous, urb.endpoint == playbackEndpoint, urb.direction == .out {
            guard urb.isoPackets.allSatisfy({ Int($0.length) <= UAC1AudioDevice.packetLimit }) else {
                return refuse(urb, in: s, "a playback packet longer than \(UAC1AudioDevice.packetLimit) bytes")
            }
            let frames = urb.outData.count / UAC1AudioDevice.bytesPerFrame
            let queued = s.playbackPacer.enqueue(id: urb.sequence, frameCount: frames) { [device, playback] in
                // Windows may send the first URB around SET_INTERFACE: accept it either way.
                if device.isPlaybackActive { playback.play(device.applyGain(.playback, to: urb.outData)) }
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
            let queued = s.capturePacer.enqueue(id: urb.sequence, frameCount: total / UAC1AudioDevice.bytesPerFrame) { [device, capture] in
                let audio = device.isCaptureActive ? device.applyGain(.capture, to: capture.captureAudio(byteCount: total)) : Data(count: total)
                // Every packet full, so the packed data is the packets back to back.
                let packets = urb.isoPackets.map { IsoPacket(offset: $0.offset, length: $0.length, actualLength: $0.length) }
                s.send(USBIP.encodeSubmitReply(sequence: urb.sequence, status: USBIP.Status.ok, actualLength: UInt32(total),
                                               startFrame: urb.startFrame, isoPackets: packets, data: audio))
            }
            if !queued { refuse(urb, in: s, "more capture queued than the device holds") }
            return
        }

        // Anything else: stall.
        stall(urb, in: s)
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
