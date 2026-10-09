import Foundation

/// Darstellungsmodell einer Route: Geometrie, gefahrener Anteil, Verkehrs- oder
/// Sonderabschnitte, Alternative ja/nein. Das Mesh wird einmal gebaut; Fortschritt
/// und Abschnittsfarben werden pro Frame als Uniforms in den Shader gegeben.
public struct RouteDisplay: Equatable, Sendable, Identifiable {
    public struct Segment: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case slow          // zähfließend (Theme: trafficSlow)
            case jam           // Stau (Theme: trafficJam)
            case closed        // Sperrung (Theme: trafficClosed)
            case custom(RGBA)  // frei (z. B. Ladeabschnitt, Mautstrecke)
        }
        /// Meter entlang der Route.
        public var from: Double
        public var to: Double
        public var kind: Kind
        public init(from: Double, to: Double, kind: Kind) { self.from = from; self.to = to; self.kind = kind }
    }

    public var id: String
    public var coordinates: [Coordinate]
    /// Meter entlang der Route bis zur aktuellen Position; davor wird "gefahren" gezeichnet.
    public var drivenDistance: Double
    public var segments: [Segment]
    /// false = Alternativroute (neutral, schmaler, ohne Fortschritt/Abschnitte).
    public var isActive: Bool
    /// true = fuer diese Route liegen Verkehrsdaten vor. Nur dann wird der
    /// Verkehrssaum gezeichnet; ohne Daten waere ein gruener Saum eine
    /// Behauptung, die niemand geprueft hat.
    public var trafficKnown: Bool = false

    /// Ob die Geometrie beim Anlegen geglaettet wird.
    ///
    /// Standardmaessig ja: Die Stuetzpunkte streuen auf geraden
    /// Strecken im Median um 3,7 Meter quer zur Fahrbahn (gemessen am
    /// 4.9.2026 an einer Route Pforzheim → Stuttgart), und das sieht
    /// man. Geglaettet wird nur, wo der Knickwinkel klein ist —
    /// Abbiegungen bleiben scharf, siehe PolylineSmoothing.
    public init(id: String = "route", coordinates: [Coordinate], drivenDistance: Double = 0,
                segments: [Segment] = [], isActive: Bool = true,
                trafficKnown: Bool = false, smoothed: Bool = true) {
        self.id = id
        self.coordinates = smoothed
            ? PolylineSmoothing.geglaettet(coordinates)
            : coordinates
        self.drivenDistance = drivenDistance
        self.segments = segments
        self.isActive = isActive
        self.trafficKnown = trafficKnown
    }

    /// Der Teil der Route, der noch vor einem liegt.
    ///
    /// Der erste Punkt wird auf `metern` interpoliert, liegt also
    /// genau dort, wo man gerade ist - sonst spraenge die Uebersicht
    /// bei jedem Stuetzpunkt.
    ///
    /// Bleiben weniger als zwei Punkte uebrig (am Ziel, oder wenn der
    /// Fortschritt ueber die Route hinauslaeuft), kommt der letzte
    /// Abschnitt zurueck statt einer leeren Liste: Eine Uebersicht
    /// ohne Inhalt waere ein leerer Bildschirm.
    public static func remainder(of coordinates: [Coordinate],
                                 from meters: Double) -> [Coordinate] {
        guard coordinates.count >= 2 else { return coordinates }
        guard meters > 0 else { return coordinates }

        var lauf = 0.0
        for i in 1..<coordinates.count {
            let a = coordinates[i - 1], b = coordinates[i]
            let d = GeoMath.distance(a, b)
            if lauf + d > meters {
                let t = d > 1e-9 ? (meters - lauf) / d : 0
                let hier = Coordinate(
                    latitude: a.latitude + (b.latitude - a.latitude) * t,
                    longitude: a.longitude + (b.longitude - a.longitude) * t)
                return [hier] + Array(coordinates[i...])
            }
            lauf += d
        }
        return Array(coordinates.suffix(2))
    }

    /// Abschnitte aus Punktindex-Bereichen.
    public static func segments(fromIndexRanges ranges: [(from: Int, to: Int, kind: Segment.Kind)], coordinates: [Coordinate]) -> [Segment] {
        guard coordinates.count >= 2 else { return [] }
        var cum: [Double] = [0]
        for i in 1..<coordinates.count { cum.append(cum[i - 1] + GeoMath.distance(coordinates[i - 1], coordinates[i])) }
        return ranges.compactMap { r in
            let a = max(0, min(r.from, cum.count - 1)), b = max(a, min(r.to, cum.count - 1))
            return b > a ? Segment(from: cum[a], to: cum[b], kind: r.kind) : nil
        }
    }
}

