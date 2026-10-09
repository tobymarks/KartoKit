import Foundation

/// Kamerazustand der Karte.
///
/// - `center`: Blickpunkt in Unit-Mercator.
/// - `zoom`: fraktionale Zoomstufe (Weltgröße = 512 · 2^zoom Pixel).
/// - `bearing`: Rotation in Grad, 0 = Norden oben, im Uhrzeigersinn.
/// - `pitch`: Neigung in Grad, 0 = senkrecht von oben, bis ~70° Navi-Perspektive.
public struct MapCamera: Equatable, Sendable {
    public var center: Vec2
    public var zoom: Double
    public var bearing: Double
    public var pitch: Double

    public static let maxPitch = 70.0
    public static let minZoom = 0.0
    public static let maxZoom = 22.0

    public init(center: Vec2, zoom: Double, bearing: Double = 0, pitch: Double = 0) {
        self.center = center
        self.zoom = zoom
        self.bearing = bearing
        self.pitch = pitch
    }

    public init(coordinate: Coordinate, zoom: Double, bearing: Double = 0, pitch: Double = 0) {
        self.init(center: Mercator.project(coordinate), zoom: zoom, bearing: bearing, pitch: pitch)
    }

    public var coordinate: Coordinate { Mercator.unproject(center) }

    /// Begrenzt Zoom/Pitch/Bearing auf gültige Bereiche.
    public mutating func clamp() {
        zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
        pitch = min(max(pitch, 0), Self.maxPitch)
        bearing = bearing.truncatingRemainder(dividingBy: 360)
        if bearing < 0 { bearing += 360 }
        center.x = min(max(center.x, 0), 1)
        center.y = min(max(center.y, 0), 1)
    }
}

/// Aus Kamera + Viewport abgeleitete Projektionsmatrizen.
///
/// Weltraum ("World Pixel Space"): x nach Osten, y nach Süden, z nach oben (Pixel
/// auf der aktuellen Zoomstufe). Höhen werden in Metern angegeben und je Kachel
/// über Meter/Pixel in diesen Raum umgerechnet.
public struct ViewProjection: Sendable {
    public let camera: MapCamera
    public let width: Double
    public let height: Double
    public let fieldOfView: Double
    public let worldSize: Double
    /// Entfernung des Auges zur Bildmitte auf der Bodenebene (in Pixeln).
    public let cameraDistance: Double
    public let near: Double
    public let far: Double
    /// Welt-Pixel → Kameraraum.
    public let view: Mat4
    public let projection: Mat4
    /// Welt-Pixel → Clip-Space (Metal, z ∈ [0,1]).
    public let viewProjection: Mat4
    public let inverseViewProjection: Mat4
    /// Augpunkt in Welt-Pixeln (z = Höhe über Boden).
    public let eye: Vec3

    public init(camera: MapCamera, width: Double, height: Double, fieldOfView: Double = 0.6435011087932844 /* ≈36.87°, wie MapLibre */) {
        self.camera = camera
        self.width = width
        self.height = height
        self.fieldOfView = fieldOfView
        worldSize = Mercator.worldSize(zoom: camera.zoom)

        let pitchRad = camera.pitch * .pi / 180
        let bearingRad = camera.bearing * .pi / 180
        let halfFov = fieldOfView / 2
        cameraDistance = 0.5 * height / tan(halfFov)

        // Entfernung zum weitesten sichtbaren Bodenpunkt (obere Bildkante bei Neigung).
        let groundAngle = .pi / 2 + pitchRad
        let topHalfSurfaceDistance = sin(halfFov) * cameraDistance / sin(min(max(.pi - groundAngle - halfFov, 0.01), .pi - 0.01))
        let furthest = cos(.pi / 2 - pitchRad) * topHalfSurfaceDistance + cameraDistance
        far = furthest * 1.5 + 1000 // Reserve für hohe Gebäude
        near = max(cameraDistance / 100, 1)

        let center = camera.center * worldSize
        let aspect = width / height

        // Welt (y nach unten) → Kamera: Zentrum verschieben, um Z drehen (Bearing),
        // um X kippen (Pitch), Kamera nach hinten, dann Perspektive.
        // Die Y-Spiegelung überführt "y nach Süden" in Metals y-nach-oben-Clip-Space.
        let flipY = Mat4.scale(1, -1, 1)
        let v = Mat4.translation(0, 0, -cameraDistance)
            * Mat4.rotationX(-pitchRad)
            * flipY
            * Mat4.rotationZ(-bearingRad)
            * Mat4.translation(-center.x, -center.y, 0)
        let p = Mat4.perspective(fovY: fieldOfView, aspect: aspect, near: near, far: far)
        view = v
        projection = p
        let m = p * v
        viewProjection = m
        inverseViewProjection = m.inverse ?? .identity
        if let invView = v.inverse {
            let e = invView * Vec4(0, 0, 0, 1)
            eye = Vec3(e.x / e.w, e.y / e.w, e.z / e.w)
        } else {
            eye = Vec3(center.x, center.y, cameraDistance)
        }
    }

    /// Welt-Pixel (z in Pixeln) → Bildschirmpunkt (Punkte, Ursprung oben links).
    public func project(worldPixel p: Vec3) -> Vec2? {
        let c = viewProjection * Vec4(p.x, p.y, p.z, 1)
        guard c.w > 0 else { return nil }
        let nx = c.x / c.w, ny = c.y / c.w
        return Vec2((nx + 1) / 2 * width, (1 - ny) / 2 * height)
    }

