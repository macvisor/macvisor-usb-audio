import Foundation

/// A fixed-capacity circular buffer of interleaved stereo frames. Writers that would overflow it drop
/// the oldest audio, so latency stays bounded.
final class StereoRing: @unchecked Sendable {
    private var samples: [Float]
    private var readIndex = 0
    private var count = 0 // samples (two per frame)
    private var lock = os_unfair_lock()

    init(capacitySeconds: Double, sampleRate: Double = 48000) {
        samples = [Float](repeating: 0, count: Int(capacitySeconds * sampleRate) * 2)
    }

    var bufferedFrames: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return count / 2
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        readIndex = 0
        count = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Appends interleaved 16-bit samples.
    func write(int16 pcm: Data) {
        pcm.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            let capacity = samples.count
            for v in src {
                if count == capacity { readIndex = (readIndex + 1) % capacity; count -= 1 } // drop the oldest
                samples[(readIndex + count) % capacity] = Float(Int16(littleEndian: v)) / 32768
                count += 1
            }
        }
    }

    /// Appends interleaved float samples.
    func write(float src: UnsafeBufferPointer<Float>) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let capacity = samples.count
        for v in src {
            if count == capacity { readIndex = (readIndex + 1) % capacity; count -= 1 }
            samples[(readIndex + count) % capacity] = v
            count += 1
        }
    }

    /// Reads up to `frames` frames into separate left and right channels; returns the frames read.
    func read(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let n = min(frames, count / 2)
        let capacity = samples.count
        for i in 0 ..< n {
            left[i] = samples[readIndex]
            right[i] = samples[(readIndex + 1) % capacity]
            readIndex = (readIndex + 2) % capacity
        }
        count -= n * 2
        return n
    }

    /// Reads up to `frames` frames as interleaved 16-bit samples, then trims the buffer to `keepFrames`
    /// if it holds more than `trimAboveFrames` (drift on a free-running source).
    func readInt16(frames: Int, trimAboveFrames: Int, keepFrames: Int) -> (Data, Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let capacity = samples.count
        if count / 2 > trimAboveFrames {
            let drop = count - keepFrames * 2
            readIndex = (readIndex + drop) % capacity
            count -= drop
        }
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
