import Foundation

/// Swift-Port von mapbox/earcut (ISC-Lizenz): schnelle Ear-Clipping-Triangulation
/// für Polygone mit Löchern. Genau der Algorithmus, den auch MapLibre für Fills nutzt.
///
/// Eingabe: flaches Koordinatenarray [x0, y0, x1, y1, …] plus Startindizes der Löcher
/// (in Punkten, nicht in Array-Positionen). Ausgabe: Dreiecks-Indizes.
public enum Earcut {
    public static func triangulate(_ data: [Double], holeIndices: [Int] = []) -> [UInt32] {
        let ctx = Context()
        defer { ctx.release() }
        return ctx.triangulate(data, holeIndices: holeIndices)
    }

    /// Abweichung der Dreiecksfläche von der Polygonfläche (Qualitätsmaß für Tests).
    public static func deviation(_ data: [Double], holeIndices: [Int], triangles: [UInt32]) -> Double {
        Context.deviation(data, holeIndices: holeIndices, triangles: triangles)
    }
}

extension Earcut {
    /// Hält alle erzeugten Knoten, damit die zyklischen prev/next-Referenzen nach dem
    /// Lauf aufgelöst werden können (sonst Speicherleck durch Retain-Zyklen).
    final class Context {
        var nodes: [Node] = []

        func release() {
            for n in nodes { n.prev = nil; n.next = nil; n.prevZ = nil; n.nextZ = nil }
            nodes.removeAll()
        }

    func triangulate(_ data: [Double], holeIndices: [Int] = []) -> [UInt32] {
        nodes.reserveCapacity(data.count / 2 + holeIndices.count * 2)
        let hasHoles = !holeIndices.isEmpty
        let outerLen = hasHoles ? holeIndices[0] * 2 : data.count
        guard var outerNode = linkedList(data, 0, outerLen, clockwise: true) else { return [] }
        var triangles: [UInt32] = []
        guard outerNode.next !== outerNode.prev else { return triangles }

        var minX = 0.0, minY = 0.0, invSize = 0.0

        if hasHoles { outerNode = eliminateHoles(data, holeIndices, outerNode) }

        // Bei größeren Polygonen: Z-Order-Hashing für schnellere Ohr-Prüfung.
        if data.count > 80 * 2 {
            minX = data[0]; minY = data[1]
            var maxX = minX, maxY = minY
            var i = 2
            while i < outerLen {
                let x = data[i], y = data[i + 1]
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
                i += 2
            }
            invSize = max(maxX - minX, maxY - minY)
            invSize = invSize != 0 ? 32767 / invSize : 0
        }

        earcutLinked(outerNode, &triangles, minX, minY, invSize, 0)
        return triangles
    }

    // MARK: - Node

    final class Node {
        let i: Int
        let x: Double
        let y: Double
        var prev: Node!
        var next: Node!
        var z: Int32 = 0
        var prevZ: Node?
        var nextZ: Node?
        var steiner = false

        init(_ i: Int, _ x: Double, _ y: Double) {
            self.i = i; self.x = x; self.y = y
        }
    }

    // MARK: - Aufbau der Ringliste

    func linkedList(_ data: [Double], _ start: Int, _ end: Int, clockwise: Bool) -> Node? {
        var last: Node?
        if clockwise == (Self.signedArea(data, start, end) > 0) {
            var i = start
            while i < end { last = insertNode(i / 2, data[i], data[i + 1], last); i += 2 }
        } else {
            var i = end - 2
            while i >= start { last = insertNode(i / 2, data[i], data[i + 1], last); i -= 2 }
        }
        if let l = last, equals(l, l.next) {
            removeNode(l)
            last = l.next
        }
        return last
    }

    /// Entfernt Duplikate und kollineare Punkte.
    func filterPoints(_ start: Node?, _ endIn: Node? = nil) -> Node? {
        guard let start else { return nil }
        var end = endIn ?? start
        var p = start
        var again: Bool
        repeat {
            again = false
            if !p.steiner && (equals(p, p.next) || area(p.prev, p, p.next) == 0) {
                removeNode(p)
                p = p.prev
                end = p.prev
                if p === p.next { break }
                again = true
            } else {
                p = p.next
            }
        } while again || p !== end
        return end
    }

