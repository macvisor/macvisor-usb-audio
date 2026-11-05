@preconcurrency import AVFoundation
import Foundation
import USBAudioDevice

/// Plays the device's playback stream on the Mac's default output device.
///
/// The output engine starts when the host starts streaming and stops `idleStop` after it stops, so a
/// short system sound right after another doesn't pay for an engine start. A CoreAudioPlayback that is
/// freed stops its engine at once (a runner drops its USB audio after a restart with other settings).
///
/// **Latency.** The server completes playback URBs 40 ms (its lead) before their audio is due, so the
/// guest keeps that much queued, and that much is what the ring holds (`StereoRing.Bounds.playback`):
/// - an engine starts with the newest 40 ms: one takes up to half a second to start, and the stream
///   doesn't wait for it;
/// - a write past 100 ms drops the oldest audio down to 40 ms;
/// - a stall: the output plays silence, then the late URBs catch up at once, and the ring would keep
///   the stall as latency. A quarter of a second averaging more than 20 ms above the target drops the
///   excess.
/// `bufferedSeconds` reports the level; the server steers its pacer to hold it at its lead, so the
/// guest follows the output device's clock.
///
/// A change of the Mac's output (AirPods connecting, a USB DAC, another default device) stops an
/// AVAudioEngine and posts `AVAudioEngineConfigurationChange`: while the host streams, the engine is
/// built again on the new device, at most once a second (a headset switching profiles posts several in
/// a row); in the idle window after a stream it just stops. An engine that fails to start is tried
/// again after a growing pause (`StartBackoff`), not at every URB.
public final class CoreAudioPlayback: PlaybackSink, @unchecked Sendable {
    public var log: (@Sendable (String) -> Void)? {
        get { logLock.withLock { logHandler } }
        set { logLock.withLock { logHandler = newValue } }
    }

    private let logLock = NSLock()
    private var logHandler: (@Sendable (String) -> Void)?
    private let ring: StereoRing
    private let idleStop: TimeInterval
    private let makeOutput: MakePlaybackOutput
    private let queue = DispatchQueue(label: "usb-audio.coreaudio.playback")
    // On the queue:
    private var output: (any PlaybackOutput)?
    /// Counts the outputs built: a change notification about an older one is stale.
    private var generation = 0
    /// Between playbackStarted and playbackStopped.
    private var streaming = false
    private var stopWork: DispatchWorkItem?
    private var backoff = StartBackoff()

    public convenience init(idleStop: TimeInterval = 30) {
        self.init(idleStop: idleStop, bounds: .playback) { ring, changed in EnginePlaybackOutput(ring: ring, changed: changed) }
    }

    /// `makeOutput` builds an output reading `ring`, which calls `changed` when the Mac's output
    /// device changes under it (tests pass a stand-in).
    init(idleStop: TimeInterval, bounds: StereoRing.Bounds, makeOutput: @escaping MakePlaybackOutput) {
        self.idleStop = idleStop
        ring = StereoRing(capacitySeconds: 0.5, bounds: bounds)
        self.makeOutput = makeOutput
    }

    deinit {
        // Nothing else holds this object, so nothing of it runs on the queue any more: the output stops
        // here, and with it the Mac's audio and the engine's notifications.
        stopWork?.cancel()
        output?.stop()
    }

    public var bufferedSeconds: Double? {
        Double(ring.bufferedFrames) / Double(UAC1AudioDevice.sampleRate)
    }

    /// What the ring dropped to hold the latency (tests).
    var ringStatistics: StereoRing.Statistics { ring.statistics }

    public func playbackStarted() {
        queue.async { [self] in
            streaming = true
            stopWork?.cancel()
            stopWork = nil
            startOutput()
        }
    }

    public func play(_ pcm: Data) {
        ring.write(int16: pcm)
        queue.async { [self] in
            guard streaming else { return }
            if let output {
                // Stopped without a notification (or before it is handled): the same as a change.
                if !output.isRunning { outputChanged(generation: generation) }
            } else if backoff.mayTry(at: Date()) {
                startOutput()
            }
        }
    }

