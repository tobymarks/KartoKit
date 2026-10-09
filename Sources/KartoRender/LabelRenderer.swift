#if canImport(UIKit) && canImport(Metal)
import UIKit
import Metal
import KartoCore

/// Zeichnet Kartenbeschriftungen: Platzierung durch `LabelPlacer` (KartoCore), Text als
/// Atlas-Sprites mit Halo (Kontur), Schilder als farbige Box + Text.
/// Straßennamen werden gedreht entlang gerader Abschnitte gesetzt (v1: gerade Fenster,
/// nicht entlang von Kurven gebogen).
@MainActor
final class LabelRenderer {
    private let atlas: IconAtlas
    private var placer = LabelPlacer()
    private var measureCache: [String: (Double, Double)] = [:]

    /// Namen mit Vorrang (aktuelle + nächste Straße im Navi).
    var highlightedNames: Set<String> {
        get { placer.highlighted } set { placer.highlighted = newValue }
    }
    /// Skalierung der Schriftgrößen (CarPlay: 1.15–1.3).
    var labelScale: Double {
        get { placer.options.labelScale } set { placer.options.labelScale = newValue }
    }

    init(atlas: IconAtlas) { self.atlas = atlas }

    private func measure(_ text: String, _ size: Double, _ bold: Bool) -> (width: Double, height: Double) {
        let key = "\(bold ? "b" : "r")\(Int(size * 4))|\(text)"
        if let m = measureCache[key] { return m }
        let font = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium)
        let s = NSString(string: text).size(withAttributes: [.font: font])
        let m = (Double(s.width), Double(s.height))
        if measureCache.count > 4000 { measureCache.removeAll() }
        measureCache[key] = m
        return m
    }

    /// Liefert die Anzahl gezeichneter Labels.
    @discardableResult
    func draw(tiles: [GPUTile], vp: ViewProjection, batch: SpriteBatch, theme: MapTheme,
              reserved: [CollisionGrid.Box], navigating: Bool) -> Int {
        let inputs = tiles.compactMap { t -> (candidates: [LabelCandidate], matrix: Mat4, extent: Double)? in
            guard !t.labels.isEmpty else { return nil }
            return (t.labels, vp.tileMatrix(for: t.id, extent: Double(t.extent)), Double(t.extent))
        }
        guard !inputs.isEmpty else { return 0 }
        // Fahransicht sehr aufgeräumt, Stöbern etwas dichter (labelScale bleibt erhalten).
        let scale = placer.options.labelScale
        placer.options = navigating ? .navigation : .browsing
        placer.options.labelScale = scale
        let placed = placer.place(tiles: inputs, viewport: (vp.width, vp.height), zoom: vp.camera.zoom,
                                  reserved: reserved, measure: { [self] t, s, b in measure(t, s, b) })
        let labels = theme.labels
        for l in placed {
            switch l.kind {
            case .shield(let cls):
                let (tw, th) = measure(l.text, l.fontSize, true)
                let w = tw + 10, h = th + 4
                // Regel und Begruendung: LabelExtractor.autobahnschild
                let motorway = LabelExtractor.autobahnschild(text: l.text, klasse: cls)
                let fill = (motorway ? theme.extra["shieldMotorwayFill"] : theme.extra["shieldPrimaryFill"]) ?? labels.shieldFill
                let textColor = (motorway ? theme.extra["shieldMotorwayText"] : theme.extra["shieldPrimaryText"]) ?? labels.shieldText
                batch.addSolidRect(center: l.center, size: Vec2(w + 2, h + 2), color: labels.shieldStroke)
                batch.addSolidRect(center: l.center, size: Vec2(w, h), color: fill)
                if let r = atlas.region(for: .text(l.text, size: l.fontSize, weight: 700, color: IconAtlas.pack(textColor), halo: IconAtlas.pack(RGBA(0, 0, 0, 0)))) {
                    batch.addQuad(center: l.center, size: Vec2(r.width, r.height), uv: (r.u0, r.v0, r.u1, r.v1))
                }
            case .road:
                if let r = atlas.region(for: .text(l.text, size: l.fontSize, weight: 500, color: IconAtlas.pack(labels.roadText), halo: IconAtlas.pack(labels.roadHalo))) {
                    batch.addQuad(center: l.center, size: Vec2(r.width, r.height), rotation: l.rotation, uv: (r.u0, r.v0, r.u1, r.v1))
                }
            case .water:
                let c = theme.extra["labelWater"] ?? labels.text
                if let r = atlas.region(for: .text(l.text, size: l.fontSize, weight: 500, color: IconAtlas.pack(c), halo: IconAtlas.pack(labels.halo))) {
                    batch.addQuad(center: l.center, size: Vec2(r.width, r.height), uv: (r.u0, r.v0, r.u1, r.v1))
                }
            case .park:
                let c = theme.extra["labelPark"] ?? labels.text
                if let r = atlas.region(for: .text(l.text, size: l.fontSize, weight: 500, color: IconAtlas.pack(c), halo: IconAtlas.pack(labels.halo))) {
                    batch.addQuad(center: l.center, size: Vec2(r.width, r.height), uv: (r.u0, r.v0, r.u1, r.v1))
                }
            case .poi:
                let c = theme.extra["labelPOI"] ?? labels.text
                if let r = atlas.region(for: .text(l.text, size: l.fontSize, weight: 500, color: IconAtlas.pack(c), halo: IconAtlas.pack(labels.halo))) {
                    batch.addQuad(center: l.center, size: Vec2(r.width, r.height), uv: (r.u0, r.v0, r.u1, r.v1))
                }
            default:
                if let r = atlas.region(for: .text(l.text, size: l.fontSize, weight: l.isBold ? 700 : 500, color: IconAtlas.pack(labels.text), halo: IconAtlas.pack(labels.halo))) {
                    batch.addQuad(center: l.center, size: Vec2(r.width, r.height), uv: (r.u0, r.v0, r.u1, r.v1))
                }
            }
        }
        return placed.count
    }
}
#endif
