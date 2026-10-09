import Foundation

/// Achsenparalleles Rechteck in Welt-Pixeln.
public struct WorldRect: Equatable, Sendable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }
    public func intersects(_ o: WorldRect) -> Bool {
        !(o.minX > maxX || o.maxX < minX || o.minY > maxY || o.maxY < minY)
    }
}

/// Bestimmt die Kacheln, die für eine Ansicht geladen/gezeichnet werden müssen.
///
/// Verfahren (angelehnt an MapLibres `coveringTiles`): Quadtree-Abstieg ab z=0.
/// Eine Kachel wird verfeinert, solange sie den sichtbaren Bodenbereich schneidet
/// und ihre projizierte Größe (abhängig von der Entfernung zum Auge) größer als
/// eine Bildschirmkachel ist. Damit bekommt der Vordergrund bei Neigung die volle
/// Zoomstufe, die Ferne aber gröbere Kacheln – entscheidend für Performance im
/// Navi-Modus mit 60° Pitch.
public enum TileCoverage {
    public struct Options: Sendable {
        public var minZoom: Int = 0
        public var maxZoom: Int = 15
        /// Verfeinerung erfolgt, wenn projizierte Kachelgröße > tileSize · lodBias.
        public var lodBias: Double = 1.0
        /// Sicherheitsgrenze gegen Kachel-Explosion bei extremen Ansichten.
        public var maxTiles: Int = 96
        public init() {}
    }

    /// Sichtbarer Bodenbereich als Bounding-Box (Welt-Pixel), Horizont geklemmt.
    public static func visibleGroundRect(_ vp: ViewProjection) -> WorldRect {
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        let steps = 4
        // Punkte jenseits des Horizonts: Strahl bis `far` verfolgen und auf Boden klappen.
        for i in 0...steps {
            for j in 0...steps {
                let s = Vec2(vp.width * Double(i) / Double(steps), vp.height * Double(j) / Double(steps))
                let g: Vec2
                if let hit = vp.unprojectToGround(screen: s) {
                    g = hit
                } else {
                    // Richtung des Sehstrahls ermitteln und auf `far` begrenzen.
                    let nx = s.x / vp.width * 2 - 1, ny = 1 - s.y / vp.height * 2
                    let a = vp.inverseViewProjection * Vec4(nx, ny, 0, 1)
                    let b = vp.inverseViewProjection * Vec4(nx, ny, 1, 1)
                    let p0 = Vec3(a.x / a.w, a.y / a.w, a.z / a.w)
                    let p1 = Vec3(b.x / b.w, b.y / b.w, b.z / b.w)
                    let dir = (p1 - p0).normalized
                    let end = p0 + dir * vp.far
                    g = Vec2(end.x, end.y)
                }
                minX = min(minX, g.x); maxX = max(maxX, g.x)
                minY = min(minY, g.y); maxY = max(maxY, g.y)
            }
        }
        // Auf Welt begrenzen (keine Wrap-Around-Darstellung im Prototyp).
        let w = vp.worldSize
        return WorldRect(minX: max(minX, 0), minY: max(minY, 0), maxX: min(maxX, w), maxY: min(maxY, w))
    }

    /// Kürzeste Distanz vom Auge zur (flachen) Kachel.
    static func distance(from eye: Vec3, to rect: WorldRect) -> Double {
        let dx = max(rect.minX - eye.x, 0, eye.x - rect.maxX)
        let dy = max(rect.minY - eye.y, 0, eye.y - rect.maxY)
        return (dx * dx + dy * dy + eye.z * eye.z).squareRoot()
    }

    public static func coveringTiles(_ vp: ViewProjection, options: Options = Options()) -> [TileID] {
        let visible = visibleGroundRect(vp)
        let targetZ = min(max(Int(vp.camera.zoom.rounded(.down)), options.minZoom), options.maxZoom)
        var result: [TileID] = []

        func tileRect(_ t: TileID) -> WorldRect {
            let size = vp.worldSize / Double(t.dimension)
            return WorldRect(minX: Double(t.x) * size, minY: Double(t.y) * size,
                             maxX: Double(t.x + 1) * size, maxY: Double(t.y + 1) * size)
        }

        func visit(_ t: TileID) {
            let r = tileRect(t)
            guard r.intersects(visible) else { return }
            if t.z >= targetZ { result.append(t); return }
            if t.z >= options.minZoom {
                // Projizierte Größe der Kachel: Pixelgröße auf aktuellem Zoom, skaliert
                // mit Kameradistanz / tatsächlicher Distanz.
                let size = vp.worldSize / Double(t.dimension)
                let d = max(distance(from: vp.eye, to: r), 1)
                let projected = size * vp.cameraDistance / d
                if projected <= Mercator.tileSize * options.lodBias {
                    result.append(t)
                    return
                }
            }
            for c in t.children { visit(c) }
        }
        visit(TileID(z: 0, x: 0, y: 0))

        if result.count > options.maxTiles {
            // Nach Entfernung sortieren und die fernsten verwerfen – besser als Ruckeln.
            result.sort { distance(from: vp.eye, to: tileRect($0)) < distance(from: vp.eye, to: tileRect($1)) }
            result = Array(result.prefix(options.maxTiles))
        }
        return result
    }
}
