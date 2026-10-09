#if canImport(UIKit) && canImport(Metal)
import UIKit
import Metal
import KartoCore

/// Zeichnet den Positions-Puck nach `PuckDesign`:
/// - Genauigkeitskreis und Halo liegen **auf dem Boden** (perspektivisch
///   der blaue Halo, der bei Neigung zur Ellipse wird)
/// - der Pfeil selbst liegt **im Bildschirmraum**: konstante Punktgröße, nie verzerrt,
///   gedreht um (Kurs − Karten-Bearing), immer über Route und Markern
/// - Formen: Vektorpfeil/Chevron/eigenes Polygon (einfarbig mit Rand) oder Bild-Asset
///   (mehrfarbig, z. B. `NavigationArrow` aus der Demo)
/// - kein Fix: `stale`-Farbe bzw. gedimmtes Bild
@MainActor
final class PuckRenderer {
    struct Mesh { let buffer: MTLBuffer; let indices: MTLBuffer; let count: Int }

    private let device: MTLDevice
    private var disc: Mesh!
    private var vectorShape: (points: [Vec2], indices: [UInt32], strokePoints: [Vec2])?
    private var vectorShapeKey: PuckDesign.Shape?

    init(device: MTLDevice) {
        self.device = device
        var b = MeshBucket<FillVertex>(layerID: "puck-disc")
        b.vertices.append(FillVertex(0, 0))
        let n = 40
        for i in 0...n {
            let a = Double(i) / Double(n) * 2 * .pi
            b.vertices.append(FillVertex(Float(cos(a)), Float(sin(a))))
        }
        for i in 1...n { b.indices.append(contentsOf: [0, UInt32(i), UInt32(i + 1)]) }
        let vb = b.vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
        let ib = b.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
        disc = Mesh(buffer: vb, indices: ib, count: b.indices.count)
    }

    /// Bildschirmposition + Bounding-Box des Pucks (für Marker-Kollision) – nil wenn außerhalb.
    func screenBox(_ puck: PuckState, design: PuckDesign, vp: ViewProjection) -> CollisionGrid.Box? {
        guard let s = vp.project(unitMercator: Mercator.project(puck.coordinate)) else { return nil }
        let r = design.size * 0.75
        return CollisionGrid.Box(center: s, width: r * 2, height: r * 2)
    }

    // MARK: - Boden (Fill-Pipeline)

    func drawGround(_ puck: PuckState, design: PuckDesign, enc: MTLRenderCommandEncoder, vp: ViewProjection,
                    fillPipeline: MTLRenderPipelineState, haloPipeline: MTLRenderPipelineState,
                    depthState: MTLDepthStencilState, stats: inout MapRenderer.FrameStats) {
        let world = Mercator.project(puck.coordinate) * vp.worldSize
        let base = vp.viewProjection * Mat4.translation(world.x, world.y, 0)
        let inView = vp.view * Vec4(world.x, world.y, 0, 1)
        let pixelScale = max(-inView.z, 1e-3) / vp.cameraDistance

        enc.setRenderPipelineState(fillPipeline)
        enc.setDepthStencilState(depthState)
        func drawDisc(_ radius: Double, _ color: RGBA, weich: Bool = false) {
            enc.setRenderPipelineState(weich ? haloPipeline : fillPipeline)
            var u = DrawUniforms(mvp: base * Mat4.scale(radius, radius, 1), color: color, light: (0, 0, 1), skalar: 0)
            enc.setVertexBuffer(disc.buffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: disc.count, indexType: .uint32, indexBuffer: disc.indices, indexBufferOffset: 0)
            stats.drawCalls += 1
        }
        // Genauigkeit in echten Metern (nur wenn größer als der Puck und nicht absurd groß)
        let mpp = Mercator.metersPerPixel(latitude: puck.coordinate.latitude, zoom: vp.camera.zoom)
        let accuracyPx = puck.accuracyMeters / mpp
        if accuracyPx > design.size * 0.8, accuracyPx < max(vp.width, vp.height) * 2 {
            drawDisc(accuracyPx, design.accuracy)
        }
        if let halo = design.halo, design.haloRadius > 0, !puck.isStale {
            drawDisc(design.haloRadius * pixelScale, halo, weich: true)
        }
    }

    // MARK: - Pfeil (Bildschirmraum, SpriteBatch)

    func drawArrow(_ puck: PuckState, design: PuckDesign, vp: ViewProjection, batch: SpriteBatch, atlas: IconAtlas) {
        guard let s = vp.project(unitMercator: Mercator.project(puck.coordinate)) else { return }
        // Rotation: Kurs relativ zum Karten-Bearing (Norden oben = 0)
        let rot = (puck.heading - vp.camera.bearing) * .pi / 180
        let size = design.size
        let dim: Float = puck.isStale ? 0.55 : 1
        let auf = auflegen(puck: puck, design: design, vp: vp, schirm: s, rot: rot)

        switch design.shape {
        case .image(let name):
            if let r = atlas.region(for: .image(name, size: size)) {
                let ax = r.width / size, ay = r.height / size
                let ecken = [Vec2(-ax, -ay), Vec2(ax, -ay), Vec2(ax, ay), Vec2(-ax, ay)]
                    .map { auf($0, size / 2) }
                batch.addQuad(corners: ecken, uv: (r.u0, r.v0, r.u1, r.v1), color: RGBA(1, 1, 1, dim))
            } else {
                drawVector(.arrow, at: s, rot: rot, size: size, design: design, stale: puck.isStale, batch: batch, auf: auf)
            }
        default:
            drawVector(design.shape, at: s, rot: rot, size: size, design: design, stale: puck.isStale, batch: batch, auf: auf)
        }
        if puck.style == .dot {
            // Punkt-Darstellung (optional, `Tuning.dotWhenStill`)
            batch.addSolidCircle(center: s, radius: size * 0.36, color: design.fill)
            batch.addSolidCircle(center: s, radius: size * 0.28, color: puck.isStale ? design.stale : design.stroke)
        }
    }

