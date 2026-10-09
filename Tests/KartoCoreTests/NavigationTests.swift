import XCTest
@testable import KartoCore

final class NavigationTests: XCTestCase {

    /// Vorausschau der Kamera in Metern - die Groesse, nach der die
    /// Kamera geregelt wird. Der Zoom ist nur ihr Ergebnis und haengt
    /// am Layout.
    private func vorausschau(_ cam: MapCamera,
                             _ vp: (width: Double, height: Double),
                             free: (x: Double, y: Double, width: Double, height: Double)? = nil,
                             anchor: Vec2 = Vec2(0.5, 0.88)) -> Double {
        NavigationController.lookAheadDistance(
            zoom: cam.zoom, pitch: cam.pitch, coordinate: cam.coordinate,
            viewport: vp, free: free ?? (0, 0, vp.width, vp.height),
            puckAnchor: anchor) ?? -1
    }

    /// Gerade Straße nach Norden, 2 km, in 100-m-Schritten.
    let start = Coordinate(latitude: 48.8917, longitude: 8.6981)
    var route: [Coordinate] {
        (0...20).map { GeoMath.destination(from: start, bearing: 0, meters: Double($0) * 100) }
    }

    func testGeoMath() {
        let b = GeoMath.destination(from: start, bearing: 90, meters: 1000)
        XCTAssertEqual(GeoMath.distance(start, b), 1000, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearing(from: start, to: b), 90, accuracy: 0.1)
        XCTAssertEqual(GeoMath.angleDelta(from: 350, to: 10), 20)
        XCTAssertEqual(GeoMath.angleDelta(from: 10, to: 350), -20)
        XCTAssertEqual(GeoMath.normalize(-90), 270)
    }

    func testSnapperProjectsOntoRoute() {
        let s = RouteSnapper(route: route)
        XCTAssertEqual(s.totalLength, 2000, accuracy: 1)
        // 12 m östlich der Straße bei 550 m
        let raw = GeoMath.destination(from: GeoMath.destination(from: start, bearing: 0, meters: 550), bearing: 90, meters: 12)
        let r = s.snap(raw)!
        XCTAssertEqual(r.crossTrack, 12, accuracy: 0.2)
        XCTAssertEqual(r.distanceAlong, 550, accuracy: 0.5)
        XCTAssertEqual(r.bearing, 0, accuracy: 0.1)
        XCTAssertEqual(r.segmentIndex, 5)
        XCTAssertEqual(GeoMath.distance(r.coordinate, GeoMath.destination(from: start, bearing: 0, meters: 550)), 0, accuracy: 0.2)
        XCTAssertEqual(GeoMath.distance(s.coordinate(atDistance: 1234)!, GeoMath.destination(from: start, bearing: 0, meters: 1234)), 0, accuracy: 0.2)
    }

    func testSnapperProgressHysteresis() {
        // U-förmige Route: hin nach Norden, 30 m nach Osten, zurück nach Süden – parallele Fahrbahnen.
        var r: [Coordinate] = []
        for i in 0...10 { r.append(GeoMath.destination(from: start, bearing: 0, meters: Double(i) * 100)) }
        let east = GeoMath.destination(from: r.last!, bearing: 90, meters: 30)
        for i in 0...10 { r.append(GeoMath.destination(from: east, bearing: 180, meters: Double(i) * 100)) }
        let s = RouteSnapper(route: r)
        // Fahrzeug auf der Hinfahrt bei 450 m, 14 m nach Osten verrauscht (Rückfahrt wäre 16 m entfernt)
        let p = GeoMath.destination(from: GeoMath.destination(from: start, bearing: 0, meters: 450), bearing: 90, meters: 14)
        let hit = s.snap(p, minSegment: 3)!
        XCTAssertEqual(hit.segmentIndex, 4)
        XCTAssertEqual(hit.bearing, 0, accuracy: 0.1)
        // Mit Fortschritt auf der Rückfahrt (Segment 15) darf nicht zur Hinfahrt zurückgesprungen werden.
        let back = s.snap(p, minSegment: 15)!
        XCTAssertGreaterThanOrEqual(back.segmentIndex, 13)
        XCTAssertEqual(back.bearing, 180, accuracy: 0.1)
    }

