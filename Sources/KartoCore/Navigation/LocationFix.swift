import Foundation

/// Ein Positions-Update, wie es von CoreLocation (oder eurer Navi-Engine) kommt.
/// Bewusst ohne CoreLocation-Abhängigkeit, damit KartoCore plattformneutral bleibt –
/// die Umwandlung aus `CLLocation` ist ein Einzeiler in KartoRender.
public struct LocationFix: Equatable, Sendable {
    public var coordinate: Coordinate
    /// Kurs über Grund in Grad (0 = Norden, im Uhrzeigersinn), nil wenn unbekannt.
    public var course: Double?
    /// Geschwindigkeit in m/s, nil wenn unbekannt.
    public var speed: Double?
    /// Horizontale Genauigkeit in Metern (Radius).
    public var horizontalAccuracy: Double
    /// Zeitstempel in Sekunden (monotone Uhr, z. B. CACurrentMediaTime oder Date).
    public var timestamp: TimeInterval
    /// true, wenn die Position bereits von einem Map-Matching auf die Route gesetzt
    /// wurde – dann überspringt der Controller das eigene Snapping.
    public var isSnapped: Bool

    public init(coordinate: Coordinate, course: Double? = nil, speed: Double? = nil,
                horizontalAccuracy: Double = 10, timestamp: TimeInterval, isSnapped: Bool = false) {
        self.coordinate = coordinate
        self.course = course
        self.speed = speed
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
        self.isSnapped = isSnapped
    }
}

/// Geodätische Hilfsfunktionen auf Unit-Mercator-Basis (lokal ausreichend genau).
public enum GeoMath {
    /// Kurs von a nach b in Grad (0 = Norden, im Uhrzeigersinn).
    public static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return normalize(atan2(y, x) * 180 / .pi)
    }

    /// Entfernung in Metern (Haversine).
    public static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let r = Mercator.earthRadius
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    /// Punkt in Entfernung `meters` und Richtung `bearing` (Grad).
    public static func destination(from c: Coordinate, bearing: Double, meters: Double) -> Coordinate {
        let r = Mercator.earthRadius
        let d = meters / r
        let b = bearing * .pi / 180
        let lat1 = c.latitude * .pi / 180, lon1 = c.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(d) + cos(lat1) * sin(d) * cos(b))
        let lon2 = lon1 + atan2(sin(b) * sin(d) * cos(lat1), cos(d) - sin(lat1) * sin(lat2))
        return Coordinate(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    /// Auf [0, 360) normalisieren.
    public static func normalize(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// Kürzeste Winkeldifferenz b − a in (−180, 180].
    public static func angleDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}
