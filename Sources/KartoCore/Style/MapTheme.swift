import Foundation

/// Straßenklassen, auf die beide Kachel-Schemata (OpenMapTiles, Protomaps) abgebildet werden.
public enum RoadClass: String, CaseIterable, Sendable, Codable {
    case motorway, trunk, primary, secondary, tertiary, minor, service, path, rail
}

public struct RoadColors: Equatable, Sendable {
    public var fill: RGBA
    public var casing: RGBA?
    public init(fill: RGBA, casing: RGBA? = nil) { self.fill = fill; self.casing = casing }
}

/// Farben der Navigations-Route.
public struct RouteColors: Equatable, Sendable {
    /// Aktive Route (Kern) und Kontrast-Rand.
    public var active: RGBA
    public var casing: RGBA
    /// Bereits gefahrener Teil.
    public var driven: RGBA
    public var drivenCasing: RGBA
    /// Nicht gewählte Alternativen.
    public var alternative: RGBA
    public var alternativeCasing: RGBA
    /// Verkehrsabschnitte auf der Route.
    public var trafficSlow: RGBA
    public var trafficJam: RGBA
    /// Sperrung / unpassierbar.
    public var trafficClosed: RGBA
    /// Zweite Farbe der Sperrschraffur. Die Streifen wechseln zwischen
    /// ihr und trafficClosed - das unterscheidet eine Sperrung auf den
    /// ersten Blick von schwerem Stau, der dieselbe rote Flaeche traegt.
    public var trafficClosedHatch: RGBA = RGBA(hex: 0xF4F1E8)
    /// Laenge eines Streifenpaars in Bildschirmpunkten. 0 = keine
    /// Schraffur, dann bleibt die Sperrung eine einfarbige Flaeche.
    public var trafficClosedHatchLength: Double = 14
    /// Freier Verkehr. Liegt als Band unter dem Casing und wird von den
    /// Abschnitten oben ueberschrieben - so entsteht der durchgehende
    /// gruen-gelb-rote Saum neben der Route.
    public var trafficFree: RGBA = RGBA(hex: 0x2FBF5C)
    /// Breite des Verkehrssaums in Punkten. 0 schaltet ihn ab.
    public var trafficFlankWidth: Double = 17
    /// Manöverpfeil auf der Straße.
    public var maneuverArrow: RGBA
    public var maneuverArrowCasing: RGBA
    /// Breiten in Punkten (Standard: 7 / 11; KartoKit-Theme: 7 / 11 / 5).
    public var activeWidth: Double = 7
    public var casingWidth: Double = 11
    public var alternativeWidth: Double = 5

    public init(active: RGBA, casing: RGBA, driven: RGBA, drivenCasing: RGBA,
                alternative: RGBA, alternativeCasing: RGBA,
                trafficSlow: RGBA, trafficJam: RGBA, trafficClosed: RGBA = RGBA(hex: 0x8B1E2D),
                trafficClosedHatch: RGBA = RGBA(hex: 0xF4F1E8),
                maneuverArrow: RGBA, maneuverArrowCasing: RGBA,
                activeWidth: Double = 7, casingWidth: Double = 11, alternativeWidth: Double = 5) {
        self.active = active; self.casing = casing
        self.driven = driven; self.drivenCasing = drivenCasing
        self.alternative = alternative; self.alternativeCasing = alternativeCasing
        self.trafficSlow = trafficSlow; self.trafficJam = trafficJam; self.trafficClosed = trafficClosed
        self.trafficClosedHatch = trafficClosedHatch
        self.maneuverArrow = maneuverArrow; self.maneuverArrowCasing = maneuverArrowCasing
        self.activeWidth = activeWidth; self.casingWidth = casingWidth; self.alternativeWidth = alternativeWidth
    }
}

