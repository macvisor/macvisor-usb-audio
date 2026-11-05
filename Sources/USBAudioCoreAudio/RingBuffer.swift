import Foundation
import os

/// A fixed-capacity circular buffer of interleaved stereo frames. Writers that would overflow it drop
/// the oldest audio, so latency stays bounded.
///
/// A playback ring has `Bounds` too: it holds its level near a target, the server's lead, whatever the
/// output engine and the guest do (see `CoreAudioPlayback`).
final class StereoRing: @unchecked Sendable {
    /// How a playback ring holds its level near `target`, in frames.
    struct Bounds: Sendable {
        /// The level the ring holds: the server's lead, which the guest keeps queued.
        var target: Int
        /// A write past it drops the oldest audio down to `target`, so the latency never exceeds it
        /// (an output that is starting, or failed to, reads nothing).
        var ceiling: Int
        /// A window of reads whose level averages more than `target + excess` drops what's above
        /// `target` (the output missed cycles, say, while the guest's URBs kept coming).
        var excess: Int
        /// A stall: the output plays silence, then the late URBs catch up all at once, and the ring
        /// would keep the stall as latency. After silence, a window averaging more than
        /// `target + stallExcess` drops what's above `target`, up to the silence played. Never more:
        /// silence for want of audio (before a stream's first URB, between streams) owes nothing.
        var stallExcess: Int
        /// The frames read per window: many output cycles (512 frames each) and URBs (480 each), so
        /// the average doesn't depend on where in their cycles a read falls.
        var window: Int

        /// The server's 40 ms lead, never more than 100 ms; a stall leaves at most 5 ms behind it
        /// after a window or two (a quarter of a second each).
        static let playback = Bounds(target: frames(ms: 40), ceiling: frames(ms: 100), excess: frames(ms: 20),
                                     stallExcess: frames(ms: 5), window: frames(ms: 250))

        static func frames(ms: Int) -> Int { 48 * ms }
    }

    /// What a playback ring dropped to hold its level (tests, diagnostics).
    struct Statistics: Equatable, Sendable {
        /// Drops of `Bounds.excess` and `Bounds.stallExcess`, and the frames they took.
        var excessTrims = 0
        var excessFrames = 0
        /// Drops at `Bounds.ceiling`, and at an output's start.
        var ceilingTrims = 0
        var startTrims = 0
    }

    /// A lock with a stable address: an `os_unfair_lock` stored in the object and passed with `&`
    /// may be moved by Swift.
    private let lock = OSAllocatedUnfairLock()
    private var samples: [Float]
    private var readIndex = 0
    private var count = 0 // samples (two per frame)
    /// The longest single write since `clear()`, in frames: an input tap's buffer.
    private var largestWrite = 0
    private let bounds: Bounds?
    private var trimPending = false
    /// The current window: the sum of each read's level before plus after it, weighted by its frames;
    /// and the frames read.
    private var windowSum = 0
    private var windowFrames = 0
    /// Silence the output played since the level was last at or below the target, or a drop.
    private var silence = 0
    private var stats = Statistics()

    init(capacitySeconds: Double, sampleRate: Double = 48000, bounds: Bounds? = nil) {
        samples = [Float](repeating: 0, count: Int(capacitySeconds * sampleRate) * 2)
        self.bounds = bounds
    }

    var bufferedFrames: Int {
        lock.withLockUnchecked { count / 2 }
    }

    var statistics: Statistics {
        lock.withLockUnchecked { stats }
    }

    func clear() {
        lock.withLockUnchecked {
            readIndex = 0
            count = 0
            largestWrite = 0
            trimPending = false
            windowSum = 0
            windowFrames = 0
            silence = 0
        }
    }

    /// The next read first drops all but the newest `Bounds.target` frames: an output starts with the
    /// audio that is due now, not with what piled up while it started.
    func trimOnNextRead() {
        lock.withLockUnchecked { trimPending = true }
    }