    public func playbackStopped() {
        queue.async { [self] in
            streaming = false
            stopWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.stopOutput() }
            stopWork = work
            queue.asyncAfter(deadline: .now() + idleStop, execute: work)
        }
    }

    /// Waits for what the queue has to do (tests).
    func waitForQueue() {
        queue.sync {}
    }

    /// On the queue.
    private func startOutput() {
        guard streaming, output == nil else { return }
        generation += 1
        let current = generation
        // The output observes changes from before its start: a change while it starts isn't lost. The
        // observer holds neither the output nor this object.
        let output = makeOutput(ring) { [weak self] in
            guard let self else { return }
            queue.async { self.outputChanged(generation: current) }
        }
        ring.trimOnNextRead()
        do {
            try output.start()
            self.output = output
            let after = backoff.succeeded(at: Date())
            log?("playback: output engine started (\(output.formatDescription))\(after > 0 ? " after \(after) failed attempt(s)" : "")")
        } catch {
            output.stop()
            if backoff.failed(at: Date()) == 1 {
                log?("playback: output engine failed to start: \(error); trying again, less and less often")
            }
        }
    }

    /// The output device changed under the engine, which stopped (on the queue). While the host streams
    /// it is built again there; in the idle window after a stream it stays stopped, and the next stream
    /// starts it.
    private func outputChanged(generation changed: Int) {
        guard changed == generation, output != nil else { return }
        guard streaming else {
            log?("playback: the Mac's output changed while no stream plays")
            stopOutput()
            return
        }
        log?("playback: the Mac's output changed; starting the engine on it again")
        teardown()
        // Not before a second after the last start; failures keep their pause.
        let at = backoff.holdOffAfterStart(seconds: 1)
        queue.asyncAfter(deadline: .now() + max(0, at.timeIntervalSinceNow)) { [weak self] in
            guard let self, output == nil, backoff.mayTry(at: Date()) else { return }
            startOutput()
        }
    }

    private func teardown() {
        output?.stop()
        output = nil
    }

    private func stopOutput() {
        stopWork?.cancel()
        stopWork = nil
        let stopped = output != nil
        teardown()
        ring.clear()
        backoff = StartBackoff()
        if stopped { log?("playback: output engine stopped") }
    }
}

/// An output as CoreAudioPlayback drives it: an AVAudioEngine in use, a stand-in in tests.
protocol PlaybackOutput: AnyObject {
    var isRunning: Bool { get }
    var formatDescription: String { get }
    /// Starts playing what the ring holds; may take half a second.
    func start() throws
    /// Stops playing and observing; safe to call more than once, from any thread.
    func stop()
}

/// Builds an output reading `ring`, whose `changed` is called when the Mac's output device changes.
typealias MakePlaybackOutput = (_ ring: StereoRing, _ changed: @escaping @Sendable () -> Void) -> any PlaybackOutput

/// An AVAudioEngine playing a ring on the Mac's default output.
final class EnginePlaybackOutput: PlaybackOutput, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let observer: any NSObjectProtocol
    private let lock = NSLock()
    private var stopped = false

    init(ring: StereoRing, changed: @escaping @Sendable () -> Void) {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(UAC1AudioDevice.sampleRate), channels: 2)!
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2, let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = ring.read(frames: Int(frameCount), left: l, right: r)
            for i in n ..< Int(frameCount) { l[i] = 0; r[i] = 0 } // underrun: silence
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { _ in changed() }
    }

    deinit { stop() }

    var isRunning: Bool { engine.isRunning }
    var formatDescription: String { "\(engine.outputNode.outputFormat(forBus: 0))" }

    func start() throws { try engine.start() }

    func stop() {
        guard lock.withLock({ () -> Bool in defer { stopped = true }; return !stopped }) else { return }
        NotificationCenter.default.removeObserver(observer)
        engine.stop()
    }
}

/// When to try starting an audio engine again: after a failure at once the first time, then after
/// 0.5, 1, 2… seconds, up to 30; after a device change not sooner than a second after the last start.
struct StartBackoff {
    private(set) var failures = 0
    private var next: Date?
    private var lastStart: Date?

    func mayTry(at now: Date) -> Bool { next.map { now >= $0 } ?? true }

    /// When the next try may be (the distant past: now).
    var nextTry: Date { next ?? .distantPast }

    /// Counts a failure; returns how many there have been in a row.
    mutating func failed(at now: Date) -> Int {
        failures += 1
        next = now.addingTimeInterval(min(30, 0.5 * pow(2, Double(failures - 1))))
        return failures
    }

    /// The engine started; returns the failures before it.
    mutating func succeeded(at now: Date) -> Int {
        defer { failures = 0; next = nil; lastStart = now }
        return failures
    }

    /// A device change: the next start waits until `seconds` after the last one (and any failure's
    /// pause). Returns when it may be.
    mutating func holdOffAfterStart(seconds: TimeInterval) -> Date {
        let floor = lastStart.map { $0.addingTimeInterval(seconds) } ?? .distantPast
        next = max(next ?? .distantPast, floor)
        return next ?? floor
    }
}

