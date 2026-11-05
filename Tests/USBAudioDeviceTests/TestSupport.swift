import Dispatch
import Foundation
@testable import USBAudioDevice

/// A clock the test moves by hand. Scheduled work runs, in deadline order, as time passes it.
final class ManualClock: PacerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64 = 1_000_000_000
    private var pending: [(deadline: UInt64, order: Int, queue: DispatchQueue, work: @Sendable () -> Void)] = []
    private var counter = 0

    func now() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return time
    }

    func schedule(at deadline: UInt64, on queue: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        lock.lock()
        counter += 1
        pending.append((deadline, counter, queue, work))
        lock.unlock()
    }

    /// Moves time forward by `nanoseconds`, running everything that falls due on its queue.
    func advance(by nanoseconds: UInt64) {
        let target = now() + nanoseconds
        while true {
            lock.lock()
            guard let i = pending.indices.filter({ pending[$0].deadline <= target })
                .min(by: { (pending[$0].deadline, pending[$0].order) < (pending[$1].deadline, pending[$1].order) }) else {
                time = target
                lock.unlock()
                return
            }
            let job = pending.remove(at: i)
            time = max(time, job.deadline)
            lock.unlock()
            job.queue.sync { job.work() }
        }
    }

    func advance(milliseconds: Double) { advance(by: UInt64(milliseconds * 1_000_000)) }
}

/// Reads from a byte buffer (protocol tests).
final class DataStream: ByteStream, @unchecked Sendable {
    private var data: Data
    private(set) var written = Data()

    init(_ data: Data) { self.data = data }

    func read(exactly count: Int) throws -> Data {
        guard data.count >= count else { throw StreamError.closed }
        let chunk = data.prefix(count)
        data.removeFirst(count)
        return Data(chunk)
    }

    func write(_ d: Data) throws { written.append(d) }
    func close() {}
}

/// Client-side USB/IP messages, written independently of the server's encoder.
enum ClientMessages {
    static func operation(_ code: UInt16, busID: String? = nil) -> Data {
        var w = BigEndianWriter()
        w.u16(0x0111); w.u16(code); w.u32(0)
        if let busID { w.fixedString(busID, size: 32) }
        return w.data
    }

    static func submit(sequence: UInt32, direction: UInt32, endpoint: UInt32, setup: [UInt8] = Array(repeating: 0, count: 8),
                       outData: Data = Data(), length: UInt32? = nil, isoLengths: [UInt32]? = nil) -> Data {
        var w = BigEndianWriter()
        w.u32(1); w.u32(sequence); w.u32(0x0001_0001); w.u32(direction); w.u32(endpoint)
        let total = length ?? (isoLengths.map { $0.reduce(0, +) } ?? UInt32(outData.count))
        w.u32(0); w.u32(total); w.u32(0); w.u32(isoLengths.map { UInt32($0.count) } ?? 0xFFFF_FFFF); w.u32(1)
        for b in setup { w.u8(b) }
        w.bytes(outData)
        var offset: UInt32 = 0
        for l in isoLengths ?? [] { w.u32(offset); w.u32(l); w.u32(0); w.u32(0); offset += l }
        return w.data
    }

    static func unlink(sequence: UInt32, target: UInt32) -> Data {
        var w = BigEndianWriter()
        w.u32(2); w.u32(sequence); w.u32(0x0001_0001); w.u32(0); w.u32(0)
        w.u32(target); w.zeros(24)
        return w.data
    }
}

/// A USB/IP client over a socket pair, for end-to-end tests of `USBAudioServer`.
final class TestClient: @unchecked Sendable {
    enum Reply: Equatable {
        case submit(sequence: UInt32, status: Int32, actualLength: UInt32, isoPackets: [IsoPacket], data: Data)
        case unlink(sequence: UInt32, status: Int32)
    }

    let stream: FileDescriptorStream
    let serverStream: FileDescriptorStream
    private var directions: [UInt32: UInt32] = [:]
    private var sequence: UInt32 = 0

    init() {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        stream = FileDescriptorStream(fileDescriptor: fds[0])
        serverStream = FileDescriptorStream(fileDescriptor: fds[1])
    }

    func send(_ data: Data) throws { try stream.write(data) }

    func importDevice(_ busID: String = "1-1") throws -> Bool {
        try send(ClientMessages.operation(0x8003, busID: busID))
        var r = BigEndianReader(try stream.read(exactly: 8))
        _ = r.u16(); _ = r.u16()
        let status = r.u32()
        if status == 0 { _ = try stream.read(exactly: 312) }
        return status == 0
    }

    @discardableResult
    func submit(direction: UInt32, endpoint: UInt32, setup: [UInt8] = Array(repeating: 0, count: 8), outData: Data = Data(),
                length: UInt32? = nil, isoLengths: [UInt32]? = nil) throws -> UInt32 {
        sequence += 1
        directions[sequence] = direction
        try send(ClientMessages.submit(sequence: sequence, direction: direction, endpoint: endpoint, setup: setup,
                                       outData: outData, length: length, isoLengths: isoLengths))
        return sequence
    }

    func unlink(_ target: UInt32) throws -> UInt32 {
        sequence += 1
        try send(ClientMessages.unlink(sequence: sequence, target: target))
        return sequence
    }

    func readReply() throws -> Reply {
        var r = BigEndianReader(try stream.read(exactly: 48))
        let command = r.u32(), seq = r.u32()
        _ = r.u32(); _ = r.u32(); _ = r.u32()
        let status = r.i32()
        if command == 4 { return .unlink(sequence: seq, status: status) }
        let actual = r.u32()
        _ = r.u32()
        let packets = r.u32()
        let isIn = directions[seq] == 1
        let data = isIn && actual > 0 ? try stream.read(exactly: Int(actual)) : Data()
        var iso: [IsoPacket] = []
        if packets != 0xFFFF_FFFF, packets > 0 {
            var d = BigEndianReader(try stream.read(exactly: Int(packets) * 16))
            for _ in 0 ..< packets { iso.append(IsoPacket(offset: d.u32(), length: d.u32(), actualLength: d.u32(), status: d.i32())) }
        }
        return .submit(sequence: seq, status: status, actualLength: actual, isoPackets: iso, data: data)
    }

    /// A control transfer; returns (status, IN data).
    func control(_ setup: SetupPacket, outData: Data = Data()) throws -> (Int32, Data) {
        try submit(direction: setup.requestType & 0x80 != 0 ? 1 : 0, endpoint: 0, setup: setup.bytes, outData: outData,
                   length: setup.requestType & 0x80 != 0 ? UInt32(setup.length) : UInt32(outData.count))
        guard case .submit(_, let status, _, _, let data) = try readReply() else { return (-1, Data()) }
        return (status, data)
    }

    func close() { stream.close() }
}

/// Serves `client`'s other end on a background thread.
func startServing(_ server: USBAudioServer, _ client: TestClient) {
    let stream = client.serverStream
    Thread.detachNewThread { server.serve(stream) }
}

/// Little-endian 16-bit PCM filled with one value.
func pcm(value: Int16, frames: Int) -> Data {
    var d = Data(count: frames * 4)
    d.withUnsafeMutableBytes { raw in
        let s = raw.bindMemory(to: Int16.self)
        for i in s.indices { s[i] = value.littleEndian }
    }
    return d
}
