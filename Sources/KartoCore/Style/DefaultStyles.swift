import Foundation

/// Style-Erzeugung aus einem `MapTheme` für die beiden verbreiteten Vector-Tile-Schemata.
/// Die Layer-IDs sind für alle Themes desselben Schemas identisch – deshalb können Themes
/// zur Laufzeit gewechselt und Farben interpoliert werden, ohne Kacheln neu zu bauen.
public extension MapStyle {

    // Kompatibilität: Standard-Themes
    static var openMapTiles: MapStyle { openMapTiles(theme: .cleanWhite) }
    static var protomaps: MapStyle { protomaps(theme: .cleanWhite) }

    /// Linienbreiten je Straßenklasse (Pixel, zoomabhängig) – auf einen aufgeräumten Navi-Look abgestimmt.
    static func roadWidth(_ c: RoadClass) -> ZoomStops {
        switch c {
        case .motorway, .trunk: return ZoomStops([(6, 1.5), (10, 2.5), (14, 7), (18, 30)])
        case .primary: return ZoomStops([(8, 1.2), (12, 3.2), (16, 12), (18, 22)])
        case .secondary: return ZoomStops([(9, 1), (12, 3), (16, 11), (18, 22)])
        case .tertiary: return ZoomStops([(11, 1), (15, 4), (18, 16)])
        case .minor: return ZoomStops([(12, 1), (15, 3.5), (18, 16)])
        case .service: return ZoomStops([(13, 0.8), (15, 2.5), (18, 12)])
        case .path: return ZoomStops([(13, 0.5), (16, 1.5), (18, 4)])
        case .rail: return ZoomStops([(12, 0.8), (16, 2)])
        }
    }

    static func casingWidth(_ c: RoadClass) -> ZoomStops {
        let w = roadWidth(c)
        return ZoomStops(w.stops.map { ($0.zoom, $0.value + max(1.2, $0.value * 0.28)) }, base: w.base)
    }

    private static func roadLayers(theme: MapTheme, sourceLayer: String, classFilter: (Set<String>) -> FeatureFilter,
                                   mapping: [(RoadClass, Set<String>)]) -> [StyleLayer] {
        var casings: [StyleLayer] = []
        var fills: [StyleLayer] = []
        // Zeichenreihenfolge: kleine Straßen zuerst, Autobahnen zuletzt
        let order: [RoadClass] = [.path, .rail, .service, .minor, .tertiary, .secondary, .primary, .trunk, .motorway]
        for rc in order {
            guard let (_, values) = mapping.first(where: { $0.0 == rc }) else { continue }
            // Layer-Struktur muss themenunabhängig sein (Theme-Wechsel ohne Kachel-Neuaufbau, Blend):
            // fehlende Farben werden als transparent geführt; der Renderer überspringt Alpha 0.
            let colors = theme.roads[rc] ?? RoadColors(fill: .transparent, casing: nil)
            let filter = Filters.all([classFilter(values), Filters.geometry(.lineString)])
            casings.append(StyleLayer(id: "road-casing-\(rc.rawValue)", sourceLayer: sourceLayer, filter: filter,
                                      paint: .line(color: colors.casing ?? .transparent, width: casingWidth(rc))))
            fills.append(StyleLayer(id: "road-\(rc.rawValue)", sourceLayer: sourceLayer, filter: filter,
                                    paint: .line(color: colors.fill, width: roadWidth(rc))))
        }
        return casings + fills
    }

    private static func buildingLayer(theme: MapTheme, sourceLayer: String, heightKey: String,
                                      baseKey: String?, extrude: Bool) -> [StyleLayer] {
        if extrude {
            // Dasselbe Zoomfenster wie die flache Variante: Ab 16 gab es
            // schon vorher Gebaeude, darunter keine. So aendert sich nur
            // die Darstellung und nicht, wann ueberhaupt etwas erscheint —
            // ein Unterschied, den man beim Vergleichen sonst dem 3D
            // zuschreibt.
            //
            // Die Kachelabdeckung verfeinert nach Entfernung. Bei geneigter
            // Kamera bleiben die Kacheln am Horizont grob und tragen damit
            // gar keine Gebaeude; die Extrusion beschraenkt sich von selbst
            // auf den Nahbereich.
            return [StyleLayer(id: "building", sourceLayer: sourceLayer, minZoom: 16,
                               filter: Filters.geometry(.polygon),
                               paint: .extrusion(color: theme.building, heightKey: heightKey, baseKey: baseKey, defaultHeight: 8))]
        }
        var layers = [StyleLayer(id: "building", sourceLayer: sourceLayer, minZoom: 16,
                                 filter: Filters.geometry(.polygon), paint: .fill(color: theme.building))]
        if let outline = theme.buildingOutline {
            layers.append(StyleLayer(id: "building-outline", sourceLayer: sourceLayer, minZoom: 16,
                                     filter: Filters.geometry(.polygon), paint: .line(color: outline, width: ZoomStops([(16, 0.5), (18, 1)]))))
        }
        return layers
    }

