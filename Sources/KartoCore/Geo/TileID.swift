import Foundation

/// Kachel-Identität im XYZ-Schema (Slippy-Map, y wächst nach Süden).
public struct TileID: Hashable, Sendable, CustomStringConvertible, Comparable {
    public let z: Int
    public let x: Int
    public let y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z; self.x = x; self.y = y
    }

    public var description: String { "\(z)/\(x)/\(y)" }

    public static func < (a: TileID, b: TileID) -> Bool {
        if a.z != b.z { return a.z < b.z }
        if a.x != b.x { return a.x < b.x }
        return a.y < b.y
    }

    /// Anzahl Kacheln pro Achse auf dieser Zoomstufe.
    public var dimension: Int { 1 << z }

    /// Obere linke Ecke in Unit-Mercator.
    public var origin: Vec2 {
        let d = Double(dimension)
        return Vec2(Double(x) / d, Double(y) / d)
    }

    /// Kantenlänge in Unit-Mercator.
    public var extent: Double { 1.0 / Double(dimension) }

    public var parent: TileID? {
        z > 0 ? TileID(z: z - 1, x: x >> 1, y: y >> 1) : nil
    }

    public var children: [TileID] {
        [
            TileID(z: z + 1, x: x * 2, y: y * 2),
            TileID(z: z + 1, x: x * 2 + 1, y: y * 2),
            TileID(z: z + 1, x: x * 2, y: y * 2 + 1),
            TileID(z: z + 1, x: x * 2 + 1, y: y * 2 + 1),
        ]
    }

    /// Geografische Breite der Kachelmitte (für Meter/Einheit-Umrechnung).
    public var centerLatitude: Double {
        let c = origin + Vec2(extent / 2, extent / 2)
        return Mercator.unproject(c).latitude
    }

    /// Enthält eine Unit-Mercator-Position?
    public func contains(_ p: Vec2) -> Bool {
        let o = origin, e = extent
        return p.x >= o.x && p.x < o.x + e && p.y >= o.y && p.y < o.y + e
    }

    /// Kachel, die eine Unit-Mercator-Position auf Zoom z enthält.
    public static func containing(_ p: Vec2, zoom: Int) -> TileID {
        let d = Double(1 << zoom)
        let x = Int((p.x * d).rounded(.down))
        let y = Int((p.y * d).rounded(.down))
        return TileID(z: zoom, x: min(max(x, 0), (1 << zoom) - 1), y: min(max(y, 0), (1 << zoom) - 1))
    }

    // MARK: - Hilbert-Kurve (für PMTiles-Directory-Lookup)

    /// PMTiles-TileID: Hilbert-Kurvenindex über alle Zoomstufen kumuliert.
    public var pmtilesID: UInt64 {
        var acc: UInt64 = 0
        for i in 0..<z { acc += UInt64(1) << UInt64(2 * i) }
        let n = UInt64(1) << UInt64(z)
        var rx: UInt64 = 0, ry: UInt64 = 0, d: UInt64 = 0
        var tx = UInt64(x), ty = UInt64(y)
        var s = n >> 1
        while s > 0 {
            rx = (tx & s) > 0 ? 1 : 0
            ry = (ty & s) > 0 ? 1 : 0
            d += s * s * ((3 * rx) ^ ry)
            // rotate
            if ry == 0 {
                if rx == 1 {
                    tx = n - 1 - tx
                    ty = n - 1 - ty
                }
                swap(&tx, &ty)
            }
            s >>= 1
        }
        return acc + d
    }
}
