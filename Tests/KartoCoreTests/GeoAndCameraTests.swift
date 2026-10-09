import XCTest
@testable import KartoCore

final class GeoAndCameraTests: XCTestCase {

    func testMercatorRoundTrip() {
        let c = Coordinate(latitude: 48.8917, longitude: 8.6981) // Pforzheim
        let p = Mercator.project(c)
        let back = Mercator.unproject(p)
        XCTAssertEqual(back.latitude, c.latitude, accuracy: 1e-9)
        XCTAssertEqual(back.longitude, c.longitude, accuracy: 1e-9)
        XCTAssertEqual(Mercator.project(Coordinate(latitude: 0, longitude: 0)).x, 0.5, accuracy: 1e-12)
        XCTAssertEqual(Mercator.project(Coordinate(latitude: 0, longitude: 0)).y, 0.5, accuracy: 1e-12)
    }

    func testTileIDBasics() {
        let p = Mercator.project(Coordinate(latitude: 48.8917, longitude: 8.6981))
        let t = TileID.containing(p, zoom: 14)
        XCTAssertEqual(t.z, 14)
        XCTAssertTrue(t.contains(p))
        XCTAssertEqual(t.parent?.children.contains(t), true)
        // Bekannte Kachel: Pforzheim z14 = 8587/5634 (Slippy-Map-Formel)
        XCTAssertEqual(t.x, 8587)
        XCTAssertEqual(t.y, 5634)
    }

    func testHilbertTileIDs() {
        // Referenzwerte aus der PMTiles-Spezifikation / pmtiles-js Tests
        XCTAssertEqual(TileID(z: 0, x: 0, y: 0).pmtilesID, 0)
        XCTAssertEqual(TileID(z: 1, x: 0, y: 0).pmtilesID, 1)
        XCTAssertEqual(TileID(z: 1, x: 0, y: 1).pmtilesID, 2)
        XCTAssertEqual(TileID(z: 1, x: 1, y: 1).pmtilesID, 3)
        XCTAssertEqual(TileID(z: 1, x: 1, y: 0).pmtilesID, 4)
        XCTAssertEqual(TileID(z: 2, x: 0, y: 0).pmtilesID, 5)
        XCTAssertEqual(TileID(z: 12, x: 3423, y: 1763).pmtilesID, 19_078_479)
    }

    func testMatrixInverse() {
        let m = Mat4.translation(3, -2, 5) * Mat4.rotationZ(0.7) * Mat4.scale(2, 2, 2)
        let inv = m.inverse!
        let id = m * inv
        for c in 0..<4 { for r in 0..<4 {
            XCTAssertEqual(id[c, r], c == r ? 1 : 0, accuracy: 1e-9)
        } }
    }

    func testProjectionCenterAndOrientation() {
        let cam = MapCamera(coordinate: Coordinate(latitude: 48.89, longitude: 8.70), zoom: 15)
        let vp = ViewProjection(camera: cam, width: 400, height: 800)
        let center = cam.center * vp.worldSize
        let s = vp.project(worldPixel: Vec3(center.x, center.y, 0))!
        XCTAssertEqual(s.x, 200, accuracy: 1e-6)
        XCTAssertEqual(s.y, 400, accuracy: 1e-6)

        // Ohne Neigung: 100 Welt-Pixel nach Osten = 100 Bildschirm-Punkte nach rechts,
        // 100 nach Süden = 100 nach unten.
        let east = vp.project(worldPixel: Vec3(center.x + 100, center.y, 0))!
        XCTAssertEqual(east.x, 300, accuracy: 1e-6)
        XCTAssertEqual(east.y, 400, accuracy: 1e-6)
        let south = vp.project(worldPixel: Vec3(center.x, center.y + 100, 0))!
        XCTAssertEqual(south.y, 500, accuracy: 1e-6)

        // Höhe über Boden verschiebt nach oben (bei Pitch) – bei Pitch 0 nur Skalierung um die Mitte.
        let up = vp.project(worldPixel: Vec3(center.x + 100, center.y, 50))!
        XCTAssertGreaterThan(up.x, 300)
    }

