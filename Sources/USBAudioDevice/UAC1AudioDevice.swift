import Foundation

/// How the device introduces itself. pid.codes' testing PID (1209:0001) until a PID is assigned.
public struct DeviceIdentity: Equatable, Sendable {
    public var vendorID: UInt16
    public var productID: UInt16
    public var deviceRelease: UInt16
    public var manufacturer: String
    public var product: String
    public var serialNumber: String

    public init(vendorID: UInt16 = 0x1209, productID: UInt16 = 0x0001, deviceRelease: UInt16 = 0x0100,
                manufacturer: String = "MacVisor", product: String = "MacVisor Audio", serialNumber: String = "0001") {
        self.vendorID = vendorID
        self.productID = productID
        self.deviceRelease = deviceRelease
        self.manufacturer = manufacturer
        self.product = product
        self.serialNumber = serialNumber
    }
}

/// An 8-byte USB SETUP packet.
public struct SetupPacket: Equatable, Sendable {
    public var requestType: UInt8
    public var request: UInt8
    public var value: UInt16
    public var index: UInt16
    public var length: UInt16

    public init(_ bytes: [UInt8]) {
        precondition(bytes.count == 8)
        requestType = bytes[0]
        request = bytes[1]
        value = UInt16(bytes[2]) | UInt16(bytes[3]) << 8
        index = UInt16(bytes[4]) | UInt16(bytes[5]) << 8
        length = UInt16(bytes[6]) | UInt16(bytes[7]) << 8
    }

    public init(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, length: UInt16) {
        self.requestType = requestType
        self.request = request
        self.value = value
        self.index = index
        self.length = length
    }

    public var bytes: [UInt8] {
        [requestType, request, UInt8(value & 0xFF), UInt8(value >> 8), UInt8(index & 0xFF), UInt8(index >> 8),
         UInt8(length & 0xFF), UInt8(length >> 8)]
    }
}

/// The outcome of a control transfer.
public enum ControlResult: Equatable, Sendable {
    /// IN data (already cut to the request's wLength), or no data for an OUT request.
    case data([UInt8])
    /// The request isn't supported: the endpoint stalls.
    case stall
}

/// Streaming state changes, raised when the host selects an interface's alternate setting.
public enum StreamEvent: Equatable, Sendable {
    case playbackStarted, playbackStopped, captureStarted, captureStopped
}

/// A full-speed USB Audio Class 1.0 device: a stereo speaker (isochronous OUT, adaptive) and a stereo
/// microphone (isochronous IN, synchronous), both 48 kHz 16-bit PCM. Windows, macOS and Linux bind
/// their built-in USB audio class drivers to it (`usbaudio.sys` on Windows).
///
/// Volume and mute are hardware controls (a feature unit per direction): the host sets them on the
/// device and expects the device to apply them, which `applyGain` does.
public final class UAC1AudioDevice: @unchecked Sendable {
    public static let sampleRate = 48000
    public static let channels = 2
    public static let bytesPerFrame = 4
    /// Frames in one 1 ms full-speed packet.
    public static let framesPerPacket = sampleRate / 1000

    public static let playbackEndpoint: UInt8 = 0x01
    public static let captureEndpoint: UInt8 = 0x82
    static let speakerFeatureUnit: UInt8 = 2
    static let microphoneFeatureUnit: UInt8 = 5
    static let volumeMinimum: Int16 = -60 * 256 // 1/256 dB
    static let volumeResolution: Int16 = 256

    public let identity: DeviceIdentity
    public let deviceDescriptor: [UInt8]
    public let configurationDescriptor: [UInt8]

    /// Called (on the caller's thread, outside the device's lock) when streaming starts or stops.
    public var onStreamEvent: (@Sendable (StreamEvent) -> Void)?

    private let lock = NSLock()
    private var configuration: UInt8 = 0
    private var alternateSettings: [UInt8] = [0, 0, 0]
    private var muted: [UInt8: Bool] = [speakerFeatureUnit: false, microphoneFeatureUnit: false]
    private var volume: [UInt8: Int16] = [speakerFeatureUnit: 0, microphoneFeatureUnit: 0]