    // MARK: - Ear Clipping

    func earcutLinked(_ earIn: Node?, _ triangles: inout [UInt32], _ minX: Double, _ minY: Double, _ invSize: Double, _ pass: Int) {
        guard var ear = earIn else { return }
        if pass == 0 && invSize != 0 { indexCurve(ear, minX, minY, invSize) }

        var stop = ear
        while ear.prev !== ear.next {
            let prev = ear.prev!, next = ear.next!
            if invSize != 0 ? isEarHashed(ear, minX, minY, invSize) : isEar(ear) {
                triangles.append(UInt32(prev.i))
                triangles.append(UInt32(ear.i))
                triangles.append(UInt32(next.i))
                removeNode(ear)
                ear = next.next
                stop = next.next
                continue
            }
            ear = next
            if ear === stop {
                if pass == 0 {
                    earcutLinked(filterPoints(ear), &triangles, minX, minY, invSize, 1)
                } else if pass == 1 {
                    ear = cureLocalIntersections(filterPoints(ear)!, &triangles)
                    earcutLinked(ear, &triangles, minX, minY, invSize, 2)
                } else if pass == 2 {
                    splitEarcut(ear, &triangles, minX, minY, invSize)
                }
                break
            }
        }
    }

    func isEar(_ ear: Node) -> Bool {
        let a = ear.prev!, b = ear, c = ear.next!
        if area(a, b, c) >= 0 { return false }
        let ax = a.x, bx = b.x, cx = c.x, ay = a.y, by = b.y, cy = c.y
        let x0 = min(ax, bx, cx), y0 = min(ay, by, cy), x1 = max(ax, bx, cx), y1 = max(ay, by, cy)
        var p = c.next!
        while p !== a {
            if p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1 &&
                pointInTriangle(ax, ay, bx, by, cx, cy, p.x, p.y) &&
                area(p.prev, p, p.next) >= 0 { return false }
            p = p.next
        }
        return true
    }

    func isEarHashed(_ ear: Node, _ minX: Double, _ minY: Double, _ invSize: Double) -> Bool {
        let a = ear.prev!, b = ear, c = ear.next!
        if area(a, b, c) >= 0 { return false }
        let ax = a.x, bx = b.x, cx = c.x, ay = a.y, by = b.y, cy = c.y
        let x0 = min(ax, bx, cx), y0 = min(ay, by, cy), x1 = max(ax, bx, cx), y1 = max(ay, by, cy)
        let minZ = zOrder(x0, y0, minX, minY, invSize)
        let maxZ = zOrder(x1, y1, minX, minY, invSize)

        var p = ear.prevZ, n = ear.nextZ
        while let pp = p, pp.z >= minZ, let nn = n, nn.z <= maxZ {
            if pp.x >= x0 && pp.x <= x1 && pp.y >= y0 && pp.y <= y1 && pp !== a && pp !== c &&
                pointInTriangle(ax, ay, bx, by, cx, cy, pp.x, pp.y) && area(pp.prev, pp, pp.next) >= 0 { return false }
            p = pp.prevZ
            if nn.x >= x0 && nn.x <= x1 && nn.y >= y0 && nn.y <= y1 && nn !== a && nn !== c &&
                pointInTriangle(ax, ay, bx, by, cx, cy, nn.x, nn.y) && area(nn.prev, nn, nn.next) >= 0 { return false }
            n = nn.nextZ
        }
        while let pp = p, pp.z >= minZ {
            if pp.x >= x0 && pp.x <= x1 && pp.y >= y0 && pp.y <= y1 && pp !== a && pp !== c &&
                pointInTriangle(ax, ay, bx, by, cx, cy, pp.x, pp.y) && area(pp.prev, pp, pp.next) >= 0 { return false }
            p = pp.prevZ
        }
        while let nn = n, nn.z <= maxZ {
            if nn.x >= x0 && nn.x <= x1 && nn.y >= y0 && nn.y <= y1 && nn !== a && nn !== c &&
                pointInTriangle(ax, ay, bx, by, cx, cy, nn.x, nn.y) && area(nn.prev, nn, nn.next) >= 0 { return false }
            n = nn.nextZ
        }
        return true
    }

