import XCTest
@testable import KartoCore

/// Integrationstests gegen ein echtes PMTiles-Archiv (Protomaps-Basemap Florenz, ODbL).
final class PMTilesAndMVTTests: XCTestCase {

    var fixtureURL: URL {
        Bundle.module.url(forResource: "firenze", withExtension: "pmtiles", subdirectory: "Fixtures")!
    }

    static let florence = Coordinate(latitude: 43.7696, longitude: 11.2558) // Dom

    func testHeaderAndDirectory() async throws {
        let archive = PMTilesArchive(url: fixtureURL)
        let h = try await archive.open()
        XCTAssertEqual(h.tileType, .mvt)
        XCTAssertEqual(h.tileCompression, .gzip)
        XCTAssertEqual(h.minZoom, 0)
        XCTAssertEqual(h.maxZoom, 15)
        XCTAssertTrue(h.clustered)
        XCTAssertEqual(h.centerLat, 43.7672134, accuracy: 1e-6)
    }

    func testDirectoryLookupBinarySearch() {
        let dir = [
            PMTilesEntry(tileID: 0, offset: 0, length: 10, runLength: 1),
            PMTilesEntry(tileID: 5, offset: 10, length: 10, runLength: 3),   // deckt 5,6,7
            PMTilesEntry(tileID: 20, offset: 20, length: 10, runLength: 1),
        ]
        XCTAssertEqual(PMTilesArchive.find(0, in: dir)?.offset, 0)
        XCTAssertEqual(PMTilesArchive.find(6, in: dir)?.offset, 10)
        XCTAssertEqual(PMTilesArchive.find(7, in: dir)?.offset, 10)
        XCTAssertNil(PMTilesArchive.find(8, in: dir))
        XCTAssertNil(PMTilesArchive.find(3, in: dir))
        XCTAssertEqual(PMTilesArchive.find(20, in: dir)?.offset, 20)
        XCTAssertNil(PMTilesArchive.find(21, in: dir))
    }

    func testFetchAndDecodeTile() async throws {
        let source = try await PMTilesSource(url: fixtureURL)
        let tile = TileID.containing(Mercator.project(Self.florence), zoom: 15)
        let data = try await source.tileData(tile)
        XCTAssertNotNil(data)
        XCTAssertFalse(Gzip.isGzipped(data!), "Tile muss dekomprimiert geliefert werden")

        let vt = try VectorTileDecoder.decode(data!)
        let names = Set(vt.layers.map { $0.name })
        XCTAssertTrue(names.contains("roads"), "\(names)")
        XCTAssertTrue(names.contains("buildings"), "\(names)")
        XCTAssertTrue(names.contains("water"), "\(names)")

        let roads = vt.layer(named: "roads")!
        XCTAssertEqual(roads.extent, 4096)
        XCTAssertGreaterThan(roads.features.count, 100)
        XCTAssertTrue(roads.features.allSatisfy { $0.type == .lineString })
        let kinds = Set(roads.features.compactMap { ($0.properties["pmap:kind"] ?? $0.properties["kind"])?.stringValue })
        XCTAssertTrue(kinds.contains("major_road") || kinds.contains("minor_road"), "\(kinds)")

        let buildings = vt.layer(named: "buildings")!
        XCTAssertGreaterThan(buildings.features.count, 500)
        XCTAssertTrue(buildings.features.allSatisfy { $0.type == .polygon })
        // Geometrien liegen innerhalb Extent + Puffer
        for f in buildings.features.prefix(200) {
            for ring in f.rings {
                XCTAssertGreaterThanOrEqual(ring.count, 4)
                XCTAssertEqual(ring.first, ring.last, "Polygonringe müssen geschlossen sein")
                for p in ring {
                    XCTAssertTrue(p.x >= -512 && p.x <= 4608 && p.y >= -512 && p.y <= 4608)
                }
            }
        }
        // Mindestens ein Gebäude mit Höhenattribut
        XCTAssertTrue(buildings.features.contains { $0.properties["height"]?.doubleValue != nil })
    }

    func testMissingTileReturnsNil() async throws {
        let source = try await PMTilesSource(url: fixtureURL)
        // Pforzheim liegt nicht im Florenz-Archiv
        let tile = TileID.containing(Mercator.project(Coordinate(latitude: 48.89, longitude: 8.70)), zoom: 14)
        let data = try await source.tileData(tile)
        XCTAssertNil(data)
        let over = try await source.tileData(TileID(z: 16, x: 0, y: 0))
        XCTAssertNil(over, "über maxZoom")
    }

