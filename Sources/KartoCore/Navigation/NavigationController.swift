import Foundation

/// Zustand des Positions-Pucks für einen Frame.
public struct PuckState: Equatable, Sendable {
    public var coordinate: Coordinate
    /// Geglätteter Kurs in Grad.
    public var heading: Double
    public var accuracyMeters: Double
    /// m/s, geglättet.
    public var speed: Double
    /// Kein Fix seit > `Tuning.staleAfter` Sekunden → grau darstellen.
    public var isStale: Bool
    /// true, solange sich das Fahrzeug bewegt.
    public var isMoving: Bool
    /// Darstellung: In der Navigation wird immer der Pfeil gezeigt, auch im Stand
    /// (Referenzfahrt 29.08.2026: 26 s Ampelstopp, Pfeil bleibt). `.dot` nur wenn
    /// `Tuning.dotWhenStill` gesetzt ist.
    public var style: Style
    public enum Style: Equatable, Sendable { case arrow, dot }

    public init(coordinate: Coordinate, heading: Double, accuracyMeters: Double, speed: Double, isStale: Bool, isMoving: Bool, style: Style = .arrow) {
        self.coordinate = coordinate
        self.heading = heading
        self.accuracyMeters = accuracyMeters
        self.speed = speed
        self.isStale = isStale
        self.isMoving = isMoving
        self.style = style
    }
}

/// Ergebnis eines Ticks: neue Kamera (nil = Karte behält Nutzerkamera) + Puck.
public struct NavigationFrame: Equatable, Sendable {
    public var camera: MapCamera?
    public var puck: PuckState?
    public init(camera: MapCamera?, puck: PuckState?) {
        self.camera = camera
        self.puck = puck
    }
}

/// Kameraführung und Positionsglättung für den Navi-Modus – das "Gefühl" von
/// Ziel: Der Pfeil gleitet, springt nie, sitzt immer auf der Straße; die
/// Kamera folgt weich, dreht mit begrenzter Rate, zoomt nach Tempo und vor Manövern.
///
/// Verwendung: `update(fix:)` bei jedem GPS-Fix (1 Hz reicht), `tick(now:…)`
/// bei jedem Frame (60/120 Hz). Alles in dieser Klasse ist deterministisch und
/// ohne UIKit testbar.
public final class NavigationController {

