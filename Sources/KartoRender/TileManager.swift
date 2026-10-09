#if canImport(Metal)
import Foundation
import Metal
import QuartzCore
import KartoCore

/// Lädt, dekodiert und tesselliert Kacheln im Hintergrund, hält einen LRU-Cache
/// von GPU-Kacheln und liefert für jede angeforderte Kachel die beste verfügbare
/// Darstellung (exakt, sonst nächster geladener Vorfahre → kein Flackern beim Zoomen).
@MainActor
final class TileManager {
    let device: MTLDevice
    let source: TileSource
    /// Style-Wechsel: nur bei geänderter Layer-Struktur (IDs/Typen) wird der Cache verworfen;
    /// ein reiner Farbwechsel (Theme) behält alle Meshes.
    var style: MapStyle {
        didSet { if Self.structure(of: style) != Self.structure(of: oldValue) { invalidateAll() } }
    }
    private static func structure(of s: MapStyle) -> [String] {
        s.layers.map { l in
            switch l.paint { case .fill: return l.id + "#f"; case .line: return l.id + "#l"; case .extrusion: return l.id + "#e" }
        }
    }

    /// Fehlgeschlagene Kacheln: Zeitpunkt + Versuchszähler für Backoff (2, 4, 8 … 60 s).
    private var failures: [TileID: (at: CFTimeInterval, attempts: Int)] = [:]
    /// Letzter Frame, in dem eine Kachel gewollt war (für Abbruch nicht mehr sichtbarer Ladevorgänge).
    private var wantedFrame: [TileID: UInt64] = [:]
    /// Netz-/Decodefehler nach außen (gedrosselt: höchstens einer pro Sekunde).
    var onError: ((Error) -> Void)?
    private var lastErrorReport: CFTimeInterval = 0

    /// Cache-Budget in Bytes (Vertex+Index). 64 MB reichen für mehrere Zoomstufen Stadtgebiet.
    var cacheBudget = 64 * 1024 * 1024

    private var cache: [TileID: GPUTile] = [:]
    private var inFlight: [TileID: Task<Void, Never>] = [:]
    private var frame: UInt64 = 0
    private var generation = 0
    private let maxConcurrent = 6

    /// Wird aufgerufen, sobald neue Kacheln verfügbar sind (→ Redraw anstoßen).
    var onTileLoaded: (() -> Void)?

    init(device: MTLDevice, source: TileSource, style: MapStyle) {
        self.device = device
        self.source = source
        self.style = style
    }

    func invalidateAll() {
        generation += 1
        for (_, t) in inFlight { t.cancel() }
        inFlight.removeAll()
        cache.removeAll()
    }

    /// Pro Frame: gewünschte Kacheln melden. Liefert die zu zeichnenden GPU-Kacheln
    /// (mit Fallbacks) und stößt fehlende Ladevorgänge an.
    func tiles(for wanted: [TileID]) -> [GPUTile] {
        frame += 1
        var result: [GPUTile] = []
        var drawn = Set<TileID>()
        var missing: [TileID] = []

        for id in wanted {
            wantedFrame[id] = frame
            if let t = cache[id] {
                t.lastUsedFrame = frame
                if !t.buckets.isEmpty { result.append(t) }
                continue
            }
            missing.append(id)
            // Fallback: nächster geladener Vorfahre (max. 5 Stufen)
            var p = id.parent
            var depth = 0
            while let pp = p, depth < 5 {
                if let t = cache[pp] {
                    t.lastUsedFrame = frame
                    if !drawn.contains(pp), !t.buckets.isEmpty { result.append(t); drawn.insert(pp) }
                    break
                }
                p = pp.parent
                depth += 1
            }
        }

        // Ladevorgänge für Kacheln abbrechen, die seit > 30 Frames nicht mehr gebraucht werden
        // (schnelles Wegzoomen/Schwenken) – gibt die Slots dem Sichtbaren.
        for (id, task) in inFlight where (wantedFrame[id] ?? 0) + 30 < frame {
            task.cancel(); inFlight[id] = nil
        }
        // Nahe Kacheln zuerst laden (Liste kommt bereits distanzsortiert aus TileCoverage).
        let now = CACurrentMediaTime()
        for id in missing where inFlight[id] == nil && inFlight.count < maxConcurrent {
            if let f = failures[id] {
                let backoff = min(60, pow(2.0, Double(f.attempts)))
                if now - f.at < backoff { continue }
            }
            load(id)
        }
        evictIfNeeded()
        return result
    }

    /// Kacheln vorausladen (z. B. in Fahrtrichtung), niedrigere Priorität als Sichtbares.
    func prefetch(_ ids: [TileID]) {
        // Eigenes, kleineres Budget: Sichtbares darf nie hinter Prefetch warten.
        for id in ids where cache[id] == nil && inFlight[id] == nil && inFlight.count < maxConcurrent - 2 {
            load(id, priority: .utility)
        }
    }

    private func load(_ id: TileID, priority: TaskPriority = .userInitiated) {
        let gen = generation
        let source = self.source
        let style = self.style
        let maxZ = source.maxZoom
        let box = DeviceBox(device: device)
        inFlight[id] = Task.detached(priority: priority) { [weak self] in
            var tile: GPUTile?
            var failure: Error?
            do {
                if let data = try await source.tileData(id), !Task.isCancelled {
                    let vt = try VectorTileDecoder.decode(data)
                    let mesh = TileMeshBuilder.build(tile: id, vectorTile: vt, style: style, sourceMaxZoom: maxZ)
                    tile = GPUTile(device: box.device, mesh: mesh)
                } else if !Task.isCancelled {
                    tile = GPUTile(empty: id)
                }
            } catch is CancellationError {
                return
            } catch {
                failure = error
            }
            let finished = tile
            let err = failure
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.inFlight[id] = nil
                if Task.isCancelled { return }
                if let err {
                    let prev = self.failures[id]?.attempts ?? 0
                    self.failures[id] = (CACurrentMediaTime(), prev + 1)
                    let now = CACurrentMediaTime()
                    if now - self.lastErrorReport > 1 { self.lastErrorReport = now; self.onError?(err) }
                    return
                }
                if let finished {
                    self.failures[id] = nil
                    finished.lastUsedFrame = self.frame
                    self.cache[id] = finished
                    self.onTileLoaded?()
                }
            }
        }
    }

    private func evictIfNeeded() {
        var total = cache.values.reduce(0) { $0 + $1.byteSize }
        guard total > cacheBudget else { return }
        // Älteste zuerst entfernen, aber nie Kacheln des aktuellen Frames.
        let sorted = cache.values.sorted { $0.lastUsedFrame < $1.lastUsedFrame }
        for t in sorted where t.lastUsedFrame < frame {
            cache[t.id] = nil
            total -= t.byteSize
            if total <= cacheBudget * 3 / 4 { break }
        }
    }

    var statistics: (cached: Int, loading: Int, bytes: Int) {
        (cache.count, inFlight.count, cache.values.reduce(0) { $0 + $1.byteSize })
    }
}
#endif
