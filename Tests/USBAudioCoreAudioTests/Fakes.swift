import Dispatch
import Foundation
@testable import USBAudioCoreAudio
@testable import USBAudioDevice

/// A value shared between the test and the queues it drives.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T { lock.withLock { stored } }

    func mutate<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

/// A clock the test moves by hand. Scheduled work runs, in deadline order, as time passes it.
final class SimulatedClock: PacerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 1_000_000_000
    private var pending: [(deadline: UInt64, order: Int, queue: DispatchQueue, work: @Sendable () -> Void)] = []
    private var counter = 0

    func now() -> UInt64 { lock.withLock { time } }

    func schedule(at deadline: UInt64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        lock.withLock {
            counter += 1
            pending.append((deadline, counter, queue, work))
        }
    }

    /// Moves time forward to `target`, running everything that falls due on its queue.
    func advance(to target: UInt64) {
        while true {
            lock.lock()
            guard let i = pending.indices.filter({ pending[$0].deadline <= target })
                .min(by: { (pending[$0].deadline, pending[$0].order) < (pending[$1].deadline, pending[$1].order) }) else {
                time = max(time, target)
                lock.unlock()
                return
            }
            let job = pending.remove(at: i)
            time = max(time, job.deadline)
            lock.unlock()
            job.queue.sync { job.work() }
        }
    }
}

/// Stands in for an AVAudioEngine output. Its start waits for `gate` (an engine's start takes 0.43 s
/// on a Mac's default 8-channel output, 5 Nov 2026), and the test pulls from the ring as the output's
/// render cycle would.
final class FakeOutput: PlaybackOutput, @unchecked Sendable {
    let ring: StereoRing
    let changed: @Sendable () -> Void
    private let gate: DispatchSemaphore?
    private let changeWhileStarting: Bool
    private let lock = NSLock()
    private var running = false
    private var stops = 0

    init(ring: StereoRing, changed: @escaping @Sendable () -> Void, gate: DispatchSemaphore?, changeWhileStarting: Bool) {
        self.ring = ring
        self.changed = changed
        self.gate = gate
        self.changeWhileStarting = changeWhileStarting
    }

    var isRunning: Bool { lock.withLock { running } }
    var stopCount: Int { lock.withLock { stops } }
    var formatDescription: String { "stand-in" }

    func start() throws {
        gate?.wait()
        lock.withLock { running = true }
        if changeWhileStarting { deviceChanged() }
    }

    func stop() {
        lock.withLock {
            running = false
            stops += 1
        }
    }

    /// The output device changed: the engine stops and says so.
    func deviceChanged() {
        lock.withLock { running = false }
        changed()
    }

    /// The engine stopped without a word.
    func stopSilently() {
        lock.withLock { running = false }
    }

    /// One render cycle of `frames`: how many the ring had, and the first one's tag (`tagged`).
    func pull(_ frames: Int) -> (count: Int, first: Int?) {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        let n = ring.read(frames: frames, left: &left, right: &right)
        guard n > 0 else { return (0, nil) }
        return (n, Int((left[0] * 32768).rounded()) | Int((right[0] * 32768).rounded()) << 15)
    }
}

/// Builds `FakeOutput`s and remembers them.
final class FakeOutputs: @unchecked Sendable {
    private let lock = NSLock()
    private var built: [FakeOutput] = []
    /// Each start waits for this, when set.
    var gate: DispatchSemaphore?
    var changeWhileStarting = false

    func make(_ ring: StereoRing, _ changed: @escaping @Sendable () -> Void) -> any PlaybackOutput {
        let output = FakeOutput(ring: ring, changed: changed, gate: gate, changeWhileStarting: changeWhileStarting)
        lock.withLock { built.append(output) }
        return output
    }

    var all: [FakeOutput] { lock.withLock { built } }
}

/// Stands in for an AVAudioEngine input.
final class FakeInput: CaptureInput, @unchecked Sendable {
    let ring: StereoRing
    let changed: @Sendable () -> Void
    private let fails: Bool
    private let lock = NSLock()
    private var running = false
    private var stops = 0

    init(ring: StereoRing, changed: @escaping @Sendable () -> Void, fails: Bool) {
        self.ring = ring
        self.changed = changed
        self.fails = fails
    }

    struct Failure: Error {}

    var isRunning: Bool { lock.withLock { running } }
    var stopCount: Int { lock.withLock { stops } }
    var formatDescription: String { "stand-in" }

    func start() throws {
        if fails { throw Failure() }
        lock.withLock { running = true }
    }

    func stop() {
        lock.withLock {
            running = false
            stops += 1
        }
    }
}

/// Builds `FakeInput`s and remembers them.
final class FakeInputs: @unchecked Sendable {
    private let lock = NSLock()
    private var built: [FakeInput] = []
    /// Starts fail while set.
    var fail = false

    func make(_ ring: StereoRing, _ changed: @escaping @Sendable () -> Void) throws -> any CaptureInput {
        let input = FakeInput(ring: ring, changed: changed, fails: lock.withLock { fail })
        lock.withLock { built.append(input) }
        return input
    }

    var all: [FakeInput] { lock.withLock { built } }
}

/// 16-bit stereo PCM whose frames carry their own index (`first` onwards): the left sample has its
/// low 15 bits, the right the next 15, so a read tells which frame came out (`FakeOutput.pull`).
func tagged(first: Int, frames: Int) -> Data {
    var d = Data(count: frames * 4)
    d.withUnsafeMutableBytes { raw in
        let s = raw.bindMemory(to: Int16.self)
        for i in 0 ..< frames {
            let f = first + i
            s[2 * i] = Int16(f & 0x7FFF).littleEndian
            s[2 * i + 1] = Int16((f >> 15) & 0x7FFF).littleEndian
        }
    }
    return d
}

/// Polls `condition` for up to `seconds`.
func eventually(within seconds: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
