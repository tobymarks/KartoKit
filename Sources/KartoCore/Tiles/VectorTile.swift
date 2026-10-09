import Foundation

/// Dekodierte Mapbox-Vector-Tile (MVT v2).
public struct VectorTile: Sendable {
    public var layers: [VectorTileLayer]

    public func layer(named name: String) -> VectorTileLayer? {
        layers.first { $0.name == name }
    }
}

public struct VectorTileLayer: Sendable {
    public var name: String
    public var extent: Int
    public var version: Int
    public var features: [VectorTileFeature]
}

public enum FeatureValue: Hashable, Sendable, CustomStringConvertible {
    case string(String)
    case double(Double)
    case int(Int64)
    case bool(Bool)

    public var description: String {
        switch self {
        case .string(let s): return s
        case .double(let d): return String(d)
        case .int(let i): return String(i)
        case .bool(let b): return String(b)
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        case .bool: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

public enum GeometryType: Int, Sendable {
    case unknown = 0, point = 1, lineString = 2, polygon = 3
}

/// Punkt in Tile-Koordinaten (0…extent, y nach unten). Int32 reicht (MVT-Spec).
public struct TilePoint: Hashable, Sendable {
    public var x: Int32
    public var y: Int32
    public init(_ x: Int32, _ y: Int32) { self.x = x; self.y = y }
}

public struct VectorTileFeature: Sendable {
    public var id: UInt64?
    public var type: GeometryType
    public var properties: [String: FeatureValue]
    /// Für Punkte: je Ring ein Punkt. Für Linien: je Ring eine Linie.
    /// Für Polygone: Ringe in Dateireihenfolge (äußere Ringe positiv orientiert,
    /// innere negativ – siehe `polygons`).
    public var rings: [[TilePoint]]

    /// Gruppiert Polygon-Ringe zu Polygonen: [ [äußerer, loch, loch…], … ]
    /// MVT: äußere Ringe haben positive (im Bildschirm-Koordinatensystem: im
    /// Uhrzeigersinn) Fläche, innere negative.
    public var polygons: [[[TilePoint]]] {
        guard type == .polygon else { return [] }
        var out: [[[TilePoint]]] = []
        for ring in rings {
            let area = VectorTileFeature.signedArea(ring)
            if area > 0 || out.isEmpty {
                out.append([ring])
            } else {
                out[out.count - 1].append(ring)
            }
        }
        return out
    }

    /// Doppelte Shoelace-Fläche; > 0 = Uhrzeigersinn bei y-nach-unten (MVT-äußerer Ring).
    public static func signedArea(_ ring: [TilePoint]) -> Double {
        var a = 0.0
        let n = ring.count
        guard n >= 3 else { return 0 }
        var j = n - 1
        for i in 0..<n {
            a += (Double(ring[j].x) - Double(ring[i].x)) * (Double(ring[i].y) + Double(ring[j].y))
            j = i
        }
        return a / 2
    }
}

/// MVT-Decoder. Einmaliger Durchlauf, keine temporären Message-Objekte.
public enum VectorTileDecoder {
    public static func decode(_ data: Data) throws -> VectorTile {
        try data.withUnsafeBytes { raw -> VectorTile in
            let buf = raw.bindMemory(to: UInt8.self)
            var reader = ProtobufReader(buf)
            var layers: [VectorTileLayer] = []
            while !reader.isAtEnd {
                let (field, wire) = try reader.readTag()
                if field == 3, wire == .lengthDelimited {
                    let range = try reader.readLengthDelimited()
                    layers.append(try decodeLayer(reader.sub(range)))
                } else {
                    try reader.skip(wire)
                }
            }
            return VectorTile(layers: layers)
        }
    }

    private static func decodeLayer(_ r: ProtobufReader) throws -> VectorTileLayer {
        var reader = r
        var name = ""
        var extent = 4096
        var version = 1
        var keys: [String] = []
        var values: [FeatureValue] = []
        var featureRanges: [(Int, Int)] = []

        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, .lengthDelimited): name = try reader.readString()
            case (2, .lengthDelimited): featureRanges.append(try reader.readLengthDelimited())
            case (3, .lengthDelimited): keys.append(try reader.readString())
            case (4, .lengthDelimited): values.append(try decodeValue(reader.sub(try reader.readLengthDelimited())))
            case (5, .varint): extent = Int(try reader.readVarint())
            case (15, .varint): version = Int(try reader.readVarint())
            default: try reader.skip(wire)
            }
        }

        var features: [VectorTileFeature] = []
        features.reserveCapacity(featureRanges.count)
        for range in featureRanges {
            features.append(try decodeFeature(reader.sub(range), keys: keys, values: values))
        }
        return VectorTileLayer(name: name, extent: extent, version: version, features: features)
    }

