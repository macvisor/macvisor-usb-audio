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
///   transport jitter. A URB that arrives late completes at once, and the host catches up. The lead
///   can change while a stream plays (`setLead`), and `takeArrivals()` says how the URBs have been
///   arriving against it, which is what `AdaptiveLead` goes by.
/// - `setRateAdjustment(ppm:)` lets the audio output's clock steer the timeline, so the guest follows
///   the Mac's audio hardware instead of drifting against it.
/// - **Bounded:** at most `maxQueuedURBs` URBs wait, reaching at most `maxAhead` into the future; a host
///   that submits faster than real time (Windows keeps about two 10 ms URBs in flight) is refused, so it
///   can't make the pacer hold an unbounded amount of audio.
public final class EndpointPacer: @unchecked Sendable {
    public struct Statistics: Equatable, Sendable {
        /// URBs that arrived after their audio was due.
        public var lateURBs = 0
        public var completedURBs = 0
        public var timelineRestarts = 0
        /// URBs `enqueue` refused (past the queue's bounds).
        public var refusedURBs = 0
        /// The latest a URB arrived after its audio was due, in seconds.
        public var worstLateness: TimeInterval = 0
        /// The least audio that was still queued ahead when a URB arrived on time, in seconds, once
        /// a stream had run a second; nil when none arrived so.
        public var leastSlack: TimeInterval?
    }

    /// How a stream's URBs arrived since the last `takeArrivals()`.
    public struct Arrivals: Equatable, Sendable {
        /// URBs that arrived after their audio was due, and the latest of them, in seconds.
        public var late = 0
        public var worstLateness: TimeInterval = 0
        /// The least audio that was still queued ahead when a URB arrived, in seconds, once a stream
        /// had its lead (not in its first second, when the queue is still filling); nil when no URB
        /// arrived so.
        public var leastSlack: TimeInterval?

        public init(late: Int = 0, worstLateness: TimeInterval = 0, leastSlack: TimeInterval? = nil) {
            self.late = late
            self.worstLateness = worstLateness
            self.leastSlack = leastSlack
        }
    }

    private struct Job {
        let id: UInt32
        let due: UInt64
        let work: @Sendable () -> Void
    }

    /// The most URBs that may wait at once, and how far ahead of now the queued audio may reach.
    public let maxQueuedURBs: Int
    public let maxAhead: TimeInterval

    private let nominalRate: Double
    private var lead: UInt64
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
    private var arrivals = Arrivals()

