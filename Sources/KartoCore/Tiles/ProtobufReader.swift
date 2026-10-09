import Foundation

/// Minimaler, allokationsarmer Protobuf-Wire-Format-Leser.
/// Bewusst ohne SwiftProtobuf-Abhängigkeit: MVT nutzt nur einen kleinen Teil des
/// Formats, und ein handgeschriebener Parser ist deutlich schneller als generierte
/// Message-Klassen (keine Zwischenobjekte pro Feature).
public struct ProtobufReader {
    public enum WireType: UInt8 {
        case varint = 0, fixed64 = 1, lengthDelimited = 2, fixed32 = 5
    }

    public struct DecodeError: Error, CustomStringConvertible {
        public let description: String
    }

    private let bytes: UnsafeBufferPointer<UInt8>
    public private(set) var position: Int
    public let end: Int

    public init(_ bytes: UnsafeBufferPointer<UInt8>, start: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.position = start
        self.end = end ?? bytes.count
    }

    public var isAtEnd: Bool { position >= end }

    public mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard position < end else { throw DecodeError(description: "varint überschreitet Puffer") }
            let b = bytes[position]
            position += 1
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw DecodeError(description: "varint zu lang") }
        }
    }

    public mutating func readTag() throws -> (field: Int, wire: WireType) {
        let v = try readVarint()
        guard let w = WireType(rawValue: UInt8(v & 0x7)) else {
            throw DecodeError(description: "unbekannter Wire-Type \(v & 0x7)")
        }
        return (Int(v >> 3), w)
    }

    public mutating func readFixed32() throws -> UInt32 {
        guard position + 4 <= end else { throw DecodeError(description: "fixed32 überschreitet Puffer") }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[position + i]) << (8 * UInt32(i)) }
        position += 4
        return v
    }

    public mutating func readFixed64() throws -> UInt64 {
        guard position + 8 <= end else { throw DecodeError(description: "fixed64 überschreitet Puffer") }
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[position + i]) << (8 * UInt64(i)) }
        position += 8
        return v
    }

    /// Liefert (start, end) eines length-delimited Felds und springt dahinter.
    public mutating func readLengthDelimited() throws -> (Int, Int) {
        let len = Int(try readVarint())
        guard position + len <= end else { throw DecodeError(description: "Länge überschreitet Puffer") }
        let start = position
        position += len
        return (start, start + len)
    }

    public mutating func readString() throws -> String {
        let (s, e) = try readLengthDelimited()
        let slice = UnsafeBufferPointer(rebasing: bytes[s..<e])
        return String(decoding: slice, as: UTF8.self)
    }

    public mutating func skip(_ wire: WireType) throws {
        switch wire {
        case .varint: _ = try readVarint()
        case .fixed64: _ = try readFixed64()
        case .fixed32: _ = try readFixed32()
        case .lengthDelimited: _ = try readLengthDelimited()
        }
    }

    /// Sub-Reader für ein eingebettetes Feld.
    public func sub(_ range: (Int, Int)) -> ProtobufReader {
        ProtobufReader(bytes, start: range.0, end: range.1)
    }

    public static func zigzag(_ v: UInt64) -> Int64 {
        Int64(v >> 1) ^ -Int64(v & 1)
    }
}
