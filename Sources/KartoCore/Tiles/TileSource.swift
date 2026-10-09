import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Liefert rohe (dekomprimierte) MVT-Bytes für eine Kachel.
public protocol TileSource: Sendable {
    var minZoom: Int { get }
    var maxZoom: Int { get }
    /// nil = Kachel existiert nicht (transparent/leer).
    func tileData(_ id: TileID) async throws -> Data?
}

/// PMTiles-Archiv als Kachelquelle (lokal oder per HTTP-Range).
public struct PMTilesSource: TileSource {
    public let archive: PMTilesArchive
    public let minZoom: Int
    public let maxZoom: Int

    public init(archive: PMTilesArchive) async throws {
        self.archive = archive
        let h = try await archive.open()
        minZoom = Int(h.minZoom)
        maxZoom = Int(h.maxZoom)
    }

    public init(url: URL) async throws {
        try await self.init(archive: PMTilesArchive(url: url))
    }

    public func tileData(_ id: TileID) async throws -> Data? {
        try await archive.tile(id)
    }
}

/// Klassische XYZ-Kachel-URL, z. B. `https://tiles.example.com/{z}/{x}/{y}.pbf?key=…`
public struct XYZTileSource: TileSource {
    public let template: String
    public let minZoom: Int
    public let maxZoom: Int
    public let session: URLSession

    public init(template: String, minZoom: Int = 0, maxZoom: Int = 14, session: URLSession = .shared) {
        self.template = template
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.session = session
    }

    public func url(for id: TileID) -> URL? {
        URL(string: template
            .replacingOccurrences(of: "{z}", with: String(id.z))
            .replacingOccurrences(of: "{x}", with: String(id.x))
            .replacingOccurrences(of: "{y}", with: String(id.y)))
    }

    public func tileData(_ id: TileID) async throws -> Data? {
        guard id.z >= minZoom, id.z <= maxZoom, let url = url(for: id) else { return nil }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 204 || http.statusCode == 404 { return nil }
            guard (200..<300).contains(http.statusCode) else { throw PMTilesError.http(http.statusCode) }
        }
        return Gzip.isGzipped(data) ? try Gzip.decompress(data) : data
    }
}

/// Öffnet die eigentliche Quelle erst bei der ersten Kachelanfrage (z. B. ein PMTiles-Archiv,
/// dessen Header asynchron gelesen wird) – damit lässt sich eine `MapView` synchron anlegen.
public actor LazyTileSource: TileSource {
    public nonisolated let minZoom: Int
    public nonisolated let maxZoom: Int
    private let make: @Sendable () async throws -> any TileSource
    private var inner: (any TileSource)?
    private var opening: Task<any TileSource, Error>?

    /// `minZoom`/`maxZoom`: Erwartete Zoomspanne (wird für die Kachelabdeckung gebraucht, bevor
    /// die Quelle offen ist). `make` liefert die echte Quelle.
    public init(minZoom: Int = 0, maxZoom: Int = 15, make: @escaping @Sendable () async throws -> any TileSource) {
        self.minZoom = minZoom; self.maxZoom = maxZoom; self.make = make
    }

    private func source() async throws -> any TileSource {
        if let inner { return inner }
        if let opening { return try await opening.value }
        let t = Task { try await make() }
        opening = t
        let s = try await t.value
        inner = s; opening = nil
        return s
    }

    public func tileData(_ id: TileID) async throws -> Data? {
        let s = try await source()
        guard id.z >= s.minZoom, id.z <= s.maxZoom else { return nil }
        return try await s.tileData(id)
    }
}

/// OpenFreeMap (openfreemap.org): kostenlose, weltweite OSM-Vektorkacheln ohne Schlüssel im
/// OpenMapTiles-Schema (`TileSchema.openMapTiles`), z0–14. Die aktuelle Kachel-URL steht im
/// TileJSON unter `https://tiles.openfreemap.org/planet` und wechselt mit jedem Datenstand –
/// deshalb wird sie beim ersten Zugriff aufgelöst. Nutzungsbedingungen: openfreemap.org
/// (Attribution © OpenMapTiles © OpenStreetMap contributors).
public enum OpenFreeMap {
    public static let tileJSONURL = URL(string: "https://tiles.openfreemap.org/planet")!
    public static let maxZoom = 14

    /// Kachelquelle mit Auflösung des TileJSON beim ersten Zugriff.
    public static func source(session: URLSession = .shared) -> LazyTileSource {
        LazyTileSource(minZoom: 0, maxZoom: maxZoom) {
            let template = try await tileTemplate(session: session)
            return XYZTileSource(template: template, minZoom: 0, maxZoom: maxZoom, session: session)
        }
    }

    /// Liest `tiles[0]` aus dem TileJSON.
    public static func tileTemplate(session: URLSession = .shared) async throws -> String {
        let (data, _) = try await session.data(from: tileJSONURL)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tiles = obj["tiles"] as? [String], let first = tiles.first else {
            throw URLError(.cannotParseResponse)
        }
        return first
    }
}
