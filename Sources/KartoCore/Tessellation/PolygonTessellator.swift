import Foundation

/// Flächen-Triangulation (Earcut) und Gebäude-Extrusion.
public enum PolygonTessellator {

    /// Flaches Koordinatenarray + Lochindizes für Earcut aus MVT-Ringen.
    static func flatten(_ polygon: [[TilePoint]]) -> (data: [Double], holes: [Int]) {
        var data: [Double] = []
        var holes: [Int] = []
        data.reserveCapacity(polygon.reduce(0) { $0 + $1.count * 2 })
        for (i, ring) in polygon.enumerated() {
            // Schließenden Duplikatpunkt weglassen (Earcut erwartet offene Ringe).
            var r = ring
            if r.count > 1, r.first == r.last { r.removeLast() }
            if i > 0 { holes.append(data.count / 2) }
            for p in r { data.append(Double(p.x)); data.append(Double(p.y)) }
        }
        return (data, holes)
    }

    /// Fläche in den Bucket triangulieren.
    public static func fill(_ polygon: [[TilePoint]], into bucket: inout MeshBucket<FillVertex>) {
        let (data, holes) = flatten(polygon)
        guard data.count >= 6 else { return }
        let tri = Earcut.triangulate(data, holeIndices: holes)
        guard !tri.isEmpty else { return }
        let base = UInt32(bucket.vertices.count)
        var i = 0
        while i < data.count {
            bucket.vertices.append(FillVertex(Float(data[i]), Float(data[i + 1])))
            i += 2
        }
        bucket.indices.reserveCapacity(bucket.indices.count + tri.count)
        for t in tri { bucket.indices.append(base + t) }
    }

    /// Gebäude: Wände je Kante (Flat-Shading-Normalen) + Dach via Earcut.
    /// Höhen in Tile-Einheiten (bereits aus Metern umgerechnet).
    ///
    /// `ton` (−1…1) reist unverändert in jedem Vertex mit und streut die
    /// Farbe dieses einen Gebäudes; 0 heisst „genau die Themefarbe".
    public static func extrude(_ polygon: [[TilePoint]], base: Double, height: Double,
                               ton: Float = 0,
                               into bucket: inout MeshBucket<ExtrusionVertex>) {
        guard height > base else { return }
        let zBase = Float(base), zTop = Float(height)

        // Wände
        for ring in polygon {
            var r = ring
            if r.count > 1, r.first == r.last { r.removeLast() }
            guard r.count >= 3 else { continue }
            for i in 0..<r.count {
                let p0 = r[i], p1 = r[(i + 1) % r.count]
                let dx = Double(p1.x - p0.x), dy = Double(p1.y - p0.y)
                let len = (dx * dx + dy * dy).squareRoot()
                guard len > 0 else { continue }
                // Außennormale für MVT-Ringorientierung (äußere Ringe im Uhrzeigersinn bei y↓).
                let nx = Float(dy / len), ny = Float(-dx / len)
                let v = UInt32(bucket.vertices.count)
                bucket.vertices.append(ExtrusionVertex(Float(p0.x), Float(p0.y), zBase, nx, ny, 0, ton))
                bucket.vertices.append(ExtrusionVertex(Float(p1.x), Float(p1.y), zBase, nx, ny, 0, ton))
                bucket.vertices.append(ExtrusionVertex(Float(p1.x), Float(p1.y), zTop, nx, ny, 0, ton))
                bucket.vertices.append(ExtrusionVertex(Float(p0.x), Float(p0.y), zTop, nx, ny, 0, ton))
                bucket.indices.append(contentsOf: [v, v + 1, v + 2, v, v + 2, v + 3])
            }
        }

        // Dach
        let (data, holes) = flatten(polygon)
        guard data.count >= 6 else { return }
        let tri = Earcut.triangulate(data, holeIndices: holes)
        guard !tri.isEmpty else { return }
        let baseIndex = UInt32(bucket.vertices.count)
        var i = 0
        while i < data.count {
            bucket.vertices.append(ExtrusionVertex(Float(data[i]), Float(data[i + 1]), zTop, 0, 0, 1, ton))
            i += 2
        }
        for t in tri { bucket.indices.append(baseIndex + t) }
    }
}