    func testPuckGlidesAndStaysOnRoad() {
        let nav = NavigationController()
        nav.route = route
        let vp = (width: 390.0, height: 844.0)
        let speed = 13.9 // 50 km/h
        var t = 0.0
        var lastPos: Coordinate?
        var maxStep = 0.0
        var maxCrossTrack = 0.0
        var frames: [NavigationFrame] = []
        // 60 s Fahrt: 1-Hz-Fixes mit ±8 m Rauschen quer zur Straße, 60-Hz-Ticks.
        for second in 0..<60 {
            let along = speed * Double(second)
            let noise = Double((second * 7919) % 17) - 8
            let raw = GeoMath.destination(from: GeoMath.destination(from: start, bearing: 0, meters: along), bearing: 90, meters: noise)
            nav.update(fix: LocationFix(coordinate: raw, course: 2, speed: speed, horizontalAccuracy: 8, timestamp: Double(second)))
            for _ in 0..<60 {
                t += 1.0 / 60
                let f = nav.tick(now: t, current: MapCamera(coordinate: start, zoom: 16), viewport: vp)
                frames.append(f)
                let p = f.puck!.coordinate
                if let lp = lastPos { maxStep = max(maxStep, GeoMath.distance(lp, p)) }
                lastPos = p
                if second > 3 {
                    let ct = RouteSnapper(route: route).snap(p)!.crossTrack
                    maxCrossTrack = max(maxCrossTrack, ct)
                }
            }
        }
        // Pro Frame höchstens ~2× die reale Bewegung (0,23 m bei 50 km/h und 60 Hz) – kein Springen.
        XCTAssertLessThan(maxStep, 0.6, "Puck springt: \(maxStep) m/Frame")
        // Trotz 8 m Rauschen bleibt der Puck auf der Straße.
        XCTAssertLessThan(maxCrossTrack, 1.0, "Puck verlässt Straße: \(maxCrossTrack) m")
        // Kurs entspricht der Straße
        XCTAssertEqual(frames.last!.puck!.heading, 0, accuracy: 1.5)
        XCTAssertFalse(frames.last!.puck!.isStale)
        XCTAssertTrue(frames.last!.puck!.isMoving)

        // Kamera: Puck sitzt am Ankerpunkt (x 50 %, y 88 %), Blick in Fahrtrichtung, Zoom passend zu 50 km/h.
        let cam = frames.last!.camera!
        let proj = ViewProjection(camera: cam, width: vp.width, height: vp.height)
        let screen = proj.project(unitMercator: Mercator.project(frames.last!.puck!.coordinate))!
        XCTAssertEqual(screen.x, 195, accuracy: 1)
        XCTAssertEqual(screen.y, 844 * 0.88, accuracy: 1)
        XCTAssertEqual(cam.bearing, 0, accuracy: 2)
        XCTAssertEqual(cam.pitch, 58, accuracy: 0.5)
        // Bei 50 km/h greift die Untergrenze: 1400 m. Welche Zoomstufe das ist,
        // haengt am Layout - hier ohne Overlays, also naeher als im Referenzlayout.
        XCTAssertEqual(vorausschau(cam, vp), 1400, accuracy: 20)

        // Position ist nach 60 s dort, wo sie sein soll (kein Nachhinken > 2 s Fahrt … tatsächlich deutlich weniger)
        let expectedAlong = speed * 59
        let along = RouteSnapper(route: route).snap(frames.last!.puck!.coordinate)!.distanceAlong
        XCTAssertEqual(along, expectedAlong + speed * 1, accuracy: speed * 0.5)
    }

