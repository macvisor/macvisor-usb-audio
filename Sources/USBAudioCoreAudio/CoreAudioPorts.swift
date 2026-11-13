@preconcurrency import AVFoundation
import Foundation
import USBAudioDevice

/// Plays the device's playback stream on the Mac's default output device.
///
/// The output engine starts when the host starts streaming, and a stream doesn't wait for it. The
/// Mac's audio hardware takes its time to start (0.43 s on a display's speakers for an engine that
/// was only paused, 0.53 s for a new one), and what the guest played meanwhile used to go unheard:
/// that much of each stream that came more than 30 s after the last, all but the last quarter second
/// of a 0.7 s system sound and the beginning of every video (the owner's Windows VM, 11 Nov 2026).
/// Two things now:
/// - **The engine goes on running after a stream**, playing silence, for `wiredIdleStop` (two minutes)
///   where the Mac's output is wired: built in, or on USB, HDMI, DisplayPort or Thunderbolt. Not
///   longer: a running output keeps the Mac from going to sleep on its own, silent or not (the audio
///   daemon holds off idle sleep for it), and a guest that makes a sound now and then would keep a
///   MacBook awake. On Bluetooth or AirPlay it runs on for `idleStop` (30 s) only: a headset kept
///   streaming silence uses its battery, and stays with the Mac. Then it pauses, keeping what it
///   was built with, and the next stream starts it again.
/// - **An engine that starts plays the stream from its beginning**, up to three quarters of a second
///   of it (`StereoRing.Bounds.startKeep`): a short sound is heard whole, half a second late, and a
///   long one starts that much behind and is played down to the lead in five seconds by the server's
///   steering, which has the guest send a tenth slower meanwhile (`startBacklog`,
///   `PlaybackSteering`), so nothing is skipped.
/// A CoreAudioPlayback that is freed stops its engine at once, on a queue of its own (a runner drops
/// its USB audio after a restart with other settings, on its main thread).
///
/// **Latency.** The server completes playback URBs 40 ms (its lead) before their audio is due, so the
/// guest keeps that much queued, and that much is what the ring holds (`StereoRing.Bounds.playback`):
/// - an engine that starts has more for a while, as above;
/// - a rush in the middle of a stream (a write past 100 ms, or a quarter of a second averaging more
///   than 20 ms above the target: a guest that stalled, so the output played silence, then sent its
///   late audio at once; an output that missed cycles) is played, not dropped: the ring keeps up to
///   a quarter of a second of it above the target (`StereoRing.Bounds.rushKeep`), and the server's
///   steering has the guest send a tenth slower until it is played down, ten times its length on.
///   It was dropped until 12 Nov 2026, so a gap was followed by a skip as long (70 ms of a Windows
///   guest's sign-in sound). More than a quarter of a second, or a rush nothing plays down in half
///   a minute, still goes.
/// `bufferedSeconds` reports the level; the server steers its pacer to hold it at its lead, so the
/// guest follows the output device's clock. A server whose lead grows because the guest's audio comes
/// late says so (`playbackLead`), and the ring holds that much, with the same room above it.
///
/// A change of the Mac's output (AirPods connecting, a USB DAC, another default device) stops an
/// AVAudioEngine and posts `AVAudioEngineConfigurationChange`: while the host streams, the engine is
/// built again on the new device, at most once a second (a headset switching profiles posts several in
/// a row); in the idle window after a stream, or paused, it just stops, and the next stream builds
/// one. An engine that fails to start is tried again after a growing pause (`StartBackoff`), not at
/// every URB or stream start.
///
/// **A guest starting and stopping its stream in a loop** (SET_INTERFACE as fast as it can send it)
/// sets what it wants, and the queue acts on the last of it (`StreamRequests`): however many starts and
/// stops, the queue holds one block at most besides the one running, and the engine starts once.
public final class CoreAudioPlayback: PlaybackSink, @unchecked Sendable {
    public var log: (@Sendable (String) -> Void)? {
        get { logLock.withLock { logHandler } }
        set { logLock.withLock { logHandler = newValue } }
    }

