import Dispatch
import Foundation
import Testing
@testable import USBAudioDevice

/// A playback sink whose `play` waits for the test: a pacer's job held between leaving the queue and
/// sending its reply.
final class BlockingSink: PlaybackSink, @unchecked Sendable {
    func playbackLead(_ seconds: Double) {}
    var startBacklog: Double { 0 }
    let entered = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    func playbackStarted() {}
    func playbackStopped() {}
    func play(_ pcm: Data) {
        entered.signal()
        proceed.wait()
    }
}

/// A microphone that counts what the server asks of it, and returns `extra` bytes more (or fewer)
/// than asked.
final class CountingSource: CaptureSource, @unchecked Sendable {
    let starts = Locked(0), stops = Locked(0), requests = Locked(0)
    let extra: Int
    init(extra: Int = 0) { self.extra = extra }
    func captureStarted() { starts.mutate { $0 += 1 } }
    func captureStopped() { stops.mutate { $0 += 1 } }
    func captureAudio(byteCount: Int) -> Data {
        requests.mutate { $0 += 1 }
        return pcm(value: 1000, frames: (byteCount + extra) / 4) + Data(count: max(0, (byteCount + extra) % 4))
    }
}

@Suite(.serialized) struct SessionTests {
    private func configure(_ client: TestClient, playback: Bool = true, capture: Bool = false) throws {
        #expect(try client.control(SetupPacket(requestType: 0x00, request: 0x09, value: 1, index: 0, length: 0)).0 == 0)
        if playback { #expect(try client.control(SetupPacket(requestType: 0x01, request: 0x0B, value: 1, index: 1, length: 0)).0 == 0) }
        if capture { #expect(try client.control(SetupPacket(requestType: 0x01, request: 0x0B, value: 1, index: 2, length: 0)).0 == 0) }
    }

    /// CMD_UNLINK for a URB whose completion is running: its RET_SUBMIT goes first, then RET_UNLINK
    /// status 0. The other order made Linux's vhci drop the connection.
    @Test func anUnlinkDuringACompletionIsAnsweredAfterIt() throws {
        let sink = BlockingSink()
        let server = USBAudioServer(playback: sink, capture: SilentSource(), lead: 0.5) // due at once
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client)
        let urb = try client.submit(direction: 0, endpoint: 1, outData: pcm(value: 1, frames: 480), isoLengths: Array(repeating: 192, count: 10))
        #expect(sink.entered.wait(timeout: .now() + 2) == .success) // its job runs, and waits
        let unlink = try client.unlink(urb)
        Thread.sleep(forTimeInterval: 0.3) // the server has read the unlink
        sink.proceed.signal()
        guard case .submit(let first, let status, _, _, _) = try client.readReply() else { Issue.record("RET_UNLINK came first"); return }
        #expect(first == urb && status == 0)
        #expect(try client.readReply() == .unlink(sequence: unlink, status: USBIP.Status.ok))
    }

    @Test func unlinkingAPendingCaptureURBSendsOnlyRetUnlink() throws {
        let clock = ManualClock()
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource(), lead: 0, clock: clock)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client, playback: false, capture: true)
        let urb = try client.submit(direction: 1, endpoint: 2, isoLengths: Array(repeating: 192, count: 10))
        let unlink = try client.unlink(urb)
        #expect(try client.readReply() == .unlink(sequence: unlink, status: USBIP.Status.connectionReset))
        clock.advance(milliseconds: 100)
        client.stream.setReadTimeout(0.3)
        #expect(throws: StreamError.timedOut) { _ = try client.readReply() }
    }

    /// The import timeout is a deadline for the whole import: a client sending a byte at a time used
    /// to hold its place for minutes.
    @Test func aSlowImportEndsAtTheDeadline() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        server.importTimeout = 0.3
        let client = TestClient()
        startServing(server, client)
        let request = ClientMessages.operation(0x8003, busID: "1-1")
        let writer = Thread {
            for byte in request {
                guard (try? client.stream.write(Data([byte]))) != nil else { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        writer.start()
        client.stream.setReadTimeout(3) // a server that waits for all 40 bytes fails the test
        let start = Date()
        #expect(throws: StreamError.closed) { _ = try client.stream.read(exactly: 1) }
        #expect(Date().timeIntervalSince(start) < 2.5) // 0.3 s, not 4 s (or 0.8 s, the first read's 8 bytes): room for a loaded CI Mac
        #expect(!server.isAttached)
    }

    /// Partial frames would swap left and right for the rest of the stream: each packet plays its
    /// whole frames.
    @Test func playbackPacketsOfPartialFramesKeepLeftAndRight() throws {
        let sink = RecordingSink()
        let server = USBAudioServer(playback: sink, capture: SilentSource(), lead: 0.5)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client)
        // A frame and half of one, then two frames: left 1, right 2.
        let frame = Data([1, 0, 2, 0])
        let data = frame + Data([1, 0]) + frame + frame
        try client.submit(direction: 0, endpoint: 1, outData: data, isoLengths: [6, 8])
        guard case .submit(_, let status, let actual, _, _) = try client.readReply() else { Issue.record("no reply"); return }
        #expect(status == 0 && actual == 14)
        #expect(sink.recorded == frame + frame + frame)
    }

    @Test func playbackPacketsSummingPastTheirBufferStall() throws {
        let sink = RecordingSink()
        let server = USBAudioServer(playback: sink, capture: SilentSource(), lead: 0.5)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client)
        // 64 packets of 192 bytes, all at offset 0 of a 192-byte buffer.
        try client.submit(direction: 0, endpoint: 1, outData: pcm(value: 1, frames: 48), length: 192,
                          isoLengths: Array(repeating: 192, count: 64), overlapping: true)
        guard case .submit(_, let status, _, _, _) = try client.readReply() else { Issue.record("no reply"); return }
        #expect(status == USBIP.Status.stall)
        #expect(sink.chunkCount == 0 && server.isAttached)
    }

    /// A capture packet asked for in a length that isn't whole frames gets the frames that fit, and
    /// the reply carries exactly the bytes it says, whatever the source returns.
    @Test(arguments: [0, 3, -5])
    func capturePacketsGetWholeFramesAndTheReplyItsLength(extra: Int) throws {
        let server = USBAudioServer(playback: NullSink(), capture: CountingSource(extra: extra), lead: 0)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client, playback: false, capture: true)
        for _ in 1 ... 2 { // the second reply parses: the stream is still in step
            try client.submit(direction: 1, endpoint: 2, isoLengths: [190, 192, 6])
            guard case .submit(_, let status, let actual, let iso, let data) = try client.readReply() else { Issue.record("no reply"); return }
            #expect(status == 0 && actual == 384 && data.count == 384)
            #expect(iso.map(\.actualLength) == [188, 192, 4])
        }
    }

    /// The runner's shutDown: the session ends and the guest's streams stop before disconnectAll
    /// returns, not when the session's thread notices.
    @Test func disconnectAllStopsTheStreamsBeforeItReturns() throws {
        let source = CountingSource()
        let server = USBAudioServer(playback: NullSink(), capture: source)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client, playback: false, capture: true)
        #expect(source.starts.value == 1)
        server.disconnectAll()
        #expect(source.stops.value == 1)
        #expect(!server.isAttached)
        Thread.sleep(forTimeInterval: 0.2) // the session's thread ends it too: once is all
        #expect(source.stops.value == 1)
        // A new import gets the device unconfigured.
        let next = TestClient()
        startServing(server, next)
        #expect(try next.importDevice())
        #expect(!server.device.isCaptureActive)
    }

    @Test func aDetachStopsTheMicrophone() throws {
        let source = CountingSource()
        let server = USBAudioServer(playback: NullSink(), capture: source)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client, playback: false, capture: true)
        client.close()
        #expect(waitUntil { source.stops.value == 1 && !server.isAttached })
    }

    /// The microphone is asked for audio only while the host records.
    @Test func aCaptureURBWhileInactiveLeavesTheSourceAlone() throws {
        let source = CountingSource()
        let server = USBAudioServer(playback: NullSink(), capture: source, lead: 0)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client, playback: false, capture: false)
        try client.submit(direction: 1, endpoint: 2, isoLengths: Array(repeating: 192, count: 10))
        guard case .submit(_, let status, _, _, let data) = try client.readReply() else { Issue.record("no reply"); return }
        #expect(status == 0 && data == Data(count: 1920))
        #expect(source.requests.value == 0 && source.starts.value == 0)
    }

    @Test func concurrentImportsAttachOnce() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        let clients = (0 ..< 8).map { _ in TestClient() }
        clients.forEach { startServing(server, $0) }
        let imported = Locked(0)
        DispatchQueue.concurrentPerform(iterations: clients.count) { i in
            if (try? clients[i].importDevice()) == true { imported.mutate { $0 += 1 } }
        }
        #expect(imported.value == 1)
    }

    /// A client gone before its import reply: the device is free again.
    @Test func anImportWhoseClientLeftFreesTheDevice() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        let client = TestClient()
        startServing(server, client)
        try client.send(ClientMessages.operation(0x8003, busID: "1-1"))
        client.close()
        // The device is free once the server has seen the client go, whenever it took the import: a
        // check of isAttached alone could pass before the import was taken (a slow CI Mac), so a new
        // client tries until its import is accepted.
        var imported = false
        for _ in 0 ..< 60 where !imported {
            let next = TestClient()
            startServing(server, next)
            imported = (try? next.importDevice()) == true
            if !imported {
                next.close()
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        #expect(imported)
    }

    @Test func controlInRepliesFitTheHostsBuffer() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        // The device descriptor (18 bytes), wLength 64, into an 8-byte buffer.
        try client.submit(direction: 1, endpoint: 0, setup: SetupPacket(requestType: 0x80, request: 0x06, value: 0x0100, index: 0, length: 64).bytes, length: 8)
        guard case .submit(_, let status, let actual, _, let data) = try client.readReply() else { Issue.record("no reply"); return }
        #expect(status == 0 && actual == 8 && data == Data(server.device.deviceDescriptor.prefix(8)))
    }

    @Test func aDirectionPastInEndsTheSession() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try client.send(ClientMessages.submit(sequence: 1, direction: 2, endpoint: 1, isoLengths: [192]))
        #expect(waitUntil { !server.isAttached })
    }

    /// A stalled control request is said once a session, with the request: a volume control the
    /// host addresses on a channel the descriptor doesn't declare would otherwise go unseen.
    @Test func theFirstStalledControlRequestIsLogged() throws {
        let lines = Locked<[String]>([])
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        server.log = { line in lines.mutate { $0.append(line) } }
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        // SET_CUR volume on channel 1 of the speaker's feature unit: only the master is declared.
        let channel1 = SetupPacket(requestType: 0x21, request: 0x01, value: 0x0201, index: UInt16(UAC1AudioDevice.speakerFeatureUnit) << 8, length: 2)
        #expect(try client.control(channel1, outData: Data([0, 0])).0 == USBIP.Status.stall)
        #expect(try client.control(channel1, outData: Data([0, 0])).0 == USBIP.Status.stall)
        #expect(waitUntil { lines.value.contains { $0.hasPrefix("stalled a control request") } })
        let stalls = lines.value.filter { $0.hasPrefix("stalled a control request") }
        #expect(stalls == ["stalled a control request the device doesn't support: bmRequestType 0x21 bRequest 0x01 wValue 0x0201 wIndex 0x0200 (later ones aren't logged)"])
    }

    /// The guest's bus ID is logged escaped: a newline in it would forge a log line.
    @Test func anUnknownBusIDIsLoggedEscaped() throws {
        let lines = Locked<[String]>([])
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        server.log = { line in lines.mutate { $0.append(line) } }
        let client = TestClient()
        startServing(server, client)
        #expect(try !client.importDevice("x\n[USBAudio] forged"))
        #expect(waitUntil { !lines.value.isEmpty })
        #expect(lines.value.allSatisfy { !$0.contains("\n") })
        #expect(lines.value.first == #"import of unknown bus ID "x\u{a}[USBAudio] forged" refused"#)
    }
}

