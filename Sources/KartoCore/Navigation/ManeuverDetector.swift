import Foundation

/// Findet Abbiegungen in einer Routen-Polylinie, wenn die Routing-Engine keine
/// Manöverliste liefert (z. B. beim Abspielen eines GPX-Tracks).
///
/// Ein Manöver ist ein Punkt, an dem sich der Kurs innerhalb von `window` Metern um
/// mehr als `minTurn` Grad ändert. Benachbarte Treffer werden zu einem Manöver
/// (am Punkt der stärksten Krümmung) zusammengefasst.
public enum ManeuverDetector {
    public static func turnPoints(route: [Coordinate], minTurn: Double = 40, window: Double = 35,
                                  mergeDistance: Double = 60) -> [Double] {
        guard route.count >= 3 else { return [] }
        let snapper = RouteSnapper(route: route)
        let total = snapper.totalLength
        guard total > window * 2 else { return [] }

        // Kursänderung über ±window/2 an Stützstellen alle 5 m
        var candidates: [(along: Double, turn: Double)] = []
        var d = window / 2
        while d < total - window / 2 {
            let b0 = snapper.bearing(atDistance: d - window / 2)
            let b1 = snapper.bearing(atDistance: d + window / 2)
            let turn = abs(GeoMath.angleDelta(from: b0, to: b1))
            if turn >= minTurn { candidates.append((d, turn)) }
            d += 5
        }

        // Zusammenfassen: Cluster mit Lücke < mergeDistance → stärkster Punkt
        var result: [Double] = []
        var cluster: [(along: Double, turn: Double)] = []
        func flush() {
            if let best = cluster.max(by: { $0.turn < $1.turn }) { result.append(best.along) }
            cluster.removeAll()
        }
        for c in candidates {
            if let last = cluster.last, c.along - last.along > mergeDistance { flush() }
            cluster.append(c)
        }
        flush()
        return result
    }
}