    /// Liefert eine Funktion, die einen Punkt der Pfeilform (Einheitskoordinaten
    /// −1…1, Norden = −y) auf den Bildschirm bringt.
    ///
    /// Bisher wurde der Pfeil rein im Bildschirmraum gezeichnet: immer gleich
    /// gross, nie verzerrt — aber bei geneigter Kamera steht er dadurch fast
    /// senkrecht im Bild, wie ein aufgestelltes Schild. Wir legen ihn statt
    /// dessen in die Fahrbahnebene, wo er dieselbe perspektivische Verkuerzung
    /// bekommt wie die Strasse darunter.
    ///
    /// Hier wird beides gerechnet und nach `design.groundAlignment` gemischt:
    /// Die Form wird einmal im Bildschirm aufgespannt und einmal auf dem Boden
    /// (um den Kurs gedreht, in Weltmasse skaliert, Ecke fuer Ecke projiziert).
    /// `pixelScale` haelt dabei die scheinbare Groesse konstant, damit der Pfeil
    /// in der Ferne nicht schrumpft.
    private func auflegen(puck: PuckState, design: PuckDesign, vp: ViewProjection,
                          schirm: Vec2, rot: Double) -> (Vec2, Double) -> Vec2 {
        let lage = design.groundAlignment
        let c = cos(rot), sn = sin(rot)
        // Reiner Bildschirmweg — der Rueckfall, wenn nichts aufgelegt wird.
        func imBild(_ p: Vec2, _ halb: Double) -> Vec2 {
            let x = p.x * halb, y = p.y * halb
            return Vec2(schirm.x + x * c - y * sn, schirm.y + x * sn + y * c)
        }
        guard lage > 0 else { return imBild }

        let unit = Mercator.project(puck.coordinate)
        let welt = unit * vp.worldSize
        let imBlick = vp.view * Vec4(welt.x, welt.y, 0, 1)
        let pixelScale = max(-imBlick.z, 1e-3) / vp.cameraDistance
        // Drehung in der Weltebene: x nach Osten, y nach Sueden, Kurs im
        // Uhrzeigersinn ab Norden.
        let kurs = puck.heading * .pi / 180
        let ck = cos(kurs), sk = sin(kurs)

        return { p, halb in
            let masz = halb * pixelScale
            let wx = (p.x * ck - p.y * sk) * masz
            let wy = (p.x * sk + p.y * ck) * masz
            guard let boden = vp.project(unitMercator: Vec2((welt.x + wx) / vp.worldSize,
                                                            (welt.y + wy) / vp.worldSize))
            else { return imBild(p, halb) }
            guard lage < 1 else { return boden }
            let bild = imBild(p, halb)
            return Vec2(bild.x + (boden.x - bild.x) * lage,
                        bild.y + (boden.y - bild.y) * lage)
        }
    }

    private func unitShape(_ shape: PuckDesign.Shape) -> (points: [Vec2], indices: [UInt32]) {
        switch shape {
        case .chevron:
            let p = [Vec2(0, -1), Vec2(0.7, 0.75), Vec2(0, 0.35), Vec2(-0.7, 0.75)]
            return (p, [0, 1, 2, 0, 2, 3])
        case .custom(let pts) where pts.count >= 3:
            var flat: [Double] = []
            for p in pts { flat.append(p.x); flat.append(p.y) }
            return (pts, Earcut.triangulate(flat))
        default: // .arrow und Fallbacks: Navi-Pfeil, Spitze oben, eingekerbte Basis
            let p = [Vec2(0, -1), Vec2(0.62, 0.55), Vec2(0, 0.22), Vec2(-0.62, 0.55)]
            return (p, [0, 1, 2, 0, 2, 3])
        }
    }

    private func drawVector(_ shape: PuckDesign.Shape, at s: Vec2, rot: Double, size: Double,
                            design: PuckDesign, stale: Bool, batch: SpriteBatch,
                            auf: (Vec2, Double) -> Vec2) {
        let (pts, idx) = unitShape(shape)
        func place(_ scale: Double) -> [Vec2] { pts.map { auf($0, scale) } }
        let half = size / 2
        // Rand als größere Kopie darunter, dann Füllung
        if design.strokeRatio > 0 {
            batch.addSolidTriangles(points: place(half * (1 + design.strokeRatio * 2)), indices: idx, color: stale ? design.stale : design.stroke)
        }
        batch.addSolidTriangles(points: place(half), indices: idx, color: stale ? RGBA(0.85, 0.85, 0.85, 1) : design.fill)
    }
}
#endif