/// Feeds the Mac's default input device to the device's microphone stream, **only while the host
/// records** (the microphone opens on `captureStarted` and closes on `captureStopped`), so macOS's
/// microphone indicator and its permission prompt mean what they say. A change of the Mac's input
/// while the host records opens the new one (at most once a second); a microphone that fails to open
/// is tried again, with the same growing pause as playback, while the host still records.
///
/// A host that stops asking for audio while it records (a paused VM, a hung guest) gets the
/// microphone closed after `idleClose` (a second): it opens again at the host's next request, by the
/// same path as a retry, so a paused VM doesn't keep the Mac's microphone open. A freed
/// CoreAudioCapture closes it at once.
public final class CoreAudioCapture: CaptureSource, @unchecked Sendable {
    public var log: (@Sendable (String) -> Void)? {
        get { lock.withLock { logHandler } }
        set { lock.withLock { logHandler = newValue } }
    }

    /// A second: room for the tap's 100 ms buffers and what the trim keeps around them.
    private let ring = StereoRing(capacitySeconds: 1)
    private let queue = DispatchQueue(label: "usb-audio.coreaudio.capture")
    private let makeInput: MakeCaptureInput
    private let idleClose: TimeInterval
    // On the queue:
    private var input: (any CaptureInput)?
    /// Counts the inputs built: a change notification about an older one is stale.
    private var generation = 0
    /// Whether the host records, and the start pauses.
    private var wanted = false
    private var backoff = StartBackoff()
    /// While the microphone is open: closes it when the host stops asking.
    private var watchdog: DispatchSourceTimer?
    /// Shared with the server's thread: when a start is due (the host records, no microphone is open),
    /// and when the host last asked for audio (uptime nanoseconds); and `log`.
    private let lock = NSLock()
    private var retryAt: Date?
    private var lastAsked: UInt64 = 0
    private var logHandler: (@Sendable (String) -> Void)?
    private let keepFrames = StereoRing.Bounds.frames(ms: 40)
    private let marginFrames = StereoRing.Bounds.frames(ms: 20)
    private let trimAboveFrames = StereoRing.Bounds.frames(ms: 150)

    public convenience init() {
        self.init(idleClose: 1) { ring, changed in try EngineCaptureInput(ring: ring, changed: changed) }
    }

    /// `makeInput` builds an input writing `ring`, which calls `changed` when the Mac's input device
    /// changes under it, or throws when no input device is usable (tests pass a stand-in).
    init(idleClose: TimeInterval, makeInput: @escaping MakeCaptureInput) {
        self.idleClose = idleClose
        self.makeInput = makeInput
    }

    deinit {
        // As for playback: nothing of this object runs on the queue any more; the microphone closes here.
        watchdog?.cancel()
        input?.stop()
    }

    public func captureStarted() {
        queue.async { [self] in
            wanted = true
            backoff = StartBackoff()
            startInput()
        }
    }

    public func captureStopped() {
        queue.async { [self] in
            wanted = false
            setRetry(at: nil)
            teardown()
            ring.clear()
            log?("capture: microphone closed")
        }
    }

    public func captureAudio(byteCount: Int) -> Data {
        let now = DispatchTime.now().uptimeNanoseconds
        let due: Bool = lock.withLock {
            lastAsked = now
            guard let at = retryAt, Date() >= at else { return false }
            retryAt = nil // one try; the queue says when the next is due
            return true
        }
        if due { queue.async { [self] in retry() } }
        var audio = ring.readInt16(frames: byteCount / UAC1AudioDevice.bytesPerFrame, keepFrames: keepFrames,
                                   marginFrames: marginFrames, trimAboveFrames: trimAboveFrames).0
        // Exactly byteCount, as the protocol says: the reply's length is the host's.
        if audio.count < byteCount { audio.append(Data(count: byteCount - audio.count)) }
        return audio
    }

    /// Whether the microphone is open (tests).
    var isOpen: Bool { queue.sync { input != nil } }

    /// Waits for what the queue has to do (tests).
    func waitForQueue() {
        queue.sync {}
    }

    private func setRetry(at date: Date?) {
        lock.withLock { retryAt = date }
    }

    private func teardown() {
        watchdog?.cancel()
        watchdog = nil
        input?.stop()
        input = nil
    }

    /// On the queue: the host asked for audio while a start was due.
    private func retry() {
        guard wanted, input == nil else { return }
        guard backoff.mayTry(at: Date()) else {
            setRetry(at: backoff.nextTry)
            return
        }
        startInput()
    }

