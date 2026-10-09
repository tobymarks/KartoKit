import Foundation

/// Farbe mit Komponenten in [0,1].
public struct RGBA: Hashable, Sendable {
    public var r: Float, g: Float, b: Float, a: Float
    public init(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, alpha: Float = 1) {
        r = Float((hex >> 16) & 0xFF) / 255
        g = Float((hex >> 8) & 0xFF) / 255
        b = Float(hex & 0xFF) / 255
        a = alpha
    }
    public var floats: [Float] { [r, g, b, a] }
    /// Vollständig transparent – Layer mit dieser Farbe werden vom Renderer übersprungen.
    public static let transparent = RGBA(0, 0, 0, 0)
}

/// Zoomabhängiger Wert mit Stützstellen, exponentiell interpoliert (wie Mapbox `exponential`).
public struct ZoomStops: Sendable, Hashable {
    public var stops: [(zoom: Double, value: Double)]
    public var base: Double

    public init(_ stops: [(Double, Double)], base: Double = 1.4) {
        self.stops = stops.map { (zoom: $0.0, value: $0.1) }.sorted { $0.zoom < $1.zoom }
        self.base = base
    }

    public static func constant(_ v: Double) -> ZoomStops { ZoomStops([(0, v)]) }

    public func value(at zoom: Double) -> Double {
        guard let first = stops.first else { return 0 }
        if zoom <= first.zoom { return first.value }
        guard let last = stops.last, zoom < last.zoom else { return stops.last?.value ?? 0 }
        var i = 0
        while i + 1 < stops.count, stops[i + 1].zoom <= zoom { i += 1 }
        let a = stops[i], b = stops[i + 1]
        let range = b.zoom - a.zoom
        let t = (zoom - a.zoom) / range
        let f: Double
        if abs(base - 1) < 1e-6 {
            f = t
        } else {
            f = (pow(base, t * range) - 1) / (pow(base, range) - 1)
        }
        return a.value + (b.value - a.value) * f
    }

    public static func == (l: ZoomStops, r: ZoomStops) -> Bool {
        l.base == r.base && l.stops.map { $0.zoom } == r.stops.map { $0.zoom } && l.stops.map { $0.value } == r.stops.map { $0.value }
    }
    public func hash(into h: inout Hasher) {
        h.combine(base)
        for s in stops { h.combine(s.zoom); h.combine(s.value) }
    }
}

/// Feature-Filter. Als Closure statt Expression-Baum: schnell, typsicher, keine JSON-Auswertung.
public typealias FeatureFilter = @Sendable (VectorTileFeature) -> Bool

public enum LayerPaint: Sendable {
    case fill(color: RGBA)
    /// Breite in Bildschirm-Pixeln (zoomabhängig). Optional Umrandung/Casing.
    case line(color: RGBA, width: ZoomStops)
    /// Gebäude/Extrusion. Höhe aus Attribut in Metern, Fallback-Höhe wenn Attribut fehlt.
    case extrusion(color: RGBA, heightKey: String, baseKey: String?, defaultHeight: Double)
}

public struct StyleLayer: Sendable, Identifiable {
    public var id: String
    public var sourceLayer: String
    public var minZoom: Double
    public var maxZoom: Double
    public var filter: FeatureFilter?
    public var paint: LayerPaint

    public init(id: String, sourceLayer: String, minZoom: Double = 0, maxZoom: Double = 24,
                filter: FeatureFilter? = nil, paint: LayerPaint) {
        self.id = id
        self.sourceLayer = sourceLayer
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.filter = filter
        self.paint = paint
    }

    public func matches(_ f: VectorTileFeature) -> Bool {
        filter?(f) ?? true
    }
}

/// Ein Style = geordnete Layer-Liste (Zeichenreihenfolge von unten nach oben) + Hintergrund.
public struct MapStyle: Sendable {
    public var background: RGBA
    public var layers: [StyleLayer]
    /// Lichtrichtung für die Extrusions-Schattierung (normalisiert, z nach oben).
    public var lightDirection: (x: Float, y: Float, z: Float)
    /// Tonstreuung der Gebäude, aus dem Theme übernommen (siehe
    /// `MapTheme.buildingTonStaerke`).
    public var buildingTonStaerke: Float

    public init(background: RGBA, layers: [StyleLayer],
                lightDirection: (Float, Float, Float) = (0.4, -0.3, 0.85),
                buildingTonStaerke: Float = 0.07) {
        self.background = background
        self.layers = layers
        self.lightDirection = lightDirection
        self.buildingTonStaerke = buildingTonStaerke
    }

