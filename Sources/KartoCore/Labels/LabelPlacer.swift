import Foundation

/// Platziertes Label im Bildschirmraum (Punkte).
public struct PlacedLabel: Equatable, Sendable {
    public var text: String
    public var kind: LabelCandidate.Kind
    public var center: Vec2
    /// Rotation in rad (im Uhrzeigersinn, 0 = waagerecht); Straßennamen entlang der Linie.
    public var rotation: Double
    public var fontSize: Double
    public var isBold: Bool
    public var box: CollisionGrid.Box
}

/// Kollisionsfreie Beschriftungsplatzierung pro Frame – rein geometrisch, ohne UIKit,
/// deshalb hier im Kern und deterministisch testbar.
///
/// Regeln (aufgeräumter Navi-Look):
/// - Prioritäten: Ortsnamen nach Rang, dann Autobahnschilder, dann Straßen nach Klasse.
/// - Straßennamen nur auf ausreichend geraden Abschnitten, immer lesbar (nie kopfüber),
///   derselbe Name nicht näher als `repeatDistance` zusammen.
/// - Hervorgehobene Namen (aktuelle und nächste Straße im Navi) zuerst.
/// - Hysterese: Labels des letzten Frames werden bevorzugt, damit nichts flackert.
public struct LabelPlacer {
    public struct Options: Sendable {
        public var labelScale = 1.0
        public var padding = 4.0
        public var repeatDistance = 320.0
        /// Straßennamen: derselbe Name nicht näher als so viele Punkte (sehr sparsam).
        public var roadRepeatDistance = 700.0
        /// Max. Winkeländerung (rad) innerhalb des Textfensters, damit ein Straßenname gesetzt wird.
        public var maxCurvature = 0.45
        public var maxLabels = 40
        /// Obergrenzen je Art – der aufgeräumte Navi-Look: wenige Straßen, wenige, aber wichtige POIs.
        /// Hervorgehobene Straßen (aktuelle/nächste) zählen nicht gegen `maxRoadLabels`.
        public var maxRoadLabels = 8
        public var maxPOILabels = 4
        public var maxPlaceLabels = 12
        public var maxShieldLabels = 4
        public init() {}

        /// Voreinstellung für die Fahransicht (sehr aufgeräumt).
        public static var navigation: Options {
            var o = Options(); o.maxLabels = 22; o.maxRoadLabels = 5; o.maxPOILabels = 3; o.maxPlaceLabels = 6; o.maxShieldLabels = 2
            o.roadRepeatDistance = 900
            return o
        }
        /// Voreinstellung zum Stöbern (mehr, aber immer noch weniger als Apple Maps).
        public static var browsing: Options {
            var o = Options(); o.maxLabels = 45; o.maxRoadLabels = 12; o.maxPOILabels = 6; o.maxPlaceLabels = 14; o.maxShieldLabels = 4
            return o
        }
    }

    public typealias Measure = (String, Double, Bool) -> (width: Double, height: Double)

    public var options = Options()
    /// Namen mit Vorrang (z. B. aktuelle Straße + nächste Straße im Navi).
    public var highlighted: Set<String> = []
    private var previous: Set<String> = []

    public init() {}