    /// On the queue.
    private func startInput() {
        guard wanted, input == nil else { return }
        generation += 1
        let current = generation
        let input: any CaptureInput
        do {
            // Observes changes from before its start, holding neither the input nor this object.
            input = try makeInput(ring) { [weak self] in
                guard let self else { return }
                queue.async { self.inputChanged(generation: current) }
            }
        } catch {
            if backoff.failed(at: Date()) == 1 { log?("capture: no usable input device (\(error)); trying again, less and less often") }
            setRetry(at: backoff.nextTry)
            return
        }
        do {
            try input.start()
            self.input = input
            let now = DispatchTime.now().uptimeNanoseconds
            lock.withLock {
                retryAt = nil
                lastAsked = max(lastAsked, now) // the host has `idleClose` from the start to ask
            }
            let after = backoff.succeeded(at: Date())
            watch()
            log?("capture: microphone open (\(input.formatDescription))\(after > 0 ? " after \(after) failed attempt(s)" : "")")
        } catch {
            input.stop()
            if backoff.failed(at: Date()) == 1 { log?("capture: microphone failed to start: \(error); trying again, less and less often") }
            setRetry(at: backoff.nextTry)
        }
    }

    /// The input device changed under the engine, which stopped (on the queue): the next request of the
    /// host opens it again, not before a second after the last start.
    private func inputChanged(generation changed: Int) {
        guard changed == generation, input != nil, wanted else { return }
        log?("capture: the Mac's input changed; opening it again")
        teardown()
        setRetry(at: backoff.holdOffAfterStart(seconds: 1))
    }

    /// While the microphone is open: a stopped engine is a change, and a host that hasn't asked for
    /// audio in `idleClose` gets the microphone closed until it asks again.
    private func watch() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = min(0.25, idleClose / 4)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.check() }
        watchdog?.cancel()
        watchdog = timer
        timer.resume()
    }

    private func check() {
        guard let input else { return }
        guard input.isRunning else {
            inputChanged(generation: generation)
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let idle = lock.withLock { now > lastAsked ? now - lastAsked : 0 }
        guard Double(idle) / 1e9 > idleClose else { return }
        log?("capture: the guest asked for no audio in \(idleClose) s (a paused VM?); microphone closed until it asks again")
        teardown()
        ring.clear()
        setRetry(at: Date())
    }
}

/// An input as CoreAudioCapture drives it: an AVAudioEngine in use, a stand-in in tests.
protocol CaptureInput: AnyObject {
    var isRunning: Bool { get }
    var formatDescription: String { get }
    /// Opens the microphone, writing to the ring.
    func start() throws
    /// Closes it and stops observing; safe to call more than once, from any thread.
    func stop()
}

/// Builds an input writing `ring`, whose `changed` is called when the Mac's input device changes;
/// throws when no input device is usable.
typealias MakeCaptureInput = (_ ring: StereoRing, _ changed: @escaping @Sendable () -> Void) throws -> any CaptureInput

/// An AVAudioEngine writing the Mac's default input to a ring, as 48 kHz stereo.
final class EngineCaptureInput: CaptureInput, @unchecked Sendable {
    /// The input's format, which can't be converted.
    struct NoUsableInput: Error, CustomStringConvertible {
        let description: String
    }

    private let engine: AVAudioEngine
    private let observer: any NSObjectProtocol
    private let lock = NSLock()
    private var stopped = false
    let formatDescription: String

    init(ring: StereoRing, changed: @escaping @Sendable () -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(UAC1AudioDevice.sampleRate), channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw NoUsableInput(description: "\(inputFormat)")
        }
        if inputFormat.channelCount == 1 { converter.channelMap = [0, 0] } // mono microphone to both channels
        // The tap's buffers are 100 ms whatever is asked (its range is 100–400 ms); the capture trim
        // keeps one of them.
        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / inputFormat.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            nonisolated(unsafe) var fed = false
            _ = converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let data = out.floatChannelData?[0] {
                ring.write(float: UnsafeBufferPointer(start: data, count: Int(out.frameLength) * 2))
            }
        }
        self.engine = engine
        formatDescription = "\(inputFormat)"
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { _ in changed() }
    }

    deinit { stop() }

    var isRunning: Bool { engine.isRunning }

    func start() throws { try engine.start() }

    func stop() {
        guard lock.withLock({ () -> Bool in defer { stopped = true }; return !stopped }) else { return }
        NotificationCenter.default.removeObserver(observer)
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