    private let logLock = NSLock()
    private var logHandler: (@Sendable (String) -> Void)?
    private let ring: StereoRing
    private let idleStop: TimeInterval
    private let wiredIdleStop: TimeInterval
    private let makeOutput: MakePlaybackOutput
    /// What the ring can hold: the most a lead grows to (0.2 s) with what an output that starts is
    /// kept (0.75 s), and room.
    private static let ringSeconds = 1.5
    /// A stream's start waits for nothing else here: at the default QoS the block that starts the
    /// engine waited behind the vCPU threads of a busy Mac.
    private let queue = DispatchQueue(label: "usb-audio.coreaudio.playback", qos: .userInitiated)
    /// Whether the host streams, as it said last; acted on by `reconcile`.
    private let requests = StreamRequests()
    /// The idle stop: one timer, set again by each stop. It used to be a work item per stop, each
    /// held for 30 s, cancelled or not (5 Nov 2026).
    private let idleTimer: DispatchSourceTimer
    // On the queue:
    private var output: (any PlaybackOutput)?
    /// The output is paused: the idle timer's doing, until the next stream.
    private var paused = false
    /// Counts the outputs built: a change notification about an older one is stale.
    private var generation = 0
    /// Between playbackStarted and playbackStopped, as `reconcile` last acted on it.
    private var streaming = false
    /// When the idle timer pauses the output (nil: it doesn't). While the host streams, when it looks
    /// whether the guest still sends audio (`stallStop`).
    private var idleStopAt: DispatchTime?
    private var backoff = StartBackoff()
    /// How long a stream may send no audio before the output pauses (nil: never).
    private let stallStop: TimeInterval?
    /// When `play` last had audio (uptime nanoseconds), from the server's thread.
    private let playedLock = NSLock()
    private var lastPlayed: UInt64 = 0

    /// - Parameters:
    ///   - idleStop: how long the output runs on after a stream.
    ///   - wiredIdleStop: how long it does where the Mac's output is wired.
    ///   - stallStop: how long it runs on in a stream that has sent no audio, as a paused VM's
    ///     doesn't: as long as after a stream on Bluetooth, and no longer where it is wired, as a
    ///     paused VM has no next sound waiting to be heard sooner.
    public convenience init(idleStop: TimeInterval = 30, wiredIdleStop: TimeInterval = 120, stallStop: TimeInterval = 30) {
        self.init(idleStop: idleStop, wiredIdleStop: wiredIdleStop, stallStop: stallStop, bounds: .playback) { ring, changed in
            try EnginePlaybackOutput(ring: ring, changed: changed)
        }
    }

    /// `makeOutput` builds an output reading `ring`, which calls `changed` when the Mac's output
    /// device changes under it, or throws when it can't be built (tests pass a stand-in).
    init(idleStop: TimeInterval, wiredIdleStop: TimeInterval? = nil, stallStop: TimeInterval? = nil, bounds: StereoRing.Bounds,
         makeOutput: @escaping MakePlaybackOutput) {
        self.idleStop = idleStop
        self.wiredIdleStop = wiredIdleStop ?? idleStop
        self.stallStop = stallStop
        ring = StereoRing(capacitySeconds: Self.ringSeconds, bounds: bounds)
        self.makeOutput = makeOutput
        idleTimer = DispatchSource.makeTimerSource(queue: queue)
        idleTimer.setEventHandler { [weak self] in self?.idleTimerFired() }
        idleTimer.schedule(deadline: .distantFuture)
        idleTimer.activate()
    }

    deinit {
        // Nothing else holds this object, so nothing of it runs on the queue any more. The output stops
        // on a queue of its own: this may be the main thread, and an engine's stop takes 25–40 ms (more
        // on Bluetooth). With it go the Mac's audio and the engine's notifications.
        idleTimer.cancel()
        if let output { retireEngine { output.stop() } }
    }

    public var bufferedSeconds: Double? {
        Double(ring.bufferedFrames) / Double(UAC1AudioDevice.sampleRate)
    }

    /// What the ring dropped to hold the latency (tests).
    var ringStatistics: StereoRing.Statistics { ring.statistics }

