import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Byte-Bereichs-Quelle für PMTiles (HTTP Range Requests oder lokale Datei).
public protocol RangeReader: Sendable {
    func read(offset: UInt64, length: UInt64) async throws -> Data
}

/// Lokale Datei (z. B. gebündeltes Offline-Archiv).
public struct FileRangeReader: RangeReader {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func read(offset: UInt64, length: UInt64) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: Int(length)) ?? Data()
    }
}

/// HTTP Range Requests – PMTiles auf S3/CDN ohne Tile-Server.
public struct HTTPRangeReader: RangeReader {
    public let url: URL
    public let session: URLSession
    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func read(offset: UInt64, length: UInt64) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 206, http.statusCode != 200 {
            throw PMTilesError.http(http.statusCode)
        }
        return data
    }
}

public enum PMTilesError: Error, CustomStringConvertible {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unsupportedCompression(UInt8)
    case truncated
    case http(Int)

    public var description: String {
        switch self {
        case .invalidMagic: return "Keine PMTiles-Datei (Magic fehlt)"
        case .unsupportedVersion(let v): return "PMTiles-Version \(v) nicht unterstützt (nur v3)"
        case .unsupportedCompression(let c): return "Kompression \(c) nicht unterstützt (nur none/gzip)"
        case .truncated: return "PMTiles-Daten abgeschnitten"
        case .http(let code): return "HTTP \(code)"
        }
    }
}

/// PMTiles-v3-Header (127 Bytes).
public struct PMTilesHeader: Sendable {
    public enum Compression: UInt8, Sendable { case unknown = 0, none = 1, gzip = 2, brotli = 3, zstd = 4 }
    public enum TileType: UInt8, Sendable { case unknown = 0, mvt = 1, png = 2, jpeg = 3, webp = 4, avif = 5 }

    public var rootDirectoryOffset: UInt64
    public var rootDirectoryLength: UInt64
    public var metadataOffset: UInt64
    public var metadataLength: UInt64
    public var leafDirectoriesOffset: UInt64
    public var leafDirectoriesLength: UInt64
    public var tileDataOffset: UInt64
    public var tileDataLength: UInt64
    public var addressedTiles: UInt64
    public var tileEntries: UInt64
    public var tileContents: UInt64
    public var clustered: Bool
    public var internalCompression: Compression
    public var tileCompression: Compression
    public var tileType: TileType
    public var minZoom: UInt8
    public var maxZoom: UInt8
    public var minLon: Double, minLat: Double, maxLon: Double, maxLat: Double
    public var centerZoom: UInt8
    public var centerLon: Double, centerLat: Double

    public static let size = 127

    public init(_ data: Data) throws {
        guard data.count >= Self.size else { throw PMTilesError.truncated }
        let b = [UInt8](data.prefix(Self.size))
        guard String(bytes: b[0..<7], encoding: .ascii) == "PMTiles" else { throw PMTilesError.invalidMagic }
        guard b[7] == 3 else { throw PMTilesError.unsupportedVersion(b[7]) }
        func u64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(b[o + i]) << (8 * UInt64(i)) }
            return v
        }
        func i32(_ o: Int) -> Int32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(b[o + i]) << (8 * UInt32(i)) }
            return Int32(bitPattern: v)
        }
        rootDirectoryOffset = u64(8); rootDirectoryLength = u64(16)
        metadataOffset = u64(24); metadataLength = u64(32)
        leafDirectoriesOffset = u64(40); leafDirectoriesLength = u64(48)
        tileDataOffset = u64(56); tileDataLength = u64(64)
        addressedTiles = u64(72); tileEntries = u64(80); tileContents = u64(88)
        clustered = b[96] == 1
        internalCompression = Compression(rawValue: b[97]) ?? .unknown
        tileCompression = Compression(rawValue: b[98]) ?? .unknown
        tileType = TileType(rawValue: b[99]) ?? .unknown
        minZoom = b[100]; maxZoom = b[101]
        minLon = Double(i32(102)) / 1e7; minLat = Double(i32(106)) / 1e7
        maxLon = Double(i32(110)) / 1e7; maxLat = Double(i32(114)) / 1e7
        centerZoom = b[118]
        centerLon = Double(i32(119)) / 1e7; centerLat = Double(i32(123)) / 1e7
    }
}

public struct PMTilesEntry: Sendable, Equatable {
    public var tileID: UInt64
    public var offset: UInt64
    public var length: UInt32
    /// 0 = Verweis auf ein Leaf-Directory, sonst Anzahl aufeinanderfolgender TileIDs mit gleichem Inhalt.
    public var runLength: UInt32
}

