#if canImport(UIKit) && canImport(MetalKit)
import UIKit
import UIKit.UIGestureRecognizerSubclass
import MetalKit
import KartoCore

/// Die Karten-View: MTKView + Gesten + Kamera-Animation + Navi-Anbindung.
///
/// Gesten:
/// - 1 Finger ziehen: verschieben, Trägheit mit UIScrollView-Abklingkurve
/// - Pinch: zoomen um den Fokuspunkt, mit Zoom-Trägheit beim Loslassen
/// - 2 Finger drehen: Bearing (erst ab 6° Schwelle, damit Pinch nicht "wackelt")
/// - 2 Finger vertikal ziehen: Pitch
/// - Doppeltipp: Zoom +1 auf den Punkt; 2-Finger-Tipp: Zoom −1
/// - Tipp + sofort ziehen ("Quick Zoom"): nach unten = rein, nach oben = raus
///
/// Navi-Modus: `navigation` setzen, `updateLocation(_:)` bei jedem Fix aufrufen.
/// Jede Geste schaltet in den freien Modus; `recenter()` (oder Auto-Rezentrieren)
/// führt animiert zurück. CarPlay: Gesten aus, `pan(by:)`/`zoom(by:)` aus den
/// CPMapTemplate-Callbacks aufrufen.
@MainActor
public final class MapView: UIView {
    public let metalView = MTKView()
    public private(set) var renderer: MapRenderer!

    /// Kamera. Setzen stoppt Animationen und löst ein Redraw aus.
    public var camera: MapCamera {
        get { renderer.camera }
        set { animation = nil; inertia = nil; zoomInertia = nil; renderer.camera = newValue; renderer.camera.clamp(); setNeedsRender() }
    }

    /// Aktueller Style (interpoliert während eines Theme-Übergangs). Nur lesen; zum Ändern `theme` setzen.
    public var style: MapStyle { renderer.style }

    /// Theme (Farben, Route, Puck). Setzen blendet weich über (`themeTransition`).
    public var theme: MapTheme {
        get { renderer.theme }
        set { renderer.theme = newValue; setNeedsRender() }
    }
    public func setTheme(_ t: MapTheme, animated: Bool) { renderer.setTheme(t, animated: animated); setNeedsRender() }

    /// Verkehrsfluss als eigene Kachelschicht ueber der Karte.
    ///
    /// `nil` schaltet sie ab. Die Quelle bestimmt die Zoomspanne; die
    /// Farben folgen dem Theme, ohne dass Kacheln neu geladen werden.
    public func setzeVerkehrsfluss(source: (any TileSource)?) {
        renderer.setzeVerkehrsfluss(source: source)
        setNeedsRender()
    }

    public var route: [Coordinate] {
        get { renderer.route }
        set { renderer.route = newValue; navigation?.route = newValue; setNeedsRender() }
    }
    /// Routen mit Fortschritt, Verkehrsabschnitten und Alternativen. Die aktive Route
    /// wird auch dem NavigationController als Snapping-Route gegeben.
    public var routes: [RouteDisplay] {
        get { renderer.routes }
        set {
            renderer.routes = newValue
            // Unveränderte Geometrie lässt der NavigationController stehen (Snapper bleibt heil).
            navigation?.route = newValue.first { $0.isActive }?.coordinates ?? []
            setNeedsRender()
        }
    }
    /// Gefahrene Strecke auf der aktiven Route in Metern. Billig – nur ein Uniform, die
    /// Routengeometrie wird nicht angefasst. Apps sollen den Fortschritt hierüber melden
    /// statt `routes` neu zu setzen. Läuft eine `navigation`, gewinnt deren Snapping-Wert.
    public var drivenDistance: Double {
        get { renderer.drivenDistance }
        set {
            guard renderer.drivenDistance != newValue else { return }
            renderer.drivenDistance = newValue
            setNeedsRender()
        }
    }
    /// Marker.
    public var annotations: [MapAnnotation] {
        get { renderer.annotations }
        set { renderer.annotations = newValue; setNeedsRender() }
    }
    /// Tipp auf einen Marker.
    public var onAnnotationTap: ((MapAnnotation) -> Void)?
    /// Nutzer beginnt eine Geste (Pan/Pinch/Rotate/Quick-Zoom) – z. B. um ein UI-Timeout zu starten.
    public var onGestureBegan: (() -> Void)?
    /// Kamera ist zur Ruhe gekommen (0,4 s ohne Änderung) bzw. im Navi-Modus alle 3 s: Kamera + sichtbarer
    /// Ausschnitt – zum Nachladen ortsbezogener Daten (Ladeparks, Ereignisse) für den Viewport.
    public var onViewportChange: ((MapCamera, CoordinateBounds) -> Void)?
    private var lastViewportCamera: MapCamera?
    private var lastCameraChangeTime: CFTimeInterval = 0
    private var lastViewportReport: CFTimeInterval = 0