    func testZoomFollowsSpeedWithRateLimit() {
        let nav = NavigationController()
        // Stadt konstant, kein Heranzoomen im Stand; Autobahn weiter weg.
        // Vorausschau statt Zoomtabelle: Unter der Untergrenze bleibt sie stehen,
        // darueber waechst sie mit dem Tempo, oben ist sie gedeckelt.
        XCTAssertEqual(nav.lookAhead(forSpeed: 0), 1400)
        XCTAssertEqual(nav.lookAhead(forSpeed: 50 / 3.6), 1400)
        XCTAssertEqual(nav.lookAhead(forSpeed: 100 / 3.6), 2222, accuracy: 1)
        XCTAssertEqual(nav.lookAhead(forSpeed: 300 / 3.6), 3000)

        // Sprung von 0 auf 130 km/h: Zoom darf nicht schneller als maxZoomRate fallen.
        nav.route = route
        var t = 0.0
        nav.update(fix: LocationFix(coordinate: start, course: 0, speed: 0, timestamp: 0))
        var f = NavigationFrame(camera: nil, puck: nil)
        for _ in 0..<60 { t += 1.0 / 60; f = nav.tick(now: t, current: MapCamera(coordinate: start, zoom: 16), viewport: (390, 844)) }
        XCTAssertEqual(vorausschau(f.camera!, (390, 844)), 1400, accuracy: 20)
        let zoomImStand = f.camera!.zoom
        nav.update(fix: LocationFix(coordinate: start, course: 0, speed: 130 / 3.6, timestamp: t))
        var prevZoom = f.camera!.zoom
        for _ in 0..<60 {
            t += 1.0 / 60
            f = nav.tick(now: t, current: MapCamera(coordinate: start, zoom: 16), viewport: (390, 844))
            let z = f.camera!.zoom
            XCTAssertLessThanOrEqual(prevZoom - z, nav.tuning.maxZoomRate / 60 + 1e-9)
            prevZoom = z
        }
        // Zoom faellt Richtung Autobahnwert, aber gebremst - nicht in einer Sekunde.
        XCTAssertLessThan(f.camera!.zoom, zoomImStand)
        XCTAssertGreaterThan(f.camera!.zoom, zoomImStand - 0.6)
        XCTAssertGreaterThan(vorausschau(f.camera!, (390, 844)), 1400)
    }