    /// OpenMapTiles-Schema (MapTiler, Stadia, eigene Planetiler-/OpenMapTiles-Server).
    static func openMapTiles(theme: MapTheme, extrudeBuildings: Bool = true) -> MapStyle {
        let cls = { (v: Set<String>) -> FeatureFilter in Filters.oneOf("class", v) }
        var layers: [StyleLayer] = [
            StyleLayer(id: "landcover-wood", sourceLayer: "landcover", filter: cls(["wood", "forest"]), paint: .fill(color: theme.forest)),
            StyleLayer(id: "landcover-grass", sourceLayer: "landcover", filter: cls(["grass", "farmland", "grassland", "meadow"]), paint: .fill(color: theme.farmland)),
            StyleLayer(id: "park", sourceLayer: "park", filter: Filters.geometry(.polygon), paint: .fill(color: theme.park)),
            StyleLayer(id: "landuse-residential", sourceLayer: "landuse", filter: cls(["residential", "suburb", "neighbourhood"]), paint: .fill(color: theme.residential)),
            StyleLayer(id: "landuse-industrial", sourceLayer: "landuse", filter: cls(["industrial", "commercial", "retail"]), paint: .fill(color: theme.industrial)),
            StyleLayer(id: "water", sourceLayer: "water", filter: Filters.geometry(.polygon), paint: .fill(color: theme.water)),
            StyleLayer(id: "waterway", sourceLayer: "waterway", paint: .line(color: theme.waterway, width: ZoomStops([(10, 0.8), (16, 3)]))),
            StyleLayer(id: "aeroway", sourceLayer: "aeroway", filter: Filters.geometry(.polygon), paint: .fill(color: theme.aeroway)),
        ]
        layers += buildingLayer(theme: theme, sourceLayer: "building", heightKey: "render_height",
                                baseKey: "render_min_height", extrude: extrudeBuildings)
        layers += roadLayers(theme: theme, sourceLayer: "transportation", classFilter: cls, mapping: [
            (.motorway, ["motorway"]), (.trunk, ["trunk"]), (.primary, ["primary"]), (.secondary, ["secondary"]),
            (.tertiary, ["tertiary"]), (.minor, ["minor"]), (.service, ["service", "track"]), (.path, ["path"]), (.rail, ["rail"]),
        ])
        layers.append(StyleLayer(id: "boundary", sourceLayer: "boundary", filter: Filters.oneOf("admin_level", ["2", "4"]),
                                 paint: .line(color: theme.boundary, width: ZoomStops([(3, 0.8), (10, 2)]))))
        return MapStyle(background: theme.background, layers: layers,
                        buildingTonStaerke: theme.buildingTonStaerke)
    }

    /// Protomaps-Basemap-Schema (v3 `pmap:kind` und v4 `kind`).
    static func protomaps(theme: MapTheme, extrudeBuildings: Bool = true) -> MapStyle {
        let kind = { (v: Set<String>) -> FeatureFilter in Filters.oneOf(keys: ["kind", "pmap:kind"], v) }
        var layers: [StyleLayer] = [
            StyleLayer(id: "earth", sourceLayer: "earth", paint: .fill(color: theme.land)),
            StyleLayer(id: "landuse-park", sourceLayer: "landuse",
                       filter: kind(["park", "forest", "wood", "grass", "cemetery", "golf_course", "nature_reserve", "garden"]),
                       paint: .fill(color: theme.park)),
            StyleLayer(id: "landuse-farmland", sourceLayer: "landuse", filter: kind(["farmland", "orchard", "allotments"]), paint: .fill(color: theme.farmland)),
            StyleLayer(id: "landuse-other", sourceLayer: "landuse",
                       filter: kind(["industrial", "commercial", "hospital", "school", "university", "railway", "military"]),
                       paint: .fill(color: theme.industrial)),
            StyleLayer(id: "water", sourceLayer: "water", filter: Filters.geometry(.polygon), paint: .fill(color: theme.water)),
            StyleLayer(id: "water-line", sourceLayer: "water", filter: Filters.geometry(.lineString),
                       paint: .line(color: theme.waterway, width: ZoomStops([(10, 0.8), (16, 3)]))),
        ]
        layers += buildingLayer(theme: theme, sourceLayer: "buildings", heightKey: "height",
                                baseKey: "min_height", extrude: extrudeBuildings)
        layers += roadLayers(theme: theme, sourceLayer: "roads", classFilter: kind, mapping: [
            (.motorway, ["highway"]), (.primary, ["major_road"]), (.secondary, ["medium_road"]),
            (.minor, ["minor_road"]), (.service, ["other"]), (.path, ["path"]), (.rail, ["rail"]),
        ])
        layers.append(StyleLayer(id: "boundary", sourceLayer: "boundaries",
                                 paint: .line(color: theme.boundary, width: ZoomStops([(3, 0.8), (10, 2)]))))
        return MapStyle(background: theme.background, layers: layers,
                        buildingTonStaerke: theme.buildingTonStaerke)
    }

    /// Farbinterpolation zwischen zwei Styles gleicher Struktur (für Tag/Nacht-Übergang).
    /// Layer werden über ihre ID gepaart; Filter/Breiten kommen von `a`.
    static func blend(_ a: MapStyle, _ b: MapStyle, _ t: Float) -> MapStyle {
        guard t > 0 else { return a }
        guard t < 1 else { return b }
        var out = a
        out.background = RGBA.lerp(a.background, b.background, t)
        let byID = Dictionary(uniqueKeysWithValues: b.layers.map { ($0.id, $0) })
        out.layers = a.layers.map { la in
            guard let lb = byID[la.id] else { return la }
            var l = la
            switch (la.paint, lb.paint) {
            case (.fill(let ca), .fill(let cb)): l.paint = .fill(color: RGBA.lerp(ca, cb, t))
            case (.line(let ca, let w), .line(let cb, _)): l.paint = .line(color: RGBA.lerp(ca, cb, t), width: w)
            case (.extrusion(let ca, let h, let bk, let d), .extrusion(let cb, _, _, _)):
                l.paint = .extrusion(color: RGBA.lerp(ca, cb, t), heightKey: h, baseKey: bk, defaultHeight: d)
            default: break
            }
            return l
        }
        return out
    }
}
