import Foundation

/// Baut aus einer dekodierten Vector-Tile und einem Style die GPU-fertigen Buckets.
/// Läuft komplett off-main-thread (reine Wertetypen, keine GPU-Abhängigkeit) und
/// ist der teuerste CPU-Schritt der Pipeline – daher hier keine Allokationen pro
/// Feature außer den Vertex-Arrays selbst.
public enum TileMeshBuilder {

    /// Bevorzugte Sprache für Beschriftungen (`name:<language>`), nil = `name`.
    nonisolated(unsafe) public static var labelLanguage: String? = Locale.current.language.languageCode?.identifier

    /// - Parameter sourceMaxZoom: Höchste Zoomstufe, die die Kachelquelle liefert. Auf dieser
    ///   Stufe wird überzoomt (die Kachel bleibt beim Hineinzoomen stehen), deshalb müssen dann
    ///   auch Layer mit höherem `minZoom` – Gebäude, Wege, Hausnummern – aus ihr gebaut werden.
    ///   Der Renderer blendet sie weiterhin erst ab ihrer eigenen Stufe ein
    ///   (`cam.zoom + 1 > layer.minZoom`). `nil` = wie bisher nur bis zur Kachelstufe.
    public static func build(tile: TileID, vectorTile: VectorTile, style: MapStyle, sourceMaxZoom: Int? = nil) -> TileMesh {
        let extent = vectorTile.layers.first?.extent ?? 4096
        var mesh = TileMesh(tile: tile, extent: extent, fills: [], lines: [], extrusions: [], drawOrder: [])
        mesh.labels = LabelExtractor.extract(from: vectorTile, language: labelLanguage)

        // Meter → Tile-Einheiten für Gebäudehöhen.
        let metersPerTileUnit = Mercator.metersPerUnit(latitude: tile.centerLatitude) * tile.extent / Double(extent)
        // Überzoomte Kacheln (letzte Stufe der Quelle) tragen alle Detailstufen.
        let ueberzoomt = sourceMaxZoom.map { tile.z >= $0 } ?? false
        let tileZoom = ueberzoomt ? Double.infinity : Double(tile.z)

        // Index nach Source-Layer, damit jeder Style-Layer nur "seine" Features sieht.
        var layersByName: [String: VectorTileLayer] = [:]
        for l in vectorTile.layers { layersByName[l.name] = l }

        for styleLayer in style.layers {
            // Kachel liegt außerhalb des Zoombereichs des Layers → überspringen.
            // (maxZoom wird großzügig geprüft: Overzoom soll weiterhin zeichnen.)
            guard tileZoom + 1 > styleLayer.minZoom else { continue }
            guard let source = layersByName[styleLayer.sourceLayer] else { continue }

            switch styleLayer.paint {
            case .fill:
                var bucket = MeshBucket<FillVertex>(layerID: styleLayer.id)
                for f in source.features where f.type == .polygon && styleLayer.matches(f) {
                    for poly in f.polygons { PolygonTessellator.fill(poly, into: &bucket) }
                }
                if !bucket.isEmpty {
                    mesh.drawOrder.append((.fill, mesh.fills.count))
                    mesh.fills.append(bucket)
                }

            case .line:
                var bucket = MeshBucket<LineVertex>(layerID: styleLayer.id)
                // Ein Gedaechtnis je Bucket: wo zwei Features denselben
                // Endpunkt haben, reicht eine Rundung fuer beide.
                var gerundet: Set<TilePoint> = []
                for f in source.features where styleLayer.matches(f) {
                    switch f.type {
                    case .lineString:
                        for line in f.rings {
                            LineTessellator.tessellate(line, into: &bucket, bereitsGerundet: &gerundet)
                        }
                    case .polygon:
                        // Umrisslinien von Flächen (z. B. Wasserkanten)
                        for ring in f.rings {
                            LineTessellator.tessellate(ring, into: &bucket, bereitsGerundet: &gerundet)
                        }
                    default: break
                    }
                }
                if !bucket.isEmpty {
                    mesh.drawOrder.append((.line, mesh.lines.count))
                    mesh.lines.append(bucket)
                }

            case .extrusion(_, let heightKey, let baseKey, let defaultHeight):
                var bucket = MeshBucket<ExtrusionVertex>(layerID: styleLayer.id)
                for f in source.features where f.type == .polygon && styleLayer.matches(f) {
                    let h = f.properties[heightKey]?.doubleValue ?? defaultHeight
                    let b = baseKey.flatMap { f.properties[$0]?.doubleValue } ?? 0
                    let top = max(h, b + 0.1) / metersPerTileUnit
                    let bottom = b / metersPerTileUnit
                    // Nur Gebaeude zeichnen, deren Schwerpunkt in DIESER
                    // Kachel liegt.
                    //
                    // Vektorkacheln tragen einen Rand: Ein Haus an der
                    // Kachelgrenze steckt vollstaendig in beiden
                    // Nachbarkacheln. Beide zeichneten es, deckungsgleich
                    // und mit demselben Tiefenwert — und welche Flaeche
                    // gewinnt, entscheidet dann die Rundung. Beim
                    // Vorbeifahren kippt das von Bild zu Bild: Das Dach
                    // flackert. Grosse Gebaeude trifft es am oefsten,
                    // weil sie Kachelgrenzen haeufiger schneiden.
                    //
                    // Der Schwerpunkt gehoert genau einer Kachel, das Haus
                    // wird also genau einmal gezeichnet — und zwar ganz,
                    // denn die Geometrie darf ueber den Rand hinausragen.
                    guard schwerpunktInKachel(f, extent: extent) else { continue }
                    let ton = gebaeudeTon(f)
                    for poly in f.polygons {
                        PolygonTessellator.extrude(poly, base: bottom, height: top,
                                                   ton: ton, into: &bucket)
                    }
                }
                if !bucket.isEmpty {
                    mesh.drawOrder.append((.extrusion, mesh.extrusions.count))
                    mesh.extrusions.append(bucket)
                }
            }
        }
        return mesh
    }

