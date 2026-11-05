import Dispatch
import Foundation

/// A monotonic clock that can run work at a time. `DispatchClock` in use; tests drive a manual one.
public protocol PacerClock: Sendable {
    /// Nanoseconds on a monotonic timeline.
    func now() -> UInt64
    /// Runs `work` on `queue` at `deadline`, or at once if it has passed.
    func schedule(at deadline: UInt64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void)
}

public struct DispatchClock: PacerClock {
    public init() {}
    public func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    /// A strict one-shot timer with no leeway: `asyncAfter`'s default leeway lets the system coalesce
    /// timers, which made URBs complete tens of milliseconds late.
    public func schedule(at deadline: UInt64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
        // The handler keeps the timer alive until it fires; cancelling releases both.
        timer.setEventHandler {
            work()
            timer.cancel()
        }
        timer.resume()
    }
}

/// Completes one isochronous endpoint's URBs **strictly in submission order**, each when its audio is
/// due on a fixed timeline, so the stream runs at the nominal rate however the URBs arrive.
///
/// - Windows keeps only about two 10 ms URBs in flight per stream. A pacer that restarted its timeline
///   whenever a URB arrived late would run slow (0.6% in a VM, 20% with 0–15 ms of jitter); this one
///   never does, short of an idle gap (`idleReset`), which starts a new timeline.
/// - Playback URBs complete `lead` early: the host keeps that much audio queued, which absorbs
///   transport jitter. A URB that arrives late completes at once, and the host catches up.
/// - `setRateAdjustment(ppm:)` lets the audio output's clock steer the timeline, so the guest follows
///   the Mac's audio hardware instead of drifting against it.
public final class EndpointPacer: @unchecked Sendable {
    public struct Statistics: Equatable, Sendable {
        /// URBs that arrived after their audio was due.
        public var lateURBs = 0
        public var completedURBs = 0
        public var timelineRestarts = 0
    }

    private struct Job {
        let id: UInt32
        let due: UInt64
        let work: @Sendable () -> Void
    }

    private let nominalRate: Double
    private let lead: UInt64
    private let idleReset: UInt64
    private let lateTolerance: UInt64
    private let clock: PacerClock
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var anchorTime: UInt64?
    private var anchorFrames: Int64 = 0
    private var frames: Int64 = 0
    private var rate: Double
    private var jobs: [Job] = []
    private var armed = false
    private var stats = Statistics()

    /// - Parameters:
    ///   - framesPerSecond: the stream's nominal sample rate.
    ///   - lead: how early URBs complete (playback); zero for capture.
    ///   - idleReset: a gap after the last queued audio that starts a new timeline.
    public init(framesPerSecond: Double = 48000, lead: TimeInterval = 0, idleReset: TimeInterval = 0.2,
                clock: PacerClock = DispatchClock(), label: String = "usb-audio.pacer") {
        nominalRate = framesPerSecond
        rate = framesPerSecond
        self.lead = UInt64(lead * 1e9)
        self.idleReset = UInt64(idleReset * 1e9)
        lateTolerance = 5_000_000
        self.clock = clock
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    public var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Queues a URB carrying `frameCount` frames. `work` runs once, after every earlier URB's, when the
    /// URB is due. It runs on the pacer's queue.
    public func enqueue(id: UInt32, frameCount: Int, work: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now()
        if anchorTime == nil || now > time(ofFrame: frames) &+ idleReset {
            if anchorTime != nil { stats.timelineRestarts += 1 }
            anchorTime = now
            anchorFrames = 0
            frames = 0
        }
        if frames > 0, now > time(ofFrame: frames) &+ lateTolerance { stats.lateURBs += 1 }
        frames += Int64(frameCount)
        let end = time(ofFrame: frames)
        let due = end > lead ? end - lead : 0
        jobs.append(Job(id: id, due: due, work: work))
        if !armed { arm() }
    }

    /// Removes a URB that hasn't completed yet. False if it already ran, is running, or is unknown.
    @discardableResult
    public func cancel(id: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return false }
        jobs.remove(at: i)
        return true
    }

    /// Drops every queued URB without running it.
    public func cancelAll() {
        lock.lock()
        jobs.removeAll()
        lock.unlock()
    }

    /// Steers the timeline: positive values make URBs complete faster. Applies from the current
    /// position on; a few hundred ppm is plenty for clock drift.
    public func setRateAdjustment(ppm: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let t = anchorTime {
            anchorTime = time(ofFrame: frames)
            anchorFrames = frames
            _ = t
        }
        rate = nominalRate * (1 + ppm / 1_000_000)
    }

    // MARK: -

    /// When frame `n` of the current timeline is due (the lock is held).
    private func time(ofFrame n: Int64) -> UInt64 {
        guard let anchor = anchorTime else { return 0 }
        return anchor &+ UInt64(max(0, Double(n - anchorFrames)) / rate * 1e9)
    }

    /// Arms a timer for the head job (the lock is held).
    private func arm() {
        guard let head = jobs.first else { armed = false; return }
        armed = true
        clock.schedule(at: head.due, on: queue) { [weak self] in self?.fire() }
    }

    private func fire() {
        lock.lock()
        guard let head = jobs.first else { armed = false; lock.unlock(); return }
        if head.due > clock.now() {
            // The job this timer was armed for was cancelled; wait for the new head.
            arm()
            lock.unlock()
            return
        }
        jobs.removeFirst()
        stats.completedURBs += 1
        lock.unlock()
        head.work()
        lock.lock()
        arm()
        lock.unlock()
    }
}