    /// Werte an einer Referenzfahrt (Stuttgart→Pforzheim) abgestimmt, siehe
    /// `ReferenceDriveTests`. Zoom in KartoKit-Konvention
    /// (512-px-Kacheln) = übliche 256-px-Zoomstufe − 1.
    public struct Tuning: Sendable {
        /// Vorausschau in Sekunden: So viel Fahrstrecke soll zwischen dem Puck und der
        /// Oberkante des freien Kartenbereichs liegen. Daraus wird der Zoom gerechnet,
        /// nicht umgekehrt.
        ///
        /// Warum nicht nach Tempo: Eine Zoomtabelle ist geräteunabhängig, die Vorausschau
        /// nicht. Auf CarPlay ist die Karte halb so hoch wie im Hochformat, derselbe Zoom
        /// zeigt dort ein Drittel weniger Strecke — und CarPlay ist der Bildschirm, auf den
        /// der Fahrer schaut. 80 s reproduzieren die Referenzkurve, gelten aber dann
        /// auf jedem Display statt nur auf dem, an dem sie gemessen wurde.
        public var lookAheadSeconds = 80.0
        /// Untergrenze: Ohne sie würde die Kamera bei 30 km/h auf 670 m heranzoomen — in der
        /// Stadt zu nah, dort steht die nächste Entscheidung schon 200 m voraus an.
        public var lookAheadMinMeters = 1400.0
        /// Obergrenze: Ohne sie wird die Route auf freier Autobahn zum Strich.
        public var lookAheadMaxMeters = 3000.0
        /// Fester Aufschlag auf den gerechneten Zoom, für App-seitige Vorlieben.
        public var zoomOffset = 0.0
        /// Kameraneigung in der Fahransicht (Referenz: 55–62°).
        public var pitch = 58.0
        /// Position des Pucks relativ zum **freien** (nicht von Overlays verdeckten)
        /// Kartenbereich. Referenz: horizontal mittig im freien Bereich, vertikal bei
        /// 88 % (iPhone: 681 von 755 pt, CarPlay: 876 von 996 px).
        public var puckAnchor = Vec2(0.5, 0.88)
        /// Manöveransicht: Die Kamera kippt vor Abbiegungen/Ausfahrten auf ~20° und zoomt näher.
        /// Auch hier eine Strecke statt einer Zoomstufe — aus demselben Grund: 16,2 wären
        /// auf CarPlay ein anderer Ausschnitt als im Hochformat. 405 m entsprechen dem
        /// Referenzsprung von +0,7 Stufen (Zoom 16,20 im Referenzlayout).
        public var maneuverLookAheadMeters = 405.0
        public var maneuverPitch = 20.0
        /// Beginn der Manöveransicht: Fahrzeit bis zum Manöver (s) – Autobahn ≈ 300 m
        /// bei 105 km/h, Stadt ≈ 100–150 m – mindestens aber `maneuverMinDistance` (m).
        public var maneuverLeadTime = 10.0
        public var maneuverMinDistance = 120.0
        /// Zeit nach dem Manöver, bis die Fahransicht zurückkommt (s). Referenz: 12–13 s.
        public var maneuverHoldAfter = 12.0
        /// Zeitkonstanten (s) der exponentiellen Glättung.
        public var positionSmoothing = 0.35
        public var headingSmoothing = 0.5
        /// Karte folgt dem Kurs mit ~0,5 s Verzögerung (Kompassnadel-Messung).
        public var bearingSmoothing = 0.5
        /// Übergang in die Manöveransicht dauert in der Referenz 6–8 s.
        public var zoomSmoothing = 2.0
        public var pitchSmoothing = 2.0
        /// Ratenbegrenzungen.
        public var maxBearingRate = 120.0   // °/s
        public var maxZoomRate = 0.6        // Zoomstufen/s
        /// Vorhersage über den letzten Fix hinaus, maximal (s).
        public var maxExtrapolation = 2.0
        /// Ab dieser Distanz zwischen Anzeige und Ziel wird gesprungen statt geglättet (m).
        public var teleportDistance = 60.0
        /// Unter dieser Geschwindigkeit gilt "steht" – Kurs wird gehalten (m/s).
        public var stillSpeed = 0.8
        /// Kein Fix seit so vielen Sekunden → stale.
        public var staleAfter = 5.0
        /// Snapping nur, wenn der rohe Fix näher als Genauigkeit + dieser Wert an der Route liegt (m).
        public var snapTolerance = 25.0
        /// Nach Nutzerinteraktion automatisch zurück in den Folgemodus (nil = nie; CarPlay: ~8 s).
        public var autoRecenterDelay: Double? = 8.0
        /// Dauer der Rezentrier-Animation (s).
        public var recenterDuration = 0.8
        /// Anteil, mit dem die Routenrichtung 40 m voraus in das Kamera-Bearing einfließt (0…1).
        /// Referenz: im Mittel 0, in Kurven 8–20° Vorlauf → moderat.
        public var routeLookaheadBlend = 0.25
        /// Im Stand Punkt-mit-Kegel statt Pfeil zeigen (Standard: nein).
        public var dotWhenStill = false
        public init() {}
    }

    public enum Mode: Equatable, Sendable {
        case following
        case freeLook
        case overview
    }

    public var tuning = Tuning()
    public private(set) var mode: Mode = .following