    func cureLocalIntersections(_ start: Node, _ triangles: inout [UInt32]) -> Node {
        var start = start
        var p = start
        repeat {
            let a = p.prev!, b = p.next.next!
            if !equals(a, b) && intersects(a, p, p.next, b) && locallyInside(a, b) && locallyInside(b, a) {
                triangles.append(UInt32(a.i)); triangles.append(UInt32(p.i)); triangles.append(UInt32(b.i))
                removeNode(p)
                removeNode(p.next)
                p = b; start = b
            }
            p = p.next
        } while p !== start
        return filterPoints(p)!
    }

    func splitEarcut(_ start: Node, _ triangles: inout [UInt32], _ minX: Double, _ minY: Double, _ invSize: Double) {
        var a = start
        repeat {
            var b = a.next.next!
            while b !== a.prev {
                if a.i != b.i && isValidDiagonal(a, b) {
                    var c = splitPolygon(a, b)
                    a = filterPoints(a, a.next)!
                    c = filterPoints(c, c.next)!
                    earcutLinked(a, &triangles, minX, minY, invSize, 0)
                    earcutLinked(c, &triangles, minX, minY, invSize, 0)
                    return
                }
                b = b.next
            }
            a = a.next
        } while a !== start
    }

    // MARK: - Löcher

    func eliminateHoles(_ data: [Double], _ holeIndices: [Int], _ outerNode: Node) -> Node {
        var queue: [Node] = []
        var outer = outerNode
        for i in 0..<holeIndices.count {
            let start = holeIndices[i] * 2
            let end = i < holeIndices.count - 1 ? holeIndices[i + 1] * 2 : data.count
            if let list = linkedList(data, start, end, clockwise: false) {
                if list === list.next { list.steiner = true }
                queue.append(getLeftmost(list))
            }
        }
        queue.sort { $0.x < $1.x }
        for q in queue {
            outer = eliminateHole(q, outer)
        }
        return outer
    }

    func eliminateHole(_ hole: Node, _ outerNode: Node) -> Node {
        guard let bridge = findHoleBridge(hole, outerNode) else { return outerNode }
        let bridgeReverse = splitPolygon(bridge, hole)
        _ = filterPoints(bridgeReverse, bridgeReverse.next)
        return filterPoints(bridge, bridge.next)!
    }

    func findHoleBridge(_ hole: Node, _ outerNode: Node) -> Node? {
        var p = outerNode
        let hx = hole.x, hy = hole.y
        var qx = -Double.infinity
        var m: Node?

        repeat {
            if hy <= p.y && hy >= p.next.y && p.next.y != p.y {
                let x = p.x + (hy - p.y) * (p.next.x - p.x) / (p.next.y - p.y)
                if x <= hx && x > qx {
                    qx = x
                    m = p.x < p.next.x ? p : p.next
                    if x == hx { return m }
                }
            }
            p = p.next
        } while p !== outerNode

        guard var mm = m else { return nil }

        let stop = mm
        let mx = mm.x, my = mm.y
        var tanMin = Double.infinity
        p = mm
        repeat {
            if hx >= p.x && p.x >= mx && hx != p.x &&
                pointInTriangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, p.x, p.y) {
                let tan = abs(hy - p.y) / (hx - p.x)
                if locallyInside(p, hole) &&
                    (tan < tanMin || (tan == tanMin && (p.x > mm.x || (p.x == mm.x && sectorContainsSector(mm, p))))) {
                    mm = p
                    tanMin = tan
                }
            }
            p = p.next
        } while p !== stop
        return mm
    }

    func sectorContainsSector(_ m: Node, _ p: Node) -> Bool {
        area(m.prev, m, p.prev) < 0 && area(p.next, m, m.next) < 0
    }

    // MARK: - Z-Order

