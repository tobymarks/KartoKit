import Foundation
import CZlib

/// gzip-/zlib-Dekompression über die System-zlib (iOS: libz, Linux: zlib1g).
public enum Gzip {
    public struct Error: Swift.Error, CustomStringConvertible {
        public let code: Int32
        public var description: String { "zlib-Fehler \(code)" }
    }

    public static func isGzipped(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Entpackt gzip- oder zlib-Streams (automatische Header-Erkennung, windowBits 15+32).
    public static func decompress(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        guard !data.isEmpty else { return data }
        var stream = z_stream()
        var status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw Error(code: status) }
        defer { inflateEnd(&stream) }

        var output = Data(capacity: expectedSize ?? data.count * 4)
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)

        try data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            repeat {
                try buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                        throw Error(code: status)
                    }
                    let produced = chunk - Int(stream.avail_out)
                    if produced > 0 { output.append(out.baseAddress!, count: produced) }
                }
            } while status != Z_STREAM_END && stream.avail_in > 0 || stream.avail_out == 0
        }
        return output
    }
}
