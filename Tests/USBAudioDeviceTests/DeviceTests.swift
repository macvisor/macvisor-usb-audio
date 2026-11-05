import Foundation
import Testing
@testable import USBAudioDevice

@Suite struct DescriptorTests {
    let device = UAC1AudioDevice()

    @Test func configurationTotalLengthMatches() {
        let c = device.configurationDescriptor
        #expect(Int(c[2]) | Int(c[3]) << 8 == c.count)
        // Every descriptor's own length walks the block exactly.
        var offset = 0
        while offset < c.count {
            #expect(c[offset] >= 2)
            offset += Int(c[offset])
        }
        #expect(offset == c.count)
    }

    @Test func audioControlHeaderCoversItsDescriptors() {
        let c = device.configurationDescriptor
        // The AC header's wTotalLength counts the header and the six terminal and unit descriptors.
        let header = c.firstRange(of: [10, 0x24, 0x01])!.lowerBound
        let declared = Int(c[header + 5]) | Int(c[header + 6]) << 8
        var offset = header, total = 0
        while offset < c.count, c[offset + 1] == 0x24 { total += Int(c[offset]); offset += Int(c[offset]) }
        #expect(declared == total)
    }

    @Test func endpointsAreFullSpeedIsochronous() {
        let c = device.configurationDescriptor
        var endpoints: [(UInt8, UInt8, Int, UInt8)] = []
        var offset = 0
        while offset < c.count {
            if c[offset + 1] == 0x05 { endpoints.append((c[offset + 2], c[offset + 3], Int(c[offset + 4]) | Int(c[offset + 5]) << 8, c[offset + 6])) }
            offset += Int(c[offset])
        }
        #expect(endpoints.count == 2)
        #expect(endpoints[0] == (0x01, 0x09, 192, 1)) // OUT, isochronous adaptive, 48 frames, 1 ms
        #expect(endpoints[1] == (0x82, 0x0D, 192, 1)) // IN, isochronous synchronous
    }

    @Test func deviceDescriptorCarriesTheIdentity() {
        let d = UAC1AudioDevice(identity: DeviceIdentity(productID: 0x4112)).deviceDescriptor
        #expect(d.count == 18)
        #expect(Int(d[8]) | Int(d[9]) << 8 == 0x1209)
        #expect(Int(d[10]) | Int(d[11]) << 8 == 0x4112)
    }

    @Test func stringDescriptors() {
        let product = device.handleControl(SetupPacket(requestType: 0x80, request: 0x06, value: 0x0302, index: 0x0409, length: 255))
        guard case .data(let bytes) = product else { Issue.record("stalled"); return }
        #expect(String(data: Data(bytes.dropFirst(2)), encoding: .utf16LittleEndian) == "MacVisor Audio")
    }
}