    public var route: [Coordinate] = [] {
        didSet {
            // Apps schieben die Route oft bei jedem Positionsfix nach. Unveränderte Geometrie
            // darf den Snapper nicht neu bauen – sonst fällt `lastSegment` mehrmals pro Sekunde
            // auf 0 zurück und das Snapping sucht jedes Mal von vorn (ruckelt, verhakt sich an
            // Kreuzungen, wo die Route sich selbst nahekommt).
            guard route != oldValue else { return }
            snapper = route.count >= 2 ? RouteSnapper(route: route) : nil
            lastSegment = 0
        }
    }
    /// Streckenpositionen (Meter entlang der Route) aller Manöver, aufsteigend.
    /// Entweder aus eurer Routing-Engine oder per `ManeuverDetector.turnPoints` aus
    /// der Routengeometrie.
    public var maneuverDistancesAlong: [Double] = [] {
        didSet { maneuverDistancesAlong.sort(); passedManeuverAt = nil }
    }
    /// Kompatibilität: nächstes Manöver einzeln setzen.
    public var nextManeuverDistanceAlong: Double? {
        get { maneuverDistancesAlong.first { $0 >= (targetAlong ?? 0) - 30 } }
        set { maneuverDistancesAlong = newValue.map { [$0] } ?? [] }
    }
    /// true, solange die Manöveransicht (flach, nah) aktiv ist.
    public private(set) var isManeuverViewActive = false
    /// Fortschritt entlang der Route in Metern (letzter gesnappter Fix), nil ohne Route.
    public var distanceAlong: Double? { targetAlong }
    /// Nächstes Manöver voraus (Meter entlang der Route), nil wenn keins mehr.
    public var upcomingManeuverDistanceAlong: Double? {
        guard let along = targetAlong else { return maneuverDistancesAlong.first }
        // Kurze Verbindungsstuecke duerfen nicht noch 30 m lang den
        // bereits gefahrenen Pfeil zeigen, waehrend die zweite Kurve kommt.
        return maneuverDistancesAlong.first { $0 > along - 5 }
    }

    /// Zweite Abbiegung begrenzt den Auslauf des aktuellen Manoeverpfeils.
    public var followingManeuverDistanceAlong: Double? {
        guard let current = upcomingManeuverDistanceAlong else { return nil }
        return maneuverDistancesAlong.first { $0 > current + 0.5 }
    }

    private var snapper: RouteSnapper?
    private var lastSegment = 0
    private var passedManeuverAt: (along: Double, time: TimeInterval)?

    // Ziel (letzter Fix, ggf. gesnappt) und Anzeige (geglättet)
    private var target: Coordinate?
    private var targetTime: TimeInterval = 0
    private var targetAlong: Double?
    private var velocity = 0.0          // m/s
    private var velocityBearing = 0.0   // °
    private var rawHeading: Double?
    private var accuracy = 10.0

    private var displayed: Coordinate?
    private var displayedHeading = 0.0
    private var displayedSpeed = 0.0
    private var lastTick: TimeInterval?

    // Kamera-Glättung
    private var camZoom: Double?
    private var camBearing = 0.0
    private var camPitch = 0.0

    // Freier Modus / Rezentrieren
    private var lastInteraction: TimeInterval = 0
    private var recenterStart: (camera: MapCamera, time: TimeInterval)?

    public init() {}

    // MARK: - Eingaben

    /// Neuer GPS-Fix. Reihenfolge egal, Frequenz beliebig (typisch 1 Hz).
    public func update(fix: LocationFix) {
        accuracy = fix.horizontalAccuracy
        var coord = fix.coordinate
        var along: Double?
        var routeBearing: Double?

        if !fix.isSnapped, let s = snapper, let r = s.snap(coord, minSegment: lastSegment) {
            if r.crossTrack <= fix.horizontalAccuracy + tuning.snapTolerance {
                coord = r.coordinate
                along = r.distanceAlong
                routeBearing = r.bearing
                lastSegment = r.segmentIndex
            }
        } else if fix.isSnapped, let s = snapper, let r = s.snap(coord, minSegment: lastSegment) {
            along = r.distanceAlong
            routeBearing = r.bearing
            lastSegment = r.segmentIndex
        }

        // Geschwindigkeit/Kurs: bevorzugt aus dem Fix, sonst aus der Bewegung seit dem letzten Fix.
        if let s = fix.speed, s >= 0 {
            velocity = s
        } else if let prev = target, fix.timestamp > targetTime {
            velocity = GeoMath.distance(prev, coord) / (fix.timestamp - targetTime)
        }
        if let c = fix.course, c >= 0, velocity > tuning.stillSpeed {
            rawHeading = c
        } else if let prev = target, velocity > tuning.stillSpeed, GeoMath.distance(prev, coord) > 2 {
            rawHeading = GeoMath.bearing(from: prev, to: coord)
        }
        // Auf der Route zählt die Straßenrichtung mehr als der verrauschte GPS-Kurs.
        if let rb = routeBearing, velocity > tuning.stillSpeed {
            if let h = rawHeading, abs(GeoMath.angleDelta(from: h, to: rb)) < 45 {
                rawHeading = rb
            } else if rawHeading == nil {
                rawHeading = rb
            }
        }
        velocityBearing = rawHeading ?? velocityBearing

        target = coord
        targetTime = fix.timestamp
        targetAlong = along
        if displayed == nil {
            displayed = coord
            displayedHeading = velocityBearing
        }
    }