    /// Kandidaten je Kachel mit ihrer Kachelmatrix (Tile-Einheiten → Clip). Rückgabe in Bildschirm-Punkten.
    public mutating func place(tiles: [(candidates: [LabelCandidate], matrix: Mat4, extent: Double)],
                               viewport: (width: Double, height: Double), zoom: Double,
                               reserved: [CollisionGrid.Box], measure: Measure) -> [PlacedLabel] {
        var grid = CollisionGrid(cellSize: 64)
        for r in reserved { grid.insert(r, force: true) }
        let W = viewport.width, H = viewport.height

        struct Item { let c: LabelCandidate; let priority: Int; let tile: Int }
        var items: [Item] = []
        for (ti, t) in tiles.enumerated() {
            for c in t.candidates where zoom >= c.minZoom || highlighted.contains(c.text) {
                var p = c.basePriority
                if highlighted.contains(c.text) { p += 1000 }
                if previous.contains(c.text) { p += 5 }
                items.append(Item(c: c, priority: p, tile: ti))
            }
        }
        items.sort { $0.priority > $1.priority }

        func project(_ m: Mat4, _ p: TilePoint) -> Vec2? {
            let c = m * Vec4(Double(p.x), Double(p.y), 0, 1)
            guard c.w > 1e-6 else { return nil }
            return Vec2((c.x / c.w + 1) / 2 * W, (1 - c.y / c.w) / 2 * H)
        }

        var placed: [PlacedLabel] = []
        var placedByText: [String: [Vec2]] = [:]
        var now = Set<String>()
        var roadCount = 0, poiCount = 0, placeCount = 0, shieldCount = 0

        for it in items where placed.count < options.maxLabels {
            // Kontingente je Art
            switch it.c.kind {
            case .road: if !highlighted.contains(it.c.text), roadCount >= options.maxRoadLabels { continue }
            case .poi: if poiCount >= options.maxPOILabels { continue }
            case .shield: if shieldCount >= options.maxShieldLabels { continue }
            case .place: if placeCount >= options.maxPlaceLabels { continue }
            default: break
            }
            let m = tiles[it.tile].matrix
            let size = it.c.fontSize * options.labelScale
            let (tw, th) = measure(it.c.text, size, it.c.isBold)
            let pad = options.padding

            switch it.c.kind {
            case .road:
                guard let path = it.c.path, path.count >= 2 else { continue }
                var screen: [Vec2] = []
                for p in path { guard let s = project(m, p) else { screen = []; break }; screen.append(s) }
                guard screen.count >= 2 else { continue }
                guard let (center, angle) = Self.straightWindow(screen, length: tw + pad * 2, maxCurvature: options.maxCurvature) else { continue }
                guard center.x > -tw, center.x < W + tw, center.y > -th, center.y < H + th else { continue }
                // Wiederholungen desselben Namens auf Abstand halten
                if let prev = placedByText[it.c.text], prev.contains(where: { ($0 - center).length < options.roadRepeatDistance }) { continue }
                // Aufrecht halten
                var rot = angle
                if rot > .pi / 2 { rot -= .pi } else if rot < -.pi / 2 { rot += .pi }
                // Box des gedrehten Textes (achsenparallele Hülle)
                let ca = abs(cos(rot)), sa = abs(sin(rot))
                let box = CollisionGrid.Box(center: center, width: tw * ca + th * sa + pad, height: tw * sa + th * ca + pad)
                guard grid.insert(box, padding: pad) else { continue }
                placed.append(PlacedLabel(text: it.c.text, kind: it.c.kind, center: center, rotation: rot, fontSize: size, isBold: it.c.isBold, box: box))
                placedByText[it.c.text, default: []].append(center)
                now.insert(it.c.text)
                if !highlighted.contains(it.c.text) { roadCount += 1 }

            case .shield:
                guard let path = it.c.path, path.count >= 2 else { continue }
                var screen: [Vec2] = []
                for p in path { guard let s = project(m, p) else { screen = []; break }; screen.append(s) }
                guard screen.count >= 2 else { continue }
                // Mitte des längsten sichtbaren Segments
                var best: (Vec2, Double)?
                for i in 0..<(screen.count - 1) {
                    let a = screen[i], b = screen[i + 1]
                    let mid = (a + b) / 2
                    guard mid.x > 0, mid.x < W, mid.y > 0, mid.y < H else { continue }
                    let l = (b - a).length
                    if best == nil || l > best!.1 { best = (mid, l) }
                }
                guard let (center, _) = best else { continue }
                if let prev = placedByText[it.c.text], prev.contains(where: { ($0 - center).length < options.repeatDistance * 1.5 }) { continue }
                let box = CollisionGrid.Box(center: center, width: tw + 12, height: th + 8)
                guard grid.insert(box, padding: pad) else { continue }
                placed.append(PlacedLabel(text: it.c.text, kind: it.c.kind, center: center, rotation: 0, fontSize: size, isBold: true, box: box))
                placedByText[it.c.text, default: []].append(center)
                now.insert(it.c.text)
                shieldCount += 1

            default:
                guard let p = it.c.point, let s = project(m, p) else { continue }
                guard s.x > -tw, s.x < W + tw, s.y > -th, s.y < H + th else { continue }
                if let prev = placedByText[it.c.text], prev.contains(where: { ($0 - s).length < options.repeatDistance }) { continue }
                let box = CollisionGrid.Box(center: s, width: tw + pad, height: th + pad)
                guard grid.insert(box, padding: pad) else { continue }
                placed.append(PlacedLabel(text: it.c.text, kind: it.c.kind, center: s, rotation: 0, fontSize: size, isBold: it.c.isBold, box: box))
                placedByText[it.c.text, default: []].append(s)
                now.insert(it.c.text)
                if case .poi = it.c.kind { poiCount += 1 } else if case .place = it.c.kind { placeCount += 1 }
            }
        }
        previous = now
        return placed
    }

    /// Sucht entlang der Bildschirm-Polylinie ein Fenster der Länge `length`, in dem sich die
    /// Richtung um höchstens `maxCurvature` ändert; bevorzugt die Mitte der Linie.
    /// Rückgabe: Mittelpunkt und Richtung (rad, Bildschirmkoordinaten, y nach unten).
    static func straightWindow(_ pts: [Vec2], length: Double, maxCurvature: Double) -> (Vec2, Double)? {
        var cum: [Double] = [0]
        for i in 1..<pts.count { cum.append(cum[i - 1] + (pts[i] - pts[i - 1]).length) }
        let total = cum.last!
        guard total >= length else { return nil }
        func pointAt(_ d: Double) -> Vec2 {
            var i = 0
            while i + 1 < cum.count - 1, cum[i + 1] < d { i += 1 }
            let seg = cum[i + 1] - cum[i]
            let t = seg > 0 ? (d - cum[i]) / seg : 0
            return pts[i] + (pts[i + 1] - pts[i]) * t
        }
        // Kandidaten-Startpunkte: von der Mitte nach außen
        let mid = (total - length) / 2
        let step = max(length / 4, 8)
        var offsets: [Double] = [0]
        var k = 1.0
        while mid - k * step >= 0 || mid + k * step <= total - length {
            offsets.append(k * step); offsets.append(-k * step); k += 1
            if offsets.count > 40 { break }
        }
        for off in offsets {
            let start = mid + off
            guard start >= 0, start + length <= total else { continue }
            // Krümmung: Richtungen der Teilstücke im Fenster vergleichen
            let n = 6
            var angles: [Double] = []
            for j in 0..<n {
                let a = pointAt(start + length * Double(j) / Double(n))
                let b = pointAt(start + length * Double(j + 1) / Double(n))
                let d = b - a
                if d.length < 1e-6 { continue }
                angles.append(atan2(d.y, d.x))
            }
            guard angles.count >= 2 else { continue }
            var maxDelta = 0.0
            for j in 1..<angles.count {
                var dl = angles[j] - angles[0]
                while dl > .pi { dl -= 2 * .pi }
                while dl < -.pi { dl += 2 * .pi }
                maxDelta = max(maxDelta, abs(dl))
            }
            if maxDelta <= maxCurvature {
                let a = pointAt(start), b = pointAt(start + length)
                let dir = b - a
                return ((a + b) / 2, atan2(dir.y, dir.x))
            }
        }
        return nil
    }
}