/// Aussehen des Positions-Pucks, z. B. weißer Pfeil mit blauem Rand auf blauem Halo.
/// Eigene Marken liefern entweder eine Vektorform (`.custom`) oder ein Bild aus dem
/// App-Bundle (`.image`), das der Renderer als Textur lädt (PNG/PDF-Asset, nach Norden
/// zeigend, quadratisch, transparenter Hintergrund).
public struct PuckDesign: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        /// Klassischer Navigationspfeil (Standard).
        case arrow
        /// Chevron ohne Rückseite.
        case chevron
        /// Eigenes Polygon in Einheitskoordinaten (−1…1, Norden = −y), Dreieckszerlegung per Earcut.
        case custom(points: [Vec2])
        /// Bild-Asset aus dem Bundle (Name wie in `UIImage(named:)`).
        case image(name: String)
    }
    public var shape: Shape
    /// Kantenlänge/Durchmesser in Punkten.
    public var size: Double
    public var fill: RGBA
    public var stroke: RGBA
    /// Randbreite relativ zur Größe (0 = kein Rand). Üblich ≈ 0,14.
    public var strokeRatio: Double
    /// Halo-Kreis auf dem Boden unter dem Puck (nil = keiner).
    public var halo: RGBA?
    public var haloRadius: Double
    public var accuracy: RGBA
    public var stale: RGBA
    /// Wie flach der Pfeil auf der Strasse liegt: 0 = aufrecht im Bildschirm
    /// (nie verzerrt, aber bei geneigter Kamera steht er wie ein Schild),
    /// 1 = vollstaendig in der Fahrbahnebene, also perspektivisch verkuerzt
    /// Werte dazwischen mischen beides.
    public var groundAlignment: Double

    public init(shape: Shape = .arrow, size: Double = 30, fill: RGBA = RGBA(hex: 0xFFFFFF),
                stroke: RGBA = RGBA(hex: 0x2F7CF6), strokeRatio: Double = 0.14,
                halo: RGBA? = RGBA(hex: 0x0D3CAA, alpha: 0.55), haloRadius: Double = 26,
                accuracy: RGBA = RGBA(hex: 0x2F7CF6, alpha: 0.12), stale: RGBA = RGBA(hex: 0x9A9A9A),
                groundAlignment: Double = 1) {
        self.shape = shape; self.size = size; self.fill = fill; self.stroke = stroke
        self.strokeRatio = strokeRatio; self.halo = halo; self.haloRadius = haloRadius
        self.accuracy = accuracy; self.stale = stale
        self.groundAlignment = min(max(groundAlignment, 0), 1)
    }
}

public struct LabelColors: Equatable, Sendable {
    public var text: RGBA
    public var halo: RGBA
    public var roadText: RGBA
    public var roadHalo: RGBA
    public var shieldFill: RGBA
    public var shieldText: RGBA
    public var shieldStroke: RGBA
    public init(text: RGBA, halo: RGBA, roadText: RGBA, roadHalo: RGBA, shieldFill: RGBA, shieldText: RGBA, shieldStroke: RGBA) {
        self.text = text; self.halo = halo; self.roadText = roadText; self.roadHalo = roadHalo
        self.shieldFill = shieldFill; self.shieldText = shieldText; self.shieldStroke = shieldStroke
    }
}

/// Ein Theme = alle Farben und Maße einer Karte, unabhängig vom Kachelschema.
/// Aus einem Theme werden die konkreten `MapStyle`s (`MapStyle.openMapTiles(theme:)`,
/// `.protomaps(theme:)`) erzeugt. Zwei Themes mit gleichem Schema haben identische
/// Layer-Struktur → Umschaltung ohne Neu-Tessellation, Farbübergang per Interpolation.
public struct MapTheme: Equatable, Sendable {
    public var name: String
    public var isDark: Bool

    // Flächen
    public var background: RGBA
    public var land: RGBA
    public var water: RGBA
    public var waterway: RGBA
    public var park: RGBA
    public var forest: RGBA
    public var farmland: RGBA
    public var residential: RGBA
    public var industrial: RGBA
    public var aeroway: RGBA
    public var building: RGBA
    public var buildingOutline: RGBA?
    /// Wie weit der Ton eines einzelnen Gebäudes von `building` abweichen
    /// darf (0…1, multiplikativ auf die Helligkeit).
    ///
    /// Themeabhängig, und das ist kein Geschmack, sondern Arithmetik: Der
    /// Anteil wirkt auf die Farbe, und dunkle Farben haben wenig, woran er
    /// wirken kann. 7 % von einem hellen Grau (0xDA) sind rund 15
    /// Helligkeitsstufen und deutlich zu sehen, 7 % von einem dunklen Blau
    /// (0x20) sind zwei — im Nachtbild wäre die Streuung damit praktisch
    /// nicht vorhanden. Dunkle Themes brauchen den größeren Anteil für
    /// denselben sichtbaren Unterschied.
    public var buildingTonStaerke: Float
    /// Gebäude als Extrusion (3D) oder flach. Navi-Ansicht: üblicherweise flach.
    public var boundary: RGBA