    public func project(unitMercator p: Vec2, elevationMeters: Double = 0) -> Vec2? {
        let mpp = Mercator.metersPerPixel(latitude: Mercator.unproject(p).latitude, zoom: camera.zoom)
        return project(worldPixel: Vec3(p.x * worldSize, p.y * worldSize, elevationMeters / mpp))
    }

    /// Bildschirmpunkt → Schnittpunkt des Sehstrahls mit der Bodenebene (Welt-Pixel).
    /// Gibt nil zurück, wenn der Strahl über den Horizont zeigt.
    public func unprojectToGround(screen s: Vec2) -> Vec2? {
        let nx = s.x / width * 2 - 1
        let ny = 1 - s.y / height * 2
        func toWorld(_ z: Double) -> Vec3? {
            let v = inverseViewProjection * Vec4(nx, ny, z, 1)
            guard abs(v.w) > 1e-12 else { return nil }
            return Vec3(v.x / v.w, v.y / v.w, v.z / v.w)
        }
        guard let p0 = toWorld(0), let p1 = toWorld(1) else { return nil }
        let dir = p1 - p0
        guard abs(dir.z) > 1e-12 else { return nil }
        let t = -p0.z / dir.z
        guard t >= 0 else { return nil }
        let hit = p0 + dir * t
        return Vec2(hit.x, hit.y)
    }

    public func unprojectToUnitMercator(screen s: Vec2) -> Vec2? {
        guard let g = unprojectToGround(screen: s) else { return nil }
        return g / worldSize
    }

    /// Sichtbarer Kartenausschnitt als Koordinaten-Box. Bei geneigter Kamera reicht der Blick bis
    /// zum Horizont – Punkte weiter als `maxDistanceMeters` von der Kameramitte werden auf diese
    /// Entfernung begrenzt, damit die Box für Datenabfragen brauchbar bleibt.
    public func visibleBounds(maxDistanceMeters: Double = 30_000) -> CoordinateBounds {
        let center = camera.center
        let mpu = Mercator.metersPerUnit(latitude: camera.coordinate.latitude)
        let limit = maxDistanceMeters / mpu   // in Unit-Mercator
        var pts: [Vec2] = []
        let samples: [Vec2] = [Vec2(0, 0), Vec2(width, 0), Vec2(0, height), Vec2(width, height),
                               Vec2(width / 2, 0), Vec2(0, height / 2), Vec2(width, height / 2), Vec2(width / 2, height)]
        for s in samples {
            var p = unprojectToUnitMercator(screen: s) ?? (center + Vec2(0, -limit))
            let d = p - center
            if d.length > limit { p = center + d * (limit / d.length) }
            pts.append(p)
        }
        pts.append(center)
        let minX = pts.map { $0.x }.min()!, maxX = pts.map { $0.x }.max()!
        let minY = pts.map { $0.y }.min()!, maxY = pts.map { $0.y }.max()!
        let sw = Mercator.unproject(Vec2(minX, maxY)), ne = Mercator.unproject(Vec2(maxX, minY))
        return CoordinateBounds(southWest: sw, northEast: ne)
    }

    /// Tile-lokale Matrix: Kachelkoordinaten in MVT-Extent-Einheiten (0…extent)
    /// → Clip-Space. Höhen (z) werden in derselben Einheit erwartet.
    /// Wird in Double berechnet und erst am Ende auf Float reduziert, damit auch
    /// bei Zoom 20+ keine Präzisionsartefakte entstehen.
    public func tileMatrix(for tile: TileID, extent: Double) -> Mat4 {
        let scale = pow(2.0, camera.zoom - Double(tile.z)) * Mercator.tileSize / extent
        let o = tile.origin * worldSize
        return viewProjection * Mat4.translation(o.x, o.y, 0) * Mat4.scale(scale, scale, scale)
    }
}


/// Geografische Bounding-Box.
public struct CoordinateBounds: Equatable, Sendable {
    public var southWest: Coordinate
    public var northEast: Coordinate
    public init(southWest: Coordinate, northEast: Coordinate) { self.southWest = southWest; self.northEast = northEast }
    public var minLatitude: Double { southWest.latitude }
    public var maxLatitude: Double { northEast.latitude }
    public var minLongitude: Double { southWest.longitude }
    public var maxLongitude: Double { northEast.longitude }
    public func contains(_ c: Coordinate) -> Bool {
        c.latitude >= minLatitude && c.latitude <= maxLatitude && c.longitude >= minLongitude && c.longitude <= maxLongitude
    }
    /// Um den Faktor vergrößert (1 = unverändert), z. B. für Vorab-Laden.
    public func expanded(by factor: Double) -> CoordinateBounds {
        let dlat = (maxLatitude - minLatitude) * (factor - 1) / 2, dlon = (maxLongitude - minLongitude) * (factor - 1) / 2
        return CoordinateBounds(southWest: Coordinate(latitude: max(-85, minLatitude - dlat), longitude: minLongitude - dlon),
                                northEast: Coordinate(latitude: min(85, maxLatitude + dlat), longitude: maxLongitude + dlon))
    }
    /// Liegt `other` (noch) komfortabel innerhalb? Für „muss neu geladen werden?“-Entscheidungen.
    public func contains(_ other: CoordinateBounds) -> Bool {
        other.minLatitude >= minLatitude && other.maxLatitude <= maxLatitude && other.minLongitude >= minLongitude && other.maxLongitude <= maxLongitude
    }
}