/// Vertex einer Route: Position in lokalen Welt-Pixeln (Zoom `RouteMesh.localZoom`,
/// relativ zum Ursprung), Extrusionsnormale, Meter entlang der Route. 20 Byte.
public struct RouteVertex: Sendable, Equatable {
    public var x: Float, y: Float
    public var nx: Float, ny: Float
    public var distance: Float
    public init(_ x: Float, _ y: Float, _ nx: Float, _ ny: Float, _ distance: Float) {
        self.x = x; self.y = y; self.nx = nx; self.ny = ny; self.distance = distance
    }
}

/// GPU-fertige Routen-Geometrie mit lokalem Koordinatensystem.
public struct RouteMesh: Sendable {
    /// Ursprung in Unit-Mercator; Vertices relativ dazu in Welt-Pixeln auf `localZoom`.
    public var origin: Vec2
    public var localZoom: Double
    public var vertices: [RouteVertex]
    public var indices: [UInt32]
    public var totalLength: Double

    public static let defaultLocalZoom = 16.0

    /// Baut Streifen mit Miter-Joins und Meter-Attribut. Doppelte Punkte werden entfernt.
    public init(coordinates: [Coordinate], localZoom: Double = RouteMesh.defaultLocalZoom) {
        self.localZoom = localZoom
        let world = Mercator.worldSize(zoom: localZoom)
        var pts: [Vec2] = []
        var dist: [Double] = []
        var total = 0.0
        var lastCoord: Coordinate?
        for c in coordinates {
            let m = Mercator.project(c)
            if let lc = lastCoord {
                let d = GeoMath.distance(lc, c)
                if d < 0.05 { continue }
                total += d
            }
            pts.append(m); dist.append(total); lastCoord = c
        }
        totalLength = total
        let o = pts.first ?? Vec2(0.5, 0.5)
        origin = o
        let local = pts.map { ($0 - o) * world }
        var verts: [RouteVertex] = []
        var idx: [UInt32] = []
        let n = local.count
        if n >= 2 {
            verts.reserveCapacity(n * 2); idx.reserveCapacity((n - 1) * 6)
            for i in 0..<n {
                let normal: Vec2
                if i == 0 {
                    normal = (local[1] - local[0]).normalized.perpendicular
                } else if i == n - 1 {
                    normal = (local[n - 1] - local[n - 2]).normalized.perpendicular
                } else {
                    let nPrev = (local[i] - local[i - 1]).normalized.perpendicular
                    let nNext = (local[i + 1] - local[i]).normalized.perpendicular
                    let sum = nPrev + nNext
                    if sum.length < 1e-9 { normal = nPrev } else {
                        let m = sum.normalized
                        normal = m * min(1.0 / max(m.dot(nPrev), 1e-6), LineTessellator.miterLimit)
                    }
                }
                let d = Float(dist[i])
                verts.append(RouteVertex(Float(local[i].x), Float(local[i].y), Float(normal.x), Float(normal.y), d))
                verts.append(RouteVertex(Float(local[i].x), Float(local[i].y), Float(-normal.x), Float(-normal.y), d))
            }
            for i in 0..<(n - 1) {
                let a = UInt32(i * 2)
                idx.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
            }

            // Runde Enden. Die Route begann und endete bisher mit einer
            // geraden Kante quer zur Fahrtrichtung — am Ziel, direkt unter
            // der Fahne, ist das der auffaelligste Schnitt auf der Karte.
            //
            // Dieselbe Scheibe wie bei den Kachellinien, nur mit dem
            // Meter-Attribut des jeweiligen Endes: Der Anfang traegt Meter 0
            // und wird damit mitgefaerbt, sobald er hinter einem liegt, das
            // Ende traegt die Gesamtlaenge und bleibt bis zuletzt hell.
            for (stelle, meter) in [(local[0], dist[0]), (local[n - 1], dist[n - 1])] {
                let mitte = UInt32(verts.count)
                verts.append(RouteVertex(Float(stelle.x), Float(stelle.y), 0, 0, Float(meter)))
                for k in 0...LineTessellator.rundungsEcken {
                    let w = 2.0 * Double.pi * Double(k) / Double(LineTessellator.rundungsEcken)
                    verts.append(RouteVertex(Float(stelle.x), Float(stelle.y),
                                             Float(cos(w)), Float(sin(w)), Float(meter)))
                }
                for k in 0..<LineTessellator.rundungsEcken {
                    let a = mitte + 1 + UInt32(k)
                    idx.append(contentsOf: [mitte, a, a + 1])
                }
            }
        }
        vertices = verts
        indices = idx
    }
}

