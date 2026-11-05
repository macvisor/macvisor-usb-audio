import Foundation

/// A bidirectional byte stream: a TCP connection, a virtio-vsock connection handed over by
/// Virtualization.framework, or a socket pair in tests.
public protocol ByteStream: AnyObject, Sendable {
    /// Blocks until exactly `count` bytes arrive. Throws `StreamError.closed` at end of stream, and
    /// `StreamError.timedOut` when a read timeout is set and passes.
    func read(exactly count: Int) throws -> Data
    /// Writes all of `data`. Callers serialise writes themselves. Throws `StreamError.closed` once the
    /// stream is closed, without touching it.
    func write(_ data: Data) throws
    /// Closes the stream; a blocked `read` returns with `StreamError.closed`.
    func close()
    /// Ends a `read` that waits longer than `seconds`; nil waits forever.
    func setReadTimeout(_ seconds: TimeInterval?)
}

extension ByteStream {
    /// Streams without timeouts (test doubles) wait forever.
    public func setReadTimeout(_ seconds: TimeInterval?) {}
}

public enum StreamError: Error, Equatable, Sendable {
    case closed
    case timedOut
    case posix(Int32)
}

/// A `ByteStream` over a file descriptor (a socket). The stream owns the descriptor unless created
/// with `ownsDescriptor: false`.
///
/// An owned descriptor is closed only when no read or write is under way, and nothing reads or writes
/// after `close()`: work a closing session still runs (a pacer's job) gets `StreamError.closed`
/// instead of writing to a descriptor number the process may have reused. A caller whose descriptor
/// belongs to someone else (a `VZVirtioSocketConnection`'s) should hand the stream a `dup` of it.
public final class FileDescriptorStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let ownsDescriptor: Bool
    private let lock = NSLock()
    private var closed = false
    /// Reads and writes under way.
    private var busy = 0
    private var descriptorClosed = false

    public init(fileDescriptor: Int32, ownsDescriptor: Bool = true) {
        fd = fileDescriptor
        self.ownsDescriptor = ownsDescriptor
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    public func read(exactly count: Int) throws -> Data {
        try begin()
        defer { end() }
        var buffer = Data(count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: got), count - got)
            }
            if n > 0 { got += n; continue }
            if n == 0 { throw StreamError.closed }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { throw isClosed ? StreamError.closed : StreamError.timedOut }
            throw isClosed ? StreamError.closed : StreamError.posix(errno)
        }
        return buffer
    }

    public func write(_ data: Data) throws {
        try begin()
        defer { end() }
        var sent = 0
        while sent < data.count {
            if isClosed { throw StreamError.closed }
            let n = data.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: sent), data.count - sent)
            }
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EINTR { continue }
            throw isClosed ? StreamError.closed : StreamError.posix(errno)
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        // Wake a blocked read or write; the descriptor itself goes once neither is under way.
        _ = shutdown(fd, SHUT_RDWR)
        closeDescriptorIfIdle()
    }

    public func setReadTimeout(_ seconds: TimeInterval?) {
        var interval = timeval()
        if let seconds, seconds > 0 {
            interval.tv_sec = Int(seconds)
            interval.tv_usec = Int32((seconds - Double(Int(seconds))) * 1_000_000)
        }
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    /// Counts a read or write in, unless the stream is closed.
    private func begin() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw StreamError.closed }
        busy += 1
    }

    private func end() {
        lock.lock()
        defer { lock.unlock() }
        busy -= 1
        closeDescriptorIfIdle()
    }

    /// The lock is held.
    private func closeDescriptorIfIdle() {
        guard closed, busy == 0, ownsDescriptor, !descriptorClosed else { return }
        descriptorClosed = true
        _ = Darwin.close(fd)
    }
}
