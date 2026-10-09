import XCTest
@testable import KartoCore

/// Spielt die Referenzfahrt Stuttgart→Pforzheim (GPX, 1 Hz) deterministisch
/// durch den NavigationController und prüft das Kameraverhalten gegen die aus den
/// Referenzwerten. Mit KARTO_TRACE=/pfad/datei.csv wird die
/// Kamera-Zeitreihe (10 Hz) geschrieben – für `Auswertung/compare_karto_trace.py`.
final class ReferenceDriveTests: XCTestCase {

    func loadTrack() throws -> GPXTrack {
        let url = Bundle.module.url(forResource: "referenzfahrt", withExtension: "gpx", subdirectory: "Fixtures")!
        return try GPXTrack(url: url)
    }

    func testGPXParsing() throws {
        let track = try loadTrack()
        XCTAssertEqual(track.points.count, 2390)
        XCTAssertNotNil(track.points[0].time)
        let route = track.simplifiedRoute()
        XCTAssertLessThan(route.count, track.points.count / 2)
        XCTAssertEqual(RouteSnapper(route: route).totalLength, 53_000, accuracy: 1500)
        let fixes = track.fixes()
        XCTAssertEqual(fixes.count, 2390)
        XCTAssertLessThan(fixes.compactMap { $0.speed }.max()!, 60)
    }

    func testManeuverDetection() throws {
        let route = try loadTrack().simplifiedRoute()
        let turns = ManeuverDetector.turnPoints(route: route)
        // Stuttgart-Innenstadt + Pforzheim: mehrere Abbiegungen, aber keine hundert
        XCTAssertGreaterThan(turns.count, 8)
        XCTAssertLessThan(turns.count, 60)
        for (a, b) in zip(turns, turns.dropFirst()) { XCTAssertGreaterThan(b - a, 50) }
    }

    func testReplayMatchesReferenceValues() throws {
        let track = try loadTrack()
        let route = track.simplifiedRoute()
        let nav = NavigationController()
        nav.route = route
        nav.maneuverDistancesAlong = ManeuverDetector.turnPoints(route: route)
        let fixes = track.fixes()
        let vp = (width: 402.0, height: 874.0)
        let free = (x: 0.0, y: 135.0, width: 402.0, height: 620.0) // typische iPhone-Overlays
        let current = MapCamera(coordinate: fixes[0].coordinate, zoom: 15)

        var trace = "gpx_time,speed_kmh,zoom,pitch,bearing,puck_heading,maneuver\n"
        var samples: [(t: Double, speed: Double, zoom: Double, pitch: Double, bearing: Double, heading: Double, maneuver: Bool)] = []
        var t = fixes[0].timestamp
        var fi = 0
        let end = fixes.last!.timestamp
        while t <= end {
            while fi < fixes.count, fixes[fi].timestamp <= t { nav.update(fix: fixes[fi]); fi += 1 }
            let f = nav.tick(now: t, current: current, viewport: vp, freeArea: free)
            if let c = f.camera, let p = f.puck {
                let s = (t: t, speed: p.speed * 3.6, zoom: c.zoom, pitch: c.pitch, bearing: c.bearing, heading: p.heading, maneuver: nav.isManeuverViewActive)
                samples.append(s)
                if Int((t * 10).rounded()) % 1 == 0 {
                    trace += String(format: "%.1f,%.1f,%.2f,%.1f,%.1f,%.1f,%d\n", t, s.speed, s.zoom, s.pitch, s.bearing, s.heading, s.maneuver ? 1 : 0)
                }
            }
            t += 0.1
        }
        if let path = ProcessInfo.processInfo.environment["KARTO_TRACE"] {
            try trace.write(toFile: path, atomically: true, encoding: .utf8)
        }

        // Stadt (< 70 km/h, außerhalb Manöveransicht): Zoom 15.5, Pitch 58
        let city = samples.filter { $0.speed < 60 && !$0.maneuver && $0.pitch > 50 }
        XCTAssertGreaterThan(city.count, 3000)
        let cityZoom = city.map { $0.zoom }.sorted()[city.count / 2]
        XCTAssertEqual(cityZoom, 15.5, accuracy: 0.1)
        // Autobahn (> 110 km/h): 14.5–14.8
        let fast = samples.filter { $0.speed > 115 && !$0.maneuver }
        XCTAssertGreaterThan(fast.count, 1000)
        let fastZoom = fast.map { $0.zoom }.sorted()[fast.count / 2]
        XCTAssertEqual(fastZoom, 14.65, accuracy: 0.2)
        // Manöveransicht kommt vor und wird auch wieder verlassen; Anteil plausibel (~20 % der Stadt-Frames)
        let manShare = Double(samples.filter { $0.maneuver }.count) / Double(samples.count)
        XCTAssertGreaterThan(manShare, 0.05)
        XCTAssertLessThan(manShare, 0.45)
        let manPitch = samples.filter { $0.maneuver }.map { $0.pitch }.min()!
        XCTAssertLessThan(manPitch, 25)
        // Ampelstopp (20:53:05, 27 s): Zoom bleibt – kein Heranzoomen im Stand
        let stop = samples.filter { $0.t > 1788029585 + 5 && $0.t < 1788029585 + 25 && $0.speed < 2 }
        XCTAssertGreaterThan(stop.count, 100)
        XCTAssertTrue(stop.allSatisfy { abs($0.zoom - 15.5) < 0.15 || $0.maneuver }, "Zoom im Stand: \(Set(stop.map { ($0.zoom * 10).rounded() / 10 }))")
        // Kamera-Bearing folgt dem Puck-Kurs eng (90 % innerhalb 10°) – außerhalb enger Kurven
        let deltas = samples.filter { $0.speed > 20 }.map { abs(GeoMath.angleDelta(from: $0.heading, to: $0.bearing)) }.sorted()
        XCTAssertLessThan(deltas[Int(Double(deltas.count) * 0.9)], 15)
    }
}