    /// Liegt der Schwerpunkt des ersten Rings in der Kachel?
    ///
    /// Gerechnet auf dem ersten Ring, nicht auf allen: Der aeussere Ring
    /// bestimmt die Lage, Loecher verschieben sie nicht.
    static func schwerpunktInKachel(_ f: VectorTileFeature, extent: Int) -> Bool {
        guard let ring = f.rings.first, !ring.isEmpty else { return false }
        var sx = 0.0, sy = 0.0
        for p in ring { sx += Double(p.x); sy += Double(p.y) }
        let n = Double(ring.count)
        let x = sx / n, y = sy / n
        return x >= 0 && y >= 0 && x < Double(extent) && y < Double(extent)
    }

    /// Die Tonstreuung eines Gebäudes, −1…1.
    ///
    /// Warum überhaupt: Die Beleuchtung unterscheidet Flächen nach ihrer
    /// Ausrichtung, nicht Häuser nach ihrer Identität. In einer Siedlung
    /// stehen die Häuser aber parallel zur Strasse — gleiche Ausrichtung,
    /// gleiche Helligkeit, und der Block wird zu einer Fläche. Erst ein
    /// Unterschied zwischen Nachbarn macht daraus wieder einzelne Häuser.
    ///
    /// Das ist ein Stilmittel und behauptet nichts: Die Ebene `building`
    /// im OpenMapTiles-Schema führt nur Höhen, keine Gebäudeart. Nach
    /// Wohnen/Gewerbe könnten wir also gar nicht einfärben, und ein Ton,
    /// der zufällig streut, darf auch nicht so aussehen, als täte er es.
    /// Deshalb bleibt die Streuung klein genug, um als Materialunterschied
    /// zu lesen, nicht als Kategorie.
    ///
    /// Der Wert hängt an der Feature-Id, nicht an der Geometrie: Dasselbe
    /// Haus hat in der z16- und der z17-Kachel dieselbe Id, aber andere
    /// Kachelkoordinaten. Aus der Geometrie abgeleitet würde ein Haus beim
    /// Zoomen die Farbe wechseln.
    static func gebaeudeTon(_ f: VectorTileFeature) -> Float {
        // Ohne Id (nicht jeder Kachelerzeuger schreibt eine) bleibt nur
        // die Geometrie. Der Sprung beim Zoomen ist dann hinnehmbar —
        // die Alternative waere, alle diese Haeuser gleich zu faerben.
        let schluessel: UInt64
        if let id = f.id {
            schluessel = id
        } else if let p = f.rings.first?.first {
            schluessel = UInt64(UInt32(bitPattern: p.x)) << 32
                | UInt64(UInt32(bitPattern: p.y))
        } else {
            return 0
        }

        // SplitMix64-Finalizer: streut auch dicht beieinander liegende
        // Ids weit auseinander. Fortlaufende OSM-Ids in einer Strasse
        // wuerden sonst einen sichtbaren Verlauf ergeben statt Streuung.
        var z = schluessel &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        // Obere 24 Bit: gleichverteilt in 0…1, dann auf −1…1 gespreizt.
        return Float(z >> 40) / Float(1 << 24) * 2 - 1
    }
}