    private static func decodeValue(_ r: ProtobufReader) throws -> FeatureValue {
        var reader = r
        var value: FeatureValue = .string("")
        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, .lengthDelimited): value = .string(try reader.readString())
            case (2, .fixed32): value = .double(Double(Float(bitPattern: try reader.readFixed32())))
            case (3, .fixed64): value = .double(Double(bitPattern: try reader.readFixed64()))
            case (4, .varint): value = .int(Int64(bitPattern: try reader.readVarint()))
            case (5, .varint): value = .int(Int64(bitPattern: try reader.readVarint()))
            case (6, .varint): value = .int(ProtobufReader.zigzag(try reader.readVarint()))
            case (7, .varint): value = .bool(try reader.readVarint() != 0)
            default: try reader.skip(wire)
            }
        }
        return value
    }

    private static func decodeFeature(_ r: ProtobufReader, keys: [String], values: [FeatureValue]) throws -> VectorTileFeature {
        var reader = r
        var id: UInt64?
        var type = GeometryType.unknown
        var properties: [String: FeatureValue] = [:]
        var geometry: [UInt32] = []

        while !reader.isAtEnd {
            let (field, wire) = try reader.readTag()
            switch (field, wire) {
            case (1, .varint): id = try reader.readVarint()
            case (2, .lengthDelimited):
                var sub = reader.sub(try reader.readLengthDelimited())
                while !sub.isAtEnd {
                    let k = Int(try sub.readVarint())
                    let v = Int(try sub.readVarint())
                    if k < keys.count, v < values.count { properties[keys[k]] = values[v] }
                }
            case (2, .varint):
                // Nicht gepackt (unüblich, aber erlaubt)
                let k = Int(try reader.readVarint())
                _ = k
            case (3, .varint): type = GeometryType(rawValue: Int(try reader.readVarint())) ?? .unknown
            case (4, .lengthDelimited):
                var sub = reader.sub(try reader.readLengthDelimited())
                while !sub.isAtEnd { geometry.append(UInt32(truncatingIfNeeded: try sub.readVarint())) }
            case (4, .varint): geometry.append(UInt32(truncatingIfNeeded: try reader.readVarint()))
            default: try reader.skip(wire)
            }
        }

        return VectorTileFeature(id: id, type: type, properties: properties, rings: decodeGeometry(geometry, type: type))
    }

    /// MVT-Geometrie-Befehle: MoveTo(1), LineTo(2), ClosePath(7); Parameter zigzag-kodiert.
    static func decodeGeometry(_ cmds: [UInt32], type: GeometryType) -> [[TilePoint]] {
        var rings: [[TilePoint]] = []
        var current: [TilePoint] = []
        var x: Int32 = 0, y: Int32 = 0
        var i = 0
        while i < cmds.count {
            let cmdInt = cmds[i]
            let cmd = cmdInt & 0x7
            let count = Int(cmdInt >> 3)
            i += 1
            switch cmd {
            case 1: // MoveTo
                for _ in 0..<count {
                    guard i + 1 < cmds.count else { return finish(rings, current) }
                    x += Int32(ProtobufReader.zigzag(UInt64(cmds[i])))
                    y += Int32(ProtobufReader.zigzag(UInt64(cmds[i + 1])))
                    i += 2
                    if type == .point {
                        current.append(TilePoint(x, y))
                    } else {
                        if !current.isEmpty { rings.append(current) }
                        current = [TilePoint(x, y)]
                    }
                }
            case 2: // LineTo
                for _ in 0..<count {
                    guard i + 1 < cmds.count else { return finish(rings, current) }
                    x += Int32(ProtobufReader.zigzag(UInt64(cmds[i])))
                    y += Int32(ProtobufReader.zigzag(UInt64(cmds[i + 1])))
                    i += 2
                    current.append(TilePoint(x, y))
                }
            case 7: // ClosePath
                if let first = current.first, current.last != first { current.append(first) }
                rings.append(current)
                current = []
            default:
                return finish(rings, current)
            }
        }
        return finish(rings, current)
    }

    private static func finish(_ rings: [[TilePoint]], _ current: [TilePoint]) -> [[TilePoint]] {
        var r = rings
        if !current.isEmpty { r.append(current) }
        return r
    }
}
