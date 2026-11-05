import Foundation
import Testing
@testable import USBAudioDevice

@Suite struct ProtocolTests {
    @Test func readsAnIsochronousOutSubmit() throws {
        let audio = pcm(value: 7, frames: 96)
        let stream = DataStream(ClientMessages.submit(sequence: 9, direction: 0, endpoint: 1, outData: audio, isoLengths: [192, 192]))
        guard case .submit(let urb) = try USBIP.readCommand(from: stream) else { Issue.record("not a submit"); return }
        #expect(urb.sequence == 9 && urb.endpoint == 1 && urb.direction == .out)
        #expect(urb.isIsochronous && urb.numberOfPackets == 2)
        #expect(urb.outData == audio)
        #expect(urb.isoPackets == [IsoPacket(offset: 0, length: 192), IsoPacket(offset: 192, length: 192)])
    }

    @Test func readsAControlInSubmitWithoutData() throws {
        let setup = SetupPacket(requestType: 0x80, request: 0x06, value: 0x0100, index: 0, length: 18)
        let stream = DataStream(ClientMessages.submit(sequence: 1, direction: 1, endpoint: 0, setup: setup.bytes, length: 18))
        guard case .submit(let urb) = try USBIP.readCommand(from: stream) else { Issue.record("not a submit"); return }
        #expect(!urb.isIsochronous)
        #expect(urb.outData.isEmpty)
        #expect(SetupPacket(urb.setup) == setup)
    }

    @Test func readsAnUnlink() throws {
        let stream = DataStream(ClientMessages.unlink(sequence: 12, target: 7))
        #expect(try USBIP.readCommand(from: stream) == .unlink(UnlinkRequest(sequence: 12, unlinkSequence: 7)))
    }

    @Test func rejectsOversizedTransfers() {
        let stream = DataStream(ClientMessages.submit(sequence: 1, direction: 1, endpoint: 2, length: 1 << 24, isoLengths: nil))
        #expect(throws: USBIP.ProtocolError.transferTooLong(1 << 24)) { try USBIP.readCommand(from: stream) }
    }

    @Test func rejectsPacketsOutsideTheBuffer() {
        var message = ClientMessages.submit(sequence: 1, direction: 1, endpoint: 2, isoLengths: [192])
        // Point the only packet past the end of its 192-byte transfer.
        message.replaceSubrange(48 ..< 52, with: [0, 0, 0, 100])
        #expect(throws: USBIP.ProtocolError.isoPacketOutOfRange) { try USBIP.readCommand(from: DataStream(message)) }
    }

    @Test func rejectsAnotherVersion() {
        var w = BigEndianWriter()
        w.u16(0x0106); w.u16(0x8005); w.u32(0)
        #expect(throws: USBIP.ProtocolError.unsupportedVersion(0x0106)) { try USBIP.readOperation(from: DataStream(w.data)) }
    }

    @Test func submitReplyLayout() {
        let reply = USBIP.encodeSubmitReply(sequence: 5, status: 0, actualLength: 4, startFrame: 3,
                                            isoPackets: [IsoPacket(offset: 0, length: 4, actualLength: 4)], data: Data([1, 2, 3, 4]))
        #expect(reply.count == 48 + 4 + 16)
        var r = BigEndianReader(reply)
        #expect(r.u32() == 3 && r.u32() == 5) // RET_SUBMIT, sequence
        #expect(r.u32() == 0 && r.u32() == 0 && r.u32() == 0) // devid, direction, ep: zero in replies
        #expect(r.i32() == 0 && r.u32() == 4 && r.u32() == 3 && r.u32() == 1 && r.u32() == 0)
        #expect(r.bytes(8) == Data(count: 8))
        #expect(r.bytes(4) == Data([1, 2, 3, 4]))
    }

    @Test func deviceListLayout() {
        let device = UAC1AudioDevice()
        let list = USBIP.encodeDeviceList([device.exportedDevice(busID: "1-1")])
        #expect(list.count == 12 + 312 + 3 * 4)
        var r = BigEndianReader(list)
        #expect(r.u16() == 0x0111 && r.u16() == 0x0005 && r.u32() == 0 && r.u32() == 1)
        _ = r.bytes(256)
        #expect(String(decoding: r.bytes(32).prefix { $0 != 0 }, as: UTF8.self) == "1-1")
        #expect(r.u32() == 1 && r.u32() == 1 && r.u32() == 2) // bus 1, device 1, full speed
        #expect(r.u16() == 0x1209 && r.u16() == 0x0001)
    }
}
