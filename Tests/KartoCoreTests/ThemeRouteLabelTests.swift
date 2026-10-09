import XCTest
@testable import KartoCore

final class ThemeRouteLabelTests: XCTestCase {

    func fixture(_ name: String, _ ext: String) -> URL {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")!
    }

    // MARK: Theme

    func testThemesProduceIdenticalLayerStructure() {
        for schema in [TileSchema.openMapTiles, .protomaps] {
            let a = schema.style(theme: .cleanWhite), b = schema.style(theme: .nightDrive), c = schema.style(theme: .kartoKit(dark: true))
            XCTAssertEqual(a.layers.map { $0.id }, b.layers.map { $0.id })
            XCTAssertEqual(a.layers.map { $0.id }, c.layers.map { $0.id })
            XCTAssertGreaterThan(a.layers.count, 15)
        }
    }

    func testStyleBlend() {
        let a = MapStyle.openMapTiles(theme: .cleanWhite), b = MapStyle.openMapTiles(theme: .nightDrive)
        let m = MapStyle.blend(a, b, 0.5)
        XCTAssertEqual(m.layers.count, a.layers.count)
        XCTAssertEqual(m.background.r, (a.background.r + b.background.r) / 2, accuracy: 1e-6)
        if case .fill(let ca) = a.layers[0].paint, case .fill(let cb) = b.layers[0].paint, case .fill(let cm) = m.layers[0].paint {
            XCTAssertEqual(cm.g, (ca.g + cb.g) / 2, accuracy: 1e-6)
        } else { XCTFail() }
        XCTAssertEqual(MapStyle.blend(a, b, 0).background, a.background)
        XCTAssertEqual(MapStyle.blend(a, b, 1).background, b.background)
    }

    func testSampleMapTokensLoad() throws {
        let data = try Data(contentsOf: fixture("sample-map-style-tokens", "json"))
        let day = try ThemeTokens.apply(json: data, to: .cleanWhite, dark: false)
        let night = try ThemeTokens.apply(json: data, to: .nightDrive, dark: true)
        XCTAssertEqual(day.background.hexString, "#E4E7DB")
        XCTAssertEqual(night.background.hexString, "#111310")
        XCTAssertEqual(day.route.active.hexString, "#7B2FA0")
        XCTAssertEqual(night.route.active.hexString, "#D8A6E2")
        XCTAssertEqual(day.route.casing.hexString, "#FFFDF8")
        XCTAssertEqual(day.roads[.motorway]?.fill.hexString, "#FCF9F1")
        XCTAssertEqual(day.roads[.motorway]?.casing?.hexString, "#C9C6BD")
        XCTAssertEqual(day.route.trafficClosed.hexString, "#8B1E2D")
        XCTAssertEqual(day.extra["chargingAvailable"]?.hexString, "#0B7563")
        XCTAssertEqual(day.accent.hexString, "#E9480D")
        XCTAssertFalse(day.isDark); XCTAssertTrue(night.isDark)
        // Eingebautes KartoKit-Theme stimmt mit den Tokens überein
        let builtIn = MapTheme.kartoKit(dark: false)
        XCTAssertEqual(builtIn.background, day.background)
        XCTAssertEqual(builtIn.route.active, day.route.active)
        XCTAssertEqual(builtIn.roads[.primary]?.fill, day.roads[.primary]?.fill)
        XCTAssertEqual(builtIn.labels.text, day.labels.text)
        if case .image(let name) = builtIn.puck.shape { XCTAssertEqual(name, "NavigationArrow") } else { XCTFail("Brand-Pfeil erwartet") }
    }

    func testSampleBrandTokensLoad() throws {
        let data = try Data(contentsOf: fixture("sample-design-tokens", "json"))
        let t = try ThemeTokens.apply(json: data, to: .cleanWhite, dark: false)
        XCTAssertEqual(t.route.active.hexString, "#7B2FA0")
        XCTAssertEqual(t.accent.hexString, "#E9480D")
        XCTAssertEqual(t.route.activeWidth, 7); XCTAssertEqual(t.route.casingWidth, 11); XCTAssertEqual(t.route.alternativeWidth, 5)
        XCTAssertEqual(t.puck.stroke.hexString, "#E9480D")
        let dark = try ThemeTokens.apply(json: data, to: .nightDrive, dark: true)
        XCTAssertEqual(dark.route.active.hexString, "#D8A6E2")
    }