/// Manöverpfeil auf der Straße (weißer Pfeil mit dunklem Rand, ~45 m vor bis
/// ~25 m nach dem Abbiegepunkt, Spitze am Ende). Liefert eine Polylinie in Koordinaten;
/// gerendert wird sie als `RouteMesh` mit Pfeilspitze.
public enum ManeuverArrow {
    public static func polyline(route: [Coordinate], maneuverDistanceAlong m: Double,
                                before: Double = 45, after: Double = 25, step: Double = 4,
                                nextManeuverDistanceAlong next: Double? = nil) -> [Coordinate] {
        let s = RouteSnapper(route: route)
        guard s.totalLength > 0, m.isFinite, before.isFinite, after.isFinite,
              step.isFinite, step > 0, before >= 0, after >= 0 else { return [] }
        // Die Spitze bleibt auf der Ausfahrt dieser Abbiegung. Bei einer
        // engen Links-rechts-Folge endet sie vor dem zweiten Manoever.
        let auslauf: Double
        if let next, next.isFinite, next > m {
            auslauf = min(after, (next - m) * 0.5)
        } else {
            auslauf = after
        }
        var out: [Coordinate] = []
        var d = max(0, m - before)
        let end = min(s.totalLength, m + auslauf)
        while d <= end {
            if let c = s.coordinate(atDistance: d) { out.append(c) }
            d += step
        }
        if let last = s.coordinate(atDistance: end), out.last.map({ GeoMath.distance($0, last) > 0.5 }) ?? true { out.append(last) }
        return out
    }

    /// Pfeilspitze als Dreieck (lokale Welt-Pixel auf `localZoom`) am Ende der Polylinie.
    public static func head(polyline: [Coordinate], origin: Vec2, localZoom: Double, widthPx: Double, lengthPx: Double) -> ([RouteVertex], [UInt32]) {
        guard polyline.count >= 2 else { return ([], []) }
        let world = Mercator.worldSize(zoom: localZoom)
        let a = (Mercator.project(polyline[polyline.count - 2]) - origin) * world
        let b = (Mercator.project(polyline[polyline.count - 1]) - origin) * world
        let dir = (b - a).normalized
        let n = dir.perpendicular
        // Das Ende der Polylinie ist die Spitze. Ein Vorziehen um
        // lengthPx kann sonst bereits ueber die naechste Kreuzung ragen.
        let tip = b
        let base = b - dir * max(0, lengthPx)
        let l = base + n * widthPx, r = base - n * widthPx
        let v = [l, r, tip].map { RouteVertex(Float($0.x), Float($0.y), 0, 0, 0) }
        return (v, [0, 1, 2])
    }
}