    public var roads: [RoadClass: RoadColors]
    public var route: RouteColors
    public var puck: PuckDesign
    public var labels: LabelColors
    /// Markenakzent (KartoKit-Theme: Signal-Orange) für Marker/Empfehlungen.
    public var accent: RGBA
    /// App-spezifische Zusatzfarben (z. B. "chargingAvailable"), aus Token-Dateien übernommen.
    public var extra: [String: RGBA] = [:]

    public init(name: String, isDark: Bool, background: RGBA, land: RGBA, water: RGBA, waterway: RGBA,
                park: RGBA, forest: RGBA, farmland: RGBA, residential: RGBA, industrial: RGBA, aeroway: RGBA,
                building: RGBA, buildingOutline: RGBA?, boundary: RGBA,
                roads: [RoadClass: RoadColors], route: RouteColors, puck: PuckDesign, labels: LabelColors, accent: RGBA) {
        self.name = name; self.isDark = isDark
        self.background = background; self.land = land; self.water = water; self.waterway = waterway
        self.park = park; self.forest = forest; self.farmland = farmland; self.residential = residential
        self.industrial = industrial; self.aeroway = aeroway; self.building = building
        self.buildingOutline = buildingOutline; self.boundary = boundary
        self.buildingTonStaerke = isDark ? 0.22 : 0.07
        self.roads = roads; self.route = route; self.puck = puck; self.labels = labels; self.accent = accent
    }

    // MARK: - Mitgelieferte Themes

    /// Dunkler Navi-Stil für Nachtfahrten.
    public static var nightDrive: MapTheme {
        MapTheme(
            name: "Night Drive", isDark: true,
            background: RGBA(hex: 0x1C3B5A), land: RGBA(hex: 0x1C3B5A),
            water: RGBA(hex: 0x0E2444), waterway: RGBA(hex: 0x0E2444),
            park: RGBA(hex: 0x004B65), forest: RGBA(hex: 0x00465E), farmland: RGBA(hex: 0x1B3E57),
            residential: RGBA(hex: 0x1F4060), industrial: RGBA(hex: 0x1B3A56), aeroway: RGBA(hex: 0x27496A),
            building: RGBA(hex: 0x204868), buildingOutline: RGBA(hex: 0x2A5478),
            boundary: RGBA(hex: 0x8A7FA8, alpha: 0.6),
            roads: [
                .motorway: RoadColors(fill: RGBA(hex: 0x7A8CC0), casing: RGBA(hex: 0x33507A)),
                .trunk: RoadColors(fill: RGBA(hex: 0x7A8CC0), casing: RGBA(hex: 0x33507A)),
                .primary: RoadColors(fill: RGBA(hex: 0x6E82B4), casing: RGBA(hex: 0x2F4B74)),
                .secondary: RoadColors(fill: RGBA(hex: 0x6478A8), casing: RGBA(hex: 0x2B466E)),
                .tertiary: RoadColors(fill: RGBA(hex: 0x6078A8), casing: RGBA(hex: 0x2B466E)),
                .minor: RoadColors(fill: RGBA(hex: 0x56699A), casing: nil),
                .service: RoadColors(fill: RGBA(hex: 0x4A5C8A), casing: nil),
                .path: RoadColors(fill: RGBA(hex: 0x3F5280), casing: nil),
                .rail: RoadColors(fill: RGBA(hex: 0x3A4C74), casing: nil),
            ],
            route: RouteColors(active: RGBA(hex: 0x00D4EC), casing: RGBA(hex: 0x005A80),
                               driven: RGBA(hex: 0x3B6F86), drivenCasing: RGBA(hex: 0x1B3B4E),
                               alternative: RGBA(hex: 0x5E7FA0), alternativeCasing: RGBA(hex: 0x233B52),
                               trafficSlow: RGBA(hex: 0xF59E0B), trafficJam: RGBA(hex: 0xDC2626),
                               maneuverArrow: RGBA(hex: 0xFFFFFF), maneuverArrowCasing: RGBA(hex: 0x1C3B5A)),
            puck: PuckDesign(),
            labels: LabelColors(text: RGBA(hex: 0xE8EEF6), halo: RGBA(hex: 0x1C3B5A, alpha: 0.9),
                                roadText: RGBA(hex: 0xFFFFFF), roadHalo: RGBA(hex: 0x1C3B5A, alpha: 0.85),
                                shieldFill: RGBA(hex: 0x2F5AA8), shieldText: RGBA(hex: 0xFFFFFF), shieldStroke: RGBA(hex: 0xFFFFFF)),
            accent: RGBA(hex: 0x2F7CF6))
    }