    /// How playback has gone since this sink was made: what a listener would have heard go wrong.
    public struct Statistics: Equatable, Sendable {
        /// Times the output ran out of audio in the middle of a stream, and the silence it played
        /// for them, in seconds.
        public var gaps = 0
        public var gapSeconds = 0.0
        /// Audio dropped to hold the latency (after a stall, or what piled up while the output
        /// started), in seconds.
        public var droppedSeconds = 0.0

        public init(gaps: Int = 0, gapSeconds: Double = 0, droppedSeconds: Double = 0) {
            self.gaps = gaps
            self.gapSeconds = gapSeconds
            self.droppedSeconds = droppedSeconds
        }
    }

    public var statistics: Statistics {
        let ring = ring.statistics
        let rate = Double(UAC1AudioDevice.sampleRate)
        return Statistics(gaps: ring.gaps, gapSeconds: Double(ring.gapFrames) / rate,
                          droppedSeconds: Double(ring.excessFrames + ring.trimmedFrames) / rate)
    }

    /// How the stream events and URBs queued their work (tests).
    var queueStatistics: StreamRequests.Statistics { requests.statistics }

    public func playbackStarted() {
        request(streaming: true)
    }

    public func play(_ pcm: Data) {
        let now = DispatchTime.now().uptimeNanoseconds
        playedLock.withLock { lastPlayed = now }
        ring.write(int16: pcm)
        // The output's check, with the stream's events: one block for all of them.
        request(streaming: nil)
    }

    public func playbackStopped() {
        request(streaming: false)
    }

    /// What the ring holds above its level for the server to play down: the stream's beginning,
    /// for an output that started late, or a rush in the middle of a stream.
    public var startBacklog: Double {
        Double(ring.heldExcess) / Double(UAC1AudioDevice.sampleRate)
    }

    /// The server's lead changed: the ring holds that much (the ring's capacity leaves room for its
    /// ceiling above the most a server asks for).
    public func playbackLead(_ seconds: Double) {
        let most = 0.4
        ring.setTarget(frames: Int((max(0.005, min(seconds, most)) * Double(UAC1AudioDevice.sampleRate)).rounded()))
    }

    /// Waits for what the queue has to do (tests).
    func waitForQueue() {
        queue.sync {}
    }

    private func request(streaming wanted: Bool?) {
        guard requests.request(wanted) else { return }
        queue.async { [self] in
            reconcile()
            requests.ran()
        }
    }

    /// On the queue: acts on what the host said last, and checks the output while it streams.
    private func reconcile() {
        let wanted = requests.take()
        if wanted != streaming {
            streaming = wanted
            if wanted {
                setIdleStop(nil)
            } else {
                setIdleStop(.now() + (output?.isWired == true ? wiredIdleStop : idleStop))
                ring.streamEnded()
            }
        }
        guard streaming else { return }
        watchStream()
        if let output {
            if paused {
                resumeOutput(output)
            } else if !output.isRunning {
                // Stopped without a notification (or before it is handled): the same as a change.
                outputChanged(generation: generation)
            }
        } else if backoff.mayTry(at: Date()) {
            startOutput()
        }
    }

    /// On the queue.
    private func setIdleStop(_ at: DispatchTime?) {
        idleStopAt = at
        idleTimer.schedule(deadline: at ?? .distantFuture)
    }

    /// On the queue, while the host streams: has the idle timer look, `stallStop` on, whether the
    /// guest still sends audio (13 Nov 2026). A paused VM leaves its stream open and sends nothing, and
    /// the output played silence for as long as it stayed paused, holding off the Mac's idle sleep and
    /// keeping a Bluetooth headset streaming; the microphone already closed for it.
    private func watchStream() {
        guard streaming, idleStopAt == nil, let stallStop else { return }
        setIdleStop(.now() + stallStop)
    }

    /// On the queue: a fire from before the timer was set again stops nothing. In a stream, the output
    /// pauses once the guest has sent no audio for `stallStop`; its next audio starts it again
    /// (`reconcile`).
    private func idleTimerFired() {
        guard var at = idleStopAt else { return }
        if streaming {
            guard let stallStop else { return }
            // None yet: the watch's own time, from the stream's start, stands. (DispatchTime of 0 is
            // DISPATCH_TIME_NOW, which kept a stream with no audio from ever pausing.)
            let last = playedLock.withLock { lastPlayed }
            if last > 0 { at = max(at, DispatchTime(uptimeNanoseconds: last) + stallStop) }
        }
        guard DispatchTime.now() >= at else {
            setIdleStop(at)
            return
        }
        if streaming, output != nil {
            log?("playback: the guest has sent no audio in \(stallStop ?? 0) s (a paused VM?); pausing the output engine until it does")
        }
        pauseOutput()
    }

