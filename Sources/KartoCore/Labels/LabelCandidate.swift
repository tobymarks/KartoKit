import Foundation

/// Beschriftungs-Kandidat aus einer Kachel (schemaneutral). Koordinaten in Tile-Einheiten.
public struct LabelCandidate: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Ortsname; `rank` 0 = Land … 6 = Ortsteil (kleiner = wichtiger).
        case place(rank: Int)
        /// Straßenname entlang der Linie.
        case road(RoadClass)
        /// Straßenschild (Autobahn-/Bundesstraßennummer) an der Linie.
        case shield(RoadClass)
        case water
        case park
        case poi
    }
    public var text: String
    public var kind: Kind
    public var point: TilePoint?
    public var path: [TilePoint]?

    public init(text: String, kind: Kind, point: TilePoint? = nil, path: [TilePoint]? = nil) {
        self.text = text; self.kind = kind; self.point = point; self.path = path
    }

    /// Basis-Priorität (höher = zuerst platzieren).
    public var basePriority: Int {
        switch kind {
        case .place(let rank): return 100 - rank * 10
        case .shield(let c): return c == .motorway ? 60 : 45
        case .road(let c):
            switch c { case .motorway, .trunk: return 50; case .primary: return 40; case .secondary: return 32; case .tertiary: return 26; default: return 20 }
        case .water: return 30
        case .park: return 22
        case .poi: return 24
        }
    }

    /// POI-Klassen, die in der Navi-Ansicht beschriftet werden: Bahnhöfe, Flughäfen, Krankenhäuser,
    /// große Einkaufszentren, Stadien, Hochschulen. Tankstellen bewusst nicht (E-Auto-App), Ladeparks
    /// zeichnet die App selbst mit Belegung (siehe `MapAnnotation.Style.pill`).
    /// Alles andere (Cafés, Läden, Bushaltestellen …) wird bewusst nicht beschriftet.
    public static let importantPOIClasses: Set<String> = [
        "railway", "station", "train_station", "airport", "aerodrome",
        "hospital", "mall", "stadium", "university", "college", "bus_station", "ferry_terminal",
        "zoo", "theme_park", "attraction", "museum", "townhall", "police",
    ]

    /// Ab welcher (KartoKit-)Zoomstufe sichtbar.
    public var minZoom: Double {
        switch kind {
        case .place(let rank): return [1, 3, 4, 7, 9, 11, 13][min(max(rank, 0), 6)]
        case .shield(let c): return c == .motorway ? 6 : 9
        case .road(let c):
            switch c { case .motorway, .trunk: return 9; case .primary: return 11; case .secondary: return 12.5; case .tertiary: return 14; case .minor: return 15; default: return 16.5 }
        case .water: return 9
        case .park: return 14
        case .poi: return 14.5
        }
    }

    /// Schriftgröße in Punkten (vor `labelScale`).
    public var fontSize: Double {
        switch kind {
        case .place(let rank): return [15, 14, 14, 13, 12, 11, 10][min(max(rank, 0), 6)]
        case .shield: return 11
        case .road(let c): return (c == .motorway || c == .trunk) ? 12 : 11
        case .water: return 11
        case .park: return 10
        case .poi: return 10
        }
    }

    public var isBold: Bool {
        if case .place(let r) = kind { return r <= 3 }
        if case .shield = kind { return true }
        return false
    }
}