    /// Appends interleaved 16-bit samples.
    func write(int16 pcm: Data) {
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            lock.withLockUnchecked {
                let capacity = samples.count
                for v in src {
                    if count == capacity { readIndex = (readIndex + 1) % capacity; count -= 1 } // drop the oldest
                    samples[(readIndex + count) % capacity] = Float(Int16(littleEndian: v)) / 32768
                    count += 1
                }
                largestWrite = max(largestWrite, src.count / 2)
                if let bounds, count / 2 > bounds.ceiling {
                    drop(frames: count / 2 - bounds.target)
                    stats.ceilingTrims += 1
                }
            }
        }
    }

    /// Appends interleaved float samples.
    func write(float src: UnsafeBufferPointer<Float>) {
        lock.withLockUnchecked {
            let capacity = samples.count
            for v in src {
                if count == capacity { readIndex = (readIndex + 1) % capacity; count -= 1 }
                samples[(readIndex + count) % capacity] = v
                count += 1
            }
            largestWrite = max(largestWrite, src.count / 2)
        }
    }

    /// Reads up to `frames` frames into separate left and right channels; returns the frames read.
    func read(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Int {
        lock.withLockUnchecked {
            if trimPending, let bounds {
                trimPending = false
                if count / 2 > bounds.target {
                    drop(frames: count / 2 - bounds.target)
                    stats.startTrims += 1
                }
                windowSum = 0
                windowFrames = 0
                silence = 0
            }
            let before = count / 2
            let n = min(frames, before)
            let capacity = samples.count
            for i in 0 ..< n {
                left[i] = samples[readIndex]
                right[i] = samples[(readIndex + 1) % capacity]
                readIndex = (readIndex + 2) % capacity
            }
            count -= n * 2
            if let bounds { measure(before: before, after: before - n, frames: frames, bounds: bounds) }
            return n
        }
    }

    /// Capture: reads up to `frames` frames as interleaved 16-bit samples, first trimming a ring that
    /// holds more than its source needs (a free-running microphone's clock runs a little fast, and a
    /// host that stops asking leaves audio behind). A trim keeps `keepFrames`, and at least one of the
    /// source's chunks plus `marginFrames`: an input tap delivers 100 ms at a time, and trimming below
    /// that gave the host tens of milliseconds of silence before the next chunk. It trims only above
    /// `trimAboveFrames`, and above what it keeps plus another chunk and the margin.
    func readInt16(frames: Int, keepFrames: Int, marginFrames: Int, trimAboveFrames: Int) -> (Data, Int) {
        lock.withLockUnchecked {
            let keep = max(keepFrames, largestWrite + marginFrames)
            if count / 2 > max(trimAboveFrames, keep + largestWrite + marginFrames) {
                drop(frames: count / 2 - keep)
            }
            let capacity = samples.count
            let n = min(frames, count / 2)
            var out = Data(count: frames * 4)
            out.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: Int16.self)
                for i in 0 ..< n * 2 {
                    let v = max(-1, min(1, samples[(readIndex + i) % capacity]))
                    dst[i] = Int16(v * 32767).littleEndian
                }
            }
            readIndex = (readIndex + n * 2) % capacity
            count -= n * 2
            return (out, n)
        }
    }

    // MARK: - With the lock held

    /// Drops the oldest `frames` frames (at most what the ring holds).
    private func drop(frames: Int) {
        let n = max(0, min(frames, count / 2))
        readIndex = (readIndex + n * 2) % samples.count
        count -= n * 2
    }

    /// Adds a read to the window; at the window's end, drops what sits above the target without
    /// need (`Bounds.excess`, `Bounds.stallExcess`). The level falls by a read and rises by a URB at
    /// a time; the midpoint of before and after a read, averaged over the window, is the level the
    /// server's steering holds at its lead.
    private func measure(before: Int, after: Int, frames: Int, bounds: Bounds) {
        silence += frames - (before - after)
        windowSum += (before + after) * frames
        windowFrames += frames
        guard windowFrames >= bounds.window else { return }
        let average = windowSum / (2 * windowFrames)
        windowSum = 0
        windowFrames = 0
        var excess = 0
        if average > bounds.target + bounds.excess {
            excess = average - bounds.target
        } else if silence > 0, average > bounds.target + bounds.stallExcess {
            excess = min(average - bounds.target, silence)
        }
        if excess > 0 || average <= bounds.target { silence = 0 }
        guard excess > 0 else { return }
        let dropped = min(excess, count / 2)
        drop(frames: dropped)
        stats.excessTrims += 1
        stats.excessFrames += dropped
    }
}
