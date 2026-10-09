import Foundation

/// GPX-Track (trkpt mit Zeitstempel) → LocationFix-Folge. Für das Abspielen
/// aufgezeichneter Fahrten in der Demo und für deterministische Tests.
public struct GPXTrack: Sendable {
    public struct Point: Equatable, Sendable {
        public var coordinate: Coordinate
        /// Sekunden seit 1970 (aus dem GPX), nil wenn ohne Zeit.
        public var time: TimeInterval?
    }

    public var points: [Point]

    public init(points: [Point]) { self.points = points }

    /// Minimaler GPX-Parser (trkpt lat/lon + <time>), keine XML-Bibliothek nötig.
    public init(gpx: String) {
        var pts: [Point] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var searchRange = gpx.startIndex..<gpx.endIndex
        while let open = gpx.range(of: "<trkpt", range: searchRange) {
            guard let close = gpx.range(of: "</trkpt>", range: open.upperBound..<gpx.endIndex) else { break }
            let block = gpx[open.lowerBound..<close.upperBound]
            func attr(_ name: String) -> Double? {
                guard let r = block.range(of: "\(name)=\"") else { return nil }
                let rest = block[r.upperBound...]
                guard let q = rest.firstIndex(of: "\"") else { return nil }
                return Double(rest[..<q])
            }
            if let lat = attr("lat"), let lon = attr("lon") {
                var time: TimeInterval?
                if let t0 = block.range(of: "<time>"), let t1 = block.range(of: "</time>", range: t0.upperBound..<block.endIndex) {
                    let str = String(block[t0.upperBound..<t1.lowerBound])
                    time = (iso.date(from: str) ?? isoFrac.date(from: str))?.timeIntervalSince1970
                }
                pts.append(Point(coordinate: Coordinate(latitude: lat, longitude: lon), time: time))
            }
            searchRange = close.upperBound..<gpx.endIndex
        }
        points = pts
    }

    public init(url: URL) throws {
        self.init(gpx: try String(contentsOf: url, encoding: .utf8))
    }

    public var coordinates: [Coordinate] { points.map { $0.coordinate } }

    /// Fixes mit Kurs und Tempo aus benachbarten Punkten. Ausreißer (> 60 m/s) werden
    /// auf den vorherigen Wert gesetzt. Zeitstempel = GPX-Zeit (Sekunden seit 1970).
    public func fixes(accuracy: Double = 8) -> [LocationFix] {
        var out: [LocationFix] = []
        out.reserveCapacity(points.count)
        var lastSpeed = 0.0
        for i in 0..<points.count {
            let p = points[i]
            guard let t = p.time else { continue }
            var speed: Double? = nil
            var course: Double? = nil
            if i > 0, let t0 = points[i - 1].time, t > t0 {
                let d = GeoMath.distance(points[i - 1].coordinate, p.coordinate)
                let s = d / (t - t0)
                speed = s <= 60 ? s : lastSpeed
                if d > 2 { course = GeoMath.bearing(from: points[i - 1].coordinate, to: p.coordinate) }
            }
            lastSpeed = speed ?? lastSpeed
            out.append(LocationFix(coordinate: p.coordinate, course: course, speed: speed,
                                   horizontalAccuracy: accuracy, timestamp: t))
        }
        return out
    }

    /// Route für die Navigation: Track auf ~`spacing` m ausgedünnt (Douglas-Peucker light),
    /// damit Snapping und Manöver-Erkennung nicht auf GPS-Zittern reagieren.
    public func simplifiedRoute(tolerance: Double = 6) -> [Coordinate] {
        let c = coordinates
        guard c.count > 2 else { return c }
        let m = c.map { Mercator.project($0) }
        let mpu = Mercator.metersPerUnit(latitude: c[0].latitude)
        var keep = [Bool](repeating: false, count: c.count)
        keep[0] = true; keep[c.count - 1] = true
        var stack = [(0, c.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b - a > 1 else { continue }
            let pa = m[a], pb = m[b]
            let ab = pb - pa
            let len2 = ab.dot(ab)
            var worst = (idx: -1, dist: 0.0)
            for i in (a + 1)..<b {
                let t = len2 > 0 ? min(max((m[i] - pa).dot(ab) / len2, 0), 1) : 0
                let d = (m[i] - (pa + ab * t)).length * mpu
                if d > worst.dist { worst = (i, d) }
            }
            if worst.dist > tolerance {
                keep[worst.idx] = true
                stack.append((a, worst.idx)); stack.append((worst.idx, b))
            }
        }
        return zip(c, keep).compactMap { $1 ? $0 : nil }
    }
}
