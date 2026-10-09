import XCTest
@testable import KartoCore

final class TessellationTests: XCTestCase {

    func testEarcutSquare() {
        let data: [Double] = [0, 0, 10, 0, 10, 10, 0, 10]
        let tri = Earcut.triangulate(data)
        XCTAssertEqual(tri.count, 6)
        XCTAssertEqual(Earcut.deviation(data, holeIndices: [], triangles: tri), 0, accuracy: 1e-12)
    }

    func testEarcutWithHole() {
        let data: [Double] = [0, 0, 100, 0, 100, 100, 0, 100,   20, 20, 20, 80, 80, 80, 80, 20]
        let tri = Earcut.triangulate(data, holeIndices: [4])
        XCTAssertEqual(tri.count % 3, 0)
        XCTAssertEqual(tri.count / 3, 8) // 4 Punkte außen + 4 innen → 8 Dreiecke
        XCTAssertEqual(Earcut.deviation(data, holeIndices: [4], triangles: tri), 0, accuracy: 1e-12)
    }

    func testEarcutConcaveAndLarge() {
        // Sternförmiges Polygon mit vielen Punkten → aktiviert Z-Order-Hashing (> 80 Punkte)
        var data: [Double] = []
        let n = 200
        for i in 0..<n {
            let a = Double(i) / Double(n) * 2 * .pi
            let r = i % 2 == 0 ? 100.0 : 55.0
            data.append(100 + r * cos(a)); data.append(100 + r * sin(a))
        }
        let tri = Earcut.triangulate(data)
        XCTAssertEqual(tri.count / 3, n - 2)
        XCTAssertLessThan(Earcut.deviation(data, holeIndices: [], triangles: tri), 1e-9)
    }

    func testEarcutDegenerate() {
        XCTAssertTrue(Earcut.triangulate([0, 0, 1, 1]).isEmpty)
        XCTAssertTrue(Earcut.triangulate([0, 0, 5, 5, 10, 10]).isEmpty) // kollinear
    }

    func testLineTessellation() {
        var b = MeshBucket<LineVertex>(layerID: "l")
        LineTessellator.tessellate([TilePoint(0, 0), TilePoint(100, 0), TilePoint(100, 100)], into: &b)
        // Streifen (zwei Vertizes je Stuetzpunkt) plus eine runde Kappe je
        // Ende. Als Formel statt als Zahl: sonst sagt ein spaeterer
        // Fehlschlag nur, dass sich etwas geaendert hat, nicht was.
        let jeKappe = 2 + LineTessellator.rundungsEcken   // Mitte + Kranz
        XCTAssertEqual(b.vertices.count, 3 * 2 + 2 * jeKappe)
        XCTAssertEqual(b.indices.count, 2 * 6 + 2 * LineTessellator.rundungsEcken * 3)
        // Die Kappe liegt auf dem Endpunkt, ihr Kranz auf dem Einheitskreis:
        // im Shader wird daraus eine Scheibe mit dem Radius der halben Breite.
        let kappe = b.vertices[6]
        XCTAssertEqual(Double(kappe.x), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(kappe.y), 0, accuracy: 1e-6)
        for k in 7..<(6 + jeKappe) {
            let v = b.vertices[k]
            XCTAssertEqual(Double((v.nx * v.nx + v.ny * v.ny).squareRoot()), 1, accuracy: 1e-6)
        }
        // Endnormale senkrecht zum Segment, Länge 1
        let v0 = b.vertices[0]
        XCTAssertEqual(abs(v0.nx), 0, accuracy: 1e-6)
        XCTAssertEqual(abs(v0.ny), 1, accuracy: 1e-6)
        // Miter am 90°-Knick: Länge √2
        let v2 = b.vertices[2]
        XCTAssertEqual(Double((v2.nx * v2.nx + v2.ny * v2.ny).squareRoot()), 2.0.squareRoot(), accuracy: 1e-5)
        // Nullsegmente werden ignoriert
        var c = MeshBucket<LineVertex>(layerID: "l")
        LineTessellator.tessellate([TilePoint(0, 0), TilePoint(0, 0)], into: &c)
        XCTAssertTrue(c.isEmpty)
    }

    func testExtrusion() {
        var b = MeshBucket<ExtrusionVertex>(layerID: "b")
        let square = [TilePoint(0, 0), TilePoint(10, 0), TilePoint(10, 10), TilePoint(0, 10), TilePoint(0, 0)]
        PolygonTessellator.extrude([square], base: 0, height: 5, into: &b)
        // 4 Wände à 4 Vertices + Dach 4 Vertices
        XCTAssertEqual(b.vertices.count, 20)
        XCTAssertEqual(b.indices.count, 4 * 6 + 6)
        // Obere Kante (0,0)-(10,0) im Uhrzeigersinn: Außennormale zeigt nach oben (−y)
        XCTAssertEqual(b.vertices[0].ny, -1, accuracy: 1e-6)
        XCTAssertEqual(b.vertices[0].nx, 0, accuracy: 1e-6)
        XCTAssertEqual(b.vertices[2].z, 5)
        XCTAssertEqual(b.vertices[16].nz, 1)
        // Basis ≥ Höhe → nichts
        var e = MeshBucket<ExtrusionVertex>(layerID: "b")
        PolygonTessellator.extrude([square], base: 5, height: 5, into: &e)
        XCTAssertTrue(e.isEmpty)
    }