    /// Heller Navi-Stil („Clean White“) mit kräftigen Straßenkontrasten.
    public static var cleanWhite: MapTheme {
        MapTheme(
            name: "Clean White", isDark: false,
            background: RGBA(hex: 0xF4F1E8), land: RGBA(hex: 0xF4F1E8),
            water: RGBA(hex: 0xB9D3E6), waterway: RGBA(hex: 0xB9D3E6),
            park: RGBA(hex: 0xD9E9C9), forest: RGBA(hex: 0xCFE3BE), farmland: RGBA(hex: 0xEDEBDD),
            residential: RGBA(hex: 0xEEEBE2), industrial: RGBA(hex: 0xE9E5DC), aeroway: RGBA(hex: 0xE3E0D8),
            building: RGBA(hex: 0xE2DED4), buildingOutline: RGBA(hex: 0xD3CEC3),
            boundary: RGBA(hex: 0x9E8FB2, alpha: 0.7),
            roads: [
                .motorway: RoadColors(fill: RGBA(hex: 0xF6C36A), casing: RGBA(hex: 0xC9884F)),
                .trunk: RoadColors(fill: RGBA(hex: 0xF6C36A), casing: RGBA(hex: 0xC9884F)),
                .primary: RoadColors(fill: RGBA(hex: 0xF9E5A8), casing: RGBA(hex: 0xC7B07A)),
                .secondary: RoadColors(fill: RGBA(hex: 0xFAF0C8), casing: RGBA(hex: 0xC7B07A)),
                .tertiary: RoadColors(fill: RGBA(hex: 0xFFFFFF), casing: RGBA(hex: 0xC8C3BC)),
                .minor: RoadColors(fill: RGBA(hex: 0xFFFFFF), casing: RGBA(hex: 0xC8C3BC)),
                .service: RoadColors(fill: RGBA(hex: 0xFFFFFF), casing: RGBA(hex: 0xD6D2CB)),
                .path: RoadColors(fill: RGBA(hex: 0xD8D3CC), casing: nil),
                .rail: RoadColors(fill: RGBA(hex: 0xB8B4AE), casing: nil),
            ],
            route: RouteColors(active: RGBA(hex: 0x60356B), casing: RGBA(hex: 0xFFFFFF),
                               driven: RGBA(hex: 0xB8A9BD), drivenCasing: RGBA(hex: 0xFFFFFF, alpha: 0.8),
                               alternative: RGBA(hex: 0x9B9992), alternativeCasing: RGBA(hex: 0xFFFFFF),
                               trafficSlow: RGBA(hex: 0xF59E0B), trafficJam: RGBA(hex: 0xDC2626),
                               maneuverArrow: RGBA(hex: 0xFFFFFF), maneuverArrowCasing: RGBA(hex: 0x60356B)),
            puck: PuckDesign(fill: RGBA(hex: 0xFFFFFF), stroke: RGBA(hex: 0xE9480D),
                             halo: RGBA(hex: 0xE9480D, alpha: 0.28), accuracy: RGBA(hex: 0xE9480D, alpha: 0.10)),
            labels: LabelColors(text: RGBA(hex: 0x3A3A36), halo: RGBA(hex: 0xF4F1E8, alpha: 0.9),
                                roadText: RGBA(hex: 0x4A4A44), roadHalo: RGBA(hex: 0xFFFFFF, alpha: 0.9),
                                shieldFill: RGBA(hex: 0x2F5AA8), shieldText: RGBA(hex: 0xFFFFFF), shieldStroke: RGBA(hex: 0xFFFFFF)),
            accent: RGBA(hex: 0xE9480D))
    }

