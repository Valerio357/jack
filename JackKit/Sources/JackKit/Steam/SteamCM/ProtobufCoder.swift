//
//  ProtobufCoder.swift
//  JackKit
//
//  Minimal protobuf encoder/decoder — no external dependencies.
//  Supports only the wire types needed for Steam CM protocol.
//

import Foundation

// MARK: - Wire types

public enum ProtoWireType: UInt8 {
    case varint = 0          // int32, int64, uint32, uint64, bool, enum
    case fixed64 = 1         // fixed64, sfixed64, double
    case lengthDelimited = 2 // string, bytes, sub-messages
    case fixed32 = 5         // fixed32, sfixed32, float
}

// MARK: - Encoder

public struct ProtoEncoder {
    private var data = Data()

    public init() {}

    public var output: Data { data }

    // Varint (int32, uint32, int64, uint64, bool)
    public mutating func writeVarint(field: UInt32, value: UInt64) {
        writeTag(field: field, wireType: .varint)
        writeRawVarint(value)
    }

    public mutating func writeBool(field: UInt32, value: Bool) {
        writeVarint(field: field, value: value ? 1 : 0)
    }

    public mutating func writeInt32(field: UInt32, value: Int32) {
        writeVarint(field: field, value: UInt64(bitPattern: Int64(value)))
    }

    public mutating func writeUInt32(field: UInt32, value: UInt32) {
        writeVarint(field: field, value: UInt64(value))
    }

    // Fixed64
    public mutating func writeFixed64(field: UInt32, value: UInt64) {
        writeTag(field: field, wireType: .fixed64)
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 8))
    }

    // Fixed32
    public mutating func writeFixed32(field: UInt32, value: UInt32) {
        writeTag(field: field, wireType: .fixed32)
        var v = value.littleEndian
        data.append(Data(bytes: &v, count: 4))
    }

    // String
    public mutating func writeString(field: UInt32, value: String) {
        guard !value.isEmpty else { return }
        let bytes = Data(value.utf8)
        writeTag(field: field, wireType: .lengthDelimited)
        writeRawVarint(UInt64(bytes.count))
        data.append(bytes)
    }

    // Bytes
    public mutating func writeBytes(field: UInt32, value: Data) {
        guard !value.isEmpty else { return }
        writeTag(field: field, wireType: .lengthDelimited)
        writeRawVarint(UInt64(value.count))
        data.append(value)
    }

    // Sub-message
    public mutating func writeMessage(field: UInt32, value: Data) {
        writeTag(field: field, wireType: .lengthDelimited)
        writeRawVarint(UInt64(value.count))
        data.append(value)
    }

    // Raw helpers
    private mutating func writeTag(field: UInt32, wireType: ProtoWireType) {
        writeRawVarint(UInt64((field << 3) | UInt32(wireType.rawValue)))
    }

    private mutating func writeRawVarint(_ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }
}

// MARK: - Decoder

public struct ProtoDecoder {
    private let data: Data
    private var offset: Int = 0

    public init(data: Data) {
        self.data = data
    }

    public var isAtEnd: Bool { offset >= data.count }

    public struct Field {
        public let number: UInt32
        public let wireType: ProtoWireType
    }

    public mutating func readField() -> Field? {
        guard !isAtEnd else { return nil }
        guard let tag = readRawVarint() else { return nil }
        let wireType = ProtoWireType(rawValue: UInt8(tag & 0x07)) ?? .varint
        let number = UInt32(tag >> 3)
        return Field(number: number, wireType: wireType)
    }

    public mutating func readVarint() -> UInt64? {
        return readRawVarint()
    }

    public mutating func readInt32() -> Int32? {
        guard let v = readRawVarint() else { return nil }
        return Int32(truncatingIfNeeded: v)
    }

    public mutating func readUInt32() -> UInt32? {
        guard let v = readRawVarint() else { return nil }
        return UInt32(truncatingIfNeeded: v)
    }

    public mutating func readBool() -> Bool? {
        guard let v = readRawVarint() else { return nil }
        return v != 0
    }

    public mutating func readFixed64() -> UInt64? {
        guard offset + 8 <= data.count else { return nil }
        let value = data[offset..<offset+8].withUnsafeBytes { $0.load(as: UInt64.self) }
        offset += 8
        return UInt64(littleEndian: value)
    }

    public mutating func readFixed32() -> UInt32? {
        guard offset + 4 <= data.count else { return nil }
        let value = data[offset..<offset+4].withUnsafeBytes { $0.load(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: value)
    }

    public mutating func readBytes() -> Data? {
        guard let length = readRawVarint() else { return nil }
        let len = Int(length)
        guard offset + len <= data.count else { return nil }
        let result = data[offset..<offset+len]
        offset += len
        return Data(result)
    }

    public mutating func readString() -> String? {
        guard let bytes = readBytes() else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    public mutating func skipField(_ field: Field) {
        switch field.wireType {
        case .varint: _ = readRawVarint()
        case .fixed64: offset += 8
        case .fixed32: offset += 4
        case .lengthDelimited: _ = readBytes()
        }
    }

    private mutating func readRawVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}