/// PMTiles-v3-Reader: Header, Directories (Root + Leaf, mit Cache), Tile-Lookup.
public actor PMTilesArchive {
    public let reader: RangeReader
    public private(set) var header: PMTilesHeader!
    private var rootDirectory: [PMTilesEntry] = []
    private var leafCache: [UInt64: [PMTilesEntry]] = [:]

    public init(reader: RangeReader) {
        self.reader = reader
    }

    public init(url: URL) {
        reader = url.isFileURL ? FileRangeReader(url: url) : HTTPRangeReader(url: url)
    }

    /// Lädt Header + Root-Directory (ein Range-Request von 16 KB reicht meist für beides).
    public func open() async throws -> PMTilesHeader {
        if header != nil { return header }
        let head = try await reader.read(offset: 0, length: 16384)
        let h = try PMTilesHeader(head)
        try Self.check(h.internalCompression)
        try Self.check(h.tileCompression)
        let dirEnd = h.rootDirectoryOffset + h.rootDirectoryLength
        let dirData: Data
        if dirEnd <= UInt64(head.count) {
            dirData = head.subdata(in: Int(h.rootDirectoryOffset)..<Int(dirEnd))
        } else {
            dirData = try await reader.read(offset: h.rootDirectoryOffset, length: h.rootDirectoryLength)
        }
        rootDirectory = try Self.decodeDirectory(Self.decompress(dirData, h.internalCompression))
        header = h
        return h
    }

    /// Liefert die (bereits dekomprimierten) Tile-Bytes oder nil, wenn die Kachel nicht existiert.
    public func tile(_ id: TileID) async throws -> Data? {
        let h = try await open()
        guard id.z >= Int(h.minZoom), id.z <= Int(h.maxZoom) else { return nil }
        let tileID = id.pmtilesID
        var directory = rootDirectory
        for _ in 0..<4 { // max. Verschachtelungstiefe
            guard let entry = Self.find(tileID, in: directory) else { return nil }
            if entry.runLength > 0 {
                let data = try await reader.read(offset: h.tileDataOffset + entry.offset, length: UInt64(entry.length))
                return try Self.decompress(data, h.tileCompression)
            }
            let leafOffset = h.leafDirectoriesOffset + entry.offset
            if let cached = leafCache[leafOffset] {
                directory = cached
            } else {
                let raw = try await reader.read(offset: leafOffset, length: UInt64(entry.length))
                let leaf = try Self.decodeDirectory(Self.decompress(raw, h.internalCompression))
                leafCache[leafOffset] = leaf
                directory = leaf
            }
        }
        return nil
    }

    // MARK: - Statische Hilfsfunktionen (testbar)

    static func check(_ c: PMTilesHeader.Compression) throws {
        guard c == .none || c == .gzip else { throw PMTilesError.unsupportedCompression(c.rawValue) }
    }

    static func decompress(_ data: Data, _ c: PMTilesHeader.Compression) throws -> Data {
        switch c {
        case .gzip: return try Gzip.decompress(data)
        case .none, .unknown: return Gzip.isGzipped(data) ? try Gzip.decompress(data) : data
        default: throw PMTilesError.unsupportedCompression(c.rawValue)
        }
    }

    /// Directory-Format: n, dann TileIDs (delta), RunLengths, Lengths, Offsets (0 = fortlaufend).
    public static func decodeDirectory(_ data: Data) throws -> [PMTilesEntry] {
        try data.withUnsafeBytes { raw -> [PMTilesEntry] in
            var r = ProtobufReader(raw.bindMemory(to: UInt8.self))
            let n = Int(try r.readVarint())
            var entries = [PMTilesEntry](repeating: PMTilesEntry(tileID: 0, offset: 0, length: 0, runLength: 0), count: n)
            var last: UInt64 = 0
            for i in 0..<n {
                last += try r.readVarint()
                entries[i].tileID = last
            }
            for i in 0..<n { entries[i].runLength = UInt32(try r.readVarint()) }
            for i in 0..<n { entries[i].length = UInt32(try r.readVarint()) }
            for i in 0..<n {
                let v = try r.readVarint()
                if v == 0, i > 0 {
                    entries[i].offset = entries[i - 1].offset + UInt64(entries[i - 1].length)
                } else {
                    entries[i].offset = v - 1
                }
            }
            return entries
        }
    }

    /// Binäre Suche: letzter Eintrag mit tileID ≤ gesucht; Treffer nur innerhalb RunLength.
    public static func find(_ tileID: UInt64, in dir: [PMTilesEntry]) -> PMTilesEntry? {
        var lo = 0, hi = dir.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if dir[mid].tileID > tileID { hi = mid - 1 } else { lo = mid + 1 }
        }
        guard hi >= 0 else { return nil }
        let e = dir[hi]
        if e.runLength == 0 { return e } // Leaf-Verweis: deckt alle IDs bis zum nächsten Eintrag ab
        return tileID < e.tileID + UInt64(e.runLength) ? e : nil
    }
}