    /// - Parameters:
    ///   - framesPerSecond: the stream's nominal sample rate.
    ///   - lead: how early URBs complete (playback); zero for capture.
    ///   - idleReset: a gap after the last queued audio that starts a new timeline.
    ///   - maxQueuedURBs, maxAhead: the bounds above which `enqueue` refuses a URB.
    public init(framesPerSecond: Double = 48000, lead: TimeInterval = 0, idleReset: TimeInterval = 0.2,
                maxQueuedURBs: Int = 64, maxAhead: TimeInterval = 2,
                clock: PacerClock = DispatchClock(), label: String = "usb-audio.pacer") {
        nominalRate = framesPerSecond
        rate = framesPerSecond
        self.maxQueuedURBs = maxQueuedURBs
        self.maxAhead = maxAhead
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

    /// A stream starts: its first URB begins a timeline of its own, however soon it comes after the
    /// last stream's audio (within the idle gap it counted as a URB of that stream, late by the
    /// pause between them). URBs still waiting keep their times.
    public func newStream() {
        lock.lock()
        defer { lock.unlock() }
        anchorTime = nil
        anchorFrames = 0
        frames = 0
    }

    /// How URBs arrived since this was last asked; asking starts the count over.
    public func takeArrivals() -> Arrivals {
        lock.lock()
        defer { lock.unlock() }
        defer { arrivals = Arrivals() }
        return arrivals
    }

    /// Changes how early URBs complete, from the next one queued on: the ones waiting keep their
    /// times, and still complete in order.
    public func setLead(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        lead = UInt64(max(0, min(seconds, maxAhead)) * 1e9)
    }

    /// Queues a URB carrying `frameCount` frames. `work` runs once, after every earlier URB's, when the
    /// URB is due. It runs on the pacer's queue. False, and nothing queued, when the URB would go past
    /// `maxQueuedURBs` or reach more than `maxAhead` into the future.
    @discardableResult
    public func enqueue(id: UInt32, frameCount: Int, work: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now()
        // A URB longer than the whole look-ahead never fits; refusing it first keeps the frame count
        // (the host's to choose) out of the timeline's arithmetic.
        guard jobs.count < maxQueuedURBs, frameCount >= 0, Double(frameCount) <= maxAhead * rate else {
            stats.refusedURBs += 1
            return false
        }
        let restarts = anchorTime == nil || now > time(ofFrame: frames) &+ idleReset
        // Where this URB's audio would end, on the current timeline or a new one.
        let wouldEnd = restarts ? now &+ duration(ofFrames: Int64(frameCount)) : time(ofFrame: frames + Int64(frameCount))
        guard wouldEnd <= now &+ UInt64(maxAhead * 1e9) else { stats.refusedURBs += 1; return false }
        if restarts {
            if anchorTime != nil {
                stats.timelineRestarts += 1
                // In the middle of a stream (a new one starts with no timeline, `newStream`), a gap
                // this long is the guest stalling, the latest a URB can be: said as late, unless it
                // is so long that the guest was paused rather than behind.
                let by = Double(now - time(ofFrame: frames)) / 1e9
                if frames > 0, by < Self.pauseGap {
                    stats.lateURBs += 1
                    stats.worstLateness = max(stats.worstLateness, by)
                    arrivals.late += 1
                    arrivals.worstLateness = max(arrivals.worstLateness, by)
                }
            }
            anchorTime = now
            anchorFrames = 0
            frames = 0
        }
        if frames > 0 {
            // Where the audio queued so far ends: this URB's audio is due from then on.
            let queuedEnd = time(ofFrame: frames)
            if now > queuedEnd &+ lateTolerance {
                let by = Double(now - queuedEnd) / 1e9
                stats.lateURBs += 1
                stats.worstLateness = max(stats.worstLateness, by)
                arrivals.late += 1
                arrivals.worstLateness = max(arrivals.worstLateness, by)
            } else if Double(frames) >= Self.settling * nominalRate {
                let slack = queuedEnd > now ? Double(queuedEnd - now) / 1e9 : 0
                arrivals.leastSlack = min(arrivals.leastSlack ?? slack, slack)
                stats.leastSlack = min(stats.leastSlack ?? slack, slack)
            }
        }
        frames += Int64(frameCount)
        let end = time(ofFrame: frames)
        let due = end > lead ? end - lead : 0
        jobs.append(Job(id: id, due: due, work: work))
        if !armed { arm() }
        return true
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

    /// Runs `work` on the pacer's queue once the job running now, if any, has finished: an answer about
    /// a URB that has left the queue goes out after that URB's own reply.
    public func afterRunningJob(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
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

    /// How much of a timeline goes by before its URBs' slack counts: at first the queue is still
    /// filling to the lead.
    private static let settling: TimeInterval = 1
    /// A gap in a stream this long or longer is a guest that was paused, not one that is late.
    private static let pauseGap: TimeInterval = 2

    // MARK: -

    /// When frame `n` of the current timeline is due (the lock is held).
    private func time(ofFrame n: Int64) -> UInt64 {
        guard let anchor = anchorTime else { return 0 }
        return anchor &+ duration(ofFrames: n - anchorFrames)
    }

    /// How long `n` frames last at the current rate, in nanoseconds; clamped, so no frame count (the
    /// host's to choose) can trap the conversion.
    private func duration(ofFrames n: Int64) -> UInt64 {
        let nanoseconds = max(0, Double(n)) / rate * 1e9
        return nanoseconds.isFinite ? UInt64(min(nanoseconds, Double(UInt64.max >> 2))) : UInt64.max >> 2
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
