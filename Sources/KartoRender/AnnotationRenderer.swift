#if canImport(UIKit) && canImport(Metal)
import UIKit
import Metal
import QuartzCore
import KartoCore

/// Zeichnet Marker als Bildschirm-Quads (über `SpriteBatch`), sortiert nach Priorität,
/// mit Kollisionsvermeidung, und merkt sich die Bildschirm-Rechtecke für Hit-Tests.
@MainActor
final class AnnotationRenderer {
    struct Placed {
        let annotation: MapAnnotation
        let box: CollisionGrid.Box
    }

    private let atlas: IconAtlas
    private(set) var placed: [Placed] = []
    /// Beschriftungen, die im letzten Bild standen — samt aktueller Deckkraft.
    ///
    /// Ohne dieses Gedaechtnis flackern Marker-Beschriftungen waehrend der Fahrt:
    /// Das Kollisionsgitter wird jedes Bild neu aufgebaut, und eine Beschriftung,
    /// die gerade an der Grenze zwischen "passt" und "passt nicht" liegt, wird
    /// sechzigmal in der Sekunde ein- und ausgeschaltet. Auf dem CarPlay-Schirm
    /// sieht das aus, als blinke die Anzeige.
    ///
    /// Zwei Massnahmen dagegen: Wer schon stand, wird zuerst platziert und darf
    /// enger stehen (Beharrung), und der Wechsel wird ueber gut eine Zehntel-
    /// sekunde auf- und abgeblendet statt hart geschaltet.
    private var labelOpacity: [String: Double] = [:]
    private var lastFrameTime: CFTimeInterval = 0
    /// Dauer des Ein- und Ausblendens in Sekunden.
    private let labelFadeSeconds = 0.18
    /// True, solange mindestens eine Beschriftung mitten im Blenden steht.
    /// Der Renderer haengt daran ein weiteres Bild an, sonst friert die
    /// Ueberblendung ein, sobald die Karte still steht.
    private(set) var blendetGerade = false

    init(atlas: IconAtlas) { self.atlas = atlas }

    /// Projiziert und sammelt die Quads im Batch. `reserved` = Boxen, die frei bleiben (Puck).
    func draw(_ annotations: [MapAnnotation], vp: ViewProjection, batch: SpriteBatch, theme: MapTheme,
              reserved: [CollisionGrid.Box], now: CFTimeInterval = CACurrentMediaTime()) {
        placed.removeAll(keepingCapacity: true)
        blendetGerade = false
        let dt = lastFrameTime > 0 ? min(max(now - lastFrameTime, 0), 0.25) : 0
        lastFrameTime = now
        guard !annotations.isEmpty else { labelOpacity.removeAll(keepingCapacity: true); return }
        var grid = CollisionGrid(cellSize: 48)
        for r in reserved { grid.insert(r, force: true) }

        // Nach Priorität (hoch zuerst), dann nach Bildschirm-Y (weiter unten = "näher" bei Neigung → zuerst)
        struct Candidate { let a: MapAnnotation; let screen: Vec2 }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(annotations.count)
        let margin = 60.0
        for a in annotations {
            guard let s = vp.project(unitMercator: Mercator.project(a.coordinate)) else { continue }
            guard s.x > -margin, s.x < vp.width + margin, s.y > -margin, s.y < vp.height + margin else { continue }
            candidates.append(Candidate(a: a, screen: s))
        }
        // Wer im letzten Bild schon stand, kommt zuerst dran. Das ist die
        // Beharrung: Sie verhindert, dass zwei gleichrangige Marker sich das
        // Gitter Bild fuer Bild gegenseitig wegnehmen, sobald ihre Bildschirm-
        // hoehe beim Fahren aneinander vorbeizieht.
        let stand = labelOpacity
        candidates.sort {
            let a0 = stand[$0.a.id] ?? 0, a1 = stand[$1.a.id] ?? 0
            if (a0 > 0) != (a1 > 0) { return a0 > a1 }
            return ($0.a.priority, $0.screen.y) > ($1.a.priority, $1.screen.y)
        }

        for c in candidates {
            guard let region = atlas.region(for: .annotation(c.a.style, size: c.a.size)) else { continue }
            let size = Vec2(region.width, region.height)
            // Box im Bildschirmraum (Anker berücksichtigen)
            let cx = c.screen.x - c.a.anchor.x * size.x / 2
            let cy = c.screen.y - c.a.anchor.y * size.y / 2
            let box = CollisionGrid.Box(center: Vec2(cx, cy), width: size.x, height: size.y)
            if !c.a.ignoresCollisions, !grid.insert(box, padding: 2) { continue }
            if c.a.ignoresCollisions { grid.insert(box, force: true) }
            batch.addQuad(center: c.screen, size: size, uv: (region.u0, region.v0, region.u1, region.v1), anchor: c.a.anchor)
            placed.append(Placed(annotation: c.a, box: box))

            // Optionale Beschriftung unter dem Marker
            if let label = c.a.label, !label.isEmpty,
               let lr = atlas.region(for: .text(label, size: 12, weight: 600, color: IconAtlas.pack(theme.labels.text), halo: IconAtlas.pack(theme.labels.halo))) {
                let lc = Vec2(cx, box.maxY + lr.height / 2 + 1)
                let lbox = CollisionGrid.Box(center: lc, width: lr.width, height: lr.height)
                // Wer schon stand, darf enger stehen — sonst wackelt er beim
                // kleinsten Ruck wieder heraus.
                let luft = (stand[c.a.id] ?? 0) > 0 ? -1.0 : 1.0
                let passt = grid.insert(lbox, padding: luft)
                let ziel = passt ? 1.0 : 0.0
                var deckung = labelOpacity[c.a.id] ?? 0
                if dt > 0 {
                    let schritt = dt / labelFadeSeconds
                    deckung += (ziel - deckung) > 0 ? min(schritt, ziel - deckung)
                                                    : max(-schritt, ziel - deckung)
                } else {
                    deckung = ziel
                }
                if deckung > 0.01 {
                    labelOpacity[c.a.id] = deckung
                    if deckung < 0.99 { blendetGerade = true }
                    batch.addQuad(center: lc, size: Vec2(lr.width, lr.height),
                                  uv: (lr.u0, lr.v0, lr.u1, lr.v1),
                                  color: RGBA(1, 1, 1, Float(deckung)))
                } else {
                    if (stand[c.a.id] ?? 0) > 0 { blendetGerade = true }
                    labelOpacity.removeValue(forKey: c.a.id)
                }
            }
        }
        // Beschriftungen von Markern, die aus dem Bild gelaufen sind, vergessen.
        if labelOpacity.count > candidates.count * 2 {
            let sichtbar = Set(candidates.map(\.a.id))
            labelOpacity = labelOpacity.filter { sichtbar.contains($0.key) }
        }
    }

    /// Marker unter einem Bildschirmpunkt (mit 8 pt Toleranz), oberster zuerst.
    func hitTest(_ p: Vec2) -> MapAnnotation? {
        for pl in placed.reversed() where pl.annotation.isTappable {
            let b = pl.box
            if p.x >= b.minX - 8, p.x <= b.maxX + 8, p.y >= b.minY - 8, p.y <= b.maxY + 8 { return pl.annotation }
        }
        return nil
    }
}
#endif