    /// Sichtbarer Ausschnitt (bei Neigung auf `maxDistanceMeters` um die Kameramitte begrenzt).
    public func visibleBounds(maxDistanceMeters: Double = 30_000) -> CoordinateBounds {
        currentViewProjection().visibleBounds(maxDistanceMeters: maxDistanceMeters)
    }
    /// Tipp auf die Karte (kein Marker) – Bildschirmpunkt und Koordinate.
    public var onMapTap: ((Vec2, Coordinate?) -> Void)?
    /// Straßennamen mit Vorrang bei der Beschriftung (aktuelle + nächste Straße).
    public var highlightedRoadNames: Set<String> {
        get { renderer.labelRenderer.highlightedNames }
        set { renderer.labelRenderer.highlightedNames = newValue; setNeedsRender() }
    }
    /// Schriftskalierung der Beschriftung (CarPlay ≈ 1.2).
    public var labelScale: Double {
        get { renderer.labelRenderer.labelScale }
        set { renderer.labelRenderer.labelScale = newValue; setNeedsRender() }
    }

    /// Manuelle Positionsanzeige ohne NavigationController.
    public var userPosition: Coordinate? {
        get { renderer.userPosition }
        set { renderer.userPosition = newValue; setNeedsRender() }
    }
    public var userHeading: Double {
        get { renderer.userHeading }
        set { renderer.userHeading = newValue; setNeedsRender() }
    }

    /// Navi-Kameraführung. Wenn gesetzt, steuert sie Kamera und Puck pro Frame.
    public var navigation: NavigationController? {
        didSet { navigation?.route = renderer.route; setNeedsRender() }
    }

    /// Gesten aktiv? (In CarPlay aus.)
    public var isGestureEnabled = true {
        didSet { gestureRecognizers?.forEach { $0.isEnabled = isGestureEnabled } }
    }

    public var minZoom = 2.0
    public var maxZoom = 20.0

    /// Wird nach jedem Frame mit Statistik aufgerufen (Debug-Overlay).
    public var onFrame: ((MapRenderer.FrameStats) -> Void)?
    /// Wird aufgerufen, wenn der Navi-Modus wechselt (z. B. für den "Rezentrieren"-Button).
    public var onNavigationModeChange: ((NavigationController.Mode) -> Void)?

    /// Von Overlays (Manöverkarte, Bottom-Sheet, CarPlay-Karten) verdeckte Ränder in Punkten.
    /// Der Puck-Anker bezieht sich auf den verbleibenden freien Bereich.
    public var overlayInsets = UIEdgeInsets.zero { didSet { setNeedsRender() } }

    /// Kamera-Logger für Testfahrten: (GPX-/Fix-Zeit des letzten Fixes, Kamera, Puck, Manöveransicht), max. 10 Hz.
    public var onNavigationTick: ((TimeInterval, MapCamera, PuckState, Bool) -> Void)?
    private var lastLogTime: CFTimeInterval = 0
    private var lastFixTimestamp: TimeInterval = 0

    // MARK: - Dynamik-Parameter

    /// Abklingfaktor pro Sekunde für Pan-Trägheit. 0.135 ≙ UIScrollView "normal" (0.998/ms).
    public var panDecelerationPerSecond = 0.135
    public var zoomDecelerationPerSecond = 0.02
    /// Rotationsschwelle in Grad, bevor eine Drehgeste greift.
    public var rotationThresholdDegrees = 6.0
    /// Quick-Zoom: Zoomstufen pro 100 pt Fingerweg.
    public var quickZoomPer100Points = 1.0

    private var displayLink: CADisplayLink?
    private var animation: CameraAnimation?
    private var inertia: (velocity: Vec2, lastTime: CFTimeInterval)?
    private var zoomInertia: (velocity: Double, focus: Vec2, lastTime: CFTimeInterval)?
    private var lastNavMode: NavigationController.Mode?
    private var frameCounter = 0

