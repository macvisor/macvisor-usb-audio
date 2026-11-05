import Foundation

/// A bidirectional byte stream: a TCP connection, a virtio-vsock connection handed over by
/// Virtualization.framework, or a socket pair in tests.
public protocol ByteStream: AnyObject, Sendable {
    /// Blocks until exactly `count` bytes arrive. Throws `StreamError.closed` at end of stream.
    func read(exactly count: Int) throws -> Data
    /// Writes all of `data`. Callers serialise writes themselves.
    func write(_ data: Data) throws
    /// Closes the stream; a blocked `read` returns with `StreamError.closed`.
    func close()
}

public enum StreamError: Error, Equatable, Sendable {
    case closed
    case posix(Int32)
}

/// A `ByteStream` over a file descriptor (a socket). The stream owns the descriptor unless created
/// with `ownsDescriptor: false` (as for a `VZVirtioSocketConnection`, which closes its own).
public final class FileDescriptorStream: ByteStream, @unchecked Sendable {
    private let fd: Int32
    private let ownsDescriptor: Bool
    private let lock = NSLock()
    private var closed = false

    public init(fileDescriptor: Int32, ownsDescriptor: Bool = true) {
        fd = fileDescriptor
        self.ownsDescriptor = ownsDescriptor
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    public func read(exactly count: Int) throws -> Data {
        var buffer = Data(count: count)
        var got = 0
        while got < count {
            let n = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: got), count - got)
            }
            if n > 0 { got += n; continue }
            if n == 0 { throw StreamError.closed }
            if errno == EINTR { continue }
            throw isClosed ? StreamError.closed : StreamError.posix(errno)
        }
        return buffer
    }

    public func write(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
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
        // Wake a blocked read; then let go of the descriptor if it's ours.
        _ = shutdown(fd, SHUT_RDWR)
        if ownsDescriptor { _ = Darwin.close(fd) }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }
}