    public init(identity: DeviceIdentity = DeviceIdentity()) {
        self.identity = identity
        deviceDescriptor = Self.makeDeviceDescriptor(identity)
        configurationDescriptor = Self.makeConfigurationDescriptor()
    }

    // MARK: Descriptors

    static func makeDeviceDescriptor(_ id: DeviceIdentity) -> [UInt8] {
        [18, 0x01, 0x10, 0x01, // bcdUSB 1.10: full speed, no qualifier or BOS needed
         0, 0, 0, 64, // class per interface; 64-byte EP0
         UInt8(id.vendorID & 0xFF), UInt8(id.vendorID >> 8), UInt8(id.productID & 0xFF), UInt8(id.productID >> 8),
         UInt8(id.deviceRelease & 0xFF), UInt8(id.deviceRelease >> 8),
         1, 2, 3, 1] // strings: manufacturer, product, serial; one configuration
    }

    static func makeConfigurationDescriptor() -> [UInt8] {
        var b: [UInt8] = []
        // Configuration: 3 interfaces, bus-powered, 100 mA. wTotalLength is patched below.
        b += [9, 0x02, 0, 0, 3, 1, 0, 0x80, 50]
        // Interface 0: AudioControl.
        b += [9, 0x04, 0, 0, 0, 0x01, 0x01, 0x00, 0]
        // Class-specific AC header: UAC 1.0, 72 bytes of AC descriptors, streaming interfaces 1 and 2.
        b += [10, 0x24, 0x01, 0x00, 0x01, 72, 0, 2, 1, 2]
        // Speaker path: USB streaming input terminal 1 -> feature unit 2 (mute, volume) -> speaker 3.
        b += [12, 0x24, 0x02, 1, 0x01, 0x01, 0, 2, 0x03, 0x00, 0, 0]
        b += [10, 0x24, 0x06, speakerFeatureUnit, 1, 1, 0x03, 0x00, 0x00, 0]
        b += [9, 0x24, 0x03, 3, 0x01, 0x03, 0, speakerFeatureUnit, 0]
        // Microphone path: microphone input terminal 4 -> feature unit 5 -> USB streaming output terminal 6.
        b += [12, 0x24, 0x02, 4, 0x01, 0x02, 0, 2, 0x03, 0x00, 0, 0]
        b += [10, 0x24, 0x06, microphoneFeatureUnit, 4, 1, 0x03, 0x00, 0x00, 0]
        b += [9, 0x24, 0x03, 6, 0x01, 0x01, 0, microphoneFeatureUnit, 0]
        // Streaming interfaces: alternate setting 0 has no endpoint; 1 streams stereo 16-bit PCM at 48 kHz.
        let maxPacket = UInt8(framesPerPacket * bytesPerFrame) // 192
        for (interface, terminal, endpoint, attributes) in [(UInt8(1), UInt8(1), playbackEndpoint, UInt8(0x09)), // iso, adaptive
                                                             (UInt8(2), UInt8(6), captureEndpoint, UInt8(0x0D))] { // iso, synchronous
            b += [9, 0x04, interface, 0, 0, 0x01, 0x02, 0x00, 0]
            b += [9, 0x04, interface, 1, 1, 0x01, 0x02, 0x00, 0]
            b += [7, 0x24, 0x01, terminal, 1, 0x01, 0x00] // AS general: PCM
            b += [11, 0x24, 0x02, 0x01, UInt8(channels), 2, 16, 1, 0x80, 0xBB, 0x00] // type I, 48000 Hz
            b += [9, 0x05, endpoint, attributes, maxPacket, 0, 1, 0, 0] // 1 ms interval
            b += [7, 0x25, 0x01, 0x01, 0, 0, 0] // sampling-frequency control
        }
        let total = UInt16(b.count)
        b[2] = UInt8(total & 0xFF)
        b[3] = UInt8(total >> 8)
        return b
    }

