#if canImport(UIKit) && canImport(Metal)
import Foundation
import Metal
import KartoCore

/// Uniform-Layout, identisch zu `RouteUniforms` in Shaders.metal (624 Byte).
struct RouteUniformsGPU {
    var mvp: (Float, Float, Float, Float, Float, Float, Float, Float,
              Float, Float, Float, Float, Float, Float, Float, Float)
    var color: (Float, Float, Float, Float)
    var drivenColor: (Float, Float, Float, Float)
    var hatchColor: (Float, Float, Float, Float)
    var halfWidth: Float
    var driven: Float
    var segmentCount: UInt32
    var pad: Float = 0
    var segments: (Seg, Seg, Seg, Seg, Seg, Seg, Seg, Seg, Seg, Seg, Seg, Seg, Seg, Seg, Seg, Seg)

    /// `hatch` ist die Laenge eines Streifenpaars in Metern; 0 zeichnet
    /// den Abschnitt einfarbig. Nur Sperrungen setzen ihn.
    struct Seg { var from: Float = 0; var to: Float = 0
                 var hatch: Float = 0; var pad1: Float = 0
                 var color: (Float, Float, Float, Float) = (0, 0, 0, 0) }

    init(mvp: Mat4, color: RGBA, drivenColor: RGBA,
         hatchColor: RGBA = RGBA(hex: 0xF4F1E8), halfWidth: Float,
         driven: Float, segments segs: [RouteUniformsGPU.Seg]) {
        let f = mvp.floats
        self.mvp = (f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12], f[13], f[14], f[15])
        self.color = (color.r, color.g, color.b, color.a)
        self.drivenColor = (drivenColor.r, drivenColor.g, drivenColor.b, drivenColor.a)
        self.hatchColor = (hatchColor.r, hatchColor.g, hatchColor.b, hatchColor.a)
        self.halfWidth = halfWidth
        self.driven = driven
        var s = [Seg](repeating: Seg(), count: 16)
        for (i, seg) in segs.prefix(16).enumerated() { s[i] = seg }
        segmentCount = UInt32(min(segs.count, 16))
        segments = (s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7], s[8], s[9], s[10], s[11], s[12], s[13], s[14], s[15])
    }
}

/// Hält GPU-Meshes pro Route (und den Manöverpfeil) und zeichnet sie mit
/// Fortschritt/Abschnitten als Uniforms. Ein Mesh wird nur bei Geometrieänderung neu gebaut.
@MainActor
final class RouteRenderer {
    private struct GPURoute {
        let mesh: RouteMesh
        let vertexBuffer: MTLBuffer
        let indexBuffer: MTLBuffer
        let indexCount: Int
        let coordinatesHash: Int
    }

    private let device: MTLDevice
    private var routes: [String: GPURoute] = [:]
    private var arrow: (GPURoute, GPURoute)?     // Linie + Spitze
    private var arrowKey: (routeID: String, distance: Double, next: Double?, width: Double, geometry: Int)?

    init(device: MTLDevice) { self.device = device }

    private static func hash(_ c: [Coordinate]) -> Int {
        var h = Hasher()
        h.combine(c.count)
        let step = max(1, c.count / 64)
        var i = 0
        while i < c.count { h.combine(c[i].latitude); h.combine(c[i].longitude); i += step }
        if let l = c.last { h.combine(l.latitude); h.combine(l.longitude) }
        return h.finalize()
    }

