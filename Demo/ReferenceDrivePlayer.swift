import Foundation
import QuartzCore
import KartoCore
import KartoRender

/// Spielt die Referenzfahrt (referenzfahrt.gpx, 1 Hz) in Echtzeit oder schneller ab und
/// schreibt die KartoKit-Kameraspur als CSV nach Documents/karto_trace_<Datum>.csv –
/// dasselbe Format wie `KARTO_TRACE` im Test, auswertbar mit
/// `Auswertung/compare_karto_trace.py`.
///
/// Damit die Kamera dasselbe Verhalten zeigt wie in der Auswertung, wird die Route aus
/// dem Track selbst gebildet und die Manöver per `ManeuverDetector` erkannt. Mit eurer
/// Routing-Engine setzt ihr stattdessen `navigation.route` + `maneuverDistancesAlong`.
@MainActor
final class ReferenceDrivePlayer {
    let track: GPXTrack
    let fixes: [LocationFix]
    let route: [Coordinate]
    let maneuvers: [Double]
    private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var csv = "gpx_time,speed_kmh,zoom,pitch,bearing,puck_heading,maneuver\n"
    private(set) var logURL: URL?

    init?(resource: String = "referenzfahrt") {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "gpx"),
              let t = try? GPXTrack(url: url), t.points.count > 10 else { return nil }
        track = t
        fixes = t.fixes()
        route = t.simplifiedRoute()
        maneuvers = ManeuverDetector.turnPoints(route: route)
    }

    var startCoordinate: Coordinate { fixes[0].coordinate }

    /// `speed`: 1 = Echtzeit (51 Minuten). Schneller ist nur zum Anschauen gedacht – die
    /// Glättung rechnet mit echten Geschwindigkeiten, bei 4× hinkt der Puck deshalb etwas.
    func start(on map: MapView, speed: Double = 1, from offsetSeconds: Double = 0) {
        stop()
        map.route = route
        map.navigation?.maneuverDistancesAlong = maneuvers
        map.onNavigationTick = { [weak self] _, cam, puck, maneuver in
            guard let self, self.isRunning, self.lastGPXTime > 0 else { return }
            self.csv += String(format: "%.1f,%.1f,%.2f,%.1f,%.1f,%.1f,%d\n",
                               self.lastGPXTime, puck.speed * 3.6, cam.zoom, cam.pitch, cam.bearing, puck.heading, maneuver ? 1 : 0)
        }
        isRunning = true
        let t0 = fixes[0].timestamp + offsetSeconds
        task = Task { [weak self, weak map] in
            guard let self else { return }
            let wall0 = CACurrentMediaTime()
            for fix in self.fixes where fix.timestamp >= t0 {
                let due = wall0 + (fix.timestamp - t0) / speed
                let wait = due - CACurrentMediaTime()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                if Task.isCancelled || !self.isRunning { return }
                // Fix-Zeit = GPX-Zeit; der Controller arbeitet mit relativen Zeiten, deshalb
                // muss der Tick dieselbe Zeitbasis bekommen → MapView rechnet intern mit
                // CACurrentMediaTime, wir liefern den Fix mit umgerechnetem Zeitstempel.
                var f = fix
                f.timestamp = wall0 + (fix.timestamp - t0) / speed
                map?.updateLocation(f)
                self.lastGPXTime = fix.timestamp
            }
            self.finish()
        }
    }

    private var lastGPXTime: TimeInterval = 0

    func stop() {
        task?.cancel(); task = nil
        if isRunning { finish() }
    }

    private func finish() {
        isRunning = false
        let name = "karto_trace_\(Int(Date().timeIntervalSince1970)).csv"
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent(name)
            try? csv.write(to: url, atomically: true, encoding: .utf8)
            logURL = url
        }
    }
}
