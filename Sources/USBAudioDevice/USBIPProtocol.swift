import Foundation

/// The USB/IP wire protocol, version 1.1.1, as the Linux kernel documents it
/// (Documentation/usb/usbip_protocol.rst). Every field is big-endian.
public enum USBIP {
    public static let version: UInt16 = 0x0111
    public static let defaultPort: UInt16 = 3240

    /// "No isochronous packets" in `number_of_packets`. Not an error and never a count.
    public static let noIsoPackets: UInt32 = 0xFFFF_FFFF

    /// Defensive limits for what a client may send.
    public static let maxTransferLength = 1 << 20
    public static let maxIsoPackets = 1024

    public enum OpCode: UInt16, Sendable {
        case requestDeviceList = 0x8005
        case replyDeviceList = 0x0005
        case requestImport = 0x8003
        case replyImport = 0x0003
    }

    public enum Command: UInt32, Sendable {
        case submit = 1
        case unlink = 2
        case replySubmit = 3
        case replyUnlink = 4
    }

    public enum Direction: UInt32, Sendable {
        case out = 0
        case `in` = 1
    }

    public enum Speed: UInt32, Sendable {
        case low = 1
        case full = 2
        case high = 3
        case superSpeed = 5
    }

    /// URB status codes (negative Linux errno values).
    public enum Status {
        public static let ok: Int32 = 0
        public static let stall: Int32 = -32 // EPIPE
        public static let invalid: Int32 = -22 // EINVAL
        public static let connectionReset: Int32 = -104 // ECONNRESET: an unlinked URB
    }

    public enum ProtocolError: Error, Equatable, Sendable {
        case unsupportedVersion(UInt16)
        case unexpectedOperation(UInt16)
        case unexpectedCommand(UInt32)
        case transferTooLong(UInt32)
        case tooManyIsoPackets(UInt32)
        case isoPacketOutOfRange
    }
}

// MARK: - Messages

/// One isochronous packet descriptor.
public struct IsoPacket: Equatable, Sendable {
    public var offset: UInt32
    public var length: UInt32
    public var actualLength: UInt32
    public var status: Int32

    public init(offset: UInt32, length: UInt32, actualLength: UInt32 = 0, status: Int32 = 0) {
        self.offset = offset
        self.length = length
        self.actualLength = actualLength
        self.status = status
    }
}

/// A USBIP_CMD_SUBMIT: one URB from the client.
public struct SubmitRequest: Equatable, Sendable {
    public var sequence: UInt32
    public var deviceID: UInt32
    public var direction: USBIP.Direction
    public var endpoint: UInt32
    public var transferFlags: UInt32
    public var transferBufferLength: UInt32
    public var startFrame: UInt32
    public var numberOfPackets: UInt32
    public var interval: UInt32
    public var setup: [UInt8]
    /// The data of an OUT transfer.
    public var outData: Data
    public var isoPackets: [IsoPacket]

    public var isIsochronous: Bool { numberOfPackets != USBIP.noIsoPackets && numberOfPackets != 0 }
}

/// A USBIP_CMD_UNLINK: the client cancels an earlier URB.
public struct UnlinkRequest: Equatable, Sendable {
    public var sequence: UInt32
    public var unlinkSequence: UInt32
}

public enum ClientCommand: Equatable, Sendable {
    case submit(SubmitRequest)
    case unlink(UnlinkRequest)
}

/// What a server exports, as OP_REP_DEVLIST and OP_REP_IMPORT describe it.
public struct ExportedDevice: Equatable, Sendable {
    public var path: String
    public var busID: String
    public var busNumber: UInt32
    public var deviceNumber: UInt32
    public var speed: USBIP.Speed
    public var vendorID: UInt16
    public var productID: UInt16
    public var deviceRelease: UInt16
    public var deviceClass: UInt8
    public var deviceSubClass: UInt8
    public var deviceProtocol: UInt8
    public var configurationValue: UInt8
    public var numberOfConfigurations: UInt8
    /// Class, subclass and protocol of each interface of the active configuration.
    public var interfaces: [(UInt8, UInt8, UInt8)]

    public static func == (a: ExportedDevice, b: ExportedDevice) -> Bool {
        a.path == b.path && a.busID == b.busID && a.busNumber == b.busNumber && a.deviceNumber == b.deviceNumber
            && a.speed == b.speed && a.vendorID == b.vendorID && a.productID == b.productID
            && a.deviceRelease == b.deviceRelease && a.deviceClass == b.deviceClass
            && a.deviceSubClass == b.deviceSubClass && a.deviceProtocol == b.deviceProtocol
            && a.configurationValue == b.configurationValue && a.numberOfConfigurations == b.numberOfConfigurations
            && a.interfaces.elementsEqual(b.interfaces, by: { $0 == $1 })
    }
}

// MARK: - Encoding

struct BigEndianWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func zeros(_ n: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: n)) }
    mutating func bytes(_ d: Data) { data.append(d) }
    /// A NUL-padded fixed-size string field.
    mutating func fixedString(_ s: String, size: Int) {
        var b = Array(s.utf8.prefix(size - 1))
        b.append(contentsOf: [UInt8](repeating: 0, count: size - b.count))
        data.append(contentsOf: b)
    }
}

struct BigEndianReader {
    let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func u16() -> UInt16 { let v = data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + 2); offset += 2; return v.withUnsafeBytes { UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self)) } }
    mutating func u32() -> UInt32 { let v = data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + 4); offset += 4; return v.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) } }
    mutating func i32() -> Int32 { Int32(bitPattern: u32()) }
    mutating func bytes(_ n: Int) -> Data { let v = data.subdata(in: data.startIndex + offset ..< data.startIndex + offset + n); offset += n; return v }
}