    /// Betriebszaehler fuer die Fahrtaufzeichnung.
    ///
    /// Absichtlich blosse Zaehler statt eines Rueckrufs: Wer wissen will, ob
    /// ueberhaupt noch gezeichnet wird, darf sich nicht auf den Render-Takt
    /// verlassen — genau der faellt ja aus, wenn etwas klemmt. Die App fragt
    /// sie deshalb aus einem eigenen Takt ab und sieht an einem stehenden
    /// Zaehler sofort, dass die Karte eingefroren ist.
    public private(set) var gezeichneteBilder: Int = 0
    /// Zeitpunkt des letzten tatsaechlich gezeichneten Bildes (CACurrentMediaTime).
    public private(set) var letztesBildZeit: CFTimeInterval = 0
    /// Zeitpunkt des letzten Takts — auch wenn nichts zu zeichnen war.
    /// Steht dieser still, schweigt der Taktgeber; steht nur `letztesBildZeit`,
    /// hatte die Karte schlicht nichts Neues zu zeigen.
    public private(set) var letzterTaktZeit: CFTimeInterval = 0
    /// Bilder, deren Abstand groesser war als das Doppelte des Solltakts.
    public private(set) var verspaeteteBilder: Int = 0

    // Gesten-Zustand
    private var panStartCenter = Vec2(0, 0)
    private var panStartGround = Vec2(0, 0)
    private var pinchStartZoom = 0.0
    private var pinchLast: (scale: Double, time: CFTimeInterval)?
    private var pinchVelocity = 0.0
    private var rotateStartBearing = 0.0
    private var rotateArmed = false
    private var rotateOffset = 0.0
    private var pitchStartPitch = 0.0
    private var pitchStartY = 0.0
    private var quickZoomStartZoom = 0.0
    private var quickZoomStartY = 0.0
    private var pinchRecognizer: UIPinchGestureRecognizer?
    private var rotateRecognizer: UIRotationGestureRecognizer?
    private var lastDirtyTime: CFTimeInterval = 0
    private var highFrameRate = false

    public convenience init(frame: CGRect, source: TileSource, style: MapStyle = .openMapTiles, camera: MapCamera) throws {
        try self.init(frame: frame, source: source, theme: .cleanWhite, schema: .openMapTiles, camera: camera)
    }

