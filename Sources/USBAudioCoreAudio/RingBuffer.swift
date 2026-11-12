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
        /// A write past it is a rush: more than the ring should hold, all at once (an output that is
        /// starting, or failed to, reads nothing; a guest that stalled sends its late audio together).
        /// With `rushKeep` it is held for the server to play down; without, the oldest audio is
        /// dropped down to `target`.
        var ceiling: Int
        /// A window of reads whose level averages more than `target + excess` has too much (the
        /// output missed cycles, say, while the guest's URBs kept coming): held to be played down
        /// with `rushKeep`, else what's above `target` is dropped.
        var excess: Int
        /// A stall: the output plays silence, then the late URBs catch up all at once, and the ring
        /// would keep the stall as latency. After silence, a window averaging more than
        /// `target + stallExcess` has what's above `target` played down (`rushKeep`) or dropped, up
        /// to the silence played. Never more: silence for want of audio (before a stream's first
        /// URB, between streams) owes nothing.
        var stallExcess: Int
        /// The frames read per window: many output cycles (512 frames each) and URBs (480 each), so
        /// the average doesn't depend on where in their cycles a read falls.
        var window: Int
        /// An output that starts plays the stream from where it began, not from where it is by then:
        /// what the ring keeps for it above `target` while it starts (the Mac's audio hardware takes
        /// about half a second), older audio going first. Zero: the newest `target` only.
        var startKeep = 0
        /// How long the ring may hold more than `target + excess` after such a start, while the
        /// server's steering plays it down (`PlaybackSteering`), before what's above counts as too
        /// much after all.
        var startHold = 0
        /// Audio that comes in a rush in the middle of a stream (a guest that sent nothing for a
        /// moment and then all of it at once, an output that missed cycles) is played, not dropped:
        /// what the ring keeps of it above `target`, for the server's steering to play down as it
        /// does a late start's beginning, within `startHold`. More than this goes, the oldest
        /// first. Zero: what is above `target` is dropped, as it was before 12 Nov 2026 (a gap was
        /// then followed by a skip of its length: 70 ms of a sign-in sound, in a Windows guest
        /// that was late in the stream's first moments).
        var rushKeep = 0

        /// The server's 40 ms lead; past 100 ms the ring is holding a rush, a quarter of a second of
        /// it at the most, which the steering plays down in ten times its length. A stall leaves at
        /// most 5 ms behind it once that is done. An output that starts has up to three quarters of
        /// a second of the stream's beginning. Either has half a minute to be played down.
        static let playback = Bounds(target: frames(ms: 40), ceiling: frames(ms: 100), excess: frames(ms: 20),
                                     stallExcess: frames(ms: 5), window: frames(ms: 250),
                                     startKeep: frames(ms: 750), startHold: frames(ms: 30000),
                                     rushKeep: frames(ms: 250))

        static func frames(ms: Int) -> Int { 48 * ms }
    }

    /// What a playback ring dropped to hold its level (tests, diagnostics).
    struct Statistics: Equatable, Sendable {
        /// Drops of `Bounds.excess` and `Bounds.stallExcess`, and the frames they took.
        var excessTrims = 0
        var excessFrames = 0
        /// Drops at `Bounds.ceiling`, and at an output's start (what was older than it keeps).
        var ceilingTrims = 0
        var startTrims = 0
        /// Outputs that started with more than the target and `excess`, for the steering to play down.
        var heldStarts = 0
        /// Rushes in the middle of a stream kept for the steering to play down (`Bounds.rushKeep`).
        var heldRushes = 0
        /// The frames the drops at `Bounds.ceiling` and at an output's start took.
        var trimmedFrames = 0
        /// Gaps: times the output ran out of audio in the middle of a stream (it played silence, and
        /// more audio came after it), and the silence they came to, in frames. Silence before a
        /// stream's first audio and after its last isn't one (`streamEnded()`), nor is silence of
        /// two seconds or more.
        var gaps = 0
        var gapFrames = 0
    }

    /// A lock with a stable address: an `os_unfair_lock` stored in the object and passed with `&`
    /// may be moved by Swift.
    private let lock = OSAllocatedUnfairLock()
    private var samples: [Float]
    private var readIndex = 0
    private var count = 0 // samples (two per frame)
    /// The longest single write since `clear()`, in frames: an input tap's buffer.
    private var largestWrite = 0
    private var bounds: Bounds?
    private var trimPending = false
    /// The current window: the sum of each read's level before plus after it, weighted by its frames;
    /// and the frames read.
    private var windowSum = 0
    private var windowFrames = 0
    /// Silence the output played in the middle of a stream since the level was last at or below the
    /// target with audio to play, or a drop; and how much of it in the current window.
    private var silence = 0
    private var windowSilence = 0
    /// Whether the stream has had audio (since `streamEnded()`), and the silence the output has played
    /// since its last audio: a gap, once more audio comes.
    private var fed = false
    private var silenceSinceAudio = 0
    /// After the target came down: the frames still to be read before the ring is held to it, and
    /// the ceiling it has from then on.
    private var settling = 0
    private var settledCeiling: Int?
    /// After an output started with the stream's beginning: the frames read since, while the ring
    /// may hold more than its target (`Bounds.startHold`); nil otherwise.
    private var heldFrames: Int?
    /// What the held ring had above its target at the output's first read or as a rush came, or in
    /// its last window.
    private var heldAbove = 0
    /// The most the ring keeps while it is held, in frames: the target and `Bounds.startKeep` after
    /// an output's start, the target and `Bounds.rushKeep` after a rush.
    private var heldCap = 0
    /// Windows read without silence since the last one that had some (`silenceExpiry`).
    private var quietWindows = 0
    /// A stall's late audio comes within a window or two of its end: silence older than this many
    /// windows without more is owed nothing (a stall past the pacer's idle gap is never caught up
    /// with, and its silence stayed to be taken out of the level's own ripple later).
    private static let silenceExpiry = 4
    /// Silence in a stream this long or longer isn't the output running out of audio that was on
    /// its way: the guest had none to send (two seconds, the pacer's measure of a pause too).
    private static let longestGap = 96000
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
            fed = false
            silenceSinceAudio = 0
            heldFrames = nil
            settling = 0
            settledCeiling = nil
            windowSilence = 0
            quietWindows = 0
        }
    }

    /// What the ring holds above its target for the server to play down, in frames: an output that
    /// started late with the stream's beginning, or a rush in the middle of a stream. What it had at
    /// the output's first read or as the rush came, then each measuring window's average (the level
    /// itself ripples by a URB, and a look at it falls anywhere in one). Zero once that is played
    /// down, or when nothing is held.
    var heldExcess: Int {
        lock.withLockUnchecked { heldFrames != nil ? heldAbove : 0 }
    }

    /// The level a playback ring holds changes (the server's lead did): the ceiling keeps its
    /// distance above it. Nothing is dropped for it: the level follows as the guest's audio does, so
    /// while a lower target is new the ring still holds the old level, and it is given the time that
    /// takes to play, and a window more, before anything above the new one counts as too much.
    func setTarget(frames: Int) {
        lock.withLockUnchecked {
            guard var changed = bounds, frames > 0, frames != changed.target else { return }
            let gap = (settledCeiling ?? changed.ceiling) - changed.target
            if frames < changed.target {
                settling = (changed.target - frames) + changed.window
                settledCeiling = frames + gap
            } else {
                settling = 0
                settledCeiling = nil
                changed.ceiling = frames + gap
            }
            changed.target = frames
            bounds = changed
            // The window so far was measured against the old target.
            windowSum = 0
            windowFrames = 0
        }
    }

    /// The stream ended: the silence the output plays from here on is no gap.
    func streamEnded() {
        lock.withLockUnchecked {
            fed = false
            silenceSinceAudio = 0
            silence = 0
            windowSilence = 0
        }
    }

    /// An output is starting. Until its first read the ring keeps the stream from its beginning, up to
    /// `Bounds.startKeep` above the target, so the output starts with what the guest played while it
    /// started rather than without it; the server's steering then plays the extra down
    /// (`PlaybackSteering`), and the ring holds it meanwhile (`Bounds.startHold`).
    func outputStarts() {
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
                if bounds != nil, !src.isEmpty {
                    // Seconds of it is a stream the guest left open with nothing to play (8.6 s
                    // before a video's sound, in a stream something else had opened), not a gap.
                    if fed, silenceSinceAudio > 0, silenceSinceAudio < Self.longestGap {
                        stats.gaps += 1
                        stats.gapFrames += silenceSinceAudio
                    }
                    fed = true
                    silenceSinceAudio = 0
                }
                if let bounds {
                    if trimPending {
                        // An output is starting: the stream's beginning is kept for it, the oldest
                        // of more than that going first.
                        let most = bounds.target + bounds.startKeep
                        if count / 2 > most + bounds.excess {
                            let over = count / 2 - most
                            drop(frames: over)
                            stats.startTrims += 1
                            stats.trimmedFrames += over
                        }
                    } else if heldFrames != nil {
                        // Held for the steering to play down: no more than it was held with.
                        if count / 2 > heldCap + bounds.excess {
                            let over = count / 2 - heldCap
                            drop(frames: over)
                            stats.ceilingTrims += 1
                            stats.trimmedFrames += over
                        }
                    } else if count / 2 > bounds.ceiling {
                        if bounds.rushKeep > 0, bounds.startHold > 0 {
                            // A rush: kept, and said to the server (`heldExcess`), which has the
                            // guest send a little slower until it is played.
                            hold(above: bounds.target, keeping: bounds.rushKeep)
                        } else {
                            let over = count / 2 - bounds.target
                            drop(frames: over)
                            stats.ceilingTrims += 1
                            stats.trimmedFrames += over
                        }
                    }
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
                let most = bounds.target + bounds.startKeep
                if count / 2 > most {
                    let over = count / 2 - most
                    drop(frames: over)
                    stats.startTrims += 1
                    stats.trimmedFrames += over
                }
                if count / 2 > bounds.target + bounds.excess, bounds.startHold > 0 {
                    heldFrames = 0
                    heldAbove = count / 2 - bounds.target
                    heldCap = most
                    stats.heldStarts += 1
                } else {
                    heldFrames = nil
                }
                windowSum = 0
                windowFrames = 0
                silence = 0
                // What the output didn't play before it started is no gap.
                silenceSinceAudio = 0
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
            if let bounds {
                if fed { silenceSinceAudio += frames - n }
                measure(before: before, after: before - n, frames: frames, bounds: bounds)
            }
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

    /// A rush in the middle of a stream is held for the steering to play down: the ring keeps up to
    /// `keeping` frames of it above `target`, the oldest of more going, and says what it holds
    /// (`heldExcess`). The windows measured so far say nothing about it.
    private func hold(above target: Int, keeping: Int) {
        let most = target + keeping
        if count / 2 > most {
            let over = count / 2 - most
            drop(frames: over)
            stats.ceilingTrims += 1
            stats.trimmedFrames += over
        }
        heldFrames = 0
        heldAbove = max(0, count / 2 - target)
        heldCap = most
        stats.heldRushes += 1
        windowSum = 0
        windowFrames = 0
        windowSilence = 0
        silence = 0
    }

    /// Drops the oldest `frames` frames (at most what the ring holds).
    private func drop(frames: Int) {
        let n = max(0, min(frames, count / 2))
        readIndex = (readIndex + n * 2) % samples.count
        count -= n * 2
    }

    /// Adds a read to the window; at the window's end, has what sits above the target without
    /// need played down or dropped (`Bounds.excess`, `Bounds.stallExcess`). The level falls by a read and rises by a URB at
    /// a time; the midpoint of before and after a read, averaged over the window, is the level the
    /// server's steering holds at its lead.
    private func measure(before: Int, after: Int, frames: Int, bounds: Bounds) {
        if settling > 0 {
            settling -= frames
            guard settling <= 0 else { return }
            settling = 0
            if let ceiling = settledCeiling { self.bounds?.ceiling = ceiling }
            settledCeiling = nil
            windowSum = 0
            windowFrames = 0
            silence = 0
            return
        }
        // Silence for want of a stream (before its first audio, after its last) owes nothing.
        let missed = fed ? frames - (before - after) : 0
        silence += missed
        windowSilence += missed
        windowSum += (before + after) * frames
        windowFrames += frames
        if let held = heldFrames { heldFrames = held + frames }
        guard windowFrames >= bounds.window else { return }
        let average = windowSum / (2 * windowFrames)
        let quiet = windowSilence == 0
        windowSum = 0
        windowFrames = 0
        windowSilence = 0
        quietWindows = quiet ? quietWindows + 1 : 0
        if quietWindows >= Self.silenceExpiry { silence = 0 }
        if let held = heldFrames {
            // Played down to the target, give or take the level's ripple (the server goes on while
            // `heldExcess` says there is more), or the time for that is over: nothing steers this
            // ring's source, and what is still above the target goes after all.
            heldAbove = max(0, average - bounds.target)
            if average <= bounds.target + bounds.stallExcess {
                heldFrames = nil
            } else if held >= bounds.startHold {
                heldFrames = nil
                if average > bounds.target + bounds.excess {
                    let dropped = min(average - bounds.target, count / 2)
                    drop(frames: dropped)
                    stats.excessTrims += 1
                    stats.excessFrames += dropped
                }
            }
            silence = 0
            return
        }
        var excess = 0
        if average > bounds.target + bounds.excess {
            excess = average - bounds.target
        } else if silence > 0, average > bounds.target + bounds.stallExcess {
            excess = min(average - bounds.target, silence)
        }
        // A window that ends in the middle of a stall has a low level and silence in it: the late
        // audio is still to come, and the silence still counts (it was forgotten here, and a 70 ms
        // stall stayed as 25 ms of latency when a window happened to end in it).
        if excess > 0 || (average <= bounds.target && quiet) { silence = 0 }
        guard excess > 0 else { return }
        if bounds.rushKeep > 0, bounds.startHold > 0 {
            // Played down, not dropped: the late audio of a stall, or what an output that missed
            // cycles left behind.
            hold(above: bounds.target, keeping: bounds.rushKeep)
            return
        }
        let dropped = min(excess, count / 2)
        drop(frames: dropped)
        stats.excessTrims += 1
        stats.excessFrames += dropped
    }
}
