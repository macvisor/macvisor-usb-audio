import Foundation

/// Where the device's playback goes. Audio is 48 kHz stereo 16-bit little-endian PCM, and arrives in
/// stream order on one queue.
public protocol PlaybackSink: AnyObject, Sendable {
    func playbackStarted()
    func play(_ pcm: Data)
    func playbackStopped()
    /// Audio queued but not yet played, if the sink knows (drives the pacer's clock correction).
    var bufferedSeconds: Double? { get }
    /// The server's lead changed (`AdaptiveLead`): that much audio is what the guest keeps queued
    /// from now on, so that much is what a sink that holds a level should hold. A sink that holds
    /// none does nothing; one that wraps another passes it on. (No default, like `startBacklog`: a
    /// wrapper that didn't pass them on left its sink at the wrong level, unnoticed.)
    func playbackLead(_ seconds: Double)
    /// What the sink holds above its level now because its output started after the stream did and
    /// has the stream's beginning to play, in seconds; zero when it holds none, or is no such sink.
    /// The server has the guest send a little slower while there is some (`PlaybackSteering`).
    var startBacklog: Double { get }
}

/// Where the device's microphone audio comes from (48 kHz stereo 16-bit little-endian PCM).
public protocol CaptureSource: AnyObject, Sendable {
    /// The host opened the microphone stream: start capturing (and only now ask for the microphone).
    func captureStarted()
    /// Exactly `byteCount` bytes: silence where audio isn't available yet.
    func captureAudio(byteCount: Int) -> Data
    func captureStopped()
}

extension PlaybackSink {
    public var bufferedSeconds: Double? { nil }
}

/// Discards playback.
public final class NullSink: PlaybackSink, @unchecked Sendable {
    public func playbackLead(_ seconds: Double) {}
    public var startBacklog: Double { 0 }
    public init() {}
    public func playbackStarted() {}
    public func play(_ pcm: Data) {}
    public func playbackStopped() {}
}

/// Silence for the microphone.
public final class SilentSource: CaptureSource, @unchecked Sendable {
    public init() {}
    public func captureStarted() {}
    public func captureAudio(byteCount: Int) -> Data { Data(count: byteCount) }
    public func captureStopped() {}
}

/// A continuous sine tone for the microphone (tests and trying a client out).
public final class ToneSource: CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private let frequency: Double
    private let amplitude: Double
    private var phase = 0.0

    public init(frequency: Double = 1000, amplitude: Double = 0.25) {
        self.frequency = frequency
        self.amplitude = amplitude
    }

    public func captureStarted() {}
    public func captureStopped() {}

    public func captureAudio(byteCount: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        var out = Data(count: byteCount)
        out.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var i = 0
            while i + 1 < samples.count {
                let v = Int16(amplitude * 32767 * sin(phase)).littleEndian
                samples[i] = v
                samples[i + 1] = v
                phase += 2 * .pi * frequency / Double(UAC1AudioDevice.sampleRate)
                if phase > 2 * .pi { phase -= 2 * .pi }
                i += 2
            }
        }
        return out
    }
}

/// Collects playback in memory (tests), optionally bounded.
public final class RecordingSink: PlaybackSink, @unchecked Sendable {
    public func playbackLead(_ seconds: Double) {}
    public var startBacklog: Double { 0 }
    private let lock = NSLock()
    private var buffer = Data()
    private var chunks = 0
    private let limit: Int

    public init(limit: Int = .max) { self.limit = limit }

    public func playbackStarted() {}
    public func playbackStopped() {}

    public func play(_ pcm: Data) {
        lock.lock()
        defer { lock.unlock() }
        chunks += 1
        if buffer.count + pcm.count <= limit { buffer.append(pcm) }
    }

    public var recorded: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public var chunkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

/// Plays the guest's own playback back into its microphone, a bounded `capacity` behind: for
/// measuring the round-trip latency inside the guest.
public final class LoopbackPort: PlaybackSink, CaptureSource, @unchecked Sendable {
    public func playbackLead(_ seconds: Double) {}
    public var startBacklog: Double { 0 }
    private let lock = NSLock()
    private var buffer = Data()
    private let capacity: Int

    public init(capacity: TimeInterval = 0.15) {
        self.capacity = Int(capacity * Double(UAC1AudioDevice.sampleRate)) * UAC1AudioDevice.bytesPerFrame
    }

    public func playbackStarted() {}
    public func playbackStopped() {}
    public func captureStarted() {}
    public func captureStopped() {}

    public func play(_ pcm: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(pcm)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
    }

    public func captureAudio(byteCount: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }
        let n = min(byteCount, buffer.count)
        var out = buffer.prefix(n)
        buffer.removeFirst(n)
        if n < byteCount { out.append(Data(count: byteCount - n)) }
        return Data(out)
    }
}

/// Writes playback to a 48 kHz stereo 16-bit WAV file; the header is completed by `close()`.
public final class WAVFileSink: PlaybackSink, @unchecked Sendable {
    public func playbackLead(_ seconds: Double) {}
    public var startBacklog: Double { 0 }
    private let lock = NSLock()
    private let handle: FileHandle
    private var bytes: UInt32 = 0

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 44))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func playbackStarted() {}
    public func playbackStopped() {}

    public func play(_ pcm: Data) {
        lock.lock()
        defer { lock.unlock() }
        handle.write(pcm)
        bytes &+= UInt32(pcm.count)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        var h = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); le32(36 + bytes)
        h.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16); le16(1); le16(2); le32(48000); le32(192_000); le16(4); le16(16)
        h.append(contentsOf: Array("data".utf8)); le32(bytes)
        try? handle.seek(toOffset: 0)
        handle.write(h)
        try? handle.close()
    }
}