    public init(frame: CGRect, source: TileSource, theme: MapTheme, schema: TileSchema, camera: MapCamera) throws {
        super.init(frame: frame)
        guard let device = MTLCreateSystemDefaultDevice() else { throw MapRenderer.RendererError.noDevice }
        metalView.frame = bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.framebufferOnly = true
        addSubview(metalView)
        renderer = try MapRenderer(device: device, view: metalView, source: source, theme: theme, schema: schema, camera: camera)
        renderer.needsRedraw = { [weak self] in self?.setNeedsRender() }
        metalView.backgroundColor = UIColor(red: CGFloat(theme.background.r), green: CGFloat(theme.background.g),
                                            blue: CGFloat(theme.background.b), alpha: 1)
        isMultipleTouchEnabled = true
        setupGestures()
        // Kein setupDisplayLink() hier: Die View haengt noch in keinem Fenster,
        // der Takt wuerde am Hauptbildschirm landen. didMoveToWindow legt ihn.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) nicht unterstützt") }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - Navigation

    /// Neuer Positions-Fix (aus CoreLocation oder eurer Engine).
    public func updateLocation(_ fix: LocationFix) {
        navigation?.update(fix: fix)
        lastFixTimestamp = fix.timestamp
        setNeedsRender()
    }

    private var freeArea: (x: Double, y: Double, width: Double, height: Double) {
        let i = overlayInsets
        return (Double(i.left), Double(i.top),
                max(Double(bounds.width - i.left - i.right), 1), max(Double(bounds.height - i.top - i.bottom), 1))
    }

    /// Zurück in den Folgemodus (animiert).
    public func recenter() {
        guard let nav = navigation else { return }
        animation = nil; inertia = nil; zoomInertia = nil
        nav.recenter(from: renderer.camera, at: CACurrentMediaTime())
        setNeedsRender()
    }

    /// Routenübersicht (ganze Route im Bild), Navi geht in den Übersichtsmodus.
    public func showRouteOverview(padding: Double = 60, animated: Bool = true) {
        guard let cam = NavigationController.cameraFitting(renderer.route, viewport: viewportSize, padding: padding) else { return }
        navigation?.setOverview()
        if animated { flyTo(cam, duration: 0.8) } else { camera = cam; navigation?.setOverview() }
    }

    /// Routenübersicht mit von Overlays verdeckten Rändern (z. B. Bottom-Sheet): Die Route landet
    /// mittig in der freien Fläche.
    ///
    /// Eingepasst wird der Restweg ab `drivenDistance`, nicht die ganze
    /// Route: Waehrend der Fahrt interessiert nur, was noch kommt, und
    /// der Massstab folgt so von selbst der schrumpfenden Strecke. Vor
    /// der Abfahrt ist `drivenDistance` null, dann ist beides dasselbe.
    /// `wholeRoute: true` erzwingt die alte Sicht auf die ganze Fahrt.
    public func showRouteOverview(insets: UIEdgeInsets, minimumPadding: Double = 24,
                                  wholeRoute: Bool = false, animated: Bool = true) {
        let i = (top: Double(insets.top), left: Double(insets.left), bottom: Double(insets.bottom), right: Double(insets.right))
        let strecke = wholeRoute
            ? renderer.route
            : RouteDisplay.remainder(of: renderer.route, from: renderer.drivenDistance)
        guard let cam = NavigationController.cameraFitting(strecke, viewport: viewportSize, insets: i, minimumPadding: minimumPadding) else { return }
        navigation?.setOverview()
        if animated { flyTo(cam, duration: 0.8) } else { camera = cam; navigation?.setOverview() }
    }

    private var viewportSize: (width: Double, height: Double) {
        (Double(bounds.width), Double(bounds.height))
    }

    // MARK: - Render-Loop
    // Gezeichnet wird nur, wenn sich etwas ändert (Gesten, Animation, neue Kacheln,
    // Navi-Tick). Im Stand: 0 Frames, 0 % GPU. Im Navi-Modus jedes Frame.

    private var renderRequested = false

    public func setNeedsRender() {
        renderRequested = true
    }

    /// Legt den Taktgeber auf den Bildschirm, auf dem die Karte wirklich liegt.
    ///
    /// `CADisplayLink(target:selector:)` haengt fest am Hauptbildschirm — also am
    /// Telefon. Sperrt der Fahrer waehrend der Fahrt sein Handy, schaltet dieser
    /// Bildschirm ab, der Taktgeber schweigt, und die Karte auf dem CarPlay-Display
    /// friert ein: Der Pfeil bleibt stehen, obwohl die Ortung munter weiterlaeuft.
    /// Beim Entsperren laeuft alles wieder an. Genau dieses Bild hat der Fahrtest
    /// gezeigt.
    ///
    /// Richtig ist der Taktgeber des eigenen Bildschirms — bei CarPlay der des
    /// Autos, und der bleibt an, egal was das Telefon in der Jackentasche macht.
    /// Weil die View beim Erzeugen noch in keinem Fenster haengt, wird der Takt
    /// bei jedem Fensterwechsel neu gelegt.
    private func setupDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil

        let proxy = DisplayLinkProxy(self)
        let auswahl = #selector(DisplayLinkProxy.tick(_:))
        let dl = window?.screen.displayLink(withTarget: proxy, selector: auswahl)
            ?? CADisplayLink(target: proxy, selector: auswahl)
        // ProMotion: 120 Hz nur bei Aktivität (siehe tick), sonst 60 Hz Leerlauf-Ticks.
        dl.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        dl.add(to: .main, forMode: .common)
        displayLink = dl
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // Ohne Fenster braucht es keinen Takt; mit neuem Fenster einen neuen.
        if window == nil {
            displayLink?.invalidate()
            displayLink = nil
        } else {
            setupDisplayLink()
        }
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        var dirty = renderRequested
        frameCounter &+= 1
        letzterTaktZeit = now

        if let anim = animation {
            renderer.camera = anim.value(at: now)
            if anim.isFinished(at: now) { animation = nil }
            dirty = true
        } else {
            if var inert = inertia {
                let dt = max(now - inert.lastTime, 0)
                inert.lastTime = now
                let decay = pow(panDecelerationPerSecond, dt)
                inert.velocity = inert.velocity * decay
                let vp = currentViewProjection()
                renderer.camera.center = renderer.camera.center + inert.velocity * dt / vp.worldSize
                renderer.camera.clamp()
                inertia = inert.velocity.length < 8 ? nil : inert
                dirty = true
            }
            if var zi = zoomInertia {
                let dt = max(now - zi.lastTime, 0)
                zi.lastTime = now
                zi.velocity *= pow(zoomDecelerationPerSecond, dt)
                zoom(by: zi.velocity * dt, around: zi.focus)
                zoomInertia = abs(zi.velocity) < 0.05 ? nil : zi
                dirty = true
            }
        }

        if let nav = navigation {
            let navFrame = nav.tick(now: now, current: renderer.camera, viewport: viewportSize, freeArea: freeArea)
            if let cam = navFrame.camera, animation == nil {
                renderer.camera = cam
                if let log = onNavigationTick, let p = navFrame.puck, now - lastLogTime >= 0.1 {
                    lastLogTime = now
                    log(lastFixTimestamp, cam, p, nav.isManeuverViewActive)
                }
                // Alle ~0,5 s die Ansicht 6 s voraus vorladen.
                if frameCounter % 30 == 0, let p = navFrame.puck, p.isMoving {
                    var ahead = cam
                    let meters = p.speed * 6
                    ahead.center = Mercator.project(GeoMath.destination(from: p.coordinate, bearing: p.heading, meters: meters))
                    renderer.prefetch(camera: ahead, viewport: viewportSize)
                }
            }
            renderer.puck = navFrame.puck
            renderer.drivenDistance = nav.distanceAlong ?? 0
            renderer.maneuverArrowDistance = nav.upcomingManeuverDistanceAlong
            renderer.maneuverArrowNextDistance = nav.followingManeuverDistanceAlong
            if navFrame.puck != nil { dirty = true }
            if nav.mode != lastNavMode {
                lastNavMode = nav.mode
                onNavigationModeChange?(nav.mode)
            }
        }

        // Viewport-Meldung: nach Ruhe oder periodisch während der Fahrt
        if let cb = onViewportChange, bounds.width > 0 {
            let cam = renderer.camera
            if cam != lastViewportCamera {
                if lastViewportCamera == nil { lastCameraChangeTime = now - 1 } else { lastCameraChangeTime = now }
                lastViewportCamera = cam
            }
            let idle = now - lastCameraChangeTime > 0.4
            let periodic = now - lastViewportReport > 3
            if (idle && lastViewportReport < lastCameraChangeTime) || (periodic && !idle) {
                lastViewportReport = now
                cb(cam, visibleBounds())
            }
        }

        // Theme-Übergang nicht während Kamerafahrten (Rezentrieren/flyTo) starten.
        renderer.deferThemeTransition = animation != nil
        if dirty || renderer.wantsContinuousRedraw {
            renderRequested = false
            lastDirtyTime = now
            metalView.draw()
            if letztesBildZeit > 0, now - letztesBildZeit > 2 * link.duration {
                verspaeteteBilder &+= 1
            }
            letztesBildZeit = now
            gezeichneteBilder &+= 1
            if renderer.wantsContinuousRedraw { renderRequested = true }
            onFrame?(renderer.lastFrameStats)
        }
        // ProMotion nur während Aktivität anfordern (Akku), 0,5 s nach der letzten Änderung zurück.
        let wantHigh = now - lastDirtyTime < 0.5
        if wantHigh != highFrameRate {
            highFrameRate = wantHigh
            displayLink?.preferredFrameRateRange = wantHigh
                ? CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        }
    }

