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

    @Test func capturePacketsSummingPastTheirBufferStall() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource(), lead: 0)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client, playback: false, capture: true)
        // 1024 packets of 192 bytes, all at offset 0 of a 192-byte buffer: each within it, the sum
        // (192 KiB, or a gigabyte with longer packets) not.
        try client.submit(direction: 1, endpoint: 2, length: 192, isoLengths: Array(repeating: 192, count: 1024), overlapping: true)
        guard case .submit(_, let status, let actual, _, let data) = try client.readReply() else { Issue.record("no reply"); return }
        #expect(status == USBIP.Status.stall && actual == 0 && data.isEmpty)
        #expect(server.isAttached) // refused, not fatal
    }

    @Test func aCapturePacketPastTheDeviceLimitStalls() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource(), lead: 0)
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client, playback: false, capture: true)
        try client.submit(direction: 1, endpoint: 2, isoLengths: [UInt32(UAC1AudioDevice.packetLimit + 1)])
        guard case .submit(_, let status, _, _, _) = try client.readReply() else { Issue.record("no reply"); return }
        #expect(status == USBIP.Status.stall)
    }

    @Test func playbackPastWhatThePacerHoldsStalls() throws {
        // Nothing completes while the clock stands still: the 64 URBs the pacer holds stay queued,
        // and the ones past them are refused at once.
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource(), lead: 0, clock: ManualClock())
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        try configure(client)
        for value in Int16(1) ... 70 {
            try client.submit(direction: 0, endpoint: 1, outData: pcm(value: value, frames: 480), isoLengths: Array(repeating: 192, count: 10))
        }
        for _ in 1 ... 6 {
            guard case .submit(_, let status, _, _, _) = try client.readReply() else { Issue.record("no reply"); return }
            #expect(status == USBIP.Status.stall)
        }
        #expect(server.statistics?.playback.refusedURBs == 6)
    }

    @Test func aTransferPastTheDeviceLimitEndsTheSession() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        // The header claims more than the device ever takes; the server stops before reading it.
        try client.send(ClientMessages.submit(sequence: 1, direction: 0, endpoint: 1,
                                              length: UInt32(UAC1AudioDevice.maxTransferLength + 4), isoLengths: nil))
        #expect(waitUntil { !server.isAttached })
    }

    @Test func aSilentConnectionIsClosedAtTheImportTimeout() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        server.importTimeout = 0.2
        let client = TestClient()
        client.stream.setReadTimeout(3) // a server that never closes fails the test instead of hanging it
        startServing(server, client)
        #expect(throws: StreamError.closed) { _ = try client.stream.read(exactly: 1) }
    }

    @Test func anImportedDeviceOutlivesTheImportTimeout() throws {
        let server = USBAudioServer(playback: NullSink(), capture: SilentSource())
        server.importTimeout = 0.2
        let client = TestClient()
        startServing(server, client)
        #expect(try client.importDevice())
        Thread.sleep(forTimeInterval: 0.5)
        #expect(server.isAttached)
        let (status, descriptor) = try client.control(SetupPacket(requestType: 0x80, request: 0x06, value: 0x0100, index: 0, length: 64))
        #expect(status == 0 && descriptor.count == 18)
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

@Suite struct AdaptiveLeadTests {
    private func arrivals(late: Int = 0, by: Double = 0, slack: Double? = nil) -> EndpointPacer.Arrivals {
        EndpointPacer.Arrivals(late: late, worstLateness: by, leastSlack: slack)
    }

    /// Late URBs grow the lead by how late they came and 20 ms, to the next 10 ms, up to the most.
    @Test func lateURBsGrowTheLeadByHowLateTheyCame() {
        var lead = AdaptiveLead(base: 0.04, most: 0.2)
        #expect(lead.tick(arrivals(slack: 0.05)) == nil)
        #expect(lead.tick(arrivals(late: 3, by: 0.034)).map { abs($0 - 0.10) < 1e-9 } == true) // 40 + 34 + 20, up to 100
        #expect(lead.tick(arrivals(late: 1, by: 0.006)).map { abs($0 - 0.13) < 1e-9 } == true)
        #expect(lead.tick(arrivals(late: 1, by: 0.5)) == 0.2)
        #expect(lead.tick(arrivals(late: 9, by: 0.5)) == nil) // at the most: nothing changes
        #expect(lead.lead == 0.2)
    }

    /// It comes down after 30 s of playing in which nothing was late: at once to where 60 ms would
    /// have been left at the worst arrival when more than 80 ms were, by 10 ms while 40 ms were; not
    /// while nothing plays, and not while a stream needs it.
    @Test func itComesDownOnlyWhenTheStreamHasRoomToSpare() {
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } == true }
        var lead = AdaptiveLead(base: 0.04, most: 0.2)
        #expect(near(lead.tick(arrivals(late: 1, by: 0.03)), 0.09))
        #expect(lead.grewForLateness)
        // Nothing plays for ten minutes: it stays.
        for _ in 1 ... 2400 { #expect(lead.tick(arrivals()) == nil) }
        // 30 s on time with 100 ms left at each arrival: down by the 40 ms beyond 60, at the 120th tick.
        for _ in 1 ... 119 { #expect(lead.tick(arrivals(slack: 0.1)) == nil) }
        #expect(near(lead.tick(arrivals(slack: 0.1)), 0.05))
        // 30 s in which one arrival found 30 ms left: it stays, and the count starts over.
        for tick in 1 ... 120 { #expect(lead.tick(arrivals(slack: tick == 60 ? 0.03 : 0.09)) == nil) }
        // A late URB in a calm stretch starts it over too.
        for _ in 1 ... 100 { _ = lead.tick(arrivals(slack: 0.09)) }
        #expect(near(lead.tick(arrivals(late: 1, by: 0.001)), 0.08)) // 50 + 1 + 20, up to 80
        for _ in 1 ... 119 { #expect(lead.tick(arrivals(slack: 0.07)) == nil) }
        // 70 ms left at the worst: a step.
        #expect(near(lead.tick(arrivals(slack: 0.07)), 0.07))
        #expect(lead.grewForLateness)
        // Plenty left: all the way down, and no further.
        for _ in 1 ... 120 { _ = lead.tick(arrivals(slack: 0.15)) }
        #expect(near(lead.lead, 0.04))
        #expect(!lead.grewForLateness)
        for _ in 1 ... 240 { #expect(lead.tick(arrivals(slack: 0.1)) == nil) }
    }

    /// A stream starts with more than the base (a guest is busiest as it starts to play), comes down
    /// as it shows it has room, and the next stream starts with it again.
    @Test func aStreamStartsWithACushion() {
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } == true }
        var lead = AdaptiveLead(base: 0.04, most: 0.2, start: 0.1)
        #expect(lead.lead == 0.1 && !lead.grewForLateness)
        #expect(lead.streamEnded() == nil) // nothing to change yet
        for _ in 1 ... 119 { #expect(lead.tick(arrivals(slack: 0.108)) == nil) }
        #expect(near(lead.tick(arrivals(slack: 0.108)), 0.06))
        for _ in 1 ... 119 { _ = lead.tick(arrivals(slack: 0.068)) }
        #expect(near(lead.tick(arrivals(slack: 0.068)), 0.05))
        // The stream ends: the next starts with the cushion, and the calm count over.
        #expect(lead.streamEnded() == 0.1)
        for _ in 1 ... 119 { #expect(lead.tick(arrivals(slack: 0.108)) == nil) }
        #expect(near(lead.tick(arrivals(slack: 0.108)), 0.06))
        // One that grew past the cushion keeps what it grew to.
        _ = lead.tick(arrivals(late: 1, by: 0.1))
        #expect(near(lead.lead, 0.18))
        #expect(lead.streamEnded() == nil)
        #expect(near(lead.lead, 0.18))
        // A cushion is never more than the most, or less than the base.
        #expect(AdaptiveLead(base: 0.04, most: 0.08, start: 0.1).lead == 0.08)
        #expect(AdaptiveLead(base: 0.04, most: 0.2, start: 0.01).lead == 0.04)
    }

    /// A server made with no lead, or with no room above its lead, keeps it.
    @Test func aLeadWithNoRoomAboveItStays() {
        var fixed = AdaptiveLead(base: 0.5, most: 0.2)
        #expect(fixed.most == 0.5)
        #expect(fixed.tick(arrivals(late: 5, by: 0.3)) == nil)
        #expect(fixed.lead == 0.5)
    }
}