    static func stringDescriptor(_ s: String) -> [UInt8] {
        let units = Array(s.utf16.prefix(126))
        var b: [UInt8] = [UInt8(2 + units.count * 2), 0x03]
        for u in units { b += [UInt8(u & 0xFF), UInt8(u >> 8)] }
        return b
    }

    func descriptor(type: UInt8, index: UInt8, language: UInt16) -> [UInt8]? {
        switch type {
        case 0x01 where index == 0: return deviceDescriptor
        case 0x02 where index == 0: return configurationDescriptor
        case 0x03:
            switch index {
            case 0: return [4, 0x03, 0x09, 0x04] // English (US)
            case 1: return Self.stringDescriptor(identity.manufacturer)
            case 2: return Self.stringDescriptor(identity.product)
            case 3: return Self.stringDescriptor(identity.serialNumber)
            default: return nil
            }
        default: return nil
        }
    }

    // MARK: USB/IP export

    public func exportedDevice(busID: String, busNumber: UInt32 = 1, deviceNumber: UInt32 = 1) -> ExportedDevice {
        ExportedDevice(path: "/sys/devices/platform/macvisor-usb-audio/\(busID)", busID: busID,
                       busNumber: busNumber, deviceNumber: deviceNumber, speed: .full,
                       vendorID: identity.vendorID, productID: identity.productID, deviceRelease: identity.deviceRelease,
                       deviceClass: 0, deviceSubClass: 0, deviceProtocol: 0, configurationValue: 1,
                       numberOfConfigurations: 1, interfaces: [(0x01, 0x01, 0x00), (0x01, 0x02, 0x00), (0x01, 0x02, 0x00)])
    }

    // MARK: State

    public var isPlaybackActive: Bool { withLock { configuration == 1 && alternateSettings[1] == 1 } }
    public var isCaptureActive: Bool { withLock { configuration == 1 && alternateSettings[2] == 1 } }

    /// Puts the device back to its unconfigured state (the session ended), raising stop events for
    /// any stream that was running.
    public func reset() {
        let events: [StreamEvent] = withLock {
            var e: [StreamEvent] = []
            if configuration == 1 && alternateSettings[1] == 1 { e.append(.playbackStopped) }
            if configuration == 1 && alternateSettings[2] == 1 { e.append(.captureStopped) }
            configuration = 0
            alternateSettings = [0, 0, 0]
            return e
        }
        events.forEach { onStreamEvent?($0) }
    }

    // MARK: Control transfers

    public func handleControl(_ setup: SetupPacket, outData: Data = Data()) -> ControlResult {
        var events: [StreamEvent] = []
        let result: ControlResult = withLock {
            let r = control(setup, outData: [UInt8](outData), events: &events)
            if case .data(let bytes) = r { return .data(Array(bytes.prefix(Int(setup.length)))) }
            return r
        }
        events.forEach { onStreamEvent?($0) }
        return result
    }