    private func currentViewProjection() -> ViewProjection {
        ViewProjection(camera: renderer.camera, width: Double(bounds.width), height: Double(bounds.height))
    }

    // MARK: - Programmatische Kamera

    /// Animiert zu einer Kamera. Kurze Wege: Ease-in-out. Lange Wege: mit Zoom-"Sprung"
    /// (erst raus, dann rein), z. B. beim Wechsel von der Routenübersicht in die Navigation.
    public func flyTo(_ target: MapCamera, duration: TimeInterval = 0.6) {
        inertia = nil; zoomInertia = nil
        var t = target
        t.clamp()
        let from = renderer.camera
        // Programmatische Kamerafahrt im Folgemodus = Nutzerwunsch → freier Modus
        // (Rezentrieren und Übersicht setzen ihren Modus vorher selbst).
        if let nav = navigation, nav.mode == .following { nav.userInteracted(at: CACurrentMediaTime()) }
        // Entfernung in Bildschirmbreiten auf dem größeren der beiden Zooms
        let distPx = (t.center - from.center).length * Mercator.worldSize(zoom: max(from.zoom, t.zoom))
        let screens = distPx / max(Double(bounds.width), 1)
        var dip = 0.0
        if screens > 1.5 { dip = min(log2(screens), 4) }
        animation = CameraAnimation(from: from, to: t, start: CACurrentMediaTime(),
                                    duration: dip > 0 ? max(duration, 0.9) : duration, zoomDip: dip, easeInOut: true)
        setNeedsRender()
    }

