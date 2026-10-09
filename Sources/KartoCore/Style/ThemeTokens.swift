import Foundation

/// Lädt Theme-Werte aus einer Design-Tokens-Datei (Format designtokens.org, wie
/// `design-tokens.json` eines Brand-Packages). Unbekannte Tokens werden ignoriert,
/// fehlende bleiben auf dem Basis-Theme – so kann ein Marken-Kit nur die Route und den
/// Puck überschreiben und den Rest der Karte vom Standard-Theme übernehmen.
///
/// Token-Pfade (Punkt-getrennt), alle optional:
///
///     map.background map.land map.water map.waterway map.park map.forest map.farmland
///     map.residential map.industrial map.aeroway map.building map.buildingOutline map.boundary
///     map.roads.<motorway|trunk|primary|secondary|tertiary|minor|service|path|rail>.fill / .casing
///     route.active route.casing route.driven route.drivenCasing route.alternative
///     route.alternativeCasing route.trafficSlow route.trafficJam route.maneuverArrow
///     route.maneuverArrowCasing route.activeWidth route.casingWidth route.alternativeWidth
///     puck.shape ("arrow" | "chevron" | "image:<Assetname>") puck.size puck.haloRadius
///     puck.fill puck.stroke puck.halo puck.accuracy puck.stale
///     labels.text labels.halo labels.roadText labels.roadHalo labels.shieldFill labels.shieldText labels.shieldStroke
///     brand.accent
///
/// Zusätzlich werden Brand-Tokens verstanden (`brand.routeLight/routeDark`,
/// `brand.signalLight/signalDark`, `brand.alternativeLight/alternativeDark`,
/// `brand.ink`, `brand.paper`) und je nach `dark` auf Route, Puck und Akzent abgebildet.
public enum ThemeTokens {
    public enum Error: Swift.Error { case invalidJSON, invalidColor(String) }

    public static func apply(json data: Data, to base: MapTheme, dark: Bool? = nil) throws -> MapTheme {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Error.invalidJSON }
        var flat: [String: Any] = [:]
        flatten(root, prefix: "", into: &flat)
        // Aliase "{a.b}" auflösen (eine Ebene)
        for (k, v) in flat {
            if let s = v as? String, s.hasPrefix("{"), s.hasSuffix("}") {
                let ref = String(s.dropFirst().dropLast())
                if let target = flat[ref] { flat[k] = target }
            }
        }
        var t = base
        let isDark = dark ?? base.isDark

        // `map-style-tokens.json`: Gruppen map.day.* / map.night.*
        let mode = isDark ? "night" : "day"
        if flat.keys.contains(where: { $0.hasPrefix("map.\(mode).") }) {
            func mc(_ k: String) -> RGBA? { (flat["map.\(mode).\(k)"] as? String).flatMap { RGBA(css: $0) } }
            if let c = mc("land") { t.background = c; t.land = c; t.farmland = c }
            if let c = mc("urban") { t.residential = c; t.industrial = c; t.aeroway = c }
            if let c = mc("building") { t.building = c }
            if let c = mc("buildingOutline") { t.buildingOutline = c }
            if let c = mc("park") { t.park = c }
            if let c = mc("forest") { t.forest = c }
            if let c = mc("water") { t.water = c; t.waterway = c }
            let casing = mc("roadCasing")
            if let c = mc("motorway") { t.roads[.motorway] = RoadColors(fill: c, casing: casing); t.roads[.trunk] = RoadColors(fill: c, casing: casing) }
            if let c = mc("primaryRoad") { t.roads[.primary] = RoadColors(fill: c, casing: casing) }
            if let c = mc("secondaryRoad") { t.roads[.secondary] = RoadColors(fill: c, casing: casing); t.roads[.tertiary] = RoadColors(fill: c, casing: casing) }
            if let c = mc("localRoad") { t.roads[.minor] = RoadColors(fill: c, casing: casing); t.roads[.service] = RoadColors(fill: c, casing: nil) }
            if let c = mc("rail") { t.roads[.rail] = RoadColors(fill: c, casing: nil) }
            if let c = mc("boundary") { t.boundary = c }
            if let c = mc("labelPrimary") { t.labels.text = c; t.labels.shieldText = c }
            if let c = mc("labelRoad") { t.labels.roadText = c }
            if let c = mc("labelHalo") { t.labels.halo = RGBA(c.r, c.g, c.b, 0.9); t.labels.roadHalo = t.labels.halo }
            if let c = mc("route") { t.route.active = c; t.route.maneuverArrowCasing = c }
            if let c = mc("routeCasing") { t.route.casing = c; t.route.drivenCasing = c; t.route.alternativeCasing = c }
            if let c = mc("alternativeRoute") { t.route.alternative = c }
            if let c = mc("trafficModerate") { t.route.trafficSlow = c }
            if let c = mc("trafficHeavy") { t.route.trafficJam = c }
            if let c = mc("trafficClosed") { t.route.trafficClosed = c }
            if let c = mc("trafficFree") { t.route.trafficFree = c }
            if let c = mc("signal") { t.accent = c; t.puck.accuracy = RGBA(c.r, c.g, c.b, 0.10) }
            for k in ["labelSecondary", "labelWater", "labelPark", "poiNeutral", "chargingAvailable", "chargingUnavailable", "bridgeCasing", "tunnelRoad", "tunnelCasing"] {
                if let c = mc(k) { t.extra[k] = c }
            }
            t.isDark = isDark
        }