    private func control(_ s: SetupPacket, outData: [UInt8], events: inout [StreamEvent]) -> ControlResult {
        let kind = (s.requestType >> 5) & 0x3 // 0 standard, 1 class
        let recipient = s.requestType & 0x1F // 0 device, 1 interface, 2 endpoint
        if kind == 0 {
            switch s.request {
            case 0x06: // GET_DESCRIPTOR
                guard let d = descriptor(type: UInt8(s.value >> 8), index: UInt8(s.value & 0xFF), language: s.index) else { return .stall }
                return .data(d)
            case 0x05, 0x01, 0x03: // SET_ADDRESS, CLEAR_FEATURE, SET_FEATURE
                return .data([])
            case 0x09: // SET_CONFIGURATION
                guard s.value <= 1 else { return .stall }
                if configuration == 1 {
                    if alternateSettings[1] == 1 { events.append(.playbackStopped) }
                    if alternateSettings[2] == 1 { events.append(.captureStopped) }
                }
                configuration = UInt8(s.value)
                alternateSettings = [0, 0, 0]
                return .data([])
            case 0x08: // GET_CONFIGURATION
                return .data([configuration])
            case 0x0B: // SET_INTERFACE
                let interface = Int(s.index & 0xFF), alt = UInt8(s.value & 0xFF)
                guard configuration == 1, (1 ... 2).contains(interface), alt <= 1 else {
                    return interface == 0 && s.value == 0 ? .data([]) : .stall
                }
                if alternateSettings[interface] != alt {
                    switch (interface, alt) {
                    case (1, 1): events.append(.playbackStarted)
                    case (1, 0): events.append(.playbackStopped)
                    case (2, 1): events.append(.captureStarted)
                    default: events.append(.captureStopped)
                    }
                }
                alternateSettings[interface] = alt
                return .data([])
            case 0x0A: // GET_INTERFACE
                let interface = Int(s.index & 0xFF)
                guard interface < alternateSettings.count else { return .stall }
                return .data([alternateSettings[interface]])
            case 0x00: // GET_STATUS
                return .data([0, 0])
            case 0x0C: // SYNCH_FRAME
                return .data([0, 0])
            default:
                return .stall
            }
        }
        guard kind == 1 else { return .stall }
        let get = s.requestType & 0x80 != 0
        // Endpoint sampling-frequency control: only 48 kHz.
        if recipient == 2, s.value >> 8 == 0x01,
           [Self.playbackEndpoint, Self.captureEndpoint].contains(UInt8(s.index & 0xFF)) {
            if !get { return outData.count >= 3 && (UInt32(outData[0]) | UInt32(outData[1]) << 8 | UInt32(outData[2]) << 16) == 48000 ? .data([]) : .stall }
            return .data(s.request == 0x84 ? [1, 0, 0] : [0x80, 0xBB, 0x00]) // GET_RES : GET_CUR/MIN/MAX
        }
        // Feature unit mute and volume (interface 0, entity in the high byte of wIndex).
        let unit = UInt8(s.index >> 8)
        if recipient == 1, s.index & 0xFF == 0, unit == Self.speakerFeatureUnit || unit == Self.microphoneFeatureUnit {
            switch (s.value >> 8, s.request) {
            case (0x01, 0x01): // SET_CUR mute
                guard let first = outData.first else { return .stall }
                muted[unit] = first != 0
                return .data([])
            case (0x01, 0x81): // GET_CUR mute
                return .data([muted[unit] == true ? 1 : 0])
            case (0x02, 0x01): // SET_CUR volume
                guard outData.count >= 2 else { return .stall }
                volume[unit] = max(Self.volumeMinimum, min(0, Int16(bitPattern: UInt16(outData[0]) | UInt16(outData[1]) << 8)))
                return .data([])
            case (0x02, 0x81): return .data(le16(volume[unit] ?? 0))
            case (0x02, 0x82): return .data(le16(Self.volumeMinimum))
            case (0x02, 0x83): return .data(le16(0))
            case (0x02, 0x84): return .data(le16(Self.volumeResolution))
            default: return .stall
            }
        }
        return .stall
    }

    private func le16(_ v: Int16) -> [UInt8] { [UInt8(UInt16(bitPattern: v) & 0xFF), UInt8(UInt16(bitPattern: v) >> 8)] }

    // MARK: Gain

    public enum Path: Sendable { case playback, capture }

    /// Applies the host's volume and mute for `path` to 16-bit PCM.
    public func applyGain(_ path: Path, to pcm: Data) -> Data {
        let unit = path == .playback ? Self.speakerFeatureUnit : Self.microphoneFeatureUnit
        let (isMuted, level) = withLock { (muted[unit] == true, volume[unit] ?? 0) }
        if isMuted { return Data(count: pcm.count) }
        if level == 0 { return pcm }
        let gain = pow(10, Double(level) / 256 / 20)
        var out = pcm
        out.withUnsafeMutableBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in samples.indices {
                samples[i] = Int16(littleEndian: Int16(clamping: Int((Double(Int16(littleEndian: samples[i])) * gain).rounded())))
            }
        }
        return out
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