extension USBIP {
    /// OP_REP_DEVLIST for `devices`.
    public static func encodeDeviceList(_ devices: [ExportedDevice]) -> Data {
        var w = BigEndianWriter()
        w.u16(version); w.u16(OpCode.replyDeviceList.rawValue); w.u32(0)
        w.u32(UInt32(devices.count))
        for device in devices {
            encode(device, into: &w)
            for (cls, sub, proto) in device.interfaces { w.u8(cls); w.u8(sub); w.u8(proto); w.u8(0) }
        }
        return w.data
    }

    /// OP_REP_IMPORT: the device on success, or only the header with a non-zero status.
    public static func encodeImportReply(_ device: ExportedDevice?) -> Data {
        var w = BigEndianWriter()
        w.u16(version); w.u16(OpCode.replyImport.rawValue); w.u32(device == nil ? 1 : 0)
        if let device { encode(device, into: &w) }
        return w.data
    }

    static func encode(_ d: ExportedDevice, into w: inout BigEndianWriter) {
        w.fixedString(d.path, size: 256)
        w.fixedString(d.busID, size: 32)
        w.u32(d.busNumber); w.u32(d.deviceNumber); w.u32(d.speed.rawValue)
        w.u16(d.vendorID); w.u16(d.productID); w.u16(d.deviceRelease)
        w.u8(d.deviceClass); w.u8(d.deviceSubClass); w.u8(d.deviceProtocol)
        w.u8(d.configurationValue); w.u8(d.numberOfConfigurations); w.u8(UInt8(d.interfaces.count))
    }

    /// USBIP_RET_SUBMIT. `data` is the IN data, packed for isochronous transfers (only the bytes each
    /// packet actually carries, in order), as the protocol requires.
    public static func encodeSubmitReply(sequence: UInt32, status: Int32, actualLength: UInt32, startFrame: UInt32,
                                         isoPackets: [IsoPacket]?, errorCount: UInt32 = 0, data: Data = Data()) -> Data {
        var w = BigEndianWriter()
        // The protocol wants devid, direction and ep zero in replies.
        w.u32(Command.replySubmit.rawValue); w.u32(sequence); w.u32(0); w.u32(0); w.u32(0)
        w.i32(status); w.u32(actualLength); w.u32(startFrame)
        w.u32(isoPackets.map { UInt32($0.count) } ?? noIsoPackets)
        w.u32(errorCount); w.zeros(8)
        w.bytes(data)
        for p in isoPackets ?? [] { w.u32(p.offset); w.u32(p.length); w.u32(p.actualLength); w.i32(p.status) }
        return w.data
    }

    /// USBIP_RET_UNLINK.
    public static func encodeUnlinkReply(sequence: UInt32, status: Int32) -> Data {
        var w = BigEndianWriter()
        w.u32(Command.replyUnlink.rawValue); w.u32(sequence); w.u32(0); w.u32(0); w.u32(0)
        w.i32(status); w.zeros(24)
        return w.data
    }
}

// MARK: - Decoding from a stream

extension USBIP {
    /// Reads an operation header (version, code, status) and checks the version.
    public static func readOperation(from stream: ByteStream) throws -> UInt16 {
        var r = BigEndianReader(try stream.read(exactly: 8))
        let v = r.u16()
        guard v == version else { throw ProtocolError.unsupportedVersion(v) }
        return r.u16()
    }

    /// Reads the bus ID that follows OP_REQ_IMPORT.
    public static func readImportBusID(from stream: ByteStream) throws -> String {
        let raw = try stream.read(exactly: 32)
        return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Reads one USBIP_CMD_SUBMIT or USBIP_CMD_UNLINK, validating every length before reading data.
    public static func readCommand(from stream: ByteStream) throws -> ClientCommand {
        var r = BigEndianReader(try stream.read(exactly: 48))
        let command = r.u32(), sequence = r.u32(), deviceID = r.u32(), directionRaw = r.u32(), endpoint = r.u32()
        switch command {
        case Command.submit.rawValue:
            let flags = r.u32(), length = r.u32(), startFrame = r.u32(), packets = r.u32(), interval = r.u32()
            let setup = [UInt8](r.bytes(8))
            guard length <= UInt32(maxTransferLength) else { throw ProtocolError.transferTooLong(length) }
            let direction = USBIP.Direction(rawValue: directionRaw) ?? .out
            let isIso = packets != noIsoPackets && packets != 0
            guard !isIso || packets <= UInt32(maxIsoPackets) else { throw ProtocolError.tooManyIsoPackets(packets) }
            let outData = direction == .out && length > 0 ? try stream.read(exactly: Int(length)) : Data()
            var iso: [IsoPacket] = []
            if isIso {
                var d = BigEndianReader(try stream.read(exactly: Int(packets) * 16))
                for _ in 0 ..< Int(packets) {
                    let p = IsoPacket(offset: d.u32(), length: d.u32(), actualLength: d.u32(), status: d.i32())
                    guard UInt64(p.offset) + UInt64(p.length) <= UInt64(length) else { throw ProtocolError.isoPacketOutOfRange }
                    iso.append(p)
                }
            }
            return .submit(SubmitRequest(sequence: sequence, deviceID: deviceID, direction: direction, endpoint: endpoint,
                                         transferFlags: flags, transferBufferLength: length, startFrame: startFrame,
                                         numberOfPackets: packets, interval: interval, setup: setup, outData: outData,
                                         isoPackets: iso))
        case Command.unlink.rawValue:
            let target = r.u32()
            return .unlink(UnlinkRequest(sequence: sequence, unlinkSequence: target))
        default:
            throw ProtocolError.unexpectedCommand(command)
        }
    }
}
