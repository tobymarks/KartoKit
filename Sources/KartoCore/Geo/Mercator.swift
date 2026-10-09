import Foundation

/// Geografische Koordinate (WGS84).
public struct Coordinate: Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Web-Mercator-Hilfsfunktionen.
///
/// Weltkoordinaten in KartoKit: "Unit Mercator" – x, y ∈ [0, 1], Ursprung oben links
/// (x nach Osten, y nach Süden). Pixelkoordinaten für eine Zoomstufe z ergeben sich
/// durch Multiplikation mit `worldSize(zoom:)`.
public enum Mercator {
    public static let earthRadius = 6_378_137.0
    public static let earthCircumference = 2 * Double.pi * earthRadius
    public static let maxLatitude = 85.051_128_779_806_59
    /// Logische Kachelgröße in Pixeln (Retina-Stil, wie MapLibre/Mapbox 512px-Tiles).
    public static let tileSize = 512.0

    public static func worldSize(zoom: Double) -> Double {
        tileSize * pow(2.0, zoom)
    }

    /// Geokoordinate → Unit-Mercator [0,1]².
    public static func project(_ c: Coordinate) -> Vec2 {
        let lat = min(max(c.latitude, -maxLatitude), maxLatitude)
        let x = (c.longitude + 180) / 360
        let sinLat = sin(lat * .pi / 180)
        let y = 0.5 - log((1 + sinLat) / (1 - sinLat)) / (4 * .pi)
        return Vec2(x, y)
    }

    /// Unit-Mercator → Geokoordinate.
    public static func unproject(_ p: Vec2) -> Coordinate {
        let lon = p.x * 360 - 180
        let n = .pi - 2 * .pi * p.y
        let lat = 180 / .pi * atan(0.5 * (exp(n) - exp(-n)))
        return Coordinate(latitude: lat, longitude: lon)
    }

    /// Meter pro Unit-Mercator-Einheit am gegebenen Breitengrad
    /// (die Mercator-Projektion staucht Entfernungen mit cos(lat)).
    public static func metersPerUnit(latitude: Double) -> Double {
        earthCircumference * cos(latitude * .pi / 180)
    }

    /// Meter pro Bildschirm-Pixel für Zoom und Breite.
    public static func metersPerPixel(latitude: Double, zoom: Double) -> Double {
        metersPerUnit(latitude: latitude) / worldSize(zoom: zoom)
    }
}
