#if canImport(Metal) && canImport(MetalKit) && canImport(UIKit)
import Foundation
import Metal
import MetalKit
import UIKit
import KartoCore

/// Metal-Renderer: zeichnet pro Frame alle sichtbaren Kacheln layerweise, dann Routen,
/// Marker, Beschriftungen und den Puck. Keine Allokationen im Frame außer Uniform-Bytes
/// und dem Sprite-Batch.
///
/// Reihenfolge (unten → oben): Flächen/Straßen/Gebäude je Style-Layer → Alternativrouten
/// → aktive Route (Casing, Kern, Verkehr) → Manöverpfeil → Puck-Boden (Halo) → Marker →
/// Labels → Puck-Pfeil.
@MainActor
public final class MapRenderer: NSObject, MTKViewDelegate {
    public let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let tileManager: TileManager
    /// Zweite Kachelquelle allein fuer den Verkehrsfluss.
    ///
    /// Bewusst getrennt von der Karte: Die Kacheln kommen von einem
    /// anderen Dienst, gelten nur Minuten und decken nur wenige
    /// Zoomstufen ab. Ein gemeinsamer Zwischenspeicher wuerde die
    /// Karte mit dem Verkehr veralten lassen.
    private var flussManager: TileManager?
    private var flussAbdeckung = TileCoverage.Options()

    /// Kachelschema der Quelle; bestimmt die Style-Erzeugung aus dem Theme.
    public let schema: TileSchema

    /// Aktuelles Theme. Setzen startet einen Farbübergang (`themeTransition` Sekunden);
    /// Kacheln werden nicht neu gebaut, weil die Layer-Struktur gleich bleibt.
    public var theme: MapTheme {
        get { targetTheme }
        set { setTheme(newValue, animated: themeTransition > 0) }
    }
    public var themeTransition: Double = 0.425   // 425 ms Crossfade
    private var currentTheme: MapTheme
    private var targetTheme: MapTheme
    private var fromStyle: MapStyle
    private var targetStyle: MapStyle
    private var transitionStart: CFTimeInterval?
    /// Übergang aufschieben (während Manöveranimation), siehe Konzept.
    public var deferThemeTransition = false

    /// Effektiver Style dieses Frames (interpoliert).
    public private(set) var style: MapStyle
    public var camera: MapCamera
    public var coverageOptions = TileCoverage.Options()

    /// Routen (aktiv + Alternativen). Kompatibilität: `route` setzt eine aktive Route.
    public var routes: [RouteDisplay] = []
    public var route: [Coordinate] {
        get { routes.first { $0.isActive }?.coordinates ?? [] }
        set {
            routes.removeAll { $0.isActive }
            if newValue.count >= 2 { routes.insert(RouteDisplay(id: "route", coordinates: newValue), at: 0) }
        }
    }
    /// Fortschritt der aktiven Route (Meter) – vom NavigationController gesetzt.
    public var drivenDistance: Double = 0
    /// Streckenposition des nächsten Manövers → weißer Pfeil auf der Straße (nil = keiner).
    public var maneuverArrowDistance: Double?
    public var maneuverArrowNextDistance: Double?
    /// Manöverpfeil nur zeichnen, wenn näher als (Meter).
    public var maneuverArrowMaxDistance = 400.0

    /// Marker.
    public var annotations: [MapAnnotation] = []

    /// Positions-Puck (von `NavigationController.tick` oder manuell gesetzt).
    public var puck: PuckState?
    public var userPosition: Coordinate? {
        get { puck?.coordinate }
        set {
            guard let c = newValue else { puck = nil; return }
            puck = PuckState(coordinate: c, heading: puck?.heading ?? 0, accuracyMeters: 10, speed: 0, isStale: false, isMoving: false)
        }
    }
    public var userHeading: Double {
        get { puck?.heading ?? 0 }
        set { puck?.heading = newValue }
    }

    public private(set) var lastFrameStats = FrameStats()
    public struct FrameStats {
        public init() {}
        public var tilesDrawn = 0
        public var drawCalls = 0
        public var tilesCached = 0
        public var tilesLoading = 0
        public var cacheBytes = 0
        public var cpuMillis = 0.0
        public var annotationsDrawn = 0
        public var labelsDrawn = 0
    }