    /// Nutzer hat die Karte angefasst (Pan/Zoom/Rotate) → freier Modus.
    public func userInteracted(at time: TimeInterval) {
        mode = .freeLook
        lastInteraction = time
        recenterStart = nil
    }

    /// Zurück in den Folgemodus, animiert ab der aktuellen Kamera.
    public func recenter(from current: MapCamera, at time: TimeInterval) {
        mode = .following
        recenterStart = (current, time)
    }

    public func setOverview() {
        mode = .overview
        recenterStart = nil
    }

    // MARK: - Tick

    /// Pro Frame aufrufen. `current` = aktuelle Kamera der View (für Rezentrier-Animation),
    /// `viewport` = Größe in Punkten.
    /// `freeArea` = von Overlays (Manöverkarte, Bottom-Sheet, CarPlay-Karten) nicht
    /// verdeckter Bereich in Punkten; der Puck-Anker bezieht sich darauf. nil = ganzer Viewport.
    public func tick(now: TimeInterval, current: MapCamera, viewport: (width: Double, height: Double),
                     freeArea: (x: Double, y: Double, width: Double, height: Double)? = nil) -> NavigationFrame {
        guard let target else { return NavigationFrame(camera: nil, puck: nil) }
        let dt = min(max(now - (lastTick ?? now), 0), 0.1)
        lastTick = now

        // 1. Vorhersage: Position entlang Kurs/Route weiterschieben (max. maxExtrapolation).
        let age = min(max(now - targetTime, 0), tuning.maxExtrapolation)
        let stale = now - targetTime > tuning.staleAfter
        var predicted = target
        if velocity > tuning.stillSpeed, !stale {
            let ahead = velocity * age
            if let along = targetAlong, let s = snapper, let p = s.coordinate(atDistance: along + ahead) {
                predicted = p
            } else {
                predicted = GeoMath.destination(from: target, bearing: velocityBearing, meters: ahead)
            }
        }

        // 2. Exponentielle Glättung der Anzeige (oder Teleport bei großem Sprung).
        var disp = displayed ?? predicted
        let gap = GeoMath.distance(disp, predicted)
        if gap > tuning.teleportDistance {
            disp = predicted
        } else if dt > 0 {
            let k = 1 - exp(-dt / tuning.positionSmoothing)
            disp = Coordinate(latitude: disp.latitude + (predicted.latitude - disp.latitude) * k,
                              longitude: disp.longitude + (predicted.longitude - disp.longitude) * k)
        }
        displayed = disp

        // 3. Kurs glätten (kürzester Weg), im Stand halten.
        displayedSpeed += (velocity - displayedSpeed) * (dt > 0 ? 1 - exp(-dt / 0.5) : 1)
        let moving = velocity > tuning.stillSpeed
        if moving, dt > 0 {
            let k = 1 - exp(-dt / tuning.headingSmoothing)
            displayedHeading = GeoMath.normalize(displayedHeading + GeoMath.angleDelta(from: displayedHeading, to: velocityBearing) * k)
        }

        let puck = PuckState(coordinate: disp, heading: displayedHeading, accuracyMeters: accuracy,
                             speed: displayedSpeed, isStale: stale, isMoving: moving,
                             style: (tuning.dotWhenStill && !moving) ? .dot : .arrow)
        updateManeuverState(now: now)

        // 4. Kamera
        switch mode {
        case .overview:
            return NavigationFrame(camera: nil, puck: puck)
        case .freeLook:
            if let delay = tuning.autoRecenterDelay, now - lastInteraction > delay, moving {
                recenter(from: current, at: now)
            } else {
                return NavigationFrame(camera: nil, puck: puck)
            }
            fallthrough
        case .following:
            let follow = followCamera(puck: puck, now: now, dt: dt, viewport: viewport, freeArea: freeArea)
            if let rs = recenterStart {
                let t = min((now - rs.time) / tuning.recenterDuration, 1)
                if t >= 1 { recenterStart = nil; return NavigationFrame(camera: follow, puck: puck) }
                let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 // ease-in-out
                return NavigationFrame(camera: Self.blend(rs.camera, follow, e), puck: puck)
            }
            return NavigationFrame(camera: follow, puck: puck)
        }
    }