        func color(_ key: String) throws -> RGBA? {
            guard let v = flat[key] else { return nil }
            guard let s = v as? String, let c = RGBA(css: s) else { throw Error.invalidColor(key) }
            return c
        }
        func number(_ key: String) -> Double? {
            guard let v = flat[key] else { return nil }
            if let d = v as? Double { return d }
            if let i = v as? Int { return Double(i) }
            if let dict = v as? [String: Any], let d = dict["value"] as? Double { return d }
            if let dict = v as? [String: Any], let i = dict["value"] as? Int { return Double(i) }
            if let s = v as? String, let d = Double(s.replacingOccurrences(of: "pt", with: "")) { return d }
            return nil
        }

        // Karte
        if let c = try color("map.background") { t.background = c }
        if let c = try color("map.land") { t.land = c }
        if let c = try color("map.water") { t.water = c; t.waterway = c }
        if let c = try color("map.waterway") { t.waterway = c }
        if let c = try color("map.park") { t.park = c }
        if let c = try color("map.forest") { t.forest = c }
        if let c = try color("map.farmland") { t.farmland = c }
        if let c = try color("map.residential") { t.residential = c }
        if let c = try color("map.industrial") { t.industrial = c }
        if let c = try color("map.aeroway") { t.aeroway = c }
        if let c = try color("map.building") { t.building = c }
        if let c = try color("map.buildingOutline") { t.buildingOutline = c }
        if let c = try color("map.boundary") { t.boundary = c }
        for rc in RoadClass.allCases {
            if let c = try color("map.roads.\(rc.rawValue).fill") { t.roads[rc, default: RoadColors(fill: c)].fill = c }
            if let c = try color("map.roads.\(rc.rawValue).casing") { t.roads[rc, default: RoadColors(fill: c)].casing = c }
        }
        // Route
        if let c = try color("route.active") { t.route.active = c }
        if let c = try color("route.casing") { t.route.casing = c }
        if let c = try color("route.driven") { t.route.driven = c }
        if let c = try color("route.drivenCasing") { t.route.drivenCasing = c }
        if let c = try color("route.alternative") { t.route.alternative = c }
        if let c = try color("route.alternativeCasing") { t.route.alternativeCasing = c }
        if let c = try color("route.trafficSlow") { t.route.trafficSlow = c }
        if let c = try color("route.trafficJam") { t.route.trafficJam = c }
        if let c = try color("route.maneuverArrow") { t.route.maneuverArrow = c }
        if let c = try color("route.maneuverArrowCasing") { t.route.maneuverArrowCasing = c }
        if let n = number("route.activeWidth") { t.route.activeWidth = n }
        if let n = number("route.casingWidth") { t.route.casingWidth = n }
        if let n = number("route.alternativeWidth") { t.route.alternativeWidth = n }
        // Puck
        if let s = flat["puck.shape"] as? String {
            if s == "arrow" { t.puck.shape = .arrow }
            else if s == "chevron" { t.puck.shape = .chevron }
            else if s.hasPrefix("image:") { t.puck.shape = .image(name: String(s.dropFirst(6))) }
        }
        if let n = number("puck.size") { t.puck.size = n }
        if let n = number("puck.haloRadius") { t.puck.haloRadius = n }
        if let c = try color("puck.fill") { t.puck.fill = c }
        if let c = try color("puck.stroke") { t.puck.stroke = c }
        if let c = try color("puck.halo") { t.puck.halo = c }
        if let c = try color("puck.accuracy") { t.puck.accuracy = c }
        if let c = try color("puck.stale") { t.puck.stale = c }
        // Labels
        if let c = try color("labels.text") { t.labels.text = c }
        if let c = try color("labels.halo") { t.labels.halo = c }
        if let c = try color("labels.roadText") { t.labels.roadText = c }
        if let c = try color("labels.roadHalo") { t.labels.roadHalo = c }
        if let c = try color("labels.shieldFill") { t.labels.shieldFill = c }
        if let c = try color("labels.shieldText") { t.labels.shieldText = c }
        if let c = try color("labels.shieldStroke") { t.labels.shieldStroke = c }
        if let c = try color("brand.accent") { t.accent = c }