@Suite struct FuzzTests {
    /// Random headers and bodies: the parser answers or throws, never traps, and what it returns is
    /// within its bounds.
    @Test func theParserTakesAnything() {
        var random = SplitMix64(seed: 42)
        for _ in 0 ..< 20_000 {
            var w = BigEndianWriter()
            let pick = { (choices: [UInt32]) -> UInt32 in choices[Int(random.next() % UInt64(choices.count))] }
            w.u32(pick([1, 1, 1, 2, UInt32(truncatingIfNeeded: random.next())]))
            w.u32(UInt32(truncatingIfNeeded: random.next()))
            w.u32(0x0001_0001)
            w.u32(pick([0, 1, 2, UInt32(truncatingIfNeeded: random.next())]))
            w.u32(pick([0, 1, 2, 15]))
            w.u32(0)
            w.u32(pick([0, 8, 192, 1920, 4000, UInt32(truncatingIfNeeded: random.next())]))
            w.u32(0)
            w.u32(pick([0, 1, 10, 1024, 1025, USBIP.noIsoPackets, UInt32(truncatingIfNeeded: random.next())]))
            w.u32(1)
            for _ in 0 ..< 8 { w.u8(UInt8(truncatingIfNeeded: random.next())) }
            for _ in 0 ..< Int(random.next() % 3000) { w.u8(UInt8(truncatingIfNeeded: random.next())) }
            guard case .submit(let urb)? = try? USBIP.readCommand(from: DataStream(w.data), maxTransferLength: UAC1AudioDevice.maxTransferLength) else { continue }
            let withinBounds = urb.transferBufferLength <= UInt32(UAC1AudioDevice.maxTransferLength)
                && (urb.direction == .in || urb.outData.count == Int(urb.transferBufferLength))
                && urb.isoPackets.allSatisfy { UInt64($0.offset) + UInt64($0.length) <= UInt64(urb.transferBufferLength) }
            if !withinBounds { Issue.record("out of bounds: \(urb)") }
            _ = USBAudioServer.playbackAudio(of: urb)
        }
    }

    /// Random control requests: an answer no longer than wLength, or a stall; never a trap.
    @Test func controlRequestsTakeAnything() {
        var random = SplitMix64(seed: 43)
        let device = UAC1AudioDevice()
        for _ in 0 ..< 200_000 {
            let bits = random.next()
            let setup = SetupPacket(requestType: UInt8(truncatingIfNeeded: bits), request: UInt8(truncatingIfNeeded: bits >> 8) % 16 | (bits & 1 << 20 != 0 ? 0x80 : 0),
                                    value: UInt16(truncatingIfNeeded: bits >> 24), index: UInt16(truncatingIfNeeded: bits >> 40) & 0x0F0F,
                                    length: UInt16(truncatingIfNeeded: random.next()))
            let out = Data((0 ..< Int(random.next() % 6)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
            if case .data(let bytes) = device.handleControl(setup, outData: out), bytes.count > Int(setup.length) {
                Issue.record("\(bytes.count) bytes for \(setup)")
            }
        }
    }
}