    public func setCamera(_ target: MapCamera, animated: Bool, duration: TimeInterval = 0.5) {
        guard animated else { camera = target; return }
        flyTo(target, duration: duration)
    }

    /// Zoom um Delta-Stufen um einen Bildschirmpunkt (Standard: Mitte). Für CarPlay-Buttons.
    public func zoom(by delta: Double, animated: Bool = true) {
        var t = renderer.camera
        t.zoom = min(max(t.zoom + delta, minZoom), maxZoom)
        navigation?.userInteracted(at: CACurrentMediaTime())
        if animated { flyTo(t, duration: 0.3) } else { camera = t }
    }

    /// Verschieben um Bildschirm-Punkte (CarPlay-Pan-Callbacks).
    public func pan(by offset: CGPoint, animated: Bool = true) {
        let vp = currentViewProjection()
        let c = Vec2(Double(bounds.width) / 2, Double(bounds.height) / 2)
        guard let g0 = vp.unprojectToGround(screen: c),
              let g1 = vp.unprojectToGround(screen: Vec2(c.x + Double(offset.x), c.y + Double(offset.y))) else { return }
        var t = renderer.camera
        t.center = t.center + (g1 - g0) / vp.worldSize
        navigation?.userInteracted(at: CACurrentMediaTime())
        if animated { flyTo(t, duration: 0.25) } else { camera = t }
    }

    /// Norden oben (Kompass-Button).
    public func resetNorth() {
        var t = renderer.camera
        t.bearing = 0
        flyTo(t, duration: 0.4)
    }

    private func zoom(by delta: Double, around focus: Vec2) {
        let before = currentViewProjection()
        let fb = before.unprojectToUnitMercator(screen: focus)
        renderer.camera.zoom = min(max(renderer.camera.zoom + delta, minZoom), maxZoom)
        if let fb, let fa = currentViewProjection().unprojectToUnitMercator(screen: focus) {
            renderer.camera.center = renderer.camera.center + (fb - fa)
        }
        renderer.camera.clamp()
    }