@Suite struct ControlTests {
    @Test func descriptorsAreCutToTheRequestedLength() {
        let device = UAC1AudioDevice()
        #expect(device.handleControl(SetupPacket(requestType: 0x80, request: 0x06, value: 0x0200, index: 0, length: 9))
            == .data(Array(device.configurationDescriptor.prefix(9))))
    }

    @Test func alternateSettingsRaiseStreamEvents() {
        let device = UAC1AudioDevice()
        let events = Locked<[StreamEvent]>([])
        device.onStreamEvent = { e in events.mutate { $0.append(e) } }
        _ = device.handleControl(SetupPacket(requestType: 0x00, request: 0x09, value: 1, index: 0, length: 0))
        _ = device.handleControl(SetupPacket(requestType: 0x01, request: 0x0B, value: 1, index: 1, length: 0))
        _ = device.handleControl(SetupPacket(requestType: 0x01, request: 0x0B, value: 1, index: 2, length: 0))
        #expect(device.isPlaybackActive && device.isCaptureActive)
        _ = device.handleControl(SetupPacket(requestType: 0x01, request: 0x0B, value: 0, index: 2, length: 0))
        device.reset()
        #expect(events.value == [.playbackStarted, .captureStarted, .captureStopped, .playbackStopped])
        #expect(!device.isPlaybackActive)
    }

    @Test func invalidAlternateSettingStalls() {
        let device = UAC1AudioDevice()
        _ = device.handleControl(SetupPacket(requestType: 0x00, request: 0x09, value: 1, index: 0, length: 0))
        #expect(device.handleControl(SetupPacket(requestType: 0x01, request: 0x0B, value: 2, index: 1, length: 0)) == .stall)
    }

    @Test func onlyFortyEightKilohertz() {
        let device = UAC1AudioDevice()
        let set = SetupPacket(requestType: 0x22, request: 0x01, value: 0x0100, index: 0x01, length: 3)
        #expect(device.handleControl(set, outData: Data([0x80, 0xBB, 0x00])) == .data([]))
        #expect(device.handleControl(set, outData: Data([0x44, 0xAC, 0x00])) == .stall) // 44100
        #expect(device.handleControl(SetupPacket(requestType: 0xA2, request: 0x81, value: 0x0100, index: 0x82, length: 3)) == .data([0x80, 0xBB, 0x00]))
    }

    @Test func volumeRangeAndGain() {
        let device = UAC1AudioDevice()
        let volume = { (request: UInt8) in SetupPacket(requestType: 0xA1, request: request, value: 0x0200, index: 0x0200, length: 2) }
        #expect(device.handleControl(volume(0x82)) == .data([0x00, 0xC4])) // −60 dB
        #expect(device.handleControl(volume(0x83)) == .data([0x00, 0x00])) // 0 dB
        #expect(device.handleControl(volume(0x84)) == .data([0x00, 0x01])) // 1 dB steps
        // −6.02 dB halves the amplitude.
        let minus6 = Int16(-6.0206 * 256)
        _ = device.handleControl(SetupPacket(requestType: 0x21, request: 0x01, value: 0x0200, index: 0x0200, length: 2),
                                 outData: Data([UInt8(UInt16(bitPattern: minus6) & 0xFF), UInt8(UInt16(bitPattern: minus6) >> 8)]))
        let out = device.applyGain(.playback, to: pcm(value: 10000, frames: 4))
        out.withUnsafeBytes { raw in #expect(abs(Int(raw.bindMemory(to: Int16.self)[0]) - 5000) <= 2) }
        // The microphone's level is separate.
        #expect(device.applyGain(.capture, to: pcm(value: 10000, frames: 1)) == pcm(value: 10000, frames: 1))
    }

    /// The descriptor declares mute and volume on the master channel only: requests for a channel
    /// stall.
    @Test func featureUnitRequestsForAChannelStall() {
        let device = UAC1AudioDevice()
        for channel: UInt16 in [1, 2, 0xFF] {
            #expect(device.handleControl(SetupPacket(requestType: 0x21, request: 0x01, value: 0x0100 | channel, index: 0x0200, length: 1), outData: Data([1])) == .stall)
            #expect(device.handleControl(SetupPacket(requestType: 0xA1, request: 0x81, value: 0x0200 | channel, index: 0x0500, length: 2)) == .stall)
        }
        #expect(device.handleControl(SetupPacket(requestType: 0xA1, request: 0x81, value: 0x0100, index: 0x0200, length: 1)) == .data([0]))
        #expect(device.applyGain(.playback, to: pcm(value: 1234, frames: 2)) == pcm(value: 1234, frames: 2))
    }

    @Test func muteSilences() {
        let device = UAC1AudioDevice()
        _ = device.handleControl(SetupPacket(requestType: 0x21, request: 0x01, value: 0x0100, index: 0x0500, length: 1), outData: Data([1]))
        #expect(device.handleControl(SetupPacket(requestType: 0xA1, request: 0x81, value: 0x0100, index: 0x0500, length: 1)) == .data([1]))
        #expect(device.applyGain(.capture, to: pcm(value: 1234, frames: 8)) == Data(count: 32))
        #expect(device.applyGain(.playback, to: pcm(value: 1234, frames: 8)) == pcm(value: 1234, frames: 8))
    }
}

/// A value shared with callbacks.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); f(&v); lock.unlock() }
}