    /// On the queue: the idle window is over. The output pauses, built as it is, and what the ring
    /// holds goes; one that stopped by itself meanwhile is let go.
    private func pauseOutput() {
        setIdleStop(nil)
        guard !paused else { return }
        // None (it failed to start, or went with the Mac's output), or one that stopped by itself:
        // what the ring kept for it goes, and the next stream starts afresh.
        guard let output, output.isRunning else {
            stopOutput()
            return
        }
        output.pause()
        paused = true
        ring.clear()
        log?("playback: output engine paused")
    }

    /// On the queue: a stream after the idle window starts the paused output again. One that doesn't
    /// start is let go, and built again as any that failed to start.
    private func resumeOutput(_ output: any PlaybackOutput) {
        let began = DispatchTime.now().uptimeNanoseconds
        ring.outputStarts()
        do {
            try output.start()
            paused = false
            log?("playback: output engine started again\(Self.took(since: began))")
        } catch {
            log?("playback: the paused output engine didn't start again: \(error); building one")
            teardown()
            startOutput()
        }
    }

    private static func took(since began: UInt64) -> String {
        String(format: " in %.0f ms", Double(DispatchTime.now().uptimeNanoseconds &- began) / 1e6)
    }

    /// On the queue.
    private func startOutput() {
        guard streaming, output == nil else { return }
        generation += 1
        let current = generation
        let began = DispatchTime.now().uptimeNanoseconds
        // Before the output is built, which takes a tenth of a second of the stream itself: from here
        // on the ring keeps the stream's beginning for it (the first 70 ms of a video went at the
        // ceiling while an engine was built, 12 Nov 2026).
        ring.outputStarts()
        do {
            // The output observes changes from before its start: a change while it starts isn't lost. The
            // observer holds neither the output nor this object.
            let output = try makeOutput(ring) { [weak self] in
                guard let self else { return }
                queue.async { self.outputChanged(generation: current) }
            }
            do {
                try output.start()
            } catch {
                output.stop()
                throw error
            }
            self.output = output
            watchStream() // a rebuild after a change starts here, not in `reconcile`
            let after = backoff.succeeded(at: Date())
            log?("playback: output engine started (\(output.formatDescription))\(Self.took(since: began))\(after > 0 ? " after \(after) failed attempt(s)" : "")")
        } catch {
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
        // Paused in a stream the guest sends nothing in: as paused after one.
        guard streaming, !paused else {
            log?("playback: the Mac's output changed while no stream plays")
            stopOutput()
            return
        }
        log?("playback: the Mac's output changed; starting the engine on it again")
        teardown()
        // From here the ring keeps the stream for the next output, within its bounds for one.
        ring.outputStarts()
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
        paused = false
    }

    private func stopOutput() {
        setIdleStop(nil)
        let stopped = output != nil
        teardown()
        ring.clear()
        backoff = StartBackoff()
        if stopped { log?("playback: output engine stopped") }
    }
}

/// What the host asked for last (streaming or not), and whether a block is queued to act on it
/// (5 Nov 2026). A guest can start and stop a stream as fast as it sends SET_INTERFACE; a block per
/// event kept the queue busy long after a flood ended (each microphone start built an engine) and let
/// it grow without bound. Now an event only sets what the host wants, and a block is queued when none
/// is: whatever the host does, the queue holds one at most besides the one running, and that one acts
/// on the latest.
final class StreamRequests: @unchecked Sendable {
    /// Blocks queued in all, and the most queued or running at once (tests).
    struct Statistics: Sendable {
        var queued = 0
        var mostAtOnce = 0
    }

    private let lock = NSLock()
    private var wanted = false
    private var blockQueued = false
    private var atOnce = 0
    private var counts = Statistics()