    public func layers(forSourceLayer name: String) -> [StyleLayer] {
        layers.filter { $0.sourceLayer == name }
    }
}

// MARK: - Filter-Helfer

public enum Filters {
    public static func equals(_ key: String, _ value: String) -> FeatureFilter {
        { $0.properties[key]?.stringValue == value }
    }
    public static func oneOf(_ key: String, _ values: Set<String>) -> FeatureFilter {
        { f in
            guard let v = f.properties[key]?.stringValue else { return false }
            return values.contains(v)
        }
    }
    /// Wert unter einem von mehreren Schlüsseln (Schema-Varianten wie `kind` / `pmap:kind`).
    public static func oneOf(keys: [String], _ values: Set<String>) -> FeatureFilter {
        { f in
            for k in keys {
                if let v = f.properties[k]?.stringValue { return values.contains(v) }
            }
            return false
        }
    }
    public static func has(_ key: String) -> FeatureFilter {
        { $0.properties[key] != nil }
    }
    public static func not(_ f: @escaping FeatureFilter) -> FeatureFilter {
        { !f($0) }
    }
    public static func all(_ fs: [FeatureFilter]) -> FeatureFilter {
        { f in fs.allSatisfy { $0(f) } }
    }
    public static func geometry(_ t: GeometryType) -> FeatureFilter {
        { $0.type == t }
    }
}

// MARK: - Verkehrsfluss

public extension MapStyle {
    /// Stil fuer die Verkehrsfluss-Kacheln (Layer "Traffic flow").
    ///
    /// Verkehrsdienste liefern je Strassenstueck traffic_level zwischen 0 und 1:
    /// 1 heisst freie Fahrt, 0 steht. Daraus vier Stufen statt eines
    /// stufenlosen Verlaufs - eine Farbe, die sich staendig leicht
    /// aendert, liest im Fahren niemand.
    ///
    /// Gezeichnet wird nur, was gemeldet ist. Fehlt traffic_level,
    /// bleibt die Strasse in ihrer Kartenfarbe: keine Farbe ist eine
    /// ehrlichere Aussage als ein geratenes Gruen.
    static func verkehrsfluss(dark: Bool) -> MapStyle {
        let d = dark
        let frei = RGBA(hex: d ? 0x1E9A45 : 0x2FBF5C)
        let zaeh = RGBA(hex: d ? 0xC8A63A : 0xE0A62A)
        let stau = RGBA(hex: d ? 0xD9603A : 0xD9542F)
        let steht = RGBA(hex: d ? 0xB03040 : 0xA8232F)
        func stufe(_ kennung: String, _ von: Double, _ bis: Double, _ c: RGBA) -> StyleLayer {
            StyleLayer(id: kennung, sourceLayer: "Traffic flow", minZoom: 10,
                       filter: { f in
                           guard let v = f.properties["traffic_level"]?.doubleValue
                           else { return false }
                           return v >= von && v < bis
                       },
                       paint: .line(color: c,
                                    width: ZoomStops([(10, 2.0), (13, 3.5), (16, 5.0)])))
        }
        _ = frei
        return MapStyle(background: RGBA(0, 0, 0, 0), layers: [
            // Schwellen an gemessenen Kacheln geeicht: traffic_level ist
            // Ist-Tempo geteilt durch Freiflusstempo, und der Median lag
            // im Raum Stuttgart bei 0,66 - bei 0,75 waere die halbe Stadt
            // dauerhaft gelb und die Farbe damit wertlos.
            //
            // Freier Verkehr wird nicht gezeichnet. Er ist der Normalfall
            // und braucht keine Farbe - gemessen an einer Aufnahme aus
            // Pforzheim waren 26.073 Bildpunkte reines 0x2FBF5C, verteilt
            // ueber das ganze Strassennetz. Damit war Gruen die haeufigste
            // Farbe im Bild und die geplante Route, die einzige Linie, die
            // zaehlt, nicht mehr die auffaelligste. Wer faehrt, muss "zaeh"
            // von "steht" unterscheiden - dass die Nebenstrasse zwei Orte
            // weiter frei ist, muss niemand wissen.
            stufe("fluss-zaeh", 0.40, 0.60, zaeh),
            stufe("fluss-stau", 0.20, 0.40, stau),
            stufe("fluss-steht", -0.01, 0.20, steht),
        ])
    }
}