        // Brand-Tokens (Light/Dark-Paare)
        let suffix = isDark ? "Dark" : "Light"
        if let c = try color("brand.route\(suffix)") {
            t.route.active = c
            t.route.maneuverArrowCasing = c
        }
        if let c = try color("brand.signal\(suffix)") {
            t.accent = c
            t.puck.stroke = c
            t.puck.halo = RGBA(c.r, c.g, c.b, isDark ? 0.35 : 0.28)
            t.puck.accuracy = RGBA(c.r, c.g, c.b, 0.10)
        }
        if let c = try color("brand.alternative\(suffix)") { t.route.alternative = c }
        if let ink = try color("brand.ink"), let paper = try color("brand.paper") {
            t.route.casing = isDark ? ink : paper
            t.route.alternativeCasing = t.route.casing
            t.puck.fill = isDark ? ink : paper
        }
        t.isDark = isDark
        return t
    }

    static func flatten(_ dict: [String: Any], prefix: String, into out: inout [String: Any]) {
        for (k, v) in dict {
            if k.hasPrefix("$") { continue }
            let key = prefix.isEmpty ? k : prefix + "." + k
            if let d = v as? [String: Any] {
                if let value = d["$value"] {
                    out[key] = value
                } else {
                    flatten(d, prefix: key, into: &out)
                }
            } else {
                out[key] = v
            }
        }
    }
}

public extension RGBA {
    /// "#RRGGBB", "#RRGGBBAA", "#RGB" oder "rgba(r,g,b,a)".
    init?(css: String) {
        var s = css.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s.removeFirst()
            if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
            guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
            if s.count == 8 {
                self.init(hex: v >> 8, alpha: Float(v & 0xFF) / 255)
            } else {
                self.init(hex: v)
            }
            return
        }
        if s.hasPrefix("rgba(") || s.hasPrefix("rgb(") {
            let inner = s.drop { $0 != "(" }.dropFirst().dropLast()
            let parts = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count >= 3 else { return nil }
            self.init(Float(parts[0] / 255), Float(parts[1] / 255), Float(parts[2] / 255), Float(parts.count > 3 ? parts[3] : 1))
            return
        }
        return nil
    }

    var hexString: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    static func lerp(_ a: RGBA, _ b: RGBA, _ t: Float) -> RGBA {
        RGBA(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
    }
}