    private var fillPipeline: MTLRenderPipelineState!
    /// Wie fillPipeline, nur mit weichem Abfall nach aussen.
    private var haloPipeline: MTLRenderPipelineState!
    private var linePipeline: MTLRenderPipelineState!
    private var extrusionPipeline: MTLRenderPipelineState!
    private var routePipeline: MTLRenderPipelineState!
    private var spritePipeline: MTLRenderPipelineState!
    private var spriteSolidPipeline: MTLRenderPipelineState!
    private var depthWrite: MTLDepthStencilState!
    private var depthNone: MTLDepthStencilState!
    /// Prueft die Tiefe, schreibt aber keine: fuer alles, was flach auf
    /// dem Boden liegt und von Gebaeuden verdeckt werden soll.
    private var depthTest: MTLDepthStencilState!

    private let routeRenderer: RouteRenderer
    private let puckRenderer: PuckRenderer
    private let atlas: IconAtlas
    private let sprites: SpriteBatch
    private let annotationRenderer: AnnotationRenderer
    let labelRenderer: LabelRenderer

    public var needsRedraw: (() -> Void)?
    /// Kacheln konnten nicht geladen werden (Netz) – App kann Hinweis zeigen.
    public var onTileError: ((Error) -> Void)? {
        get { tileManager.onError } set { tileManager.onError = newValue }
    }