    func testBearingRotatesEastToTop() {
        let cam = MapCamera(coordinate: Coordinate(latitude: 48.89, longitude: 8.70), zoom: 15, bearing: 90)
        let vp = ViewProjection(camera: cam, width: 400, height: 800)
        let center = cam.center * vp.worldSize
        let east = vp.project(worldPixel: Vec3(center.x + 100, center.y, 0))!
        XCTAssertEqual(east.x, 200, accuracy: 1e-6)
        XCTAssertEqual(east.y, 300, accuracy: 1e-6) // oben
    }

    func testPitchPushesNorthIntoDistance() {
        let cam = MapCamera(coordinate: Coordinate(latitude: 48.89, longitude: 8.70), zoom: 15, pitch: 60)
        let vp = ViewProjection(camera: cam, width: 400, height: 800)
        let center = cam.center * vp.worldSize
        let n1 = vp.project(worldPixel: Vec3(center.x, center.y - 100, 0))!
        let n2 = vp.project(worldPixel: Vec3(center.x, center.y - 200, 0))!
        XCTAssertLessThan(n1.y, 400)                 // Norden liegt oben
        XCTAssertLessThan(n2.y, n1.y)                // weiter nördlich = weiter oben
        XCTAssertLessThan(n1.y - n2.y, 400 - n1.y)   // … aber perspektivisch gestaucht
        // Gebäude ragen nach oben
        let tall = vp.project(worldPixel: Vec3(center.x, center.y, 100))!
        XCTAssertLessThan(tall.y, 400)
    }

    func testUnprojectRoundTrip() {
        let cam = MapCamera(coordinate: Coordinate(latitude: 48.89, longitude: 8.70), zoom: 16, bearing: 35, pitch: 55)
        let vp = ViewProjection(camera: cam, width: 390, height: 844)
        for s in [Vec2(195, 422), Vec2(20, 800), Vec2(370, 600), Vec2(100, 500)] {
            let g = vp.unprojectToGround(screen: s)!
            let back = vp.project(worldPixel: Vec3(g.x, g.y, 0))!
            XCTAssertEqual(back.x, s.x, accuracy: 1e-4)
            XCTAssertEqual(back.y, s.y, accuracy: 1e-4)
        }
        // Über dem Horizont (Pitch + halbes FOV > 90°): kein Bodenpunkt
        let camFlat = MapCamera(coordinate: Coordinate(latitude: 48.89, longitude: 8.70), zoom: 16, pitch: 80)
        let vp2 = ViewProjection(camera: camFlat, width: 390, height: 844)
        XCTAssertNil(vp2.unprojectToGround(screen: Vec2(195, 0)))
        XCTAssertNotNil(vp2.unprojectToGround(screen: Vec2(195, 844)))
    }

    func testTileMatrixMapsTileCornerToWorld() {
        let cam = MapCamera(coordinate: Coordinate(latitude: 48.89, longitude: 8.70), zoom: 14.5, bearing: 20, pitch: 40)
        let vp = ViewProjection(camera: cam, width: 390, height: 844)
        let tile = TileID.containing(cam.center, zoom: 14)
        let m = vp.tileMatrix(for: tile, extent: 4096)
        // Kachelursprung über tileMatrix vs. direkt über viewProjection
        let a = m * Vec4(0, 0, 0, 1)
        let o = tile.origin * vp.worldSize
        let b = vp.viewProjection * Vec4(o.x, o.y, 0, 1)
        XCTAssertEqual(a.x / a.w, b.x / b.w, accuracy: 1e-9)
        XCTAssertEqual(a.y / a.w, b.y / b.w, accuracy: 1e-9)
        // Kachelende (4096) = Ursprung + Kachelgröße auf aktuellem Zoom
        let c = m * Vec4(4096, 4096, 0, 1)
        let size = Mercator.tileSize * pow(2.0, 0.5)
        let d = vp.viewProjection * Vec4(o.x + size, o.y + size, 0, 1)
        XCTAssertEqual(c.x / c.w, d.x / d.w, accuracy: 1e-9)
        XCTAssertEqual(c.y / c.w, d.y / d.w, accuracy: 1e-9)
    }

