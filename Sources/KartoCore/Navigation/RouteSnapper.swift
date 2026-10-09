import Foundation

/// Projiziert Positionen auf eine Routen-Polylinie ("Map-Matching light").
///
/// Gute Navi-Apps zeigen den Pfeil während der Navigation praktisch immer exakt auf der
/// Straße – auch bei 15 m GPS-Streuung. Das erreicht man nicht mit dem rohen Fix,
/// sondern indem man die Position auf die Route zieht, solange sie plausibel nah
/// ist, und den Fortschritt entlang der Route nur vorwärts laufen lässt.
public struct RouteSnapper: Sendable {
    public struct Result: Equatable, Sendable {
        public var coordinate: Coordinate
        /// Richtung der Route am Snap-Punkt (Grad).
        public var bearing: Double
        /// Fortschritt entlang der Route in Metern.
        public var distanceAlong: Double
        /// Seitlicher Abstand des rohen Fixes zur Route in Metern.
        public var crossTrack: Double
        public var segmentIndex: Int
    }

    public let route: [Coordinate]
    let mercator: [Vec2]
    let cumulative: [Double]
    let metersPerUnit: Double
    public var totalLength: Double { cumulative.last ?? 0 }

    public init(route: [Coordinate]) {
        self.route = route
        mercator = route.map { Mercator.project($0) }
        let lat = route.first?.latitude ?? 0
        metersPerUnit = Mercator.metersPerUnit(latitude: lat)
        var cum: [Double] = [0]
        cum.reserveCapacity(route.count)
        for i in 1..<max(route.count, 1) {
            cum.append(cum[i - 1] + GeoMath.distance(route[i - 1], route[i]))
        }
        cumulative = cum
    }

    /// Snap mit Fortschritts-Hysterese: sucht nur ab `minSegment` (letzter bekannter
    /// Fortschritt, minus kleiner Rückschau) und bevorzugt bei ähnlichem Abstand das
    /// weiter vorne liegende Segment – verhindert Zurückspringen an Kreuzungen und
    /// bei parallelen Straßen.
    public func snap(_ c: Coordinate, minSegment: Int = 0, lookbackSegments: Int = 2, maxCandidates: Int = 400) -> Result? {
        guard mercator.count >= 2 else { return nil }
        let p = Mercator.project(c)
        let start = max(minSegment - lookbackSegments, 0)
        let end = min(start + maxCandidates, mercator.count - 1)
        guard start < end else { return nil }

        var best: (dist: Double, seg: Int, t: Double, point: Vec2)?
        for i in start..<end {
            let a = mercator[i], b = mercator[i + 1]
            let ab = b - a
            let len2 = ab.dot(ab)
            let t = len2 > 0 ? min(max((p - a).dot(ab) / len2, 0), 1) : 0
            let q = a + ab * t
            let d = (p - q).length
            // 2 % Bonus für spätere Segmente bei praktisch gleichem Abstand
            if let bb = best {
                if d < bb.dist * 1.02 { best = (d, i, t, q) }
            } else {
                best = (d, i, t, q)
            }
        }
        guard let b = best else { return nil }
        let segLen = cumulative[b.seg + 1] - cumulative[b.seg]
        let along = cumulative[b.seg] + segLen * b.t
        return Result(coordinate: Mercator.unproject(b.point),
                      bearing: GeoMath.bearing(from: route[b.seg], to: route[b.seg + 1]),
                      distanceAlong: along,
                      crossTrack: b.dist * metersPerUnit,
                      segmentIndex: b.seg)
    }

    /// Punkt in `meters` Entfernung entlang der Route (für Vorausschau der Kamera).
    public func coordinate(atDistance meters: Double) -> Coordinate? {
        guard route.count >= 2 else { return route.first }
        let d = min(max(meters, 0), totalLength)
        var i = 0
        while i + 1 < cumulative.count - 1, cumulative[i + 1] < d { i += 1 }
        let segLen = cumulative[i + 1] - cumulative[i]
        let t = segLen > 0 ? (d - cumulative[i]) / segLen : 0
        let a = mercator[i], b = mercator[i + 1]
        return Mercator.unproject(a + (b - a) * t)
    }

    /// Routenrichtung an einer Streckenposition (Grad).
    public func bearing(atDistance meters: Double) -> Double {
        guard route.count >= 2 else { return 0 }
        let d = min(max(meters, 0), totalLength)
        var i = 0
        while i + 1 < cumulative.count - 1, cumulative[i + 1] < d { i += 1 }
        return GeoMath.bearing(from: route[i], to: route[i + 1])
    }
}
