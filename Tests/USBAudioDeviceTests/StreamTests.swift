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
