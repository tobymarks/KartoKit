import Foundation

/// Ein Marker auf der Karte. Größe in Punkten, bleibt bei Zoom/Neigung konstant.
/// Das Aussehen wird als Beschreibung übergeben; der Renderer rastert es einmal in
/// einen Atlas (CoreGraphics) und zeichnet danach nur Quads.
public struct MapAnnotation: Equatable, Sendable, Identifiable {
    public enum Style: Hashable, Sendable {
        /// Tropfenförmiger Pin (wie `MKMarkerAnnotationView`) mit Glyph-Text oder SF-Symbol.
        case pin(color: RGBA, glyphText: String? = nil, symbolName: String? = nil, glyphColor: RGBA = RGBA(1, 1, 1, 1))
        /// Kreis mit Symbol/Text (Ladestation-Stil). `ring` = äußerer Empfehlungsring (z. B. Signal-Orange).
        case circle(color: RGBA, glyphText: String? = nil, symbolName: String? = nil, glyphColor: RGBA = RGBA(1, 1, 1, 1), ring: RGBA? = nil)
        /// Bild aus dem App-Bundle (`UIImage(named:)`).
        case image(name: String)
        /// Freistehender Text mit Halo (z. B. Zielname).
        case text(String, color: RGBA, halo: RGBA)
        /// Pille mit Symbol + Text und kleiner Spitze unten (z. B. für Ladeparks: „⚡ 3/4“).
        /// `size` = Höhe der Pille; Breite ergibt sich aus dem Text. Anker: Spitze.
        case pill(text: String, symbolName: String? = nil, fill: RGBA, textColor: RGBA = RGBA(1, 1, 1, 1), stroke: RGBA = RGBA(1, 1, 1, 1))
        /// Runder Marker mit Symbol und segmentiertem Ring außen – ein Segment je Einheit (z. B. Ladepunkt),
        /// jedes in eigener Farbe (frei/belegt/defekt). `segments` leer = geschlossener Ring in `track`.
        /// Bei mehr als 16 Segmenten wird der Ring proportional (ohne Lücken) gezeichnet. Anker: Mitte.
        case ring(symbolName: String? = nil, fill: RGBA, symbolColor: RGBA = RGBA(1, 1, 1, 1), segments: [RGBA], track: RGBA)
    }

    public var id: String
    public var coordinate: Coordinate
    public var style: Style
    /// Bounding-Box in Punkten.
    public var size: Double
    /// Anker relativ zur Box: (0,0) = Mitte auf der Koordinate, (0,1) = Unterkante (Pin-Spitze).
    public var anchor: Vec2
    /// Höhere Priorität gewinnt bei Überlappung (0 = darf verdrängt werden).
    public var priority: Int
    /// Tap-Ereignis erzeugen?
    public var isTappable: Bool
    /// Nicht mit anderen Markern kollidieren lassen (immer zeichnen).
    public var ignoresCollisions: Bool
    /// Optionaler Untertitel/Beschriftung unter dem Marker (z. B. Stopp-Name).
    public var label: String?

    public init(id: String, coordinate: Coordinate, style: Style, size: Double = 32, anchor: Vec2? = nil,
                priority: Int = 0, isTappable: Bool = true, ignoresCollisions: Bool = false, label: String? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.style = style
        self.size = size
        if let anchor { self.anchor = anchor } else {
            switch style {
            case .pin, .pill: self.anchor = Vec2(0, 1)
            default: self.anchor = Vec2(0, 0)
            }
        }
        self.priority = priority
        self.isTappable = isTappable
        self.ignoresCollisions = ignoresCollisions
        self.label = label
    }
}

/// Einfaches Kollisionsgitter im Bildschirmraum (für Marker und Labels).
/// Einfügen in Prioritätsreihenfolge; `insert` liefert false, wenn die Box überlappt.
public struct CollisionGrid {
    public struct Box: Equatable, Sendable {
        public var minX: Double, minY: Double, maxX: Double, maxY: Double
        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
        }
        public init(center: Vec2, width: Double, height: Double) {
            minX = center.x - width / 2; maxX = center.x + width / 2
            minY = center.y - height / 2; maxY = center.y + height / 2
        }
        public func intersects(_ o: Box, padding: Double = 0) -> Bool {
            !(o.minX > maxX + padding || o.maxX < minX - padding || o.minY > maxY + padding || o.maxY < minY - padding)
        }
    }

    private let cell: Double
    private var cells: [Int: [Box]] = [:]
    public private(set) var boxes: [Box] = []

    public init(cellSize: Double = 64) { cell = cellSize }

    private func keys(_ b: Box) -> [Int] {
        let x0 = Int((b.minX / cell).rounded(.down)), x1 = Int((b.maxX / cell).rounded(.down))
        let y0 = Int((b.minY / cell).rounded(.down)), y1 = Int((b.maxY / cell).rounded(.down))
        var out: [Int] = []
        for y in y0...max(y0, y1) { for x in x0...max(x0, x1) { out.append(x &* 73856093 ^ y &* 19349663) } }
        return out
    }

    public func collides(_ b: Box, padding: Double = 0) -> Bool {
        for k in keys(b) {
            for o in cells[k] ?? [] where o.intersects(b, padding: padding) { return true }
        }
        return false
    }

    @discardableResult
    public mutating func insert(_ b: Box, padding: Double = 0, force: Bool = false) -> Bool {
        if !force, collides(b, padding: padding) { return false }
        for k in keys(b) { cells[k, default: []].append(b) }
        boxes.append(b)
        return true
    }
}