    /// Sets what the host wants (nil: as it is); returns whether to queue a block, which calls `take`
    /// and, when it's done, `ran`.
    func request(_ wanted: Bool?) -> Bool {
        lock.withLock {
            if let wanted { self.wanted = wanted }
            guard !blockQueued else { return false }
            blockQueued = true
            atOnce += 1
            counts.queued += 1
            counts.mostAtOnce = max(counts.mostAtOnce, atOnce)
            return true
        }
    }

    /// In the queued block: what the host wants now. A request from here on queues another block.
    func take() -> Bool {
        lock.withLock {
            blockQueued = false
            return wanted
        }
    }

    /// The queued block is done.
    func ran() {
        lock.withLock { atOnce -= 1 }
    }

    var statistics: Statistics { lock.withLock { counts } }
}

/// Where engines that are let go stop (5 Nov 2026): a CoreAudioPlayback or CoreAudioCapture can be
/// freed on the main thread, and an engine's stop takes 25–40 ms there, more on Bluetooth.
private let engineTeardownQueue = DispatchQueue(label: "usb-audio.coreaudio.teardown", qos: .utility)

/// Stops an engine (`stop`) on a queue of its own, holding it until then.
func retireEngine(_ stop: @escaping @Sendable () -> Void) {
    engineTeardownQueue.async(execute: stop)
}

/// An output as CoreAudioPlayback drives it: an AVAudioEngine in use, a stand-in in tests.
protocol PlaybackOutput: AnyObject, Sendable {
    var isRunning: Bool { get }
    var formatDescription: String { get }
    /// Starts playing what the ring holds; takes as long as the Mac's audio hardware does to start,
    /// up to half a second.
    func start() throws
    /// Stops playing, and the Mac's audio hardware with it, keeping what `start()` needs to play
    /// again. Still observing: a change of the Mac's output is still said.
    func pause()
    /// Whether the Mac's output is one that costs nothing to keep started while nothing plays: built
    /// in, or on USB, HDMI, DisplayPort or Thunderbolt; not a Bluetooth or AirPlay one.
    var isWired: Bool { get }
    /// Stops playing and observing; safe to call more than once, from any thread.
    func stop()
}

/// Builds an output reading `ring`, whose `changed` is called when the Mac's output device changes;
/// throws when it can't be built.
typealias MakePlaybackOutput = (_ ring: StereoRing, _ changed: @escaping @Sendable () -> Void) throws -> any PlaybackOutput

/// An AVAudioEngine playing a ring on the Mac's default output.
final class EnginePlaybackOutput: PlaybackOutput, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let observer: any NSObjectProtocol
    private let lock = NSLock()
    private var stopped = false

    init(ring: StereoRing, changed: @escaping @Sendable () -> Void) throws {
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
        // On macOS 27 a connection that fails throws, a failed start (5 Nov 2026): the older call
        // raises an Objective-C exception, which takes the runner down. Swift 6.4 is the first with
        // macOS 27's SDK; older ones build the older call.
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            try engine.connectNode(source, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(source, to: engine.mainMixerNode, format: format)
        }
        #else
        engine.connect(source, to: engine.mainMixerNode, format: format)
        #endif
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { _ in changed() }
    }

    deinit { stop() }

    var isRunning: Bool { engine.isRunning }
    var formatDescription: String { "\(engine.outputNode.outputFormat(forBus: 0))" }

    var isWired: Bool {
        guard let unit = engine.outputNode.audioUnit else { return false }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr else { return false }
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return Self.wiredTransports.contains(transport)
    }

    /// Not Bluetooth, Bluetooth LE or AirPlay, and not what can't be told (an aggregate or a virtual
    /// device may have a headset behind it).
    static let wiredTransports: Set<UInt32> = [
        kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeHDMI,
        kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire,
        kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeAVB,
    ]

    func start() throws { try engine.start() }