    func testBuildMeshFromRealTile() async throws {
        let source = try await PMTilesSource(url: fixtureURL)
        // Das Archiv reicht nur bis Zoom 15, die Gebaeudeschicht beginnt bei
        // 16. Die Kachelkennung entscheidet, welche Stilschichten greifen —
        // die Geometrie kommt aus den Daten. Also die Bytes von z15 unter
        // einer z16-Kennung bauen: Was hier geprueft wird, ist die
        // Extrusion, nicht die Kachelauswahl.
        let quelle = TileID.containing(Mercator.project(Self.florence), zoom: 15)
        let tile = TileID(z: 16, x: quelle.x * 2, y: quelle.y * 2)
        let vt = try VectorTileDecoder.decode(try await source.tileData(quelle)!)

        let start = Date()
        let mesh = TileMeshBuilder.build(tile: tile, vectorTile: vt,
                                         style: .protomaps(theme: .cleanWhite, extrudeBuildings: true))
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(mesh.fills.isEmpty)
        XCTAssertFalse(mesh.lines.isEmpty)
        XCTAssertFalse(mesh.extrusions.isEmpty)
        XCTAssertEqual(mesh.drawOrder.count, mesh.fills.count + mesh.lines.count + mesh.extrusions.count)

        let ext = try XCTUnwrap(mesh.extrusions.first,
                                "Keine Extrusion gebaut — Stilschicht oder Zoomfenster?")
        XCTAssertEqual(ext.indices.count % 3, 0)
        XCTAssertTrue(ext.indices.allSatisfy { Int($0) < ext.vertices.count })
        // Höhen plausibel: Florenz-Dom ~ 100 m; Tile-Einheit auf z15 ≈ 0.25 m → z < 2000
        let maxZ = ext.vertices.map { $0.z }.max()!
        XCTAssertGreaterThan(maxZ, 10)
        XCTAssertLessThan(maxZ, 2000)

        for l in mesh.lines {
            XCTAssertTrue(l.indices.allSatisfy { Int($0) < l.vertices.count }, l.layerID)
        }
        for f in mesh.fills {
            XCTAssertTrue(f.indices.allSatisfy { Int($0) < f.vertices.count }, f.layerID)
        }
        print("Mesh z15 Florenz: \(mesh.vertexBytes / 1024) KB Vertices, \(mesh.drawOrder.count) Draw-Calls, \(Int(elapsed * 1000)) ms (Debug-Build)")
    }

    func testEarcutOnRealBuildingsHasLowDeviation() async throws {
        let source = try await PMTilesSource(url: fixtureURL)
        let tile = TileID.containing(Mercator.project(Self.florence), zoom: 15)
        let vt = try VectorTileDecoder.decode(try await source.tileData(tile)!)
        var checked = 0
        for f in vt.layer(named: "buildings")!.features {
            for poly in f.polygons {
                let (data, holes) = PolygonTessellator.flatten(poly)
                guard data.count >= 6 else { continue }
                let tri = Earcut.triangulate(data, holeIndices: holes)
                let dev = Earcut.deviation(data, holeIndices: holes, triangles: tri)
                XCTAssertLessThan(dev, 0.05, "Feature \(f.id ?? 0): Abweichung \(dev)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 300)
    }

    func testVarintAndZigzag() {
        XCTAssertEqual(ProtobufReader.zigzag(0), 0)
        XCTAssertEqual(ProtobufReader.zigzag(1), -1)
        XCTAssertEqual(ProtobufReader.zigzag(2), 1)
        XCTAssertEqual(ProtobufReader.zigzag(3), -2)
        let bytes: [UInt8] = [0xAC, 0x02] // 300
        bytes.withUnsafeBufferPointer { buf in
            var r = ProtobufReader(buf)
            XCTAssertEqual(try? r.readVarint(), 300)
            XCTAssertTrue(r.isAtEnd)
        }
    }

    func testGeometryCommandDecoding() {
        // Beispiel aus der MVT-Spec: MoveTo(1,1), LineTo(2,0), LineTo(0,2), ClosePath → Dreieck (1,1)(3,1)(3,3)
        let cmds: [UInt32] = [9, 2, 2, 18, 4, 0, 0, 4, 15]
        let rings = VectorTileDecoder.decodeGeometry(cmds, type: .polygon)
        XCTAssertEqual(rings.count, 1)
        XCTAssertEqual(rings[0], [TilePoint(1, 1), TilePoint(3, 1), TilePoint(3, 3), TilePoint(1, 1)])
        // Multipoint: MoveTo mit count 2
        let pts = VectorTileDecoder.decodeGeometry([17, 10, 14, 3, 9], type: .point)
        XCTAssertEqual(pts, [[TilePoint(5, 7), TilePoint(3, 2)]])
    }
}
