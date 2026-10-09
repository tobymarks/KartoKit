#if canImport(UIKit) && canImport(Metal)
import Foundation
import Metal
import KartoCore

/// Vertex für Bildschirm-Quads (Marker, Labels, Puck). 32 Byte, Layout wie `SpriteVertexIn`.
struct SpriteVertex {
    var x: Float, y: Float
    var u: Float, v: Float
    var r: Float, g: Float, b: Float, a: Float
}

/// Sammelt pro Frame alle Bildschirm-Quads/-Dreiecke und zeichnet sie in wenigen
/// Draw-Calls: erst texturierte (Atlas), dann einfarbige. Dynamische Buffer im
/// Dreifach-Ring, damit die GPU nicht auf die CPU wartet.
@MainActor
final class SpriteBatch {
    private let device: MTLDevice
    private var texturedVerts: [SpriteVertex] = []
    private var texturedIdx: [UInt32] = []
    private var solidVerts: [SpriteVertex] = []
    private var solidIdx: [UInt32] = []
    private var ring: [(v: MTLBuffer, i: MTLBuffer)] = []
    private var ringIndex = 0
    private let sampler: MTLSamplerState

    init(device: MTLDevice) {
        self.device = device
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .notMipmapped
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)!
    }

    func begin() {
        texturedVerts.removeAll(keepingCapacity: true); texturedIdx.removeAll(keepingCapacity: true)
        solidVerts.removeAll(keepingCapacity: true); solidIdx.removeAll(keepingCapacity: true)
    }

    /// Texturiertes Quad: Mitte, Größe (Punkte), Rotation (rad, im Uhrzeigersinn), UV-Rechteck.
    func addQuad(center: Vec2, size: Vec2, rotation: Double = 0, uv: (u0: Float, v0: Float, u1: Float, v1: Float),
                 color: RGBA = RGBA(1, 1, 1, 1), anchor: Vec2 = Vec2(0, 0)) {
        let c = cos(rotation), s = sin(rotation)
        let hw = size.x / 2, hh = size.y / 2
        // Anker: (0,0) = Mitte, (0,1) = Unterkante auf `center` (Pin-Spitze)
        let ox = -anchor.x * hw, oy = -anchor.y * hh
        let corners = [(-hw + ox, -hh + oy), (hw + ox, -hh + oy), (hw + ox, hh + oy), (-hw + ox, hh + oy)]
        let uvs: [(Float, Float)] = [(uv.u0, uv.v0), (uv.u1, uv.v0), (uv.u1, uv.v1), (uv.u0, uv.v1)]
        let base = UInt32(texturedVerts.count)
        for (i, p) in corners.enumerated() {
            let x = center.x + p.0 * c - p.1 * s
            let y = center.y + p.0 * s + p.1 * c
            texturedVerts.append(SpriteVertex(x: Float(x), y: Float(y), u: uvs[i].0, v: uvs[i].1, r: color.r, g: color.g, b: color.b, a: color.a))
        }
        texturedIdx.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
    }

    /// Texturiertes Quad mit frei gesetzten Ecken (im Uhrzeigersinn ab oben links).
    ///
    /// Gebraucht fuer alles, was in der Kartenebene liegt statt im Bildschirm:
    /// Die vier Ecken werden dann in Weltkoordinaten aufgespannt und einzeln
    /// projiziert, wodurch das Bild dieselbe perspektivische Verkuerzung bekommt
    /// wie die Strasse darunter.
    func addQuad(corners: [Vec2], uv: (u0: Float, v0: Float, u1: Float, v1: Float),
                 color: RGBA = RGBA(1, 1, 1, 1)) {
        guard corners.count == 4 else { return }
        let uvs: [(Float, Float)] = [(uv.u0, uv.v0), (uv.u1, uv.v0), (uv.u1, uv.v1), (uv.u0, uv.v1)]
        let base = UInt32(texturedVerts.count)
        for (i, p) in corners.enumerated() {
            texturedVerts.append(SpriteVertex(x: Float(p.x), y: Float(p.y), u: uvs[i].0, v: uvs[i].1,
                                              r: color.r, g: color.g, b: color.b, a: color.a))
        }
        texturedIdx.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
    }

    /// Einfarbiges Rechteck (Halo-Box, Schild-Hintergrund).
    func addSolidRect(center: Vec2, size: Vec2, rotation: Double = 0, color: RGBA) {
        let c = cos(rotation), s = sin(rotation)
        let hw = size.x / 2, hh = size.y / 2
        let corners = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]
        let base = UInt32(solidVerts.count)
        for p in corners {
            solidVerts.append(SpriteVertex(x: Float(center.x + p.0 * c - p.1 * s), y: Float(center.y + p.0 * s + p.1 * c),
                                           u: 0, v: 0, r: color.r, g: color.g, b: color.b, a: color.a))
        }
        solidIdx.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
    }

    /// Einfarbige Dreiecke (Vektor-Puck, Pfeilspitzen) – Punkte in Bildschirm-Punkten.
    func addSolidTriangles(points: [Vec2], indices: [UInt32], color: RGBA) {
        let base = UInt32(solidVerts.count)
        for p in points {
            solidVerts.append(SpriteVertex(x: Float(p.x), y: Float(p.y), u: 0, v: 0, r: color.r, g: color.g, b: color.b, a: color.a))
        }
        solidIdx.append(contentsOf: indices.map { $0 + base })
    }

    /// Kreis als Fächer (Bildschirm-Punkte).
    func addSolidCircle(center: Vec2, radius: Double, color: RGBA, segments: Int = 32) {
        var pts = [center]
        var idx: [UInt32] = []
        for i in 0...segments {
            let a = Double(i) / Double(segments) * 2 * .pi
            pts.append(Vec2(center.x + radius * cos(a), center.y + radius * sin(a)))
        }
        for i in 1...segments { idx.append(contentsOf: [0, UInt32(i), UInt32(i + 1)]) }
        addSolidTriangles(points: pts, indices: idx, color: color)
    }

    var isEmpty: Bool { texturedIdx.isEmpty && solidIdx.isEmpty }

    /// Zeichnet beide Listen. `screenToClip`: Punkte → Clip (Ursprung oben links).
    func flush(enc: MTLRenderCommandEncoder, texturedPipeline: MTLRenderPipelineState, solidPipeline: MTLRenderPipelineState,
               depthState: MTLDepthStencilState, texture: MTLTexture?, width: Double, height: Double, stats: inout MapRenderer.FrameStats) {
        guard !isEmpty else { return }
        var m = Mat4.identity
        m[0, 0] = 2 / width; m[1, 1] = -2 / height; m[3, 0] = -1; m[3, 1] = 1
        var u = SpriteUniformsGPU(m)
        enc.setDepthStencilState(depthState)

        // Ring-Buffer: ein Vertex/Index-Buffer je Frame, wächst bei Bedarf
        let vBytes = (texturedVerts.count + solidVerts.count) * MemoryLayout<SpriteVertex>.stride
        let iBytes = (texturedIdx.count + solidIdx.count) * MemoryLayout<UInt32>.stride
        if ring.count < 3 || ring[ringIndex].v.length < vBytes || ring[ringIndex].i.length < iBytes {
            let vb = device.makeBuffer(length: max(vBytes, 64 * 1024) * 2, options: .storageModeShared)!
            let ib = device.makeBuffer(length: max(iBytes, 16 * 1024) * 2, options: .storageModeShared)!
            if ring.count < 3 { ring.append((vb, ib)) } else { ring[ringIndex] = (vb, ib) }
        }
        let buf = ring[ringIndex]
        ringIndex = (ringIndex + 1) % 3
        // Reihenfolge: erst die einfarbigen Flächen (Schild-Hintergründe), dann die texturierten
        // Quads (Text, Marker, Puck) – sonst decken die Schilder ihren eigenen Text ab.
        let allVerts = solidVerts + texturedVerts
        let texturedOffset = UInt32(solidVerts.count)
        let allIdx = solidIdx + texturedIdx.map { $0 + texturedOffset }
        allVerts.withUnsafeBytes { buf.v.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        allIdx.withUnsafeBytes { buf.i.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        enc.setVertexBuffer(buf.v, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<SpriteUniformsGPU>.stride, index: 1)
        if !solidIdx.isEmpty {
            enc.setRenderPipelineState(solidPipeline)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: solidIdx.count, indexType: .uint32, indexBuffer: buf.i, indexBufferOffset: 0)
            stats.drawCalls += 1
        }
        if !texturedIdx.isEmpty, let texture {
            enc.setRenderPipelineState(texturedPipeline)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: texturedIdx.count, indexType: .uint32, indexBuffer: buf.i,
                                      indexBufferOffset: solidIdx.count * MemoryLayout<UInt32>.stride)
            stats.drawCalls += 1
        }
    }
}

struct SpriteUniformsGPU {
    var m: (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)
    init(_ mat: Mat4) {
        let f = mat.floats
        m = (f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13], f[14], f[15])
    }
}
#endif
