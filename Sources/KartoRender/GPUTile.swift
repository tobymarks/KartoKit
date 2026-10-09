#if canImport(Metal)
import Foundation
import Metal
import KartoCore

/// Uniform-Layout, identisch zu `DrawUniforms` in Shaders.metal (96 Byte).
struct DrawUniforms {
    var mvp: (Float, Float, Float, Float, Float, Float, Float, Float,
              Float, Float, Float, Float, Float, Float, Float, Float)
    var color: (Float, Float, Float, Float)
    var light: (Float, Float, Float, Float)

    /// `skalar` landet in `light.w` und bedeutet je nach Shader etwas
    /// anderes: bei Linien die halbe Breite in Tile-Einheiten, bei
    /// Gebäuden die Tonstreuung. Flächen lesen ihn nicht. Ein Feld für
    /// zwei Zwecke, weil beide Shader es nie gleichzeitig brauchen — die
    /// Bedeutung steht deshalb an der Aufrufstelle, nicht hier.
    init(mvp: Mat4, color: RGBA, light: (Float, Float, Float), skalar: Float) {
        let f = mvp.floats
        self.mvp = (f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7],
                    f[8], f[9], f[10], f[11], f[12], f[13], f[14], f[15])
        self.color = (color.r, color.g, color.b, color.a)
        self.light = (light.0, light.1, light.2, skalar)
    }
}

/// GPU-Repräsentation eines Buckets (Vertex- + Indexbuffer).
final class GPUBucket: @unchecked Sendable {
    enum Kind { case fill, line, extrusion }
    let kind: Kind
    let layerID: String
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    init?<V: Sendable>(device: MTLDevice, kind: Kind, bucket: MeshBucket<V>) {
        guard !bucket.indices.isEmpty else { return nil }
        let vBytes = bucket.vertices.count * MemoryLayout<V>.stride
        let iBytes = bucket.indices.count * MemoryLayout<UInt32>.stride
        guard let vb = bucket.vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: vBytes, options: .storageModeShared) }),
              let ib = bucket.indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: iBytes, options: .storageModeShared) })
        else { return nil }
        vb.label = "\(bucket.layerID) vertices"
        ib.label = "\(bucket.layerID) indices"
        self.kind = kind
        self.layerID = bucket.layerID
        vertexBuffer = vb
        indexBuffer = ib
        indexCount = bucket.indices.count
    }
}

/// Eine geladene Kachel auf der GPU. Buckets nach Style-Layer-ID, damit der Renderer
/// layerweise über alle Kacheln zeichnen kann (korrekte Überlagerung über Kachelgrenzen).
final class GPUTile: @unchecked Sendable {
    let id: TileID
    let extent: Int
    let buckets: [String: GPUBucket]
    /// Beschriftungs-Kandidaten (Tile-Einheiten), für den LabelRenderer.
    let labels: [LabelCandidate]
    /// Nur vom MainActor (TileManager) geschrieben.
    var lastUsedFrame: UInt64 = 0
    let byteSize: Int

    init(device: MTLDevice, mesh: TileMesh) {
        id = mesh.tile
        extent = mesh.extent
        var b: [String: GPUBucket] = [:]
        for f in mesh.fills { if let g = GPUBucket(device: device, kind: .fill, bucket: f) { b[f.layerID] = g } }
        for l in mesh.lines { if let g = GPUBucket(device: device, kind: .line, bucket: l) { b[l.layerID] = g } }
        for e in mesh.extrusions { if let g = GPUBucket(device: device, kind: .extrusion, bucket: e) { b[e.layerID] = g } }
        buckets = b
        labels = mesh.labels
        byteSize = mesh.vertexBytes + mesh.fills.reduce(0) { $0 + $1.indices.count * 4 }
            + mesh.lines.reduce(0) { $0 + $1.indices.count * 4 }
            + mesh.extrusions.reduce(0) { $0 + $1.indices.count * 4 }
    }

    /// Leere Kachel (existiert nicht in der Quelle) – wird gecacht, damit nicht erneut angefragt wird.
    init(empty id: TileID) {
        self.id = id
        extent = 4096
        buckets = [:]
        labels = []
        byteSize = 0
    }
}

/// MTLDevice ist thread-sicher, aber nicht als Sendable annotiert.
struct DeviceBox: @unchecked Sendable {
    let device: MTLDevice
}
#endif