    /// Der Ton muss in JEDEM Vertex stehen — Wände wie Dach. Steht er nur
    /// in den Wänden, bekommt dasselbe Haus ein Dach in einer anderen
    /// Helligkeit als seine Mauern.
    func testExtrusionTonInAllenVertices() {
        var b = MeshBucket<ExtrusionVertex>(layerID: "b")
        let square = [TilePoint(0, 0), TilePoint(10, 0), TilePoint(10, 10), TilePoint(0, 10), TilePoint(0, 0)]
        PolygonTessellator.extrude([square], base: 0, height: 5, ton: 0.5, into: &b)
        XCTAssertEqual(b.vertices.count, 20)
        for v in b.vertices {
            XCTAssertEqual(v.ton, 0.5, accuracy: 1e-6)
        }
        // Ohne Angabe bleibt es bei der reinen Themefarbe.
        var o = MeshBucket<ExtrusionVertex>(layerID: "b")
        PolygonTessellator.extrude([square], base: 0, height: 5, into: &o)
        XCTAssertTrue(o.vertices.allSatisfy { $0.ton == 0 })
    }

    /// Dieselbe Id ergibt denselben Ton, unabhängig von der Geometrie.
    /// Das ist die Eigenschaft, an der die Zoomstabilität hängt: In der
    /// z17-Kachel hat dasselbe Haus andere Koordinaten.
    func testGebaeudeTonHaengtAnDerIdNichtAnDerGeometrie() {
        let ring16 = [TilePoint(10, 10), TilePoint(20, 10), TilePoint(20, 20), TilePoint(10, 10)]
        let ring17 = [TilePoint(2048, 300), TilePoint(2068, 300), TilePoint(2068, 320), TilePoint(2048, 300)]
        let a = VectorTileFeature(id: 4711, type: .polygon, properties: [:], rings: [ring16])
        let b = VectorTileFeature(id: 4711, type: .polygon, properties: [:], rings: [ring17])
        XCTAssertEqual(TileMeshBuilder.gebaeudeTon(a), TileMeshBuilder.gebaeudeTon(b))

        // Verschiedene Häuser müssen sich unterscheiden — sonst war die
        // ganze Übung umsonst.
        let c = VectorTileFeature(id: 4712, type: .polygon, properties: [:], rings: [ring16])
        XCTAssertNotEqual(TileMeshBuilder.gebaeudeTon(a), TileMeshBuilder.gebaeudeTon(c))
    }

    /// Fortlaufende Ids (eine Strasse in OSM) duerfen keinen Verlauf
    /// ergeben, sondern muessen streuen — und der Wert muss im Bereich
    /// bleiben, mit dem der Shader rechnet.
    func testGebaeudeTonStreutUndBleibtImBereich() {
        var werte: [Float] = []
        for id in UInt64(1000)...UInt64(1200) {
            let f = VectorTileFeature(id: id, type: .polygon, properties: [:], rings: [])
            let t = TileMeshBuilder.gebaeudeTon(f)
            XCTAssertGreaterThanOrEqual(t, -1)
            XCTAssertLessThan(t, 1)
            werte.append(t)
        }
        // Beide Hälften des Bereichs sind besetzt, und aufeinander
        // folgende Ids liegen im Mittel weit auseinander. Ein Verlauf
        // wuerde beides verfehlen.
        XCTAssertTrue(werte.contains { $0 < -0.5 })
        XCTAssertTrue(werte.contains { $0 > 0.5 })
        let spruenge = zip(werte, werte.dropFirst()).map { abs($0 - $1) }
        let mittel = spruenge.reduce(0, +) / Float(spruenge.count)
        XCTAssertGreaterThan(mittel, 0.4)

        // Ohne Id und ohne Geometrie bleibt es bei der Themefarbe.
        let leer = VectorTileFeature(id: nil, type: .polygon, properties: [:], rings: [])
        XCTAssertEqual(TileMeshBuilder.gebaeudeTon(leer), 0)
    }

    func testPolygonGroupingByOrientation() {
        // Äußerer Ring im Uhrzeigersinn (y↓), Loch gegen den Uhrzeigersinn
        let outer = [TilePoint(0, 0), TilePoint(10, 0), TilePoint(10, 10), TilePoint(0, 10), TilePoint(0, 0)]
        let hole = [TilePoint(2, 2), TilePoint(2, 8), TilePoint(8, 8), TilePoint(8, 2), TilePoint(2, 2)]
        let f = VectorTileFeature(id: nil, type: .polygon, properties: [:], rings: [outer, hole, outer])
        XCTAssertGreaterThan(VectorTileFeature.signedArea(outer), 0)
        XCTAssertLessThan(VectorTileFeature.signedArea(hole), 0)
        let polys = f.polygons
        XCTAssertEqual(polys.count, 2)
        XCTAssertEqual(polys[0].count, 2)
        XCTAssertEqual(polys[1].count, 1)
    }
}