    // MARK: - Folgekamera

    /// Manöveransicht ein/aus: aktiv ab `maneuverLeadTime` Fahrzeit (mind. `maneuverMinDistance`)
    /// vor dem nächsten Manöver bis `maneuverHoldAfter` Sekunden nach dem Passieren.
    private func updateManeuverState(now: TimeInterval) {
        guard let along = targetAlong, !maneuverDistancesAlong.isEmpty else { isManeuverViewActive = false; return }
        // Passierte Manöver merken (Haltezeit)
        if let last = maneuverDistancesAlong.last(where: { $0 <= along }) {
            if passedManeuverAt == nil || passedManeuverAt!.along != last { passedManeuverAt = (last, now) }
        }
        var active = false
        if let p = passedManeuverAt, now - p.time < tuning.maneuverHoldAfter, along - p.along < 400 { active = true }
        if let next = maneuverDistancesAlong.first(where: { $0 > along }) {
            let dist = next - along
            let v = max(velocity, 5)  // im Stand wie 18 km/h rechnen
            if dist < tuning.maneuverMinDistance || dist / v < tuning.maneuverLeadTime { active = true }
        }
        isManeuverViewActive = active
    }

    private func followCamera(puck: PuckState, now: TimeInterval, dt: TimeInterval, viewport: (width: Double, height: Double),
                              freeArea: (x: Double, y: Double, width: Double, height: Double)?) -> MapCamera {
        // Erst die Neigung: Der Zoom wird aus der gewünschten Sichtweite gerechnet, und die
        // hängt an der Neigung. In der Manöveransicht ist beides anders.
        let pitchTarget = isManeuverViewActive ? tuning.maneuverPitch : tuning.pitch
        let streckeZiel = isManeuverViewActive
            ? min(tuning.maneuverLookAheadMeters, lookAhead(forSpeed: puck.speed))
            : lookAhead(forSpeed: puck.speed)
        let frei = freeArea ?? (0, 0, viewport.width, viewport.height)
        // Ohne brauchbaren Viewport (vor dem ersten Layout) bleibt der letzte Zoom stehen.
        let zoomTarget = Self.zoom(forLookAhead: streckeZiel, pitch: pitchTarget,
                                   coordinate: puck.coordinate,
                                   viewport: viewport, free: frei,
                                   puckAnchor: tuning.puckAnchor)
            .map { $0 + tuning.zoomOffset }
            ?? camZoom ?? 15.5
        // Bearing-Ziel: Kurs, leicht in die Routenrichtung 40 m voraus gedreht (Kurven "vorausahnen").
        var bearingTarget = puck.heading
        if let along = targetAlong, let s = snapper, puck.isMoving {
            let ahead = s.bearing(atDistance: along + 40)
            bearingTarget = GeoMath.normalize(puck.heading + GeoMath.angleDelta(from: puck.heading, to: ahead) * tuning.routeLookaheadBlend)
        }

        // Glättung mit Ratenbegrenzung
        if camZoom == nil { camZoom = zoomTarget; camBearing = bearingTarget; camPitch = tuning.pitch }
        if dt > 0 {
            let kz = 1 - exp(-dt / tuning.zoomSmoothing)
            var dz = (zoomTarget - camZoom!) * kz
            dz = min(max(dz, -tuning.maxZoomRate * dt), tuning.maxZoomRate * dt)
            camZoom! += dz

            if puck.isMoving {
                let kb = 1 - exp(-dt / tuning.bearingSmoothing)
                var db = GeoMath.angleDelta(from: camBearing, to: bearingTarget) * kb
                db = min(max(db, -tuning.maxBearingRate * dt), tuning.maxBearingRate * dt)
                camBearing = GeoMath.normalize(camBearing + db)
            }
            let kp = 1 - exp(-dt / tuning.pitchSmoothing)
            camPitch += (pitchTarget - camPitch) * kp
        }

        // Kamerazentrum so wählen, dass der Puck am Ankerpunkt (im freien Bereich) sitzt.
        var cam = MapCamera(coordinate: puck.coordinate, zoom: camZoom!, bearing: camBearing, pitch: camPitch)
        let vp = ViewProjection(camera: cam, width: viewport.width, height: viewport.height)
        let anchorScreen = Vec2(frei.x + tuning.puckAnchor.x * frei.width,
                                frei.y + tuning.puckAnchor.y * frei.height)
        if let anchorGround = vp.unprojectToGround(screen: anchorScreen),
           let centerGround = vp.unprojectToGround(screen: Vec2(viewport.width / 2, viewport.height / 2)) {
            let offset = (anchorGround - centerGround) / vp.worldSize
            cam.center = cam.center - offset
        }
        cam.clamp()
        return cam
    }