    /// KartoKit-Standardtheme nach `map-style-tokens.json` (Beispiel in Tests/KartoCoreTests/Fixtures):
    /// warm-neutrale Karte, Plum/Lilac-Route, Signal-Orange nur für Position und Empfehlung,
    /// Straßenhierarchie über Breite und Casing statt Farbe. Puck = `NavigationArrow`-Asset.
    public static func kartoKit(dark: Bool) -> MapTheme {
        let d = dark
        // Vegetation in der Farbfamilie um 0xB5E5AC, neutrales Land um 0xDDE3D8 –
        // eine Stufe heller und ruhiger gehalten.
        let land = RGBA(hex: d ? 0x111310 : 0xE4E7DB)
        let urban = RGBA(hex: d ? 0x171916 : 0xE6E4E8)
        let casing = RGBA(hex: d ? 0x090B09 : 0xC9C6BD)
        let signal = RGBA(hex: d ? 0xFF6A2B : 0xE9480D)
        // Neues Plum: gegen die jetzt gruene Karte hatte 0x60356B zu wenig
        // Leuchtkraft. Gleiche Farbfamilie (Farbton 286 statt 283 Grad),
        // aber Helligkeit 42 -> 63 Prozent, Saettigung 50 -> 71 Prozent.
        let route = RGBA(hex: d ? 0xD8A6E2 : 0x7B2FA0)
        let routeCasing = RGBA(hex: d ? 0x0B0D0B : 0xFFFDF8)
        let motorway = RGBA(hex: d ? 0x343630 : 0xFCF9F1)
        let primary = RGBA(hex: d ? 0x2B2D28 : 0xF7F4EC)
        let secondary = RGBA(hex: d ? 0x252722 : 0xF1EEE6)
        let local = RGBA(hex: d ? 0x1E201C : 0xE8E5DE)
        var t = MapTheme(
            name: d ? "KartoKit Night" : "KartoKit Day", isDark: d,
            background: land, land: land,
            // Flaechen bewusst unterscheidbar: ruhige, neutrale Stadt, gruenes
            // Land, blaues Wasser und drei statt einer Stadtflaeche (Wohnen,
            // Gewerbe, Flughafen). Eine einfarbige Karte liest sich im Fahren
            // schlecht.
            water: RGBA(hex: d ? 0x102833 : 0x8FCEE5), waterway: RGBA(hex: d ? 0x102833 : 0x8FCEE5),
            park: RGBA(hex: d ? 0x17281E : 0xC3E3AE), forest: RGBA(hex: d ? 0x122117 : 0xB2DA9E),
            farmland: RGBA(hex: d ? 0x161A12 : 0xD2E6C2),
            residential: urban, industrial: RGBA(hex: d ? 0x141613 : 0xDEDBD8),
            aeroway: RGBA(hex: d ? 0x101210 : 0xD9D7DC),
            building: RGBA(hex: d ? 0x22241F : 0xDAD7CE), buildingOutline: RGBA(hex: d ? 0x30322D : 0xC5C2B9),
            boundary: RGBA(hex: d ? 0x41433E : 0xBEBCB4),
            roads: [
                .motorway: RoadColors(fill: motorway, casing: casing), .trunk: RoadColors(fill: motorway, casing: casing),
                .primary: RoadColors(fill: primary, casing: casing),
                .secondary: RoadColors(fill: secondary, casing: casing), .tertiary: RoadColors(fill: secondary, casing: casing),
                .minor: RoadColors(fill: local, casing: casing), .service: RoadColors(fill: local, casing: nil),
                .path: RoadColors(fill: RGBA(hex: d ? 0x2A2C27 : 0xDCD9D1), casing: nil),
                .rail: RoadColors(fill: RGBA(hex: d ? 0x555750 : 0xAAA8A1), casing: nil),
            ],
            route: RouteColors(active: route, casing: routeCasing,
                               driven: RGBA(hex: d ? 0x5A4A5E : 0xB9AEBC), drivenCasing: routeCasing,
                               alternative: RGBA(hex: d ? 0x686865 : 0x9B9992), alternativeCasing: routeCasing,
                               trafficSlow: RGBA(hex: d ? 0xF0AA3C : 0xD99022), trafficJam: RGBA(hex: d ? 0xFF6557 : 0xD64B3E),
                               trafficClosed: RGBA(hex: d ? 0xD9364F : 0x8B1E2D),
                               trafficClosedHatch: RGBA(hex: d ? 0x1A0F12 : 0xF7F3EA),
                               maneuverArrow: RGBA(hex: d ? 0xF4F1E8 : 0xFFFDF8), maneuverArrowCasing: route),
            // Brand-Pfeil (Asset `NavigationArrow` aus dem Brand-Package, 40 pt in der Navigation);
            // Genauigkeit dezent, Kegel/Puls separat in Code.
            //
            // Der Halo war hier bewusst abgeschaltet ("entfaellt laut Konzept").
            // Er kommt zurueck, aber nicht als die harte Scheibe von damals:
            // halo_fragment laesst ihn nach aussen quadratisch auslaufen, wie
            // der übliche blaue Schein. Weiss, weil der Pfeil selbst dunkel
            // ist und der Schein ihn vom Untergrund abheben soll — auf heller
            // Karte wie auf Satellitenbild.
            puck: PuckDesign(shape: .image(name: "NavigationArrow"), size: 40,
                             fill: RGBA(hex: d ? 0xE8E4DA : 0x171816), stroke: RGBA(hex: d ? 0x0B0D0B : 0xF4F1E8),
                             strokeRatio: 0.12,
                             halo: RGBA(hex: 0xFFFFFF, alpha: d ? 0.50 : 0.70), haloRadius: 26,
                             accuracy: RGBA(signal.r, signal.g, signal.b, 0.10), stale: RGBA(hex: 0x777872)),
            labels: LabelColors(text: RGBA(hex: d ? 0xE8E4DA : 0x333431), halo: RGBA(hex: d ? 0x111310 : 0xF4F1E8, alpha: 0.9),
                                roadText: RGBA(hex: d ? 0xC7C4BA : 0x555650), roadHalo: RGBA(hex: d ? 0x111310 : 0xF4F1E8, alpha: 0.9),
                                shieldFill: RGBA(hex: d ? 0x343630 : 0xFCF9F1), shieldText: RGBA(hex: d ? 0xE8E4DA : 0x333431),
                                shieldStroke: casing),
            accent: signal)
        // Verkehrssaum. Das Gruen liegt je nach
        // Strassenklasse zwischen 0x2CAB55 und 0x32FA70; wir nehmen die
        // Mitte, damit der Saum liest ohne zu schreien.
        t.route.trafficFree = RGBA(hex: d ? 0x1E9A45 : 0x2FBF5C)
        t.extra = [
            "labelSecondary": RGBA(hex: d ? 0xA7A49C : 0x686A65),
            "labelWater": RGBA(hex: d ? 0x7FA2AA : 0x607C82),
            "labelPark": RGBA(hex: d ? 0x8BA088 : 0x5E725B),
            "labelPOI": RGBA(hex: d ? 0xB9B4A8 : 0x6B6760),
            // Straßenschilder nach deutscher Konvention: Autobahn blau/weiß, Bundesstraße gelb/schwarz
            "shieldMotorwayFill": RGBA(hex: d ? 0x2A4F93 : 0x2F5AA8), "shieldMotorwayText": RGBA(hex: 0xFFFFFF),
            "shieldPrimaryFill": RGBA(hex: d ? 0xC9A227 : 0xF2C230), "shieldPrimaryText": RGBA(hex: 0x1E1E1C),
            "poiNeutral": RGBA(hex: d ? 0xB8B5AD : 0x5D5F5A),
            "chargingAvailable": RGBA(hex: d ? 0x5DE1B8 : 0x0B7563),
            "chargingUnavailable": RGBA(hex: 0x777872),
            "bridgeCasing": RGBA(hex: d ? 0x050705 : 0xB8B5AD),
            "tunnelRoad": RGBA(hex: d ? 0x1B1D19 : 0xE2DFD7),
            "tunnelCasing": RGBA(hex: d ? 0x30322D : 0xD0CDC4),
        ]
        return t
    }
}

/// Kachelschema der Quelle – bestimmt, welche Style-Erzeugung ein Theme durchläuft.
public enum TileSchema: String, Sendable, Codable {
    case openMapTiles, protomaps

    /// - Parameter extrudeBuildings: Gebaeude als Koerper statt als Grundriss.
    ///
    /// Bewusst hier und nicht im Theme: Alle Themes muessen dieselbe
    /// Layer-Struktur ergeben, sonst braucht ein Tag/Nacht-Wechsel einen
    /// Kachel-Neuaufbau und die Ueberblendung bricht. Ein Schalter am
    /// Theme koennte diese Regel je Theme verletzen — hier gilt er fuer
    /// alle gleich.
    public func style(theme: MapTheme, extrudeBuildings: Bool = true) -> MapStyle {
        switch self {
        case .openMapTiles: return .openMapTiles(theme: theme, extrudeBuildings: extrudeBuildings)
        case .protomaps: return .protomaps(theme: theme, extrudeBuildings: extrudeBuildings)
        }
    }
}