/// Zieht Beschriftungs-Kandidaten aus einer Vector-Tile (OpenMapTiles- und Protomaps-Schema).
public enum LabelExtractor {
    /// `language`: bevorzugter Namensschlüssel (z. B. "de" → `name:de`, Fallback `name`).
    public static func extract(from tile: VectorTile, language: String? = nil) -> [LabelCandidate] {
        var out: [LabelCandidate] = []
        func name(_ f: VectorTileFeature) -> String? {
            if let l = language, let n = f.properties["name:\(l)"]?.stringValue, !n.isEmpty { return n }
            if let n = f.properties["name"]?.stringValue, !n.isEmpty { return n }
            return nil
        }
        func centroid(_ f: VectorTileFeature) -> TilePoint? {
            if let p = f.rings.first?.first { return p }
            return nil
        }
        for layer in tile.layers {
            switch layer.name {
            // OpenMapTiles
            case "place":
                for f in layer.features {
                    guard let n = name(f), let p = centroid(f) else { continue }
                    let cls = f.properties["class"]?.stringValue ?? ""
                    let rank: Int
                    switch cls {
                    case "continent", "country": rank = 0
                    case "state", "province": rank = 1
                    case "city": rank = (f.properties["rank"]?.doubleValue ?? 10) <= 3 ? 2 : 3
                    case "town": rank = 4
                    case "village": rank = 5
                    default: rank = 6
                    }
                    out.append(LabelCandidate(text: n, kind: .place(rank: rank), point: p))
                }
            case "transportation_name":
                for f in layer.features where f.type == .lineString {
                    let cls = Self.roadClass(f.properties["class"]?.stringValue ?? "")
                    for path in f.rings where path.count >= 2 {
                        if let n = name(f) { out.append(LabelCandidate(text: n, kind: .road(cls), path: path)) }
                        if let ref = f.properties["ref"]?.stringValue, let first = Self.primaryRef(ref), cls == .motorway || cls == .trunk || cls == .primary {
                            out.append(LabelCandidate(text: first, kind: .shield(cls), path: path))
                        }
                    }
                }
            case "water_name":
                for f in layer.features {
                    guard let n = name(f), let p = centroid(f), Self.isLabelWorthyWater(n) else { continue }
                    out.append(LabelCandidate(text: n, kind: .water, point: p))
                }
            case "park":
                for f in layer.features where f.type == .point { if let n = name(f), let p = centroid(f) { out.append(LabelCandidate(text: n, kind: .park, point: p)) } }
            case "poi":
                for f in layer.features where f.type == .point {
                    let cls = f.properties["class"]?.stringValue ?? ""
                    let sub = f.properties["subclass"]?.stringValue ?? ""
                    guard LabelCandidate.importantPOIClasses.contains(cls) || LabelCandidate.importantPOIClasses.contains(sub) else { continue }
                    // OpenMapTiles-`rank`: klein = wichtig; alles jenseits von 20 ist Beiwerk.
                    if let r = f.properties["rank"]?.doubleValue, r > 20 { continue }
                    if let n = name(f), let p = centroid(f) { out.append(LabelCandidate(text: n, kind: .poi, point: p)) }
                }
            // Protomaps
            case "places":
                for f in layer.features {
                    guard let n = name(f), let p = centroid(f) else { continue }
                    let kind = (f.properties["kind"] ?? f.properties["pmap:kind"])?.stringValue ?? ""
                    let pop = (f.properties["population"] ?? f.properties["pmap:population"])?.doubleValue ?? 0
                    let rank: Int
                    switch kind {
                    case "country": rank = 0
                    case "region", "state": rank = 1
                    case "locality", "city": rank = pop > 300_000 ? 2 : (pop > 50_000 ? 3 : (pop > 8_000 ? 4 : 5))
                    case "neighbourhood", "suburb": rank = 6
                    default: rank = 5
                    }
                    out.append(LabelCandidate(text: n, kind: .place(rank: rank), point: p))
                }
            case "roads":
                for f in layer.features where f.type == .lineString {
                    let kind = (f.properties["kind"] ?? f.properties["pmap:kind"])?.stringValue ?? ""
                    let cls = Self.protomapsClass(kind)
                    for path in f.rings where path.count >= 2 {
                        if let n = name(f) { out.append(LabelCandidate(text: n, kind: .road(cls), path: path)) }
                        if let ref = (f.properties["ref"] ?? f.properties["pmap:ref"])?.stringValue, let first = Self.primaryRef(ref), cls == .motorway || cls == .primary {
                            out.append(LabelCandidate(text: first, kind: .shield(cls), path: path))
                        }
                    }
                }
            case "water":
                for f in layer.features where f.type == .point {
                    guard let n = name(f), let p = centroid(f), Self.isLabelWorthyWater(n) else { continue }
                    out.append(LabelCandidate(text: n, kind: .water, point: p))
                }
            case "pois":
                for f in layer.features where f.type == .point {
                    let kind = (f.properties["kind"] ?? f.properties["pmap:kind"])?.stringValue ?? ""
                    guard LabelCandidate.importantPOIClasses.contains(kind) else { continue }
                    if let r = (f.properties["min_zoom"] ?? f.properties["pmap:min_zoom"])?.doubleValue, r > 15 { continue }
                    if let n = name(f), let p = centroid(f) { out.append(LabelCandidate(text: n, kind: .poi, point: p)) }
                }
            default: break
            }
        }
        return out
    }

    /// Gewässernamen: OpenMapTiles führt auch Springbrunnen, Wasserspiele und Regenbecken als „lake“ –
    /// die beschriften Navi-Karten üblicherweise nicht. Heuristik über den Namen (DE/EN), bis das Schema Flächen liefert.
    static func isLabelWorthyWater(_ name: String) -> Bool {
        let n = name.lowercased()
        for bad in ["brunnen", "fountain", "wasserspiel", "becken", "basin", "pool", "bassin", "kläranlage", "reservoir"] where n.contains(bad) { return false }
        return true
    }

    /// OSM-`ref` kann mehrere Nummern enthalten ("A 8;A 81", "B 10; B 294"): nur die erste zeigen.
    /// Landes-/Kreisstraßen (L 621, K 4512, St 2054) bekommen kein Schild.
    static func primaryRef(_ ref: String) -> String? {
        let first = ref.split(whereSeparator: { $0 == ";" || $0 == "," }).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !first.isEmpty else { return nil }
        let upper = first.uppercased()
        if upper.hasPrefix("L ") || upper.hasPrefix("K ") || upper.hasPrefix("ST ") || upper.hasPrefix("S ") { return nil }
        return first
    }

    /// Traegt das Schild die blaue Autobahnfarbe?
    ///
    /// Die deutsche Beschilderung richtet sich nach der Nummer, nicht
    /// nach dem Ausbau. Die B 29 ist autobahnaehnlich ausgebaut und in
    /// OSM deshalb `trunk` — nach Klasse gefaerbt stand sie blau neben
    /// der gelben B 10, die `primary` ist.
    ///
    /// Herabgestuft wird nur, nie heraufgestuft: Ein „B" macht aus einem
    /// blauen Schild ein gelbes, aber kein „A" macht aus einem gelben
    /// ein blaues. Sonst faerbte die Regel britische A-roads blau — dort
    /// sind Autobahnen „M".
    public static func autobahnschild(text: String, klasse: RoadClass) -> Bool {
        guard klasse == .motorway || klasse == .trunk else { return false }
        return !text.uppercased().hasPrefix("B")
    }

    static func roadClass(_ s: String) -> RoadClass {
        switch s {
        case "motorway": return .motorway
        case "trunk": return .trunk
        case "primary": return .primary
        case "secondary": return .secondary
        case "tertiary": return .tertiary
        case "minor": return .minor
        case "service", "track": return .service
        case "rail": return .rail
        default: return .path
        }
    }

    static func protomapsClass(_ s: String) -> RoadClass {
        switch s {
        case "highway": return .motorway
        case "major_road": return .primary
        case "medium_road": return .secondary
        case "minor_road": return .minor
        case "path": return .path
        case "rail": return .rail
        default: return .service
        }
    }
}