    func testCSSColorParsing() {
        XCTAssertEqual(RGBA(css: "#60356B")?.hexString, "#60356B")
        XCTAssertEqual(RGBA(css: "#fff")?.hexString, "#FFFFFF")
        XCTAssertEqual(RGBA(css: "#00000080")?.a ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(RGBA(css: "rgba(255, 0, 0, 0.5)")?.r, 1)
        XCTAssertNil(RGBA(css: "blau"))
    }

    // MARK: Route

    let start = Coordinate(latitude: 48.8917, longitude: 8.6981)
    var straight: [Coordinate] { (0...10).map { GeoMath.destination(from: start, bearing: 90, meters: Double($0) * 100) } }

    func testRouteMeshDistancesAndLocalFrame() {
        let m = RouteMesh(coordinates: straight)
        XCTAssertEqual(m.totalLength, 1000, accuracy: 1)
        // Streifen (zwei je Stuetzpunkt) plus die beiden runden Enden.
        // Als Formel statt als Zahl, damit ein spaeterer Fehlschlag sagt,
        // was sich geaendert hat, und nicht nur dass sich etwas geaendert hat.
        let jeKappe = 2 + LineTessellator.rundungsEcken
        XCTAssertEqual(m.vertices.count, 11 * 2 + 2 * jeKappe)
        XCTAssertEqual(m.indices.count, 10 * 6 + 2 * LineTessellator.rundungsEcken * 3)
        // Die Kappe am Ziel traegt die volle Laenge — sonst faerbte der
        // Fortschritt sie ein, sobald man losfaehrt.
        XCTAssertEqual(Double(m.vertices[m.vertices.count - 1].distance), 1000, accuracy: 1)
        XCTAssertEqual(m.vertices[0].distance, 0)
        XCTAssertEqual(Double(m.vertices[20].distance), 1000, accuracy: 1)
        // Ursprung = erster Punkt, x wächst nach Osten in Welt-Pixeln auf z16
        XCTAssertEqual(m.vertices[0].x, 0); XCTAssertEqual(m.vertices[0].y, 0)
        let mpp = Mercator.metersPerPixel(latitude: start.latitude, zoom: 16)
        XCTAssertEqual(Double(m.vertices[20].x), 1000 / mpp, accuracy: 2)
        // Normalen senkrecht (nach Norden/Süden), Länge 1
        XCTAssertEqual(abs(m.vertices[0].ny), 1, accuracy: 1e-4)
        XCTAssertEqual(m.vertices[0].nx, 0, accuracy: 1e-4)
    }

    func testRouteSegmentsFromIndexRanges() {
        let segs = RouteDisplay.segments(fromIndexRanges: [(from: 2, to: 4, kind: .jam), (from: 9, to: 20, kind: .slow)], coordinates: straight)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].from, 200, accuracy: 1); XCTAssertEqual(segs[0].to, 400, accuracy: 1)
        XCTAssertEqual(segs[1].to, 1000, accuracy: 1)
    }

    func testManeuverArrowGeometry() {
        // Rechtwinklige Abbiegung bei 500 m
        var route = (0...5).map { GeoMath.destination(from: start, bearing: 90, meters: Double($0) * 100) }
        let corner = route.last!
        route += (1...5).map { GeoMath.destination(from: corner, bearing: 180, meters: Double($0) * 100) }
        // Ausdrueckliche Laengen: Der Test prueft die Geometrie, nicht
        // die Vorgabewerte. Die stehen weiter unten und duerfen sich
        // aendern, ohne diesen Test mitzureissen.
        let line = ManeuverArrow.polyline(route: route, maneuverDistanceAlong: 500,
                                          before: 35, after: 25)
        XCTAssertGreaterThan(line.count, 10)
        XCTAssertEqual(GeoMath.distance(line.first!, corner), 35, accuracy: 1)
        XCTAssertEqual(GeoMath.distance(line.last!, corner), 25, accuracy: 1)
        XCTAssertEqual(GeoMath.bearing(from: line[line.count - 2], to: line.last!), 180, accuracy: 2)
        let mesh = RouteMesh(coordinates: line)
        let (hv, hi) = ManeuverArrow.head(polyline: line, origin: mesh.origin, localZoom: mesh.localZoom, widthPx: 6, lengthPx: 10)
        XCTAssertEqual(hv.count, 3); XCTAssertEqual(hi, [0, 1, 2])
        XCTAssertGreaterThan(hv[2].y, hv[0].y) // Spitze zeigt nach Süden (+y)
    }

    /// Die Schildfarbe folgt der Nummer, nicht dem Ausbau.
    func testSchildfarbeNachNummer() {
        // Der gemeldete Fall: B 29 ist autobahnaehnlich ausgebaut und in
        // OSM `trunk`, die B 10 daneben `primary`. Nach Klasse gefaerbt
        // standen zwei Bundesstrassen in zwei Farben nebeneinander.
        XCTAssertFalse(LabelExtractor.autobahnschild(text: "B 29", klasse: .trunk))
        XCTAssertFalse(LabelExtractor.autobahnschild(text: "B29", klasse: .trunk))
        XCTAssertFalse(LabelExtractor.autobahnschild(text: "B 10", klasse: .primary))
        // Autobahnen bleiben blau.
        XCTAssertTrue(LabelExtractor.autobahnschild(text: "A 8", klasse: .motorway))
        XCTAssertTrue(LabelExtractor.autobahnschild(text: "A81", klasse: .trunk))
        // Nur herabstufen: Eine britische A-road ist `trunk` und bleibt
        // blau, eine `primary` wird durch ein "A" nicht blau.
        XCTAssertTrue(LabelExtractor.autobahnschild(text: "A 1", klasse: .trunk))
        XCTAssertFalse(LabelExtractor.autobahnschild(text: "A 1", klasse: .primary))
        // Europastrassen und alles Uebrige unveraendert.
        XCTAssertTrue(LabelExtractor.autobahnschild(text: "E 52", klasse: .motorway))
        XCTAssertFalse(LabelExtractor.autobahnschild(text: "E 52", klasse: .secondary))
    }

    /// Gebaeude an der Kachelgrenze duerfen nur einmal gezeichnet werden.
    ///
    /// Vektorkacheln tragen einen Rand: Wer ein Haus an der Grenze in
    /// beiden Nachbarkacheln zeichnet, legt zwei deckungsgleiche Flaechen
    /// mit demselben Tiefenwert uebereinander. Welche gewinnt, entscheidet
    /// die Rundung — und beim Vorbeifahren kippt das von Bild zu Bild.
    func testGebaeudeNurInEigenerKachel() throws {
        let data = try Data(contentsOf: fixture("openfreemap-14-8609-5642", "pbf"))
        let vt = try VectorTileDecoder.decode(data)
        let ebene = try XCTUnwrap(vt.layers.first { $0.name == "building" })
        let gebaeude = ebene.features.filter { $0.type == .polygon }
        let draussen = gebaeude.filter {
            !TileMeshBuilder.schwerpunktInKachel($0, extent: ebene.extent)
        }
        // Die Kachel traegt tatsaechlich Haeuser aus dem Randbereich —
        // sonst pruefte dieser Test nichts.
        XCTAssertFalse(draussen.isEmpty,
                       "Kachel ohne Randgebaeude — Test sagt nichts aus")

        let mesh = TileMeshBuilder.build(tile: TileID(z: 14, x: 8609, y: 5642), vectorTile: vt,
                                         style: .openMapTiles(theme: .kartoKit(dark: false)),
                                         sourceMaxZoom: 14)
        let bucket = try XCTUnwrap(mesh.extrusions.first { $0.layerID == "building" })
        // Jedes gezeichnete Gebaeude traegt genau einen Ton. Die Anzahl
        // verschiedener Toene ist damit die Anzahl gezeichneter Haeuser.
        let gezeichnet = Set(bucket.vertices.map { $0.ton }).count
        XCTAssertEqual(gezeichnet, gebaeude.count - draussen.count,
                       "gezeichnet \(gezeichnet), erwartet \(gebaeude.count - draussen.count)")
    }

    /// Die Vorgabelaenge bestimmt, ob der Pfeil im Fahren auffaellt.
    ///
    /// Mit 35 m vor und 25 m nach dem Manoever war er bei z 15,5 und
    /// geneigter Kamera ein Stummel von wenigen Pixeln — im Simulator
    /// ueber mehrere Aufnahmen nicht auszumachen. Wer die Werte wieder
    /// senkt, macht ihn unsichtbar; deshalb stehen sie hier fest.
    /// Die Tonstreuung muss an einer echten OpenFreeMap-Kachel ankommen,
    /// nicht nur an konstruierten Polygonen. Genau dort entscheidet sich,
    /// ob die Haeuser auf dem Geraet unterschiedlich aussehen.
    func testGebaeudeTonStreutInEchterKachel() throws {
        let data = try Data(contentsOf: fixture("openfreemap-14-8609-5642", "pbf"))
        let vt = try VectorTileDecoder.decode(data)
        let mesh = TileMeshBuilder.build(tile: TileID(z: 14, x: 8609, y: 5642), vectorTile: vt,
                                         style: .openMapTiles(theme: .kartoKit(dark: false)),
                                         sourceMaxZoom: 14)
        // Die Stuttgart-Kachel, nicht die von Bad Teinach: Dort steht ein
        // einziges Gebaeude, und ein Ton allein sagt ueber Streuung nichts.
        XCTAssertGreaterThan(vt.layers.first { $0.name == "building" }?.features.count ?? 0, 50)
        let bucket = try XCTUnwrap(mesh.extrusions.first { $0.layerID == "building" })
        XCTAssertGreaterThan(bucket.vertices.count, 100)

        let toene = Set(bucket.vertices.map { $0.ton })
        XCTAssertGreaterThan(toene.count, 10,
                             "Alle Gebaeude der Kachel teilen sich \(toene.count) Ton/Toene")
        // Und die Streuung muss den Bereich ausschoepfen, nicht nur um 0
        // zittern — sonst ist der Unterschied auf dem Schirm keiner.
        XCTAssertLessThan(toene.min() ?? 0, -0.5)
        XCTAssertGreaterThan(toene.max() ?? 0, 0.5)
    }

    func testManeuverArrowVorgabelaenge() {
        var route = (0...5).map { GeoMath.destination(from: start, bearing: 90, meters: Double($0) * 100) }
        let corner = route.last!
        route += (1...5).map { GeoMath.destination(from: corner, bearing: 180, meters: Double($0) * 100) }
        let line = ManeuverArrow.polyline(route: route, maneuverDistanceAlong: 500)
        XCTAssertEqual(GeoMath.distance(line.first!, corner), 45, accuracy: 1)
        XCTAssertEqual(GeoMath.distance(line.last!, corner), 25, accuracy: 1)
    }

    func testTightLeftRightArrowEndsBeforeSecondTurn() {
        let first = GeoMath.destination(from: start, bearing: 0, meters: 100)
        let second = GeoMath.destination(from: first, bearing: 270, meters: 16)
        let end = GeoMath.destination(from: second, bearing: 0, meters: 100)
        let route = [start, first, second, end]
        let m = GeoMath.distance(start, first)
        let next = m + GeoMath.distance(first, second)
        let line = ManeuverArrow.polyline(route: route, maneuverDistanceAlong: m,
                                          nextManeuverDistanceAlong: next)
        XCTAssertEqual(GeoMath.distance(first, line.last!), 8, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearing(from: line[line.count - 2], to: line.last!), 270, accuracy: 2)
        let mesh = RouteMesh(coordinates: line)
        let (head, _) = ManeuverArrow.head(polyline: line, origin: mesh.origin,
                                          localZoom: mesh.localZoom, widthPx: 6, lengthPx: 20)
        let tip = (Mercator.project(line.last!) - mesh.origin) * Mercator.worldSize(zoom: mesh.localZoom)
        XCTAssertEqual(Double(head[2].x), tip.x, accuracy: 0.01)
        XCTAssertEqual(Double(head[2].y), tip.y, accuracy: 0.01)
    }

    func testFollowingManeuverUsesNextDistinctTurn() {
        let nav = NavigationController()
        nav.maneuverDistancesAlong = [140, 100, 100]
        XCTAssertEqual(nav.upcomingManeuverDistanceAlong, 100)
        XCTAssertEqual(nav.followingManeuverDistanceAlong, 140)
        nav.maneuverDistancesAlong = [100]
        XCTAssertNil(nav.followingManeuverDistanceAlong)
    }

    func testCloseFollowingTurnBecomesCurrentAfterFirstTurn() {
        let nav = NavigationController()
        nav.route = (0...20).map { GeoMath.destination(from: start, bearing: 0, meters: Double($0) * 10) }
        nav.maneuverDistancesAlong = [100, 116]
        nav.update(fix: LocationFix(coordinate: GeoMath.destination(from: start, bearing: 0, meters: 108),
                                   course: 0, speed: 5, horizontalAccuracy: 2, timestamp: 1))
        XCTAssertEqual(nav.upcomingManeuverDistanceAlong, 116)
        XCTAssertNil(nav.followingManeuverDistanceAlong)
    }

    // MARK: Kollision + Labels

    func testCollisionGrid() {
        var g = CollisionGrid(cellSize: 32)
        XCTAssertTrue(g.insert(CollisionGrid.Box(center: Vec2(100, 100), width: 40, height: 20)))
        XCTAssertFalse(g.insert(CollisionGrid.Box(center: Vec2(110, 105), width: 40, height: 20)))
        XCTAssertTrue(g.insert(CollisionGrid.Box(center: Vec2(200, 100), width: 40, height: 20)))
        XCTAssertFalse(g.insert(CollisionGrid.Box(center: Vec2(150, 100), width: 70, height: 20), padding: 2))
        XCTAssertEqual(g.boxes.count, 2)
    }

    func testStraightWindow() {
        let line = (0...20).map { Vec2(Double($0) * 10, 100) }
        let r = LabelPlacer.straightWindow(line, length: 80, maxCurvature: 0.3)!
        XCTAssertEqual(r.0.x, 100, accuracy: 1e-6); XCTAssertEqual(r.0.y, 100, accuracy: 1e-6)
        XCTAssertEqual(r.1, 0, accuracy: 1e-6)
        // Zu kurz
        XCTAssertNil(LabelPlacer.straightWindow(line, length: 500, maxCurvature: 0.3))
        // Rechter Winkel in der Mitte → Fenster weicht auf einen Schenkel aus
        let corner = (0...10).map { Vec2(Double($0) * 10, 100) } + (1...10).map { Vec2(100, 100 + Double($0) * 10) }
        let c = LabelPlacer.straightWindow(corner, length: 60, maxCurvature: 0.3)!
        XCTAssertTrue(c.0.y == 100 || c.0.x == 100)
        XCTAssertTrue(abs(c.1) < 0.01 || abs(abs(c.1) - .pi / 2) < 0.01)
    }

    func testLabelPlacerPrioritiesAndUpright() {
        // Kachel-Matrix = Identität auf Bildschirm (Tile-Einheiten = Punkte), Viewport 400×400
        var m = Mat4.identity
        m[0, 0] = 2 / 400; m[1, 1] = -2 / 400; m[3, 0] = -1; m[3, 1] = 1
        let city = LabelCandidate(text: "Pforzheim", kind: .place(rank: 2), point: TilePoint(200, 200))
        let village = LabelCandidate(text: "Dorf", kind: .place(rank: 5), point: TilePoint(205, 203)) // kollidiert mit Stadt
        // Straße von rechts nach links (Richtung 180°) → muss aufrecht gedreht werden
        let road = LabelCandidate(text: "Calwer Straße", kind: .road(.primary), path: (0...10).map { TilePoint(Int32(300 - $0 * 20), 300) })
        let shield = LabelCandidate(text: "A8", kind: .shield(.motorway), path: [TilePoint(20, 40), TilePoint(380, 40)])
        var placer = LabelPlacer()
        let measure: LabelPlacer.Measure = { text, size, _ in (Double(text.count) * size * 0.6, size * 1.2) }
        let placed = placer.place(tiles: [([city, village, road, shield], m, 4096)], viewport: (400, 400), zoom: 15, reserved: [], measure: measure)
        let texts = placed.map { $0.text }
        XCTAssertTrue(texts.contains("Pforzheim"))
        XCTAssertFalse(texts.contains("Dorf"), "kollidierendes Label mit niedrigerer Priorität wird verdrängt")
        XCTAssertTrue(texts.contains("A8"))
        let r = placed.first { $0.text == "Calwer Straße" }!
        XCTAssertEqual(r.rotation, 0, accuracy: 1e-6, "Text bleibt lesbar (nicht kopfüber)")
        XCTAssertEqual(r.center.y, 300, accuracy: 1e-6)
        // Hervorhebung: Dorf gewinnt gegen Stadt
        placer.highlighted = ["Dorf"]
        let p2 = placer.place(tiles: [([city, village], m, 4096)], viewport: (400, 400), zoom: 15, reserved: [], measure: measure)
        XCTAssertEqual(p2.map { $0.text }, ["Dorf"])
        // Zoom-Sichtbarkeit: Dorf (Rang 5) erst ab Zoom 11
        placer.highlighted = []
        let p3 = placer.place(tiles: [([village], m, 4096)], viewport: (400, 400), zoom: 8, reserved: [], measure: measure)
        XCTAssertTrue(p3.isEmpty)
    }

    /// Aufgeräumter Navi-Look: wenige Straßennamen, wenige POIs – auch wenn Platz wäre.
    func testLabelBudgetsKeepMapSparse() {
        var m = Mat4.identity
        m[0, 0] = 2 / 2000; m[1, 1] = -2 / 2000; m[3, 0] = -1; m[3, 1] = 1
        // 30 verschiedene Nebenstraßen untereinander, 20 POIs in einer Reihe – kollisionsfrei
        var roads: [LabelCandidate] = []
        for i in 0..<30 {
            let y = Int32(60 + i * 60)
            roads.append(LabelCandidate(text: "Straße \(i)", kind: .road(.minor), path: [TilePoint(100, y), TilePoint(900, y)]))
        }
        var pois: [LabelCandidate] = []
        for i in 0..<20 {
            let x = Int32(1000 + i * 45)
            pois.append(LabelCandidate(text: "Tanke \(i)", kind: .poi, point: TilePoint(x, 1500)))
        }
        var placer = LabelPlacer()
        placer.options = .navigation
        placer.highlighted = ["Straße 29"]
        let measure: LabelPlacer.Measure = { text, size, _ in (Double(text.count) * size * 0.6, size * 1.2) }
        let placed = placer.place(tiles: [(roads + pois, m, 4096)], viewport: (2000, 2000), zoom: 16, reserved: [], measure: measure)
        let roadNames = placed.filter { if case .road = $0.kind { return true } else { return false } }.map { $0.text }
        let poiNames = placed.filter { $0.kind == LabelCandidate.Kind.poi }.map { $0.text }
        XCTAssertEqual(roadNames.count, LabelPlacer.Options.navigation.maxRoadLabels + 1, "Kontingent + hervorgehobene Straße")
        XCTAssertTrue(roadNames.contains("Straße 29"), "aktuelle Straße immer dabei")
        XCTAssertEqual(poiNames.count, LabelPlacer.Options.navigation.maxPOILabels)
        // Nebenstraßen erst ab KartoKit-Zoom 15 (≈ 16 in 256-px-Konvention)
        let p2 = placer.place(tiles: [(roads, m, 4096)], viewport: (2000, 2000), zoom: 14.5, reserved: [], measure: measure)
        XCTAssertEqual(p2.map { $0.text }, ["Straße 29"], "unter minZoom nur die hervorgehobene (aktuelle) Straße")
    }

    func testShieldShowsOnlyPrimaryRef() {
        XCTAssertEqual(LabelExtractor.primaryRef("A 8;A 81"), "A 8")
        XCTAssertEqual(LabelExtractor.primaryRef("B 10; B 294"), "B 10")
        XCTAssertEqual(LabelExtractor.primaryRef("A 5"), "A 5")
        XCTAssertNil(LabelExtractor.primaryRef(";"))
    }

    /// Echte OpenFreeMap-Kachel (Bad Teinach, z14): Dekodieren, Mesh im OpenMapTiles-Schema, Labels.
    func testOpenFreeMapTileDecodesAndBuilds() throws {
        let data = try Data(contentsOf: fixture("openfreemap-14-8586-5648", "pbf"))
        let vt = try VectorTileDecoder.decode(data)
        XCTAssertTrue(vt.layers.contains { $0.name == "transportation" })
        let mesh = TileMeshBuilder.build(tile: TileID(z: 14, x: 8586, y: 5648), vectorTile: vt, style: .openMapTiles(theme: .kartoKit(dark: false)))
        XCTAssertFalse(mesh.lines.isEmpty); XCTAssertFalse(mesh.fills.isEmpty)
        let labels = LabelExtractor.extract(from: vt, language: "de")
        XCTAssertTrue(labels.contains { $0.text == "Bad Teinach" })
        XCTAssertTrue(labels.contains { if case .road = $0.kind { return true } else { return false } })
        XCTAssertNil(LabelExtractor.primaryRef("L 621"), "Landesstraßen ohne Schild")
        // Overzoom: Auf der letzten Stufe der Quelle (OpenFreeMap z14) müssen auch Layer mit
        // höherem minZoom (Gebäude ab 16) gebaut werden – sonst bleibt die Karte beim
        // Hineinzoomen flach. Ohne `sourceMaxZoom` bleibt es beim alten Verhalten.
        let ohne = TileMeshBuilder.build(tile: TileID(z: 14, x: 8586, y: 5648), vectorTile: vt,
                                         style: .openMapTiles(theme: .kartoKit(dark: false)))
        let mit = TileMeshBuilder.build(tile: TileID(z: 14, x: 8586, y: 5648), vectorTile: vt,
                                        style: .openMapTiles(theme: .kartoKit(dark: false)), sourceMaxZoom: 14)
        XCTAssertFalse(ohne.extrusions.contains { $0.layerID == "building" }, "z14 < minZoom 16")
        XCTAssertTrue(mit.extrusions.contains { $0.layerID == "building" }, "überzoomte Kachel trägt Gebäude")
        // Stuttgart-Kachel: Seen ja, Springbrunnen nein; Ladesäulen nicht als POI
        let vt2 = try VectorTileDecoder.decode(try Data(contentsOf: fixture("openfreemap-14-8609-5642", "pbf")))
        let l2 = LabelExtractor.extract(from: vt2, language: "de")
        let water = l2.filter { $0.kind == .water }.map { $0.text }
        XCTAssertTrue(water.contains("Feuersee"), "\(water)")
        XCTAssertFalse(water.contains { $0.lowercased().contains("brunnen") }, "\(water)")
        XCTAssertFalse(l2.contains { $0.kind == .poi && $0.text.lowercased().contains("ladesäule") })
        XCTAssertNil(LabelExtractor.primaryRef("K 4512"))
        XCTAssertEqual(LabelExtractor.primaryRef("B 294"), "B 294")
    }

    func testLabelExtractionFromRealTile() async throws {
        let url = Bundle.module.url(forResource: "firenze", withExtension: "pmtiles", subdirectory: "Fixtures")!
        let source = try await PMTilesSource(url: url)
        let tile = TileID.containing(Mercator.project(Coordinate(latitude: 43.7696, longitude: 11.2558)), zoom: 15)
        let vt = try VectorTileDecoder.decode(try await source.tileData(tile)!)
        let labels = LabelExtractor.extract(from: vt, language: "de")
        let roads = labels.filter { if case .road = $0.kind { return true } else { return false } }
        XCTAssertGreaterThan(roads.count, 30, "Straßennamen im Zentrum von Florenz")
        XCTAssertTrue(roads.contains { $0.text.contains("Via") })
        XCTAssertTrue(roads.allSatisfy { ($0.path?.count ?? 0) >= 2 })
        let places = labels.filter { if case .place = $0.kind { return true } else { return false } }
        XCTAssertFalse(places.isEmpty)
    }

    // MARK: Disk-Cache

    struct CountingSource: TileSource {
        final class Box: @unchecked Sendable { var calls = 0 }
        let box = Box()
        var minZoom = 0; var maxZoom = 15
        var fail = false
        func tileData(_ id: TileID) async throws -> Data? {
            box.calls += 1
            if fail { throw PMTilesError.http(500) }
            return id.x % 2 == 0 ? Data("tile-\(id)".utf8) : nil
        }
    }

    func testCachedTileSource() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("karto-test-\(UUID().uuidString)")
        let inner = CountingSource()
        let cache = CachedTileSource(wrapping: inner, name: "t", maxBytes: 1 << 20, baseDirectory: dir)
        let a = TileID(z: 10, x: 2, y: 3), b = TileID(z: 10, x: 3, y: 3)
        let d1 = try await cache.tileData(a)
        XCTAssertEqual(d1, Data("tile-10/2/3".utf8))
        let d2 = try await cache.tileData(a)
        XCTAssertEqual(d2, d1)
        XCTAssertEqual(inner.box.calls, 1, "zweiter Zugriff aus dem Cache")
        let n1 = try await cache.tileData(b)
        XCTAssertNil(n1)
        let n2 = try await cache.tileData(b)
        XCTAssertNil(n2)
        XCTAssertEqual(inner.box.calls, 2, "leere Kachel gemerkt")
        // Offline: gecachte Kachel trotz Fehler der Quelle
        var failing = CountingSource(); failing.fail = true
        let cache2 = CachedTileSource(wrapping: failing, name: "t", maxBytes: 1 << 20, maxAge: 0, baseDirectory: dir)
        let d3 = try await cache2.tileData(a)
        XCTAssertEqual(d3, d1)
        try? FileManager.default.removeItem(at: dir)
    }
}