    func pause() {
        guard !lock.withLock({ stopped }) else { return }
        engine.pause()
    }

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
/// CoreAudioCapture closes it at once, on a queue of its own.
///
/// **A guest starting and stopping its recording in a loop** (5 Nov 2026): each start used to build and
/// start an engine (0.1–0.5 s) and reset the failures' pause, so the queue fell behind and grew. Now
/// the starts and stops set what the host wants and the queue acts on the last of it
/// (`StreamRequests`); the microphone opens `openSpacing` after its last opening at the soonest, and
/// a failure's pause holds across starts.
public final class CoreAudioCapture: CaptureSource, @unchecked Sendable {
    public var log: (@Sendable (String) -> Void)? {
        get { lock.withLock { logHandler } }
        set { lock.withLock { logHandler = newValue } }
    }

    /// The least time from one opening of the microphone to the next.
    static let openSpacing: TimeInterval = 0.25

    /// A second: room for the tap's 100 ms buffers and what the trim keeps around them.
    private let ring = StereoRing(capacitySeconds: 1)
    private let queue = DispatchQueue(label: "usb-audio.coreaudio.capture")
    private let makeInput: MakeCaptureInput
    private let idleClose: TimeInterval
    /// Whether the host records, as it said last; acted on by `reconcile`.
    private let requests = StreamRequests()
    // On the queue:
    private var input: (any CaptureInput)?
    /// Counts the inputs built: a change notification about an older one is stale.
    private var generation = 0
    /// Whether the host records, as `reconcile` last acted on it, and the start pauses.
    private var wanted = false
    private var backoff = StartBackoff()
    /// When the microphone was last opened, or tried.
    private var lastOpen: Date?
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
        // As for playback: nothing of this object runs on the queue any more; the microphone closes now,
        // on the engines' own queue rather than the thread that let this go.
        watchdog?.cancel()
        if let input { retireEngine { input.stop() } }
    }

    public func captureStarted() {
        request(recording: true)
    }

    public func captureStopped() {
        request(recording: false)
    }

    public func captureAudio(byteCount: Int) -> Data {
        let now = DispatchTime.now().uptimeNanoseconds
        let due: Bool = lock.withLock {
            lastAsked = now
            guard let at = retryAt, Date() >= at else { return false }
            retryAt = nil // one try; the queue says when the next is due
            return true
        }
        if due { queue.async { [self] in open() } }
        var audio = ring.readInt16(frames: byteCount / UAC1AudioDevice.bytesPerFrame, keepFrames: keepFrames,
                                   marginFrames: marginFrames, trimAboveFrames: trimAboveFrames).0
        // Exactly byteCount, as the protocol says: the reply's length is the host's.
        if audio.count < byteCount { audio.append(Data(count: byteCount - audio.count)) }
        return audio
    }

    /// Whether the microphone is open (tests).
    var isOpen: Bool { queue.sync { input != nil } }

    /// How the stream events queued their work (tests).
    var queueStatistics: StreamRequests.Statistics { requests.statistics }

    /// Waits for what the queue has to do (tests).
    func waitForQueue() {
        queue.sync {}
    }

    private func request(recording: Bool) {
        guard requests.request(recording) else { return }
        queue.async { [self] in
            reconcile()
            requests.ran()
        }
    }

    /// On the queue: acts on what the host said last. A start and a stop in between act on nothing.
    private func reconcile() {
        let recording = requests.take()
        guard recording != wanted else { return }
        wanted = recording
        if recording {
            open()
        } else {
            setRetry(at: nil)
            let wasOpen = input != nil
            teardown()
            ring.clear()
            if wasOpen { log?("capture: microphone closed") }
        }
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

    /// On the queue: when the microphone may open next, after a failure's pause (or a device change's)
    /// and `openSpacing` after its last opening.
    private var nextOpen: Date {
        max(backoff.nextTry, lastOpen.map { $0.addingTimeInterval(Self.openSpacing) } ?? .distantPast)
    }

    /// On the queue (the host started recording, or asked for audio while a start was due): opens the
    /// microphone if it may now, or has the host's first request from then on do it.
    private func open() {
        guard wanted, input == nil else { return }
        let at = nextOpen
        guard Date() >= at else {
            setRetry(at: at)
            return
        }
        startInput()
    }

    /// On the queue.
    private func startInput() {
        guard wanted, input == nil else { return }
        lastOpen = Date()
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
            setRetry(at: nextOpen)
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
            setRetry(at: nextOpen)
        }
    }