    /// Sichtweite in Metern vom Puck bis zur Oberkante des freien Bereichs.
    ///
    /// Das ist die Größe, die der Fahrer wahrnimmt — nicht die Zoomstufe. Sie hängt außer
    /// vom Zoom an der Bildhöhe, der Neigung und daran, wie viel Fläche Overlays verdecken.
    public static func lookAheadDistance(zoom: Double, pitch: Double, coordinate: Coordinate,
                                         viewport: (width: Double, height: Double),
                                         free: (x: Double, y: Double, width: Double, height: Double),
                                         puckAnchor: Vec2) -> Double? {
        guard viewport.width > 1, viewport.height > 1, free.height > 1 else { return nil }
        let cam = MapCamera(coordinate: coordinate, zoom: zoom, bearing: 0, pitch: pitch)
        let vp = ViewProjection(camera: cam, width: viewport.width, height: viewport.height)
        let x = free.x + puckAnchor.x * free.width
        guard let unten = vp.unprojectToUnitMercator(screen: Vec2(x, free.y + puckAnchor.y * free.height)),
              let oben = vp.unprojectToUnitMercator(screen: Vec2(x, free.y))
        else { return nil }
        return GeoMath.distance(Mercator.unproject(unten), Mercator.unproject(oben))
    }

    /// Zoom, der die gewünschte Sichtweite ergibt.
    ///
    /// Exakt, nicht genähert: In Weltpixeln ist die Geometrie der Bodenebene vom Zoom
    /// unabhängig, nur die Umrechnung in Meter hängt daran. Die Sichtweite ist deshalb
    /// streng proportional zu 2^(-Zoom), und ein einziger Referenzaufruf genügt.
    public static func zoom(forLookAhead meters: Double, pitch: Double, coordinate: Coordinate,
                            viewport: (width: Double, height: Double),
                            free: (x: Double, y: Double, width: Double, height: Double),
                            puckAnchor: Vec2) -> Double? {
        guard meters > 1 else { return nil }
        let referenz = 15.0
        guard let bei = lookAheadDistance(zoom: referenz, pitch: pitch, coordinate: coordinate,
                                          viewport: viewport, free: free, puckAnchor: puckAnchor),
              bei > 1
        else { return nil }
        return referenz + log2(bei / meters)
    }

    /// Gewünschte Sichtweite bei dieser Geschwindigkeit, in Metern.
    public func lookAhead(forSpeed mps: Double) -> Double {
        min(max(mps * tuning.lookAheadSeconds, tuning.lookAheadMinMeters),
            tuning.lookAheadMaxMeters)
    }

    static func blend(_ a: MapCamera, _ b: MapCamera, _ t: Double) -> MapCamera {
        let db = GeoMath.angleDelta(from: a.bearing, to: b.bearing)
        var c = MapCamera(center: a.center + (b.center - a.center) * t,
                          zoom: a.zoom + (b.zoom - a.zoom) * t,
                          bearing: GeoMath.normalize(a.bearing + db * t),
                          pitch: a.pitch + (b.pitch - a.pitch) * t)
        c.clamp()
        return c
    }

    // MARK: - Übersicht