    func testManeuverViewActivatesByLeadTimeAndHolds() {
        let nav = NavigationController()
        nav.route = route
        nav.maneuverDistancesAlong = [1000]
        let fast = 100 / 3.6 // 27,8 m/s → Lead 10 s = 278 m
        let cam0 = MapCamera(coordinate: start, zoom: 16)
        // 500 m vor dem Manöver: Fahransicht
        nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: start, bearing: 0, meters: 500), course: 0, speed: fast, timestamp: 0))
        _ = nav.tick(now: 0.1, current: cam0, viewport: (390, 844))
        XCTAssertFalse(nav.isManeuverViewActive)
        // 250 m davor (9 s Fahrzeit): Manöveransicht aktiv — 405 m Vorausschau bei 20°
        nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: start, bearing: 0, meters: 750), course: 0, speed: fast, timestamp: 1))
        var f = NavigationFrame(camera: nil, puck: nil)
        for i in 1...900 { f = nav.tick(now: 1 + Double(i) / 60, current: cam0, viewport: (390, 844)) }
        XCTAssertTrue(nav.isManeuverViewActive)
        XCTAssertEqual(vorausschau(f.camera!, (390, 844)), 405, accuracy: 15)
        XCTAssertEqual(f.camera!.pitch, 20, accuracy: 1)
        // Manöver passiert (1050 m), nach 5 s noch aktiv, nach 14 s wieder Fahransicht
        nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: start, bearing: 0, meters: 1050), course: 0, speed: 10, timestamp: 20))
        for i in 1...300 { f = nav.tick(now: 20 + Double(i) / 60, current: cam0, viewport: (390, 844)) }
        XCTAssertTrue(nav.isManeuverViewActive)
        for i in 1...600 { f = nav.tick(now: 25 + Double(i) / 60, current: cam0, viewport: (390, 844)) }
        XCTAssertFalse(nav.isManeuverViewActive)
        XCTAssertGreaterThan(f.camera!.pitch, 45, "Pitch kehrt zur Fahransicht zurück")
    }

    func testManeuverViewInCityByMinDistance() {
        let nav = NavigationController()
        nav.route = route
        nav.maneuverDistancesAlong = [1000]
        // 30 km/h: Lead 10 s = 83 m < 120 m Mindestdistanz → ab 120 m aktiv
        nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: start, bearing: 0, meters: 870), course: 0, speed: 30 / 3.6, timestamp: 0))
        _ = nav.tick(now: 0.1, current: MapCamera(coordinate: start, zoom: 16), viewport: (390, 844))
        XCTAssertFalse(nav.isManeuverViewActive)
        nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: start, bearing: 0, meters: 890), course: 0, speed: 30 / 3.6, timestamp: 1))
        _ = nav.tick(now: 1.1, current: MapCamera(coordinate: start, zoom: 16), viewport: (390, 844))
        XCTAssertTrue(nav.isManeuverViewActive)
    }

    func testFreeAreaAnchor() {
        // CarPlay: Karten links (820 pt) verdecken, Puck mittig im freien Bereich, 88 % Höhe
        let nav = NavigationController()
        nav.route = route
        nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: start, bearing: 0, meters: 300), course: 0, speed: 10, timestamp: 0))
        var f = NavigationFrame(camera: nil, puck: nil)
        let vp = (width: 1139.0, height: 498.0)
        for i in 1...120 { f = nav.tick(now: Double(i) / 60, current: MapCamera(coordinate: start, zoom: 16), viewport: vp, freeArea: (410, 0, 729, 498)) }
        let proj = ViewProjection(camera: f.camera!, width: vp.width, height: vp.height)
        let s = proj.project(unitMercator: Mercator.project(f.puck!.coordinate))!
        XCTAssertEqual(s.x, 410 + 729 / 2, accuracy: 1)
        XCTAssertEqual(s.y, 498 * 0.88, accuracy: 1)
    }

    func testFreeLookAndAutoRecenter() {
        let nav = NavigationController()
        nav.tuning.autoRecenterDelay = 3
        nav.route = route
        nav.update(fix: LocationFix(coordinate: start, course: 0, speed: 10, timestamp: 0))
        _ = nav.tick(now: 0.1, current: MapCamera(coordinate: start, zoom: 16), viewport: (390, 844))
        nav.userInteracted(at: 0.2)
        XCTAssertEqual(nav.mode, .freeLook)
        let user = MapCamera(coordinate: start, zoom: 12, bearing: 90, pitch: 0)
        var f = nav.tick(now: 1, current: user, viewport: (390, 844))
        XCTAssertNil(f.camera, "Im freien Modus keine Kamera-Übernahme")
        XCTAssertNotNil(f.puck)
        // Nach 3 s ohne Interaktion: automatisches Rezentrieren, animiert ab der Nutzerkamera.
        nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: start, bearing: 0, meters: 40), course: 0, speed: 10, timestamp: 4))
        f = nav.tick(now: 4.0, current: user, viewport: (390, 844))
        XCTAssertEqual(nav.mode, .following)
        XCTAssertNotNil(f.camera)
        XCTAssertLessThan(f.camera!.zoom, 13, "Animation startet bei der Nutzerkamera")
        f = nav.tick(now: 4.0 + nav.tuning.recenterDuration + 0.1, current: user, viewport: (390, 844))
        XCTAssertGreaterThan(f.camera!.zoom, 15.3, "… und endet bei der Folgekamera")
        XCTAssertEqual(f.camera!.pitch, 58, accuracy: 0.5)
    }

    func testStaleAndStandstillHoldHeading() {
        let nav = NavigationController()
        nav.update(fix: LocationFix(coordinate: start, course: 45, speed: 10, timestamp: 0))
        var f = nav.tick(now: 0.5, current: MapCamera(coordinate: start, zoom: 16), viewport: (390, 844))
        XCTAssertEqual(f.puck!.heading, 45, accuracy: 0.01)
        // Stillstand: Kurs bleibt, Pfeil bleibt (kein Punkt)
        nav.update(fix: LocationFix(coordinate: start, course: -1, speed: 0, timestamp: 1))
        f = nav.tick(now: 1.5, current: MapCamera(coordinate: start, zoom: 16), viewport: (390, 844))
        XCTAssertEqual(f.puck!.heading, 45, accuracy: 0.01)
        XCTAssertFalse(f.puck!.isMoving)
        XCTAssertEqual(f.puck!.style, .arrow)
        nav.tuning.dotWhenStill = true
        f = nav.tick(now: 1.6, current: MapCamera(coordinate: start, zoom: 16), viewport: (390, 844))
        XCTAssertEqual(f.puck!.style, .dot)
        // Kein Fix mehr → stale nach 5 s
        f = nav.tick(now: 7, current: MapCamera(coordinate: start, zoom: 16), viewport: (390, 844))
        XCTAssertTrue(f.puck!.isStale)
    }

    func testCameraFittingRoute() {
        let cam = NavigationController.cameraFitting(route, viewport: (390, 844), padding: 40)!
        let vp = ViewProjection(camera: cam, width: 390, height: 844)
        for c in route {
            let s = vp.project(unitMercator: Mercator.project(c))!
            XCTAssertGreaterThanOrEqual(s.x, 39); XCTAssertLessThanOrEqual(s.x, 351)
            XCTAssertGreaterThanOrEqual(s.y, 39); XCTAssertLessThanOrEqual(s.y, 805)
        }
        // Route ist 2 km hoch → Höhe (764 px) begrenzt: 2,6 m/px ≈ Zoom 14.3 auf 48,9° Breite
        XCTAssertEqual(cam.zoom, 14.26, accuracy: 0.1)
    }

    /// Übersicht mit Overlay-Rändern: Routenmitte liegt in der Mitte der freien Fläche.
    func testCameraFittingWithInsets() {
        let a = Coordinate(latitude: 48.90, longitude: 8.70), b = Coordinate(latitude: 48.80, longitude: 8.80)
        let vp = (width: 400.0, height: 800.0)
        let insets = (top: 60.0, left: 20.0, bottom: 400.0, right: 20.0)   // Bottom-Sheet nimmt die untere Hälfte
        let cam = NavigationController.cameraFitting([a, b], viewport: vp, insets: insets)!
        let proj = ViewProjection(camera: cam, width: vp.width, height: vp.height)
        let pa = proj.project(unitMercator: Mercator.project(a))!, pb = proj.project(unitMercator: Mercator.project(b))!
        // Beide Punkte innerhalb der freien Fläche (mit Mindestrand)
        for p in [pa, pb] {
            XCTAssertGreaterThan(p.y, insets.top + 20); XCTAssertLessThan(p.y, vp.height - insets.bottom - 20)
            XCTAssertGreaterThan(p.x, insets.left + 20); XCTAssertLessThan(p.x, vp.width - insets.right - 20)
        }
        // Mitte der Route ≈ Mitte der freien Fläche (y = 60 + 340/2 = 230)
        XCTAssertEqual((pa.y + pb.y) / 2, insets.top + (vp.height - insets.top - insets.bottom) / 2, accuracy: 2)
        XCTAssertEqual((pa.x + pb.x) / 2, vp.width / 2, accuracy: 2)
    }

    /// Kleines Display mit großen Rändern (CarPlay-Instrumentenanzeige): Die Übersicht darf nicht
    /// auf einen Strich herauszoomen – zu große Ränder werden gestaucht.
    func testCameraFittingClampsOversizedInsets() {
        let a = Coordinate(latitude: 48.90, longitude: 8.70), b = Coordinate(latitude: 48.86, longitude: 8.75)
        let carplay = (width: 480.0, height: 260.0)
        let insets = (top: 120.0, left: 200.0, bottom: 100.0, right: 112.0)
        let cam = NavigationController.cameraFitting([a, b], viewport: carplay, insets: insets)!
        // Ohne Stauchung blieben in der Höhe 40 pt und in der Breite 168 pt übrig – der Zoom darf
        // nicht wesentlich unter dem eines symmetrischen Fits mit 40 pt Rand liegen.
        let referenz = NavigationController.cameraFitting([a, b], viewport: carplay, padding: 40)!
        XCTAssertGreaterThan(cam.zoom, referenz.zoom - 1.5)
        let proj = ViewProjection(camera: cam, width: carplay.width, height: carplay.height)
        for c in [a, b] {
            let p = proj.project(unitMercator: Mercator.project(c))!
            XCTAssertGreaterThan(p.x, 0); XCTAssertLessThan(p.x, carplay.width)
            XCTAssertGreaterThan(p.y, 0); XCTAssertLessThan(p.y, carplay.height)
        }
        // Extremfall: Ränder größer als der Viewport → trotzdem ein brauchbarer Fit
        let irre = (top: 400.0, left: 700.0, bottom: 400.0, right: 700.0)   // größer als der Viewport
        let cam2 = NavigationController.cameraFitting([a, b], viewport: carplay, insets: irre)!
        XCTAssertGreaterThan(cam2.zoom, referenz.zoom - 2.5)
    }

    /// Route pro Positionsfix neu setzen darf das Snapping nicht zurückwerfen: Bei gleicher
    /// Geometrie bleibt der Snapper samt Fortschritt stehen – sonst sucht er wieder ab Segment 0
    /// und springt an Stellen, wo die Route sich selbst nahekommt (Kreuzung, Wendeschleife),
    /// auf die falsche Fahrbahn.
    func testUnchangedRouteKeepsSnapperProgress() {
        var r: [Coordinate] = []
        for i in 0...10 { r.append(GeoMath.destination(from: start, bearing: 0, meters: Double(i) * 100)) }
        let east = GeoMath.destination(from: r.last!, bearing: 90, meters: 30)
        for i in 0...10 { r.append(GeoMath.destination(from: east, bearing: 180, meters: Double(i) * 100)) }

        let nav = NavigationController()
        nav.route = r
        // Hinfahrt bis 900 m, dann Wende, dann Rückfahrt bis auf Höhe 450 m.
        var t = 0.0
        for m in stride(from: 0.0, through: 900.0, by: 50.0) {
            nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: start, bearing: 0, meters: m),
                                        course: 0, speed: 13.9, horizontalAccuracy: 8, timestamp: t))
            t += 1
        }
        for m in stride(from: 1000.0, through: 550.0, by: -50.0) {
            nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: east, bearing: 180, meters: 1000 - m),
                                        course: 180, speed: 13.9, horizontalAccuracy: 8, timestamp: t))
            t += 1
        }
        let vorher = nav.distanceAlong ?? 0
        XCTAssertGreaterThan(vorher, 1000, "Fahrzeug ist auf der Rückfahrt")

        nav.route = r                      // identische Geometrie erneut zugewiesen (jeder Fix)
        nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: east, bearing: 180, meters: 500),
                                    course: 180, speed: 13.9, horizontalAccuracy: 8, timestamp: t))
        XCTAssertGreaterThan(nav.distanceAlong ?? 0, 1000, "Snapper darf nicht auf die Hinfahrt zurückfallen")

        // Echte Änderung (Neuberechnung) baut den Snapper weiterhin neu: Fortschritt startet
        // wieder bei 0, ein Fix auf der neuen Route wird ab Segment 0 gesucht.
        nav.route = Array(r.prefix(6))            // nur noch 500 m geradeaus
        nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: start, bearing: 0, meters: 250),
                                    course: 0, speed: 13.9, horizontalAccuracy: 8, timestamp: t + 1))
        XCTAssertEqual(nav.distanceAlong ?? -1, 250, accuracy: 5)
    }

    // MARK: Restweg fuer die Uebersicht

    /// Eine Strecke Nord-Sued mit gleichmaessigen Schritten: Damit
    /// laesst sich die Interpolation gegen die Haversine-Distanz
    /// pruefen, ohne Fixture.
    private func gerade(punkte: Int, abstandM: Double,
                        kurs: Double = 0) -> [Coordinate] {
        var liste = [Coordinate(latitude: 48.0, longitude: 9.0)]
        for _ in 1..<punkte {
            liste.append(GeoMath.destination(from: liste.last!,
                                             bearing: kurs, meters: abstandM))
        }
        return liste
    }

    private func laenge(_ c: [Coordinate]) -> Double {
        zip(c, c.dropFirst()).reduce(0) { $0 + GeoMath.distance($1.0, $1.1) }
    }

    func testRemainderSchneidetAnDerGefahrenenStrecke() {
        let route = gerade(punkte: 11, abstandM: 100)   // 1000 m
        let rest = RouteDisplay.remainder(of: route, from: 250)
        XCTAssertEqual(laenge(rest), 750, accuracy: 1.0)
        // Der erste Punkt liegt zwischen den Stuetzpunkten, nicht auf einem.
        XCTAssertEqual(GeoMath.distance(route[0], rest[0]), 250, accuracy: 1.0)
        XCTAssertEqual(rest.last, route.last)
    }

    func testRemainderOhneFortschrittIstDieGanzeRoute() {
        let route = gerade(punkte: 5, abstandM: 200)
        XCTAssertEqual(RouteDisplay.remainder(of: route, from: 0), route)
        XCTAssertEqual(RouteDisplay.remainder(of: route, from: -10), route)
    }

    func testRemainderAmZielLiefertDenLetztenAbschnitt() {
        // Ueber das Ende hinaus darf nie eine leere Liste kommen - die
        // Uebersicht haette sonst nichts einzupassen und zeigte einen
        // leeren Bildschirm.
        let route = gerade(punkte: 6, abstandM: 100)   // 500 m
        for gefahren in [500.0, 900.0] {
            let rest = RouteDisplay.remainder(of: route, from: gefahren)
            XCTAssertEqual(rest.count, 2)
            XCTAssertEqual(rest.last, route.last)
        }
    }

    func testRemainderSchrumpftMonoton() {
        // Waehrend der Fahrt darf der Rest nie wieder laenger werden -
        // sonst zoomte die Uebersicht zwischendurch heraus.
        let route = gerade(punkte: 21, abstandM: 250)  // 5000 m
        var vorher = Double.infinity
        for gefahren in stride(from: 0.0, through: 4800.0, by: 137.0) {
            let jetzt = laenge(RouteDisplay.remainder(of: route, from: gefahren))
            XCTAssertLessThanOrEqual(jetzt, vorher + 1.0)
            vorher = jetzt
        }
    }

    func testUebersichtZoomtMitDemRestHinein() {
        // Der eigentliche Zweck: kuerzerer Rest, groesserer Massstab.
        let route = gerade(punkte: 41, abstandM: 500)  // 20 km
        let sicht = (width: 900.0, height: 400.0)
        let raender = (top: 16.0, left: 320.0, bottom: 24.0, right: 54.0)
        var vorher = -Double.infinity
        for gefahren in [0.0, 5000.0, 12000.0, 18000.0] {
            let rest = RouteDisplay.remainder(of: route, from: gefahren)
            let cam = NavigationController.cameraFitting(rest, viewport: sicht,
                                                         insets: raender)
            XCTAssertNotNil(cam)
            XCTAssertGreaterThan(cam!.zoom, vorher)
            vorher = cam!.zoom
        }
    }

    func testUebersichtNutztDieFreieFlaecheRechts() {
        // Bei breitem linken Rand muss die Kartenmitte nach rechts
        // wandern - sonst bleibt rechts der Leerraum, um den es ging.
        // Ost-West: Nur dann bestimmt die Breite den Massstab, und nur
        // dann sagt ein seitlicher Rand ueberhaupt etwas ueber ihn aus.
        let route = gerade(punkte: 11, abstandM: 500, kurs: 90)
        let sicht = (width: 900.0, height: 400.0)
        let mittig = NavigationController.cameraFitting(
            route, viewport: sicht,
            insets: (top: 0, left: 0, bottom: 0, right: 0))!
        let links = NavigationController.cameraFitting(
            route, viewport: sicht,
            insets: (top: 0, left: 324, bottom: 0, right: 54))!
        XCTAssertLessThan(links.center.x, mittig.center.x)
        XCTAssertLessThan(links.zoom, mittig.zoom)
    }
}