    func indexCurve(_ start: Node, _ minX: Double, _ minY: Double, _ invSize: Double) {
        var p = start
        repeat {
            if p.z == 0 { p.z = zOrder(p.x, p.y, minX, minY, invSize) }
            p.prevZ = p.prev
            p.nextZ = p.next
            p = p.next
        } while p !== start
        p.prevZ?.nextZ = nil
        p.prevZ = nil
        _ = sortLinked(p)
    }

    func sortLinked(_ list: Node) -> Node {
        var list: Node? = list
        var inSize = 1
        var numMerges: Int
        repeat {
            var p = list
            list = nil
            var tail: Node?
            numMerges = 0
            while let pp = p {
                numMerges += 1
                var q: Node? = pp
                var pSize = 0
                for _ in 0..<inSize {
                    pSize += 1
                    q = q?.nextZ
                    if q == nil { break }
                }
                var qSize = inSize
                var pNode: Node? = pp
                while pSize > 0 || (qSize > 0 && q != nil) {
                    var e: Node
                    if pSize != 0 && (qSize == 0 || q == nil || pNode!.z <= q!.z) {
                        e = pNode!; pNode = pNode!.nextZ; pSize -= 1
                    } else {
                        e = q!; q = q!.nextZ; qSize -= 1
                    }
                    if let t = tail { t.nextZ = e } else { list = e }
                    e.prevZ = tail
                    tail = e
                }
                p = q
            }
            tail?.nextZ = nil
            inSize *= 2
        } while numMerges > 1
        return list!
    }

    func zOrder(_ x: Double, _ y: Double, _ minX: Double, _ minY: Double, _ invSize: Double) -> Int32 {
        var xi = Int32(truncatingIfNeeded: Int((x - minX) * invSize))
        var yi = Int32(truncatingIfNeeded: Int((y - minY) * invSize))
        xi = (xi | (xi << 8)) & 0x00FF00FF
        xi = (xi | (xi << 4)) & 0x0F0F0F0F
        xi = (xi | (xi << 2)) & 0x33333333
        xi = (xi | (xi << 1)) & 0x55555555
        yi = (yi | (yi << 8)) & 0x00FF00FF
        yi = (yi | (yi << 4)) & 0x0F0F0F0F
        yi = (yi | (yi << 2)) & 0x33333333
        yi = (yi | (yi << 1)) & 0x55555555
        return xi | (yi << 1)
    }

    // MARK: - Geometrie-Hilfen

    func getLeftmost(_ start: Node) -> Node {
        var p = start, leftmost = start
        repeat {
            if p.x < leftmost.x || (p.x == leftmost.x && p.y < leftmost.y) { leftmost = p }
            p = p.next
        } while p !== start
        return leftmost
    }

    func pointInTriangle(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double, _ px: Double, _ py: Double) -> Bool {
        (cx - px) * (ay - py) >= (ax - px) * (cy - py) &&
        (ax - px) * (by - py) >= (bx - px) * (ay - py) &&
        (bx - px) * (cy - py) >= (cx - px) * (by - py)
    }

