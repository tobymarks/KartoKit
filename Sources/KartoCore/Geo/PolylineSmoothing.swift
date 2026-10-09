import Foundation

/// Glaettet eine Linie dort, wo sie gerade sein sollte — und nur dort.
///
/// **Warum ueberhaupt.** Am 4. September 2026 fiel auf, dass die
/// Routenlinie auf einer schnurgeraden Strasse in Pforzheim sichtbar
/// schlaengelt, waehrend die Fahrbahn darunter gerade laeuft. Die
/// Messung an einer echten Route (Pforzheim → Stuttgart, 1018
/// Stuetzpunkte) hat den Verdacht bestaetigt: Auf Fenstern, die
/// nachweislich gerade sind, betraegt die Querabweichung von der
/// Ausgleichsgeraden im Median **3,7 Meter**, in zehn Prozent der
/// Faelle ueber 9,6 Meter. Das ist keine Rundung — die Koordinaten
/// liegen zwar auf einem Raster von 10^-5 Grad, also rund 1,1 m, aber
/// das erklaert nur einen Bruchteil. Der Rest ist die Streuung der
/// Wegknoten selbst.
///
/// **Warum kruemmungsabhaengig.** Eine Linie durchgehend zu glaetten
/// ist der naheliegende und falsche Weg: In einer engen Kurve schneidet
/// die geglaettete Linie die Ecke und liegt dann sichtbar neben der
/// Fahrbahn — deutlich schlimmer als das Zappeln, das sie beheben
/// sollte. Deshalb wirkt die Glaettung nur, wo der Knickwinkel klein
/// ist, also genau im Fall „muesste eigentlich gerade sein". Echte
/// Abbiegungen bleiben unangetastet scharf.
///
/// **Verfahren.** Ein Punkt wird zu seinem eigenen Mittelwert mit den
/// beiden Nachbarn hin verschoben (ein Chaikin-artiger Schritt, aber
/// ortstreu statt eckenschneidend). Das Gewicht faellt linear von
/// vollem Einfluss bei 0° auf null beim Grenzwinkel. Zwei Durchgaenge
/// genuegen; mehr glaetten heisst nur, langsam doch die Kurven zu
/// verlieren.
public enum PolylineSmoothing {

    /// Bis zu welchem Knickwinkel geglaettet wird.
    ///
    /// Zwanzig Grad, gemessen zwischen den beiden anliegenden
    /// Strecken. Eine gerade Strasse mit Knotenstreuung liegt deutlich
    /// darunter; jede Abbiegung, jede Ausfahrt und jeder Kreisverkehr
    /// deutlich darueber.
    public static let maxWinkelGrad: Double = 20

    /// Wie stark ein Punkt hoechstens zu seinem Nachbarmittel wandert.
    ///
    /// Halb: Das reicht, um die Streuung sichtbar zu beruhigen, und
    /// laesst die Linie trotzdem dort, wo die Daten sie hinlegen.
    public static let staerke: Double = 0.5

    /// Wie oft der Durchgang wiederholt wird.
    public static let durchgaenge = 2

    /// Glaettet die Linie. Endpunkte bleiben unberuehrt: Sie sind
    /// Anfang und Ziel und duerfen sich nicht bewegen.
    public static func geglaettet(
        _ punkte: [Coordinate],
        maxWinkelGrad: Double = maxWinkelGrad,
        staerke: Double = staerke,
        durchgaenge: Int = durchgaenge
    ) -> [Coordinate] {
        guard punkte.count >= 3, durchgaenge > 0 else { return punkte }
        var aus = punkte
        for _ in 0..<durchgaenge {
            aus = einDurchgang(aus, maxWinkelGrad: maxWinkelGrad,
                               staerke: staerke)
        }
        return aus
    }

    private static func einDurchgang(
        _ punkte: [Coordinate], maxWinkelGrad: Double, staerke: Double
    ) -> [Coordinate] {
        var aus = punkte
        // Auf einen lokal metrischen Raum, damit der Winkel in hohen
        // Breiten nicht von der Laengenverzerrung verfaelscht wird.
        let cosLat = cos(punkte[punkte.count / 2].latitude * .pi / 180)
        for i in 1..<(punkte.count - 1) {
            let a = punkte[i - 1], b = punkte[i], c = punkte[i + 1]
            let v1 = (x: (b.longitude - a.longitude) * cosLat,
                      y: b.latitude - a.latitude)
            let v2 = (x: (c.longitude - b.longitude) * cosLat,
                      y: c.latitude - b.latitude)
            let n1 = (v1.x * v1.x + v1.y * v1.y).squareRoot()
            let n2 = (v2.x * v2.x + v2.y * v2.y).squareRoot()
            guard n1 > 0, n2 > 0 else { continue }
            let cs = max(-1, min(1, (v1.x * v2.x + v1.y * v2.y) / (n1 * n2)))
            let winkel = acos(cs) * 180 / .pi
            guard winkel < maxWinkelGrad else { continue }
            // Voller Einfluss bei 0 Grad, keiner am Grenzwinkel.
            let gewicht = staerke * (1 - winkel / maxWinkelGrad)
            let mittelLat = (a.latitude + c.latitude) / 2
            let mittelLon = (a.longitude + c.longitude) / 2
            aus[i] = Coordinate(
                latitude: b.latitude + (mittelLat - b.latitude) * gewicht,
                longitude: b.longitude + (mittelLon - b.longitude) * gewicht)
        }
        return aus
    }
}
