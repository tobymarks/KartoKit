import Foundation

/// Wandelt Polylinien in Dreiecksstreifen um: Miter-Joins im Verlauf, runde
/// Kappen an den Enden, runde Ecken dort, wo der Miter sonst abgeschnitten
/// wuerde.
///
/// Die Breite steckt nicht im Mesh, sondern kommt pro Frame als Uniform in den
/// Shader – so bleibt ein Mesh für alle fraktionalen Zoomstufen gültig und die
/// Linienbreite in Pixeln konstant. Das ist derselbe Trick wie bei MapLibre.
///
/// Die Rundungen nutzen genau diesen Trick mit: Ein Kranz von Vertizes an
/// derselben Stelle, deren Normalen im Kreis stehen, wird im Shader zur
/// Scheibe mit dem Radius der halben Linienbreite. Kein zweiter Shader, kein
/// zweiter Zeichenaufruf, keine Breite im Mesh.
public enum LineTessellator {
    /// Maximale Miter-Länge (relativ zur halben Breite); darüber wird abgeschnitten.
    public static let miterLimit = 2.0

    /// Ecken einer Rundung. Sechs genuegen: die Linien sind zwei bis sechs
    /// Pixel breit, die Scheibe misst also selten mehr als drei Pixel. Die
    /// Sehne haengt dabei um 13 Prozent des Radius durch — bei anderthalb
    /// Pixel Radius ein Fuenftel Pixel, unter der Aufloesung.
    ///
    /// Die Zahl ist nicht kosmetisch: jede Scheibe kostet sieben Vertizes,
    /// und eine Stadtkachel enthaelt dreitausend Linienfeatures. Deshalb
    /// kommt die Scheibe nur an die Enden und an wirklich scharfe Knicke,
    /// nie an jeden Stuetzpunkt.
    static let rundungsEcken = 6

    public static func tessellate(_ line: [TilePoint], into bucket: inout MeshBucket<LineVertex>) {
        var eigen: Set<TilePoint> = []
        tessellate(line, into: &bucket, bereitsGerundet: &eigen)
    }

    /// - Parameter bereitsGerundet: Endpunkte, an denen in diesem Bucket
    ///   schon eine Scheibe liegt. Kacheln zerlegen Strassen in viele kurze
    ///   Features — im Testfall 3.120 Features mit im Schnitt nur 1,8
    ///   Punkten. Ohne dieses Gedaechtnis bekaeme jeder gemeinsame Punkt
    ///   zwei deckungsgleiche Scheiben.
    public static func tessellate(_ line: [TilePoint], into bucket: inout MeshBucket<LineVertex>,
                                  bereitsGerundet: inout Set<TilePoint>) {
        // Duplikate entfernen (MVT enthält gelegentlich Nullsegmente).
        var pts: [Vec2] = []
        pts.reserveCapacity(line.count)
        for p in line {
            let v = Vec2(Double(p.x), Double(p.y))
            if let last = pts.last, (last - v).length < 1e-9 { continue }
            pts.append(v)
        }
        guard pts.count >= 2 else { return }

        let base = UInt32(bucket.vertices.count)
        let n = pts.count
        // Stuetzpunkte, an denen der Miter nicht reicht — dort wird der
        // Aussenwinkel hinterher mit einer Scheibe geschlossen. Erst
        // sammeln, dann zeichnen: der Streifen braucht seine Vertizes
        // fortlaufend, eine Scheibe mittendrin wuerde die Indizes zerreissen.
        var scharfeEcken: [Vec2] = []

        for i in 0..<n {
            let normal: Vec2
            if i == 0 {
                normal = (pts[1] - pts[0]).normalized.perpendicular
            } else if i == n - 1 {
                normal = (pts[n - 1] - pts[n - 2]).normalized.perpendicular
            } else {
                let nPrev = (pts[i] - pts[i - 1]).normalized.perpendicular
                let nNext = (pts[i + 1] - pts[i]).normalized.perpendicular
                let sum = nPrev + nNext
                if sum.length < 1e-9 {
                    // 180°-Kehre: einfache Normale, und die Ecke wird rund.
                    normal = nPrev
                    scharfeEcken.append(pts[i])
                } else {
                    let m = sum.normalized
                    let voll = 1.0 / max(m.dot(nPrev), 1e-6)
                    if voll > miterLimit { scharfeEcken.append(pts[i]) }
                    normal = m * min(voll, miterLimit)
                }
            }
            bucket.vertices.append(LineVertex(Float(pts[i].x), Float(pts[i].y), Float(normal.x), Float(normal.y)))
            bucket.vertices.append(LineVertex(Float(pts[i].x), Float(pts[i].y), Float(-normal.x), Float(-normal.y)))
        }

        for i in 0..<(n - 1) {
            let a = base + UInt32(i * 2)
            bucket.indices.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
        }

        // Enden runden. Bei einem geschlossenen Ring (Flaechenumriss) fallen
        // Anfang und Ende zusammen; die zweite Scheibe liegt dann exakt auf
        // der ersten und stoert nicht.
        for ende in [line.first!, line.last!] where bereitsGerundet.insert(ende).inserted {
            scheibe(Vec2(Double(ende.x), Double(ende.y)), into: &bucket)
        }
        for p in scharfeEcken { scheibe(p, into: &bucket) }
    }

    /// Eine Scheibe vom Radius der halben Linienbreite.
    ///
    /// Sie erledigt drei Dinge, die sonst drei Sonderfaelle waeren: die runde
    /// Kappe am Ende, die runde Ecke am scharfen Knick — und, der eigentliche
    /// Gewinn, die Naht zwischen zwei getrennten Features, die sich einen
    /// Punkt teilen. Der Verkehrsfluss zerfaellt genau dort in eigene
    /// Features, wo die Farbe wechselt, und liegt ausserdem in vier
    /// getrennten Style-Layern; zwei stumpfe Kappen im Winkel liessen dort
    /// eine Kerbe stehen. Legt jedes Feature seine Scheibe an den gemeinsamen
    /// Punkt, ist die Kerbe zu, ohne dass eines vom anderen wissen muesste.
    ///
    /// Die Ueberlappung ist unbedenklich, solange die Farben deckend sind —
    /// und das sind sie: Strassen, Fluss und Umrisse zeichnen mit Alpha 1.
    static func scheibe(_ p: Vec2, into bucket: inout MeshBucket<LineVertex>) {
        let mitte = UInt32(bucket.vertices.count)
        bucket.vertices.append(LineVertex(Float(p.x), Float(p.y), 0, 0))
        for k in 0...rundungsEcken {
            let w = 2.0 * Double.pi * Double(k) / Double(rundungsEcken)
            bucket.vertices.append(LineVertex(Float(p.x), Float(p.y),
                                              Float(cos(w)), Float(sin(w))))
        }
        for k in 0..<rundungsEcken {
            let a = mitte + 1 + UInt32(k)
            bucket.indices.append(contentsOf: [mitte, a, a + 1])
        }
    }
}