    func isValidDiagonal(_ a: Node, _ b: Node) -> Bool {
        a.next.i != b.i && a.prev.i != b.i && !intersectsPolygon(a, b) &&
        ((locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b) &&
          (area(a.prev, a, b.prev) != 0 || area(a, b.prev, b) != 0)) ||
         (equals(a, b) && area(a.prev, a, a.next) > 0 && area(b.prev, b, b.next) > 0))
    }

    func area(_ p: Node, _ q: Node, _ r: Node) -> Double {
        (q.y - p.y) * (r.x - q.x) - (q.x - p.x) * (r.y - q.y)
    }

    func equals(_ p1: Node, _ p2: Node) -> Bool {
        p1.x == p2.x && p1.y == p2.y
    }

    func intersects(_ p1: Node, _ q1: Node, _ p2: Node, _ q2: Node) -> Bool {
        let o1 = sign(area(p1, q1, p2)), o2 = sign(area(p1, q1, q2))
        let o3 = sign(area(p2, q2, p1)), o4 = sign(area(p2, q2, q1))
        if o1 != o2 && o3 != o4 { return true }
        if o1 == 0 && onSegment(p1, p2, q1) { return true }
        if o2 == 0 && onSegment(p1, q2, q1) { return true }
        if o3 == 0 && onSegment(p2, p1, q2) { return true }
        if o4 == 0 && onSegment(p2, q1, q2) { return true }
        return false
    }

    func onSegment(_ p: Node, _ q: Node, _ r: Node) -> Bool {
        q.x <= max(p.x, r.x) && q.x >= min(p.x, r.x) && q.y <= max(p.y, r.y) && q.y >= min(p.y, r.y)
    }

    func sign(_ v: Double) -> Int { v > 0 ? 1 : (v < 0 ? -1 : 0) }

    func intersectsPolygon(_ a: Node, _ b: Node) -> Bool {
        var p = a
        repeat {
            if p.i != a.i && p.next.i != a.i && p.i != b.i && p.next.i != b.i && intersects(p, p.next, a, b) { return true }
            p = p.next
        } while p !== a
        return false
    }

    func locallyInside(_ a: Node, _ b: Node) -> Bool {
        area(a.prev, a, a.next) < 0
            ? area(a, b, a.next) >= 0 && area(a, a.prev, b) >= 0
            : area(a, b, a.prev) < 0 || area(a, a.next, b) < 0
    }

    func middleInside(_ a: Node, _ b: Node) -> Bool {
        var p = a
        var inside = false
        let px = (a.x + b.x) / 2, py = (a.y + b.y) / 2
        repeat {
            if ((p.y > py) != (p.next.y > py)) && p.next.y != p.y &&
                (px < (p.next.x - p.x) * (py - p.y) / (p.next.y - p.y) + p.x) { inside.toggle() }
            p = p.next
        } while p !== a
        return inside
    }

    func splitPolygon(_ a: Node, _ b: Node) -> Node {
        let a2 = Node(a.i, a.x, a.y), b2 = Node(b.i, b.x, b.y)
        nodes.append(a2); nodes.append(b2)
        let an = a.next!, bp = b.prev!
        a.next = b; b.prev = a
        a2.next = an; an.prev = a2
        b2.next = a2; a2.prev = b2
        bp.next = b2; b2.prev = bp
        return b2
    }

    func insertNode(_ i: Int, _ x: Double, _ y: Double, _ last: Node?) -> Node {
        let p = Node(i, x, y)
        nodes.append(p)
        if let last {
            p.next = last.next
            p.prev = last
            last.next.prev = p
            last.next = p
        } else {
            p.prev = p
            p.next = p
        }
        return p
    }

    func removeNode(_ p: Node) {
        p.next.prev = p.prev
        p.prev.next = p.next
        p.prevZ?.nextZ = p.nextZ
        p.nextZ?.prevZ = p.prevZ
    }

    static func signedArea(_ data: [Double], _ start: Int, _ end: Int) -> Double {
        var sum = 0.0
        var i = start, j = end - 2
        while i < end {
            sum += (data[j] - data[i]) * (data[i + 1] + data[j + 1])
            j = i
            i += 2
        }
        return sum
    }

    static func deviation(_ data: [Double], holeIndices: [Int], triangles: [UInt32]) -> Double {
        let hasHoles = !holeIndices.isEmpty
        let outerLen = hasHoles ? holeIndices[0] * 2 : data.count
        var polygonArea = abs(Self.signedArea(data, 0, outerLen))
        if hasHoles {
            for i in 0..<holeIndices.count {
                let start = holeIndices[i] * 2
                let end = i < holeIndices.count - 1 ? holeIndices[i + 1] * 2 : data.count
                polygonArea -= abs(Self.signedArea(data, start, end))
            }
        }
        var trianglesArea = 0.0
        var i = 0
        while i < triangles.count {
            let a = Int(triangles[i]) * 2, b = Int(triangles[i + 1]) * 2, c = Int(triangles[i + 2]) * 2
            trianglesArea += abs((data[a] - data[c]) * (data[b + 1] - data[a + 1]) - (data[a] - data[b]) * (data[c + 1] - data[a + 1]))
            i += 3
        }
        return polygonArea == 0 && trianglesArea == 0 ? 0 : abs((trianglesArea - polygonArea) / polygonArea)
    }
}
}