    /// The input device changed under the engine, which stopped (on the queue): the next request of the
    /// host opens it again, not before a second after the last start.
    private func inputChanged(generation changed: Int) {
        guard changed == generation, input != nil, wanted else { return }
        log?("capture: the Mac's input changed; opening it again")
        teardown()
        _ = backoff.holdOffAfterStart(seconds: 1)
        setRetry(at: nextOpen)
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
protocol CaptureInput: AnyObject, Sendable {
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
    /// The input's format, which can't be tapped or converted.
    struct NoUsableInput: Error, CustomStringConvertible {
        let description: String
    }

    private let engine: AVAudioEngine
    /// The engine's input node, kept: the engine's getter binds it to the Mac's input device through
    /// coreaudiod, synchronously, and `stop` needn't do that again (5 Nov 2026).
    private let input: AVAudioInputNode
    private let observer: any NSObjectProtocol
    private let lock = NSLock()
    private var stopped = false
    let formatDescription: String

    init(ring: StereoRing, changed: @escaping @Sendable () -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let hardware = input.inputFormat(forBus: 0)
        if let problem = Self.tapProblem(tap: (inputFormat.sampleRate, inputFormat.channelCount),
                                         hardware: (hardware.sampleRate, hardware.channelCount)) {
            throw NoUsableInput(description: "\(problem): \(inputFormat), the device's \(hardware)")
        }
        guard let writer = TapWriter(from: inputFormat, to: ring) else { throw NoUsableInput(description: "\(inputFormat)") }
        // The tap's buffers are 100 ms whatever is asked (its range is 100–400 ms); the capture trim
        // keeps one of them. On macOS 27 a tap that can't be installed throws, a failed open (5 Nov
        // 2026): the older call raises an Objective-C exception, which takes the runner down, for a
        // format that isn't the device's (the Mac's input changed since the formats were read) or a
        // second tap. Swift 6.4 is the first with macOS 27's SDK; older ones build the older call.
        #if compiler(>=6.4)
        if #available(macOS 27, *) {
            try input.installAudioTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, _ in
                writer.write(AVAudioPCMBuffer(copying: buffer))
            }
        } else {
            input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, _ in writer.write(buffer) }
        }
        #else
        input.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, _ in writer.write(buffer) }
        #endif
        self.engine = engine
        self.input = input
        formatDescription = "\(inputFormat)"
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { _ in changed() }
    }

    deinit { stop() }

    /// What keeps the input's format (`tap`) from being tapped on the device's (`hardware`), each as
    /// (sample rate, channels), or nil: both need a rate and channels, and the rates must be the same.
    /// A Mac without an input device reports 0 Hz and no channels; a device that changes between the
    /// two reads (an AirPods profile switch, a USB microphone unplugged, another rate) can report
    /// another rate. A tap of such a format raised an Objective-C exception (5 Nov 2026).
    static func tapProblem(tap: (rate: Double, channels: AVAudioChannelCount),
                           hardware: (rate: Double, channels: AVAudioChannelCount)) -> String? {
        guard tap.rate > 0, tap.channels > 0 else { return "no usable input format" }
        guard hardware.rate > 0, hardware.channels > 0 else { return "no usable input device" }
        guard tap.rate == hardware.rate else { return "the input's rate isn't the device's" }
        return nil
    }

    var isRunning: Bool { engine.isRunning }

    func start() throws { try engine.start() }

    func stop() {
        guard lock.withLock({ () -> Bool in defer { stopped = true }; return !stopped }) else { return }
        NotificationCenter.default.removeObserver(observer)
        input.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Converts the tap's buffers to 48 kHz stereo and writes them to the ring. Used by the tap's thread
/// only, a buffer at a time.
private final class TapWriter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let sourceRate: Double
    private let ring: StereoRing

    init?(from format: AVAudioFormat, to ring: StereoRing) {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(UAC1AudioDevice.sampleRate), channels: 2, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target) else { return nil }
        if format.channelCount == 1 { converter.channelMap = [0, 0] } // mono microphone to both channels
        self.converter = converter
        self.target = target
        sourceRate = format.sampleRate
        self.ring = ring
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / sourceRate) + 32
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
}
