import Foundation

// Kleine, plattformunabhängige lineare Algebra.
// Bewusst kein `simd`-Import: der Kern soll auch unter Linux (CI, Tests) bauen.
// Speicherlayout von `Float4x4` ist spaltenweise (column-major) und damit
// bit-kompatibel zu `simd_float4x4` – der Renderer kann es direkt kopieren.

public struct Vec2: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }

    public var length: Double { (x * x + y * y).squareRoot() }
    public var normalized: Vec2 { let l = length; return l > 0 ? self / l : Vec2(0, 0) }
    /// Um 90° gedrehte Normale (links von der Richtung, bei y-nach-unten rechts).
    public var perpendicular: Vec2 { Vec2(-y, x) }
    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
}

public struct Vec3: Hashable, Sendable {
    public var x: Double, y: Double, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var normalized: Vec3 { let l = length; return l > 0 ? self * (1 / l) : self }
    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
}

public struct Vec4: Hashable, Sendable {
    public var x: Double, y: Double, z: Double, w: Double
    public init(_ x: Double, _ y: Double, _ z: Double, _ w: Double) { self.x = x; self.y = y; self.z = z; self.w = w }
}

/// 4×4-Matrix, column-major, double precision.
/// Doubles im Kern verhindern die typischen Zitter-Artefakte bei hohen Zoomstufen;
/// erst die pro Tile relativierte Matrix wird als Float an die GPU gegeben.
public struct Mat4: Equatable, Sendable {
    /// m[column][row]
    public var m: [[Double]]

    public init(columns: [[Double]]) {
        precondition(columns.count == 4 && columns.allSatisfy { $0.count == 4 })
        m = columns
    }

    public static let identity = Mat4(columns: [
        [1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1],
    ])

    public subscript(col: Int, row: Int) -> Double {
        get { m[col][row] }
        set { m[col][row] = newValue }
    }

    public static func * (a: Mat4, b: Mat4) -> Mat4 {
        var r = Mat4.identity
        for c in 0..<4 {
            for row in 0..<4 {
                var s = 0.0
                for k in 0..<4 { s += a[k, row] * b[c, k] }
                r[c, row] = s
            }
        }
        return r
    }

    public static func * (a: Mat4, v: Vec4) -> Vec4 {
        Vec4(
            a[0, 0] * v.x + a[1, 0] * v.y + a[2, 0] * v.z + a[3, 0] * v.w,
            a[0, 1] * v.x + a[1, 1] * v.y + a[2, 1] * v.z + a[3, 1] * v.w,
            a[0, 2] * v.x + a[1, 2] * v.y + a[2, 2] * v.z + a[3, 2] * v.w,
            a[0, 3] * v.x + a[1, 3] * v.y + a[2, 3] * v.z + a[3, 3] * v.w
        )
    }

    public static func translation(_ x: Double, _ y: Double, _ z: Double) -> Mat4 {
        var r = identity
        r[3, 0] = x; r[3, 1] = y; r[3, 2] = z
        return r
    }

    public static func scale(_ x: Double, _ y: Double, _ z: Double) -> Mat4 {
        var r = identity
        r[0, 0] = x; r[1, 1] = y; r[2, 2] = z
        return r
    }

    public static func rotationX(_ rad: Double) -> Mat4 {
        let c = cos(rad), s = sin(rad)
        var r = identity
        r[1, 1] = c; r[1, 2] = s
        r[2, 1] = -s; r[2, 2] = c
        return r
    }

    public static func rotationZ(_ rad: Double) -> Mat4 {
        let c = cos(rad), s = sin(rad)
        var r = identity
        r[0, 0] = c; r[0, 1] = s
        r[1, 0] = -s; r[1, 1] = c
        return r
    }

    /// Perspektivprojektion für Metal-Clip-Space (z in [0, 1]).
    public static func perspective(fovY: Double, aspect: Double, near: Double, far: Double) -> Mat4 {
        let f = 1.0 / tan(fovY / 2)
        var r = Mat4(columns: [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]])
        r[0, 0] = f / aspect
        r[1, 1] = f
        r[2, 2] = far / (near - far)
        r[2, 3] = -1
        r[3, 2] = (far * near) / (near - far)
        return r
    }

    /// Flache Float-Darstellung (16 Werte, column-major) – kopierbar in simd_float4x4.
    public var floats: [Float] {
        var out: [Float] = []
        out.reserveCapacity(16)
        for c in 0..<4 { for r in 0..<4 { out.append(Float(m[c][r])) } }
        return out
    }

    /// Allgemeine Inverse (Gauß-Jordan). Für Kamera-Unprojection ausreichend.
    public var inverse: Mat4? {
        var a = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 4)
        for r in 0..<4 {
            for c in 0..<4 { a[r][c] = self[c, r] }
            a[r][4 + r] = 1
        }
        for i in 0..<4 {
            var pivot = i
            for r in (i + 1)..<4 where abs(a[r][i]) > abs(a[pivot][i]) { pivot = r }
            if abs(a[pivot][i]) < 1e-12 { return nil }
            a.swapAt(i, pivot)
            let inv = 1 / a[i][i]
            for c in 0..<8 { a[i][c] *= inv }
            for r in 0..<4 where r != i {
                let f = a[r][i]
                if f != 0 { for c in 0..<8 { a[r][c] -= f * a[i][c] } }
            }
        }
        var out = Mat4.identity
        for r in 0..<4 { for c in 0..<4 { out[c, r] = a[r][4 + c] } }
        return out
    }
}
