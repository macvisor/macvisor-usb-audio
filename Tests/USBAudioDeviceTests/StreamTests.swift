import Foundation
import Testing
@testable import USBAudioDevice

@Suite struct StreamTests {
    private func pair() -> (FileDescriptorStream, FileDescriptorStream) {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (FileDescriptorStream(fileDescriptor: fds[0]), FileDescriptorStream(fileDescriptor: fds[1]))
    }

    @Test func aWriteAfterCloseThrowsAndSendsNothing() throws {
        let (a, b) = pair()
        try a.write(Data([1]))
        a.close()
        // A closing session's late work: refused before it touches the descriptor.
        #expect(throws: StreamError.closed) { try a.write(Data([2])) }
        #expect(try b.read(exactly: 1) == Data([1]))
        #expect(throws: StreamError.closed) { _ = try b.read(exactly: 1) }
    }

    /// A read waits in poll() a second at a time: data after a second still arrives, and close()
    /// ends a read with no timeout.
    @Test func aReadWaitsAcrossPollSlicesAndEndsAtClose() throws {
        let (a, b) = pair()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.3) { try? b.write(Data([7])) }
        #expect(try a.read(exactly: 1) == Data([7]))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { a.close() }
        let start = Date()
        #expect(throws: StreamError.closed) { _ = try a.read(exactly: 1) }
        #expect(Date().timeIntervalSince(start) < 1.5)
        withExtendedLifetime(b) {}
    }

    /// The timeout bounds the whole read: a peer sending a byte at a time doesn't stretch it.
    @Test func aReadTimeoutBoundsTheWholeRead() {
        let (a, b) = pair()
        let writer = Thread {
            for _ in 0 ..< 20 {
                guard (try? b.write(Data([1]))) != nil else { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        writer.start()
        a.setReadTimeout(0.3)
        let start = Date()
        #expect(throws: StreamError.timedOut) { _ = try a.read(exactly: 20) }
        #expect(Date().timeIntervalSince(start) < 0.8)
        b.close()
    }

    /// A closed stream's descriptor number may be someone else's by now: setReadTimeout leaves it
    /// alone.
    @Test func aClosedStreamLeavesAReusedDescriptorAlone() {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let stream = FileDescriptorStream(fileDescriptor: fds[0])
        stream.close()
        var reused: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &reused) == 0)
        defer { Darwin.close(reused[0]); Darwin.close(reused[1]); Darwin.close(fds[1]) }
        stream.setReadTimeout(5)
        guard let fd = reused.first(where: { $0 == fds[0] }) else { return } // not reused: nothing to see
        var interval = timeval()
        var size = socklen_t(MemoryLayout<timeval>.size)
        #expect(getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, &size) == 0)
        #expect(interval.tv_sec == 0 && interval.tv_usec == 0)
    }

    @Test func aReadTimeoutEndsAWaitingRead() {
        let (a, b) = pair()
        // The peer stays open (a released stream closes its socket: that would be end of stream).
        withExtendedLifetime(b) {
            a.setReadTimeout(0.1)
            let start = Date()
            #expect(throws: StreamError.timedOut) { _ = try a.read(exactly: 1) }
            #expect(Date().timeIntervalSince(start) < 2)
            a.setReadTimeout(nil)
        }
    }
}
