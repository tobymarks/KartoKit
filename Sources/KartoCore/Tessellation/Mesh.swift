import Foundation

// GPU-fertige Vertex-Layouts. Die Structs sind so gebaut, dass sie 1:1 in Metal-
// Buffer kopiert werden können (siehe Shaders.metal – Layouts müssen übereinstimmen).

/// Flächen: nur Position in Tile-Einheiten. 8 Byte/Vertex.
public struct FillVertex: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public init(_ x: Float, _ y: Float) { self.x = x; self.y = y }
}

/// Linien: Position + Extrusionsnormale (Einheitsvektor × Miter-Länge) + Seite.
/// Der Vertex-Shader verschiebt entlang `normal` um die halbe Linienbreite (in
/// Tile-Einheiten, pro Frame aus Pixelbreite berechnet). 16 Byte/Vertex.
public struct LineVertex: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var nx: Float
    public var ny: Float
    public init(_ x: Float, _ y: Float, _ nx: Float, _ ny: Float) { self.x = x; self.y = y; self.nx = nx; self.ny = ny }
}

/// Extrusion: 3D-Position (z in Tile-Einheiten) + Normale für Beleuchtung
/// + Tonstreuung des Gebäudes. 28 Byte/Vertex.
///
/// `ton` ist für alle Vertices eines Gebäudes derselbe Wert in −1…1 und
/// hellt dessen Farbe im Shader minimal auf oder ab. Ohne ihn teilen sich
/// benachbarte Häuser mit gleicher Wandausrichtung exakt denselben Ton und
/// eine Siedlung verschmilzt zu einer Fläche.
public struct ExtrusionVertex: Sendable, Equatable {
    public var x: Float, y: Float, z: Float
    public var nx: Float, ny: Float, nz: Float
    public var ton: Float
    public init(_ x: Float, _ y: Float, _ z: Float,
                _ nx: Float, _ ny: Float, _ nz: Float, _ ton: Float = 0) {
        self.x = x; self.y = y; self.z = z
        self.nx = nx; self.ny = ny; self.nz = nz
        self.ton = ton
    }
}

/// Ein Zeichenbefehl: ein Style-Layer innerhalb einer Kachel.
public struct MeshBucket<V: Sendable>: Sendable {
    public var layerID: String
    public var vertices: [V]
    public var indices: [UInt32]
    public init(layerID: String, vertices: [V] = [], indices: [UInt32] = []) {
        self.layerID = layerID
        self.vertices = vertices
        self.indices = indices
    }
    public var isEmpty: Bool { indices.isEmpty }
}

/// Komplette, GPU-fertige Kachel: Buckets in Style-Reihenfolge.
public struct TileMesh: Sendable {
    public var tile: TileID
    public var extent: Int
    public var fills: [MeshBucket<FillVertex>]
    public var lines: [MeshBucket<LineVertex>]
    public var extrusions: [MeshBucket<ExtrusionVertex>]
    /// Reihenfolge, in der die Buckets (über alle Typen) gezeichnet werden: (Typ, Index).
    public var drawOrder: [(kind: BucketKind, index: Int)]
    /// Beschriftungs-Kandidaten dieser Kachel (Tile-Einheiten).
    public var labels: [LabelCandidate] = []

    public enum BucketKind: Sendable { case fill, line, extrusion }

    public var vertexBytes: Int {
        fills.reduce(0) { $0 + $1.vertices.count * MemoryLayout<FillVertex>.stride }
            + lines.reduce(0) { $0 + $1.vertices.count * MemoryLayout<LineVertex>.stride }
            + extrusions.reduce(0) { $0 + $1.vertices.count * MemoryLayout<ExtrusionVertex>.stride }
    }
}