    func testCoverageFlatView() {
        let cam = MapCamera(coordinate: Coordinate(latitude: 48.89, longitude: 8.70), zoom: 14.3)
        let vp = ViewProjection(camera: cam, width: 390, height: 844)
        let tiles = TileCoverage.coveringTiles(vp)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertTrue(tiles.allSatisfy { $0.z == 14 })
        XCTAssertTrue(tiles.contains(TileID.containing(cam.center, zoom: 14)))
        XCTAssertLessThanOrEqual(tiles.count, 12)
    }

    func testCoveragePitchedViewUsesLOD() {
        let cam = MapCamera(coordinate: Coordinate(latitude: 48.89, longitude: 8.70), zoom: 15.2, pitch: 65)
        let vp = ViewProjection(camera: cam, width: 390, height: 844)
        var opts = TileCoverage.Options()
        opts.maxZoom = 15
        let tiles = TileCoverage.coveringTiles(vp, options: opts)
        XCTAssertFalse(tiles.isEmpty)
        XCTAssertLessThanOrEqual(tiles.count, opts.maxTiles)
        let zooms = Set(tiles.map { $0.z })
        XCTAssertTrue(zooms.contains(15), "Vordergrund in voller Auflösung")
        XCTAssertGreaterThan(zooms.count, 1, "Ferne in gröberen Kacheln: \(zooms)")
        XCTAssertTrue(tiles.contains(TileID.containing(cam.center, zoom: 15)))
        // Keine Überlappungen: keine Kachel darf Vorfahre einer anderen sein
        let set = Set(tiles)
        for t in tiles {
            var p = t.parent
            while let pp = p { XCTAssertFalse(set.contains(pp), "\(pp) überdeckt \(t)"); p = pp.parent }
        }
    }

    func testZoomStops() {
        let s = ZoomStops([(10, 1), (14, 4)], base: 1)
        XCTAssertEqual(s.value(at: 8), 1)
        XCTAssertEqual(s.value(at: 12), 2.5, accuracy: 1e-9)
        XCTAssertEqual(s.value(at: 20), 4)
        let e = ZoomStops([(10, 1), (14, 4)], base: 2)
        XCTAssertLessThan(e.value(at: 12), 2.5) // exponentiell: langsamer Start
    }

    func testVisibleBoundsFlatAndPitched() {
        let c = Coordinate(latitude: 48.89, longitude: 8.70)
        let flat = ViewProjection(camera: MapCamera(coordinate: c, zoom: 14, bearing: 0, pitch: 0), width: 400, height: 800)
        let b = flat.visibleBounds()
        XCTAssertTrue(b.contains(c))
        XCTAssertLessThan(b.maxLatitude - b.minLatitude, 0.1)
        XCTAssertGreaterThan(b.maxLatitude - b.minLatitude, 0.01)
        // Geneigt: Horizont wird auf 30 km begrenzt, Box bleibt endlich und enthält die Mitte
        let pitched = ViewProjection(camera: MapCamera(coordinate: c, zoom: 12, bearing: 30, pitch: 60), width: 400, height: 800)
        let pb = pitched.visibleBounds(maxDistanceMeters: 30_000)
        XCTAssertTrue(pb.contains(c))
        XCTAssertLessThan(pb.maxLatitude - pb.minLatitude, 0.6)
        XCTAssertTrue(pb.expanded(by: 1.5).contains(pb))
    }
}