    private func upload(_ mesh: RouteMesh, hash: Int) -> GPURoute? {
        guard !mesh.indices.isEmpty,
              let vb = mesh.vertices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }),
              let ib = mesh.indices.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        else { return nil }
        return GPURoute(mesh: mesh, vertexBuffer: vb, indexBuffer: ib, indexCount: mesh.indices.count, coordinatesHash: hash)
    }

    /// Meshes mit dem aktuellen Routen-Satz abgleichen (nur geänderte Geometrien neu bauen).
    func sync(_ displays: [RouteDisplay]) {
        var keep = Set<String>()
        for d in displays {
            keep.insert(d.id)
            let h = Self.hash(d.coordinates)
            if let existing = routes[d.id], existing.coordinatesHash == h { continue }
            if let g = upload(RouteMesh(coordinates: d.coordinates), hash: h) { routes[d.id] = g } else { routes[d.id] = nil }
        }
        for k in routes.keys where !keep.contains(k) { routes[k] = nil }
    }

    /// Manöverpfeil für die aktive Route an Streckenposition `distanceAlong` (nil = keiner).
    func syncManeuverArrow(route: RouteDisplay?, distanceAlong: Double?, nextDistanceAlong: Double?, widthPx: Double) {
        guard let route, let d = distanceAlong else { arrow = nil; arrowKey = nil; return }
        let geometry = Self.hash(route.coordinates)
        if let k = arrowKey, k.routeID == route.id, abs(k.distance - d) < 0.5,
           k.next == nextDistanceAlong, k.width == widthPx, k.geometry == geometry,
           arrow != nil { return }
        let line = ManeuverArrow.polyline(route: route.coordinates, maneuverDistanceAlong: d,
                                          nextManeuverDistanceAlong: nextDistanceAlong)
        guard line.count >= 2 else { arrow = nil; arrowKey = nil; return }
        let mesh = RouteMesh(coordinates: line)
        let (hv, hi) = ManeuverArrow.head(polyline: line, origin: mesh.origin, localZoom: mesh.localZoom,
                                          widthPx: widthPx * 1.6, lengthPx: widthPx * 2.2)
        var head = RouteMesh(coordinates: [])
        head.origin = mesh.origin; head.localZoom = mesh.localZoom; head.vertices = hv; head.indices = hi
        if let l = upload(mesh, hash: 0), let h = upload(head, hash: 0) {
            arrow = (l, h); arrowKey = (route.id, d, nextDistanceAlong, widthPx, geometry)
        } else { arrow = nil }
    }

    private func localMatrix(_ mesh: RouteMesh, vp: ViewProjection) -> (Mat4, Double) {
        let scale = pow(2.0, vp.camera.zoom - mesh.localZoom)
        let o = mesh.origin * vp.worldSize
        return (vp.viewProjection * Mat4.translation(o.x, o.y, 0) * Mat4.scale(scale, scale, scale), 1 / scale)
    }

    private func draw(_ g: GPURoute, enc: MTLRenderCommandEncoder, u: inout RouteUniformsGPU, stats: inout MapRenderer.FrameStats) {
        enc.setVertexBuffer(g.vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<RouteUniformsGPU>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<RouteUniformsGPU>.stride, index: 1)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: g.indexCount, indexType: .uint32, indexBuffer: g.indexBuffer, indexBufferOffset: 0)
        stats.drawCalls += 1
    }

    /// Zeichnet Alternativen zuerst, dann die aktive Route (Casing + Kern), dann den Manöverpfeil.
    func draw(_ displays: [RouteDisplay], theme: RouteColors, enc: MTLRenderCommandEncoder, vp: ViewProjection,
              pipeline: MTLRenderPipelineState, depthState: MTLDepthStencilState, stats: inout MapRenderer.FrameStats) {
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        let zoom = vp.camera.zoom
        // Breiten in Pixeln (leicht zoomabhängig: bei Übersicht schmaler)
        let widthScale = min(1.0, max(0.55, (zoom - 9) / 6))
        // Streifenlaenge in Metern, so gewaehlt dass ein Streifenpaar
        // auf dem Bildschirm immer gleich lang bleibt. Unter drei
        // Metern flimmert es, also dort abgefangen.
        let mpp = Mercator.metersPerPixel(
            latitude: Mercator.unproject(vp.camera.center).latitude,
            zoom: zoom)
        let hatchM = theme.trafficClosedHatchLength > 0
            ? Float(max(3.0, theme.trafficClosedHatchLength * mpp)) : 0
        let ordered = displays.filter { !$0.isActive } + displays.filter { $0.isActive }
        for d in ordered {
            guard let g = routes[d.id] else { continue }
            let (mvp, upp) = localMatrix(g.mesh, vp: vp)
            let core = (d.isActive ? theme.activeWidth : theme.alternativeWidth) * widthScale
            let casing = (d.isActive ? theme.casingWidth : theme.alternativeWidth + 3) * widthScale
            let driven = Float(d.isActive ? d.drivenDistance : 0)
            let segs: [RouteUniformsGPU.Seg] = d.isActive ? d.segments.map { s in
                let c: RGBA
                var hatch: Float = 0
                switch s.kind {
                case .slow: c = theme.trafficSlow
                case .jam: c = theme.trafficJam
                case .closed: c = theme.trafficClosed; hatch = hatchM
                case .custom(let x): c = x
                }
                return RouteUniformsGPU.Seg(from: Float(s.from), to: Float(s.to),
                                            hatch: hatch,
                                            color: (c.r, c.g, c.b, c.a))
            } : []

            // Verkehrssaum, ganz unten und breiter als das Casing: durchgehend
            // die Freifluss-Farbe, an den gemeldeten Abschnitten gelb bis rot.
            // Der Saum macht die Karte deutlich farbiger und lesbarer.
            //
            // Nur wo Verkehrsdaten vorliegen: ohne sie waere ein gruener Saum
            // die Behauptung freier Fahrt, die niemand gemeldet hat.
            if d.isActive, d.trafficKnown, theme.trafficFlankWidth > 0 {
                let saum = theme.trafficFlankWidth * widthScale
                var us = RouteUniformsGPU(mvp: mvp, color: theme.trafficFree,
                                          drivenColor: theme.drivenCasing,
                                          hatchColor: theme.trafficClosedHatch,
                                          halfWidth: Float(saum / 2 * upp),
                                          driven: driven, segments: segs)
                draw(g, enc: enc, u: &us, stats: &stats)
            }

            // Casing
            var uc = RouteUniformsGPU(mvp: mvp, color: d.isActive ? theme.casing : theme.alternativeCasing,
                                      drivenColor: d.isActive ? theme.drivenCasing : theme.alternativeCasing,
                                      halfWidth: Float(casing / 2 * upp), driven: driven, segments: [])
            draw(g, enc: enc, u: &uc, stats: &stats)

            // Kern mit Abschnitten
            var uk = RouteUniformsGPU(mvp: mvp,
                                      color: d.isActive ? theme.active : theme.alternative,
                                      drivenColor: theme.driven,
                                      hatchColor: theme.trafficClosedHatch,
                                      halfWidth: Float(core / 2 * upp),
                                      driven: driven, segments: segs)
            draw(g, enc: enc, u: &uk, stats: &stats)
        }
        if let (line, head) = arrow {
            let (mvp, upp) = localMatrix(line.mesh, vp: vp)
            let w = theme.activeWidth * widthScale * 0.9
            for (color, width) in [(theme.maneuverArrowCasing, w + 4), (theme.maneuverArrow, w)] {
                var u = RouteUniformsGPU(mvp: mvp, color: color, drivenColor: color, halfWidth: Float(width / 2 * upp), driven: -1, segments: [])
                draw(line, enc: enc, u: &u, stats: &stats)
                // Spitze: ohne Extrusion (Normale 0), Farbe wie Kern; Casing-Spitze etwas größer wäre ein zweites Mesh – hier eine Spitze
            }
            let (hmvp, _) = localMatrix(head.mesh, vp: vp)
            var uh = RouteUniformsGPU(mvp: hmvp, color: theme.maneuverArrow, drivenColor: theme.maneuverArrow, halfWidth: 0, driven: -1, segments: [])
            draw(head, enc: enc, u: &uh, stats: &stats)
        }
    }
}
#endif