    // MARK: - Gesten

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let loc = g.location(in: self)
        let p = Vec2(loc.x, loc.y)
        if let a = renderer.annotation(at: p) {
            onAnnotationTap?(a)
        } else if let cb = onMapTap {
            let coord = currentViewProjection().unprojectToUnitMercator(screen: p).map { Mercator.unproject($0) }
            cb(p, coord)
        }
    }

    private func setupGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        let pitch = UIPanGestureRecognizer(target: self, action: #selector(handlePitch(_:)))
        pitch.minimumNumberOfTouches = 2
        pitch.maximumNumberOfTouches = 2
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        let quickZoom = QuickZoomGestureRecognizer(target: self, action: #selector(handleQuickZoom(_:)))
        doubleTap.require(toFail: quickZoom)
        pan.require(toFail: quickZoom) // Quick-Zoom scheitert ohne vorherigen Tipp sofort → kein spürbarer Verzug
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        for g in [pan, pinch, rotate, pitch, doubleTap, twoFingerTap, quickZoom, tap] as [UIGestureRecognizer] {
            g.delegate = self
            addGestureRecognizer(g)
        }
        pinchRecognizer = pinch
        rotateRecognizer = rotate
    }

    private func gestureBegan() {
        animation = nil; inertia = nil; zoomInertia = nil
        navigation?.userInteracted(at: CACurrentMediaTime())
        onGestureBegan?()
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let vp = currentViewProjection()
        let loc = g.location(in: self)
        switch g.state {
        case .began:
            gestureBegan()
            panStartCenter = renderer.camera.center
            panStartGround = vp.unprojectToGround(screen: Vec2(loc.x, loc.y)) ?? renderer.camera.center * vp.worldSize
        case .changed:
            // Der Bodenpunkt unter dem Finger bleibt unter dem Finger.
            var start = renderer.camera
            start.center = panStartCenter
            let vpStart = ViewProjection(camera: start, width: vp.width, height: vp.height)
            guard let ground = vpStart.unprojectToGround(screen: Vec2(loc.x, loc.y)) else { return }
            renderer.camera.center = panStartCenter + (panStartGround - ground) / vp.worldSize
            renderer.camera.clamp()
            setNeedsRender()
        case .ended, .cancelled:
            // Zweiter Finger gelandet (Pinch/Rotate aktiv) → keine Trägheit aus dem Pan-Ende
            let multi = [pinchRecognizer?.state, rotateRecognizer?.state].contains { $0 == .began || $0 == .changed }
            guard !multi else { return }
            let v = g.velocity(in: self)
            // Bildschirm- → Weltgeschwindigkeit über die Bodenprojektion (exakt inkl. Bearing/Pitch)
            let c = Vec2(vp.width / 2, vp.height / 2)
            if let g0 = vp.unprojectToGround(screen: c),
               let g1 = vp.unprojectToGround(screen: Vec2(c.x + Double(v.x) * 0.1, c.y + Double(v.y) * 0.1)) {
                let vel = (g0 - g1) * 10 // px/s in Welt-Pixeln
                if vel.length > 60 { inertia = (vel, CACurrentMediaTime()) }
            }
        default: break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        let loc = g.location(in: self)
        let focus = Vec2(loc.x, loc.y)
        let now = CACurrentMediaTime()
        switch g.state {
        case .began:
            gestureBegan()
            pinchStartZoom = renderer.camera.zoom
            pinchLast = (1, now)
            pinchVelocity = 0
        case .changed:
            let target = min(max(pinchStartZoom + log2(Double(g.scale)), minZoom), maxZoom)
            zoom(by: target - renderer.camera.zoom, around: focus)
            if let last = pinchLast, now - last.time > 0.016 {
                let v = (log2(Double(g.scale)) - log2(last.scale)) / (now - last.time)
                pinchVelocity = pinchVelocity * 0.6 + v * 0.4
                pinchLast = (Double(g.scale), now)
            }
            setNeedsRender()
        case .ended, .cancelled:
            if abs(pinchVelocity) > 0.5, let last = pinchLast, now - last.time < 0.1 {
                zoomInertia = (min(max(pinchVelocity, -4), 4), focus, now)
            }
        default: break
        }
    }

    @objc private func handleRotate(_ g: UIRotationGestureRecognizer) {
        switch g.state {
        case .began:
            gestureBegan()
            rotateStartBearing = renderer.camera.bearing
            rotateArmed = false
            rotateOffset = 0
        case .changed:
            let deg = Double(g.rotation) * 180 / .pi
            if !rotateArmed {
                guard abs(deg) > rotationThresholdDegrees else { return }
                rotateArmed = true
                rotateOffset = deg // kein Sprung beim Einrasten
            }
            renderer.camera.bearing = rotateStartBearing - (deg - rotateOffset)
            renderer.camera.clamp()
            setNeedsRender()
        default: break
        }
    }

    @objc private func handlePitch(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            gestureBegan()
            pitchStartPitch = renderer.camera.pitch
            pitchStartY = Double(t.y)
        case .changed:
            guard abs(t.y) > abs(t.x) * 1.2 else { return }
            renderer.camera.pitch = pitchStartPitch - (Double(t.y) - pitchStartY) * 0.5
            renderer.camera.clamp()
            setNeedsRender()
        default: break
        }
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        let loc = g.location(in: self)
        navigation?.userInteracted(at: CACurrentMediaTime())
        var target = renderer.camera
        target.zoom = min(target.zoom + 1, maxZoom)
        // Halb auf den Punkt zu (Punkt bleibt unter dem Finger → 100 %)
        let vp = currentViewProjection()
        if let fb = vp.unprojectToUnitMercator(screen: Vec2(loc.x, loc.y)) {
            let after = ViewProjection(camera: target, width: vp.width, height: vp.height)
            if let fa = after.unprojectToUnitMercator(screen: Vec2(loc.x, loc.y)) {
                target.center = target.center + (fb - fa)
            }
        }
        flyTo(target, duration: 0.3)
    }

    @objc private func handleTwoFingerTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        navigation?.userInteracted(at: CACurrentMediaTime())
        var target = renderer.camera
        target.zoom = max(target.zoom - 1, minZoom)
        flyTo(target, duration: 0.3)
    }

    @objc private func handleQuickZoom(_ g: QuickZoomGestureRecognizer) {
        let loc = g.anchor
        switch g.state {
        case .began:
            gestureBegan()
            quickZoomStartZoom = renderer.camera.zoom
            quickZoomStartY = Double(g.location(in: self).y)
        case .changed:
            let dy = Double(g.location(in: self).y) - quickZoomStartY
            let target = min(max(quickZoomStartZoom + dy / 100 * quickZoomPer100Points, minZoom), maxZoom)
            zoom(by: target - renderer.camera.zoom, around: Vec2(loc.x, loc.y))
            setNeedsRender()
        default: break
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        setNeedsRender()
    }
}

