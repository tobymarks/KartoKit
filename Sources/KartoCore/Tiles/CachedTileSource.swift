import Foundation

/// Disk-Cache um eine beliebige `TileSource` (XYZ oder PMTiles): fertige, dekomprimierte
/// MVT-Bytes je Kachel als Datei. Offline werden gecachte Kacheln geliefert; bei
/// Netzfehlern greift der Cache ebenfalls. LRU-Verdrängung nach Zugriffszeit.
///
///     let source = CachedTileSource(wrapping: XYZTileSource(template: …), name: "maptiler-v3", maxBytes: 300 << 20)
public actor CachedTileSource: TileSource {
    public let inner: TileSource
    public nonisolated let minZoom: Int
    public nonisolated let maxZoom: Int
    private let directory: URL
    private let maxBytes: Int
    private var approxBytes = 0
    private var lastSweep = Date.distantPast
    /// Kacheln, die die Quelle als "nicht vorhanden" gemeldet hat (kein Dateizugriff nötig).
    private var knownEmpty = Set<TileID>()
    /// Kachel-Alter, ab dem online neu geladen wird (Sekunden); nil = nie ablaufen.
    public let maxAge: TimeInterval?

    public init(wrapping inner: TileSource, name: String, maxBytes: Int = 300 * 1024 * 1024, maxAge: TimeInterval? = 14 * 86400,
                baseDirectory: URL? = nil) {
        self.inner = inner
        minZoom = inner.minZoom
        maxZoom = inner.maxZoom
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        let base = baseDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("KartoKitTiles", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(_ id: TileID) -> URL {
        directory.appendingPathComponent("\(id.z)").appendingPathComponent("\(id.x)_\(id.y).mvt")
    }

    public func tileData(_ id: TileID) async throws -> Data? {
        if knownEmpty.contains(id) { return nil }
        let url = fileURL(id)
        let fm = FileManager.default
        var cached: Data?
        var fresh = false
        if let attrs = try? fm.attributesOfItem(atPath: url.path), let mod = attrs[.modificationDate] as? Date {
            cached = try? Data(contentsOf: url)
            if cached != nil {
                fresh = maxAge.map { Date().timeIntervalSince(mod) < $0 } ?? true
                // Zugriffszeit für LRU aktualisieren (billig, nur bei Treffern)
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            }
        }
        if let c = cached, fresh { return c.isEmpty ? nil : c }

        do {
            let data = try await inner.tileData(id)
            guard let data else {
                knownEmpty.insert(id)
                try? Data().write(to: url) // leer = existiert nicht
                return nil
            }
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            approxBytes += data.count
            if approxBytes > maxBytes / 8 || Date().timeIntervalSince(lastSweep) > 300 { sweep() }
            return data
        } catch {
            // Offline / Fehler: alte Kachel ist besser als keine.
            if let c = cached { return c.isEmpty ? nil : c }
            throw error
        }
    }

    /// Größe prüfen und älteste Dateien löschen, bis 80 % des Budgets erreicht sind.
    private func sweep() {
        lastSweep = Date()
        approxBytes = 0
        let fm = FileManager.default
        guard let e = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        var files: [(URL, Int, Date)] = []
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]), v.isDirectory != true else { continue }
            files.append((u, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }
        for f in files.sorted(by: { $0.2 < $1.2 }) {
            try? fm.removeItem(at: f.0)
            total -= f.1
            if total < maxBytes * 8 / 10 { break }
        }
    }

    /// Cache leeren (z. B. bei Kartenupdate).
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        knownEmpty.removeAll()
    }

    public func diskUsage() -> Int {
        var total = 0
        if let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e { total += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        }
        return total
    }
}