    public init(device: MTLDevice, view: MTKView, source: TileSource, theme: MapTheme, schema: TileSchema, camera: MapCamera) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw RendererError.noCommandQueue }
        commandQueue = q
        self.schema = schema
        currentTheme = theme; targetTheme = theme
        let st = schema.style(theme: theme)
        fromStyle = st; targetStyle = st; style = st
        self.camera = camera
        tileManager = TileManager(device: device, source: source, style: st)
        coverageOptions.maxZoom = source.maxZoom
        coverageOptions.minZoom = source.minZoom
        routeRenderer = RouteRenderer(device: device)
        puckRenderer = PuckRenderer(device: device)
        atlas = IconAtlas(device: device, scale: max(view.contentScaleFactor, UIScreen.main.scale, 2))
        sprites = SpriteBatch(device: device)
        annotationRenderer = AnnotationRenderer(atlas: atlas)
        labelRenderer = LabelRenderer(atlas: atlas)
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 4
        view.clearColor = Self.clearColor(theme.background)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self

        try buildPipelines(view: view)
        tileManager.onTileLoaded = { [weak self] in self?.needsRedraw?() }
    }

    /// Kompatibilität: Style direkt (Theme = Clean White, Schema aus dem Style nicht ableitbar → OpenMapTiles).
    public convenience init(device: MTLDevice, view: MTKView, source: TileSource, style: MapStyle, camera: MapCamera) throws {
        try self.init(device: device, view: view, source: source, theme: .cleanWhite, schema: .openMapTiles, camera: camera)
    }

    public enum RendererError: Error { case noDevice, noCommandQueue, libraryNotFound, functionMissing(String) }

    private static func clearColor(_ c: RGBA) -> MTLClearColor {
        MTLClearColor(red: Double(c.r), green: Double(c.g), blue: Double(c.b), alpha: 1)
    }

    // MARK: - Theme

    public func setTheme(_ t: MapTheme, animated: Bool) {
        guard t != targetTheme else { return }
        fromStyle = style
        currentTheme = targetTheme
        targetTheme = t
        targetStyle = schema.style(theme: t)
        if animated, themeTransition > 0 {
            transitionStart = CACurrentMediaTime()
        } else {
            transitionStart = nil
            style = targetStyle
            currentTheme = t
        }
        tileManager.style = targetStyle   // gleiche Struktur → kein Neubau, nur für neue Kacheln
        needsRedraw?()
    }

    /// Interpolierten Style für diesen Frame bestimmen; true = Übergang läuft noch.
    private func advanceTheme(now: CFTimeInterval) -> Bool {
        guard let start = transitionStart else { return false }
        if deferThemeTransition { transitionStart = now; return true }
        let t = Float(min((now - start) / themeTransition, 1))
        style = MapStyle.blend(fromStyle, targetStyle, t)
        if t >= 1 { transitionStart = nil; currentTheme = targetTheme; style = targetStyle; return false }
        return true
    }

    /// Für Puck/Route/Labels: Theme-Farben interpoliert wie der Style.
    private func blendedTheme(now: CFTimeInterval) -> MapTheme {
        guard let start = transitionStart, !deferThemeTransition else { return transitionStart == nil ? targetTheme : currentTheme }
        let t = Float(min((now - start) / themeTransition, 1))
        var m = targetTheme
        let a = currentTheme, b = targetTheme
        m.route.active = RGBA.lerp(a.route.active, b.route.active, t)
        m.route.casing = RGBA.lerp(a.route.casing, b.route.casing, t)
        m.route.driven = RGBA.lerp(a.route.driven, b.route.driven, t)
        m.route.drivenCasing = RGBA.lerp(a.route.drivenCasing, b.route.drivenCasing, t)
        m.route.alternative = RGBA.lerp(a.route.alternative, b.route.alternative, t)
        m.route.alternativeCasing = RGBA.lerp(a.route.alternativeCasing, b.route.alternativeCasing, t)
        m.labels.text = RGBA.lerp(a.labels.text, b.labels.text, t)
        m.labels.halo = RGBA.lerp(a.labels.halo, b.labels.halo, t)
        m.labels.roadText = RGBA.lerp(a.labels.roadText, b.labels.roadText, t)
        m.labels.roadHalo = RGBA.lerp(a.labels.roadHalo, b.labels.roadHalo, t)
        return m
    }

    // MARK: - Pipelines

    private func buildPipelines(view: MTKView) throws {
        let library: MTLLibrary
        do { library = try device.makeDefaultLibrary(bundle: .module) } catch { throw RendererError.libraryNotFound }
        func fn(_ name: String) throws -> MTLFunction {
            guard let f = library.makeFunction(name: name) else { throw RendererError.functionMissing(name) }
            return f
        }
        func makePipeline(vertex: String, fragment: String, descriptor: MTLVertexDescriptor, blend: Bool) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = vertex
            d.vertexFunction = try fn(vertex)
            d.fragmentFunction = try fn(fragment)
            d.vertexDescriptor = descriptor
            d.colorAttachments[0].pixelFormat = view.colorPixelFormat
            d.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            d.rasterSampleCount = view.sampleCount
            if blend {
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        func desc(_ attrs: [(MTLVertexFormat, Int)], stride: Int) -> MTLVertexDescriptor {
            let d = MTLVertexDescriptor()
            for (i, a) in attrs.enumerated() {
                d.attributes[i].format = a.0; d.attributes[i].offset = a.1; d.attributes[i].bufferIndex = 0
            }
            d.layouts[0].stride = stride
            return d
        }

        fillPipeline = try makePipeline(vertex: "fill_vertex", fragment: "color_fragment",
                                        descriptor: desc([(.float2, 0)], stride: MemoryLayout<FillVertex>.stride), blend: true)
        haloPipeline = try makePipeline(vertex: "halo_vertex", fragment: "halo_fragment",
                                        descriptor: desc([(.float2, 0)], stride: MemoryLayout<FillVertex>.stride), blend: true)
        linePipeline = try makePipeline(vertex: "line_vertex", fragment: "color_fragment",
                                        descriptor: desc([(.float2, 0), (.float2, 8)], stride: MemoryLayout<LineVertex>.stride), blend: true)
        extrusionPipeline = try makePipeline(vertex: "extrusion_vertex", fragment: "color_fragment",
                                             descriptor: desc([(.float3, 0), (.float3, 12), (.float, 24)], stride: MemoryLayout<ExtrusionVertex>.stride), blend: false)
        routePipeline = try makePipeline(vertex: "route_vertex", fragment: "route_fragment",
                                         descriptor: desc([(.float2, 0), (.float2, 8), (.float, 16)], stride: MemoryLayout<RouteVertex>.stride), blend: true)
        let spriteDesc = desc([(.float2, 0), (.float2, 8), (.float4, 16)], stride: MemoryLayout<SpriteVertex>.stride)
        spritePipeline = try makePipeline(vertex: "sprite_vertex", fragment: "sprite_fragment", descriptor: spriteDesc, blend: true)
        spriteSolidPipeline = try makePipeline(vertex: "sprite_vertex", fragment: "sprite_solid_fragment", descriptor: spriteDesc, blend: true)

        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .lessEqual; dw.isDepthWriteEnabled = true
        depthWrite = device.makeDepthStencilState(descriptor: dw)
        let dn = MTLDepthStencilDescriptor()
        dn.depthCompareFunction = .always; dn.isDepthWriteEnabled = false
        depthNone = device.makeDepthStencilState(descriptor: dn)
        // .lessEqual statt .less: Bodenlayer liegen alle auf z = 0 und
        // sind damit gleich tief - sie sollen sich weiterhin in ihrer
        // Malreihenfolge ueberdecken duerfen, nur nicht die Gebaeude.
        let dt = MTLDepthStencilDescriptor()
        dt.depthCompareFunction = .lessEqual; dt.isDepthWriteEnabled = false
        depthTest = device.makeDepthStencilState(descriptor: dt)
    }

    // MARK: - MTKViewDelegate

    /// Verkehrsfluss ein- oder ausschalten.
    ///
    /// `nil` entfernt die Schicht. Der Stil kommt aus dem Theme, die
    /// Farben werden erst beim Zeichnen gewaehlt - so folgt der Fluss
    /// dem Tag-Nacht-Wechsel ohne neue Kacheln.
    public func setzeVerkehrsfluss(source: (any TileSource)?) {
        guard let source else { flussManager = nil; return }
        flussManager = TileManager(device: device, source: source,
                                   style: .verkehrsfluss(dark: false))
        flussAbdeckung.minZoom = source.minZoom
        flussAbdeckung.maxZoom = source.maxZoom
    }

    nonisolated public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        MainActor.assumeIsolated { if let cb = needsRedraw { cb() } }
    }

    nonisolated public func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame(in: view) }
    }

    /// true, solange eine Animation (Theme-Übergang) weitere Frames braucht.
    public private(set) var wantsContinuousRedraw = false

    private func drawFrame(in view: MTKView) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let now = CACurrentMediaTime()
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer() else { return }

        wantsContinuousRedraw = advanceTheme(now: now)
        let theme = blendedTheme(now: now)

        var cam = camera
        cam.clamp()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let vp = ViewProjection(camera: cam, width: Double(size.width), height: Double(size.height))

        let wanted = TileCoverage.coveringTiles(vp, options: coverageOptions)
        let tiles = tileManager.tiles(for: wanted)

        pass.colorAttachments[0].clearColor = Self.clearColor(style.background)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.label = "KartoKit map"
        enc.setCullMode(.none)

        var stats = FrameStats()
        stats.tilesDrawn = tiles.count
        let light = style.lightDirection
        let lightVec = (light.x, light.y, light.z)

        struct TileFrame { let tile: GPUTile; let mvp: Mat4; let unitsPerPixel: Double }
        let frames: [TileFrame] = tiles.map { t in
            let mvp = vp.tileMatrix(for: t.id, extent: Double(t.extent))
            let pixelsPerTile = Mercator.tileSize * pow(2.0, cam.zoom - Double(t.id.z))
            return TileFrame(tile: t, mvp: mvp, unitsPerPixel: Double(t.extent) / pixelsPerTile)
        }

        // 1. Kachel-Layer (Layer außen, Kacheln innen)
        for layer in style.layers {
            switch layer.paint {
            case .fill(let color):
                guard color.a > 0.002, cam.zoom + 1 > layer.minZoom else { continue }
                enc.setRenderPipelineState(fillPipeline); enc.setDepthStencilState(depthTest)
                for f in frames {
                    guard let b = f.tile.buckets[layer.id] else { continue }
                    var u = DrawUniforms(mvp: f.mvp, color: color, light: lightVec, skalar: 0)
                    enc.setVertexBuffer(b.vertexBuffer, offset: 0, index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32, indexBuffer: b.indexBuffer, indexBufferOffset: 0)
                    stats.drawCalls += 1
                }
            case .line(let color, let width):
                let px = width.value(at: cam.zoom)
                guard px > 0.05, color.a > 0.002, cam.zoom + 1 > layer.minZoom else { continue }
                enc.setRenderPipelineState(linePipeline); enc.setDepthStencilState(depthTest)
                for f in frames {
                    guard let b = f.tile.buckets[layer.id] else { continue }
                    var u = DrawUniforms(mvp: f.mvp, color: color, light: lightVec, skalar: Float(px / 2 * f.unitsPerPixel))
                    enc.setVertexBuffer(b.vertexBuffer, offset: 0, index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32, indexBuffer: b.indexBuffer, indexBufferOffset: 0)
                    stats.drawCalls += 1
                }
            case .extrusion(let color, _, _, _):
                guard cam.zoom + 1 > layer.minZoom else { continue }
                enc.setRenderPipelineState(extrusionPipeline); enc.setDepthStencilState(depthWrite)
                for f in frames {
                    guard let b = f.tile.buckets[layer.id] else { continue }
                    // skalar = Tonstreuung je Gebäude (nicht Linienbreite).
                    var u = DrawUniforms(mvp: f.mvp, color: color, light: lightVec,
                                         skalar: style.buildingTonStaerke)
                    enc.setVertexBuffer(b.vertexBuffer, offset: 0, index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount, indexType: .uint32, indexBuffer: b.indexBuffer, indexBufferOffset: 0)
                    stats.drawCalls += 1
                }
            }
        }


        // 1b. Verkehrsfluss ueber der Karte, unter der Route.
        //
        // Eigene Abdeckung, weil die Quelle nur wenige Zoomstufen
        // kennt: weiter drin zeichnet dieselbe Kachel hochgezoomt.
        // Der Fluss auf einer Autobahn ist bei z16 dieselbe Aussage
        // wie bei z13 - nur die Anfragen waeren sechzehnmal so viele.
        if let fm = flussManager {
            let flussStil = MapStyle.verkehrsfluss(dark: theme.isDark)
            let flussKacheln = fm.tiles(for: TileCoverage.coveringTiles(vp, options: flussAbdeckung))
            for layer in flussStil.layers {
                guard case .line(let color, let width) = layer.paint else { continue }
                let px = width.value(at: cam.zoom)
                guard px > 0.05, color.a > 0.002 else { continue }
                enc.setRenderPipelineState(linePipeline)
                enc.setDepthStencilState(depthTest)
                for t in flussKacheln {
                    guard let b = t.buckets[layer.id] else { continue }
                    let mvp = vp.tileMatrix(for: t.id, extent: Double(t.extent))
                    let proKachel = Mercator.tileSize * pow(2.0, cam.zoom - Double(t.id.z))
                    let upp = Double(t.extent) / proKachel
                    var u = DrawUniforms(mvp: mvp, color: color, light: lightVec,
                                         skalar: Float(px / 2 * upp))
                    enc.setVertexBuffer(b.vertexBuffer, offset: 0, index: 0)
                    enc.setVertexBytes(&u, length: MemoryLayout<DrawUniforms>.stride, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: b.indexCount,
                                              indexType: .uint32, indexBuffer: b.indexBuffer,
                                              indexBufferOffset: 0)
                    stats.drawCalls += 1
                }
            }
        }
        // 2. Routen + Manöverpfeil
        var displays = routes
        if let i = displays.firstIndex(where: { $0.isActive }) { displays[i].drivenDistance = drivenDistance }
        routeRenderer.sync(displays)
        let active = displays.first { $0.isActive }
        var arrowDist: Double? = nil
        if let m = maneuverArrowDistance, m - drivenDistance < maneuverArrowMaxDistance, m - drivenDistance > -60 { arrowDist = m }
        routeRenderer.syncManeuverArrow(route: active, distanceAlong: arrowDist,
                                        nextDistanceAlong: maneuverArrowNextDistance,
                                        widthPx: theme.route.activeWidth)
        routeRenderer.draw(displays, theme: theme.route, enc: enc, vp: vp, pipeline: routePipeline, depthState: depthNone, stats: &stats)

        // 3. Puck-Boden (Halo/Genauigkeit)
        if let p = puck {
            puckRenderer.drawGround(p, design: theme.puck, enc: enc, vp: vp, fillPipeline: fillPipeline,
                                        haloPipeline: haloPipeline, depthState: depthNone, stats: &stats)
        }

        // 4. Bildschirm-Ebene: Marker, Labels, Puck-Pfeil
        sprites.begin()
        var reserved: [CollisionGrid.Box] = []
        if let p = puck, let box = puckRenderer.screenBox(p, design: theme.puck, vp: vp) { reserved.append(box) }
        annotationRenderer.draw(annotations, vp: vp, batch: sprites, theme: theme, reserved: reserved)
        // Solange eine Beschriftung ein- oder ausblendet, noch ein Bild anfordern.
        if annotationRenderer.blendetGerade { needsRedraw?() }
        stats.annotationsDrawn = annotationRenderer.placed.count
        reserved += annotationRenderer.placed.map { $0.box }
        stats.labelsDrawn = labelRenderer.draw(tiles: tiles, vp: vp, batch: sprites, theme: theme, reserved: reserved, navigating: puck?.isMoving ?? false)
        if let p = puck {
            puckRenderer.drawArrow(p, design: theme.puck, vp: vp, batch: sprites, atlas: atlas)
        }
        sprites.flush(enc: enc, texturedPipeline: spritePipeline, solidPipeline: spriteSolidPipeline, depthState: depthNone,
                      texture: atlas.texture, width: vp.width, height: vp.height, stats: &stats)

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        let s = tileManager.statistics
        stats.tilesCached = s.cached; stats.tilesLoading = s.loading; stats.cacheBytes = s.bytes
        stats.cpuMillis = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        lastFrameStats = stats
    }

    // MARK: - Abfragen

    /// Marker unter einem Bildschirmpunkt (Punkte).
    public func annotation(at point: Vec2) -> MapAnnotation? {
        annotationRenderer.hitTest(point)
    }

    // MARK: - Prefetch

    public func prefetch(camera: MapCamera, viewport: (width: Double, height: Double)) {
        var c = camera
        c.clamp()
        let vp = ViewProjection(camera: c, width: viewport.width, height: viewport.height)
        var opts = coverageOptions
        opts.maxTiles = 24
        tileManager.prefetch(TileCoverage.coveringTiles(vp, options: opts))
    }
}
#endif