extension MapView: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Pinch + Rotate + 2-Finger-Pan gleichzeitig; Taps und Quick-Zoom exklusiv.
        if g is UITapGestureRecognizer || other is UITapGestureRecognizer { return false }
        if g is QuickZoomGestureRecognizer || other is QuickZoomGestureRecognizer { return false }
        return true
    }
}

/// "Tap, dann sofort ziehen" – Einhand-Zoom.
/// Erkennt: ein Touch endet, innerhalb von 0,3 s beginnt am selben Ort ein neuer
/// Touch, der sich > 8 pt bewegt. Ein Doppeltipp ohne Bewegung fällt durch (→ DoubleTap).
final class QuickZoomGestureRecognizer: UIGestureRecognizer {
    private var lastTapEnd: (time: TimeInterval, point: CGPoint)?
    private var candidateStart: CGPoint?
    private var touchBegan: TimeInterval = 0
    private(set) var anchor = CGPoint.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, event.allTouches?.count ?? 1 == 1, let t = touches.first, let v = view else { state = .failed; return }
        let p = t.location(in: v)
        touchBegan = t.timestamp
        if let last = lastTapEnd, t.timestamp - last.time < 0.3, hypot(p.x - last.point.x, p.y - last.point.y) < 30 {
            candidateStart = p
            anchor = last.point
        } else {
            candidateStart = nil
            lastTapEnd = nil
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first, let v = view else { return }
        let p = t.location(in: v)
        if state == .possible {
            if let s = candidateStart {
                if hypot(p.x - s.x, p.y - s.y) > 8 { state = .began }
            } else if hypot(p.x - (lastTapEnd?.point.x ?? -999), p.y - (lastTapEnd?.point.y ?? -999)) > 8 {
                state = .failed
            }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = touches.first, let v = view else { return }
        if state == .began || state == .changed {
            state = .ended
        } else {
            // Nur ein kurzer Einzel-Tipp zählt als Auftakt (kein Pinch-Ende, kein langes Halten).
            if t.timestamp - touchBegan < 0.3, event.allTouches?.count ?? 1 == 1 {
                lastTapEnd = (t.timestamp, t.location(in: v))
            } else {
                lastTapEnd = nil
            }
            state = .failed
        }
        candidateStart = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
        candidateStart = nil
    }

    override func reset() {
        super.reset()
        candidateStart = nil
    }
}

/// Vermeidet Retain-Zyklus zwischen CADisplayLink und MapView.
private final class DisplayLinkProxy: NSObject {
    weak var view: MapView?
    init(_ view: MapView) { self.view = view }
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { if let v = view { v.tick(link) } }
    }
}

/// Kamera-Animation: Ease-out (Gesten-Nachlauf) oder Ease-in-out (programmatisch),
/// optional mit Zoom-Dip für lange Strecken; Bearing auf kürzestem Weg.
struct CameraAnimation {
    let from: MapCamera
    let to: MapCamera
    let start: CFTimeInterval
    let duration: CFTimeInterval
    var zoomDip = 0.0
    var easeInOut = false

    func isFinished(at t: CFTimeInterval) -> Bool { t >= start + duration }

    func value(at t: CFTimeInterval) -> MapCamera {
        let raw = min(max((t - start) / duration, 0), 1)
        let e: Double
        if easeInOut {
            e = raw < 0.5 ? 4 * raw * raw * raw : 1 - pow(-2 * raw + 2, 3) / 2
        } else {
            e = 1 - pow(1 - raw, 3)
        }
        let db = GeoMath.angleDelta(from: from.bearing, to: to.bearing)
        var zoom = from.zoom + (to.zoom - from.zoom) * e
        if zoomDip > 0 { zoom -= zoomDip * sin(raw * .pi) } // Bogen: raus und wieder rein
        var c = MapCamera(center: from.center + (to.center - from.center) * e,
                          zoom: zoom,
                          bearing: from.bearing + db * e,
                          pitch: from.pitch + (to.pitch - from.pitch) * e)
        c.clamp()
        return c
    }
}
#endif
