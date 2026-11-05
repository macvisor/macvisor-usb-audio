import Foundation
import Testing
@testable import USBAudioDevice

@Suite(.serialized) struct ServerTests {
    private func configure(_ client: TestClient, playback: Bool = true, capture: Bool = false) throws {
        #expect(try client.control(SetupPacket(requestType: 0x00, request: 0x09, value: 1, index: 0, length: 0)).0 == 0)
        if playback { #expect(try client.control(SetupPacket(requestType: 0x01, request: 0x0B, value: 1, index: 1, length: 0)).0 == 0) }
        if capture { #expect(try client.control(SetupPacket(requestType: 0x01, request: 0x0B, value: 1, index: 2, length: 0)).0 == 0) }
    }

    @Test func deviceList() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        let client = TestClient()
        startServing(server, client)
        try client.send(ClientMessages.operation(0x8005))
        var r = BigEndianReader(try client.stream.read(exactly: 12))
        #expect(r.u16() == 0x0111 && r.u16() == 0x0005 && r.u32() == 0 && r.u32() == 1)
    }

    @Test func importEnumerateAndDetach() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        #expect(server.isAttached)
        let (status, descriptor) = try client.control(SetupPacket(requestType: 0x80, request: 0x06, value: 0x0100, index: 0, length: 64))
        #expect(status == 0 && descriptor.count == 18)
        #expect(try client.control(SetupPacket(requestType: 0x80, request: 0x06, value: 0x0307, index: 0x0409, length: 255)).0 == USBIP.Status.stall)
        client.close()
        #expect(waitUntil { !server.isAttached })
    }

    @Test func aSecondImportIsRefusedWhileAttached() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        let first = TestClient(), second = TestClient()
        startServing(server, first)
        #expect(try first.importDevice())
        startServing(server, second)
        #expect(try !second.importDevice())
        // After disconnectAll (e.g. the VM was restored) the device can be imported again.
        server.disconnectAll()
        #expect(waitUntil { !server.isAttached })
        let third = TestClient()
        startServing(server, third)
        #expect(try third.importDevice())
        #expect(throws: (any Error).self) { try first.importDevice() } // the first connection is closed
    }

    @Test func playbackArrivesInSubmissionOrder() throws {
        let sink = RecordingSink()
        let server = USBAudioServer(playback: sink, capture: SilentSource(), lead: 0.5) // all due at once
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client)
        for value in Int16(1) ... 30 { try client.submit(direction: 0, endpoint: 1, outData: pcm(value: value, frames: 480), isoLengths: Array(repeating: 192, count: 10)) }
        var sequences: [UInt32] = []
        for _ in 1 ... 30 {
            guard case .submit(let seq, let status, let actual, let iso, _) = try client.readReply() else { continue }
            #expect(status == 0 && actual == 1920 && iso.allSatisfy { $0.actualLength == 192 && $0.status == 0 })
            sequences.append(seq)
        }
        #expect(sequences == sequences.sorted())
        let audio = sink.recorded
        #expect(audio.count == 30 * 1920)
        audio.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for chunk in 0 ..< 30 { #expect(s[chunk * 960] == Int16(chunk + 1)) }
        }
    }

    @Test func unlinkingAPendingURBSendsOnlyRetUnlink() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource(), lead: 0)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client)
        var ids: [UInt32] = []
        for _ in 1 ... 5 { ids.append(try client.submit(direction: 0, endpoint: 1, outData: pcm(value: 1, frames: 480), isoLengths: Array(repeating: 192, count: 10))) }
        let unlink = try client.unlink(ids[4]) // due 50 ms from now
        var replies: [TestClient.Reply] = []
        for _ in 1 ... 5 { replies.append(try client.readReply()) }
        #expect(replies.contains(.unlink(sequence: unlink, status: USBIP.Status.connectionReset)))
        let completed = replies.compactMap { if case .submit(let s, _, _, _, _) = $0 { return s } else { return nil } }
        #expect(completed == Array(ids.prefix(4)))
    }

    @Test func captureDeliversTheSourceAndHonoursMute() throws {
        let server = USBAudioServer(playback: NullSink(), capture: ToneSource(frequency: 1000, amplitude: 0.5), lead: 0)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client, playback: false, capture: true)
        try client.submit(direction: 1, endpoint: 2, isoLengths: Array(repeating: 192, count: 10))
        guard case .submit(_, let status, let actual, let iso, let data) = try client.readReply() else { Issue.record("no reply"); return }
        #expect(status == 0 && actual == 1920 && data.count == 1920 && iso.count == 10)
        data.withUnsafeBytes { raw in #expect(raw.bindMemory(to: Int16.self).map { abs(Int($0)) }.max()! > 15_000) }
        // Mute the microphone's feature unit: silence.
        #expect(try client.control(SetupPacket(requestType: 0x21, request: 0x01, value: 0x0100, index: 0x0500, length: 1), outData: Data([1])).0 == 0)
        try client.submit(direction: 1, endpoint: 2, isoLengths: Array(repeating: 192, count: 10))
        guard case .submit(_, _, _, _, let muted) = try client.readReply() else { Issue.record("no reply"); return }
        #expect(muted == Data(count: 1920))
    }

    @Test func otherEndpointsStall() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try client.submit(direction: 1, endpoint: 3, length: 64)
        guard case .submit(_, let status, _, _, _) = try client.readReply() else { Issue.record("no reply"); return }
        #expect(status == USBIP.Status.stall)
    }
}

/// Polls `condition` for up to two seconds.
func waitUntil(_ condition: () -> Bool) -> Bool {
    for _ in 0 ..< 200 {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