    /// Kamera, die die gesamte Route (oder beliebige Punkte) in den Viewport einpasst.
    public static func cameraFitting(_ coords: [Coordinate], viewport: (width: Double, height: Double),
                                     padding: Double = 60, bearing: Double = 0, pitch: Double = 0) -> MapCamera? {
        guard !coords.isEmpty else { return nil }
        let pts = coords.map { Mercator.project($0) }
        let minX = pts.map { $0.x }.min()!, maxX = pts.map { $0.x }.max()!
        let minY = pts.map { $0.y }.min()!, maxY = pts.map { $0.y }.max()!
        let w = max(maxX - minX, 1e-9), h = max(maxY - minY, 1e-9)
        let availW = max(viewport.width - 2 * padding, 1), availH = max(viewport.height - 2 * padding, 1)
        // worldSize so, dass Box in den Viewport passt: w * worldSize <= availW
        let zoomX = log2(availW / (w * Mercator.tileSize))
        let zoomY = log2(availH / (h * Mercator.tileSize))
        var cam = MapCamera(center: Vec2((minX + maxX) / 2, (minY + maxY) / 2),
                            zoom: min(zoomX, zoomY), bearing: bearing, pitch: pitch)
        cam.clamp()
        return cam
    }

    /// Wie `cameraFitting(_:viewport:padding:)`, aber mit ungleichen Rändern (Overlays oben/unten/
    /// seitlich): Die Route wird in die freie Fläche eingepasst und deren Mitte auf die Bildschirmmitte
    /// der freien Fläche gelegt – nicht auf die Mitte des ganzen Viewports.
    public static func cameraFitting(_ coords: [Coordinate], viewport: (width: Double, height: Double),
                                     insets: (top: Double, left: Double, bottom: Double, right: Double),
                                     minimumPadding: Double = 24, bearing: Double = 0, pitch: Double = 0) -> MapCamera? {
        guard !coords.isEmpty, viewport.width > 1, viewport.height > 1 else { return nil }
        // Ränder begrenzen: Bleibt weniger als `minFreeFraction` der Fläche übrig (CarPlay-Ränder auf
        // kleinen Displays), werden beide Ränder der Achse gleichmäßig gestaucht. Sonst zoomt die
        // Übersicht so weit heraus, dass die Route zum Strich wird – schlechter als leicht verdeckt.
        // 35 %: Ein Bottom-Sheet über der halben Höhe (Planungsansicht) bleibt unangetastet – dort
        // ist das enge Einpassen gewollt. Gestaucht wird erst, wenn kaum noch Fläche übrig bliebe.
        let minFreeFraction = 0.35
        var (top, left, bottom, right) = (max(insets.top, 0), max(insets.left, 0), max(insets.bottom, 0), max(insets.right, 0))
        let minFreeW = viewport.width * minFreeFraction, minFreeH = viewport.height * minFreeFraction
        if viewport.width - left - right < minFreeW, left + right > 0 {
            let f = max(viewport.width - minFreeW, 0) / (left + right)
            left *= f; right *= f
        }
        if viewport.height - top - bottom < minFreeH, top + bottom > 0 {
            let f = max(viewport.height - minFreeH, 0) / (top + bottom)
            top *= f; bottom *= f
        }
        let freeW = viewport.width - left - right, freeH = viewport.height - top - bottom
        // Mindestrand nie größer als 10 % der freien Fläche.
        let padX = min(minimumPadding, freeW * 0.1), padY = min(minimumPadding, freeH * 0.1)

        let pts = coords.map { Mercator.project($0) }
        let minX = pts.map { $0.x }.min()!, maxX = pts.map { $0.x }.max()!
        let minY = pts.map { $0.y }.min()!, maxY = pts.map { $0.y }.max()!
        let w = max(maxX - minX, 1e-9), h = max(maxY - minY, 1e-9)
        let availW = max(freeW - 2 * padX, 1), availH = max(freeH - 2 * padY, 1)
        let zoom = min(log2(availW / (w * Mercator.tileSize)), log2(availH / (h * Mercator.tileSize)))
        // Mitte der freien Fläche liegt um (dx, dy) Pixel neben der Viewport-Mitte → Kartenmitte gegenläufig verschieben.
        let dx = (left - right) / 2, dy = (top - bottom) / 2
        let worldSize = Mercator.tileSize * pow(2.0, zoom)
        var cam = MapCamera(center: Vec2((minX + maxX) / 2 - dx / worldSize, (minY + maxY) / 2 - dy / worldSize),
                            zoom: zoom, bearing: bearing, pitch: pitch)
        cam.clamp()
        return cam
    }
}
