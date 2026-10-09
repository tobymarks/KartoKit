// Demo-App für KartoKit.
//
// Einrichtung (ca. 3 Minuten):
//   1. Xcode → File → New → Project → iOS App (SwiftUI), z. B. "KartoDemo".
//   2. File → Add Package Dependencies… → "Add Local…" → den Ordner KartoKit wählen.
//      Beim Target "KartoDemo" die Library "KartoRender" hinzufügen.
//   3. Diese Datei + ContentView.swift in das Projekt ziehen (die generierten
//      App-/ContentView-Dateien ersetzen).
//   4. Demo/firenze.pmtiles in das App-Target ziehen ("Copy items if needed",
//      Target Membership: KartoDemo) → läuft komplett offline.
//   5. Für 120 Hz auf ProMotion-Geräten in der Info.plist des App-Targets
//      "CADisableMinimumFrameDurationOnPhone" = YES setzen.
//   6. Optional: MAPTILER_KEY in ContentView.swift setzen → weltweite Online-Kacheln.
//   7. Referenzfahrt (Stuttgart→Pforzheim, GPX): Demo/referenzfahrt.gpx
//      und ReferenceDrivePlayer.swift ins Target; braucht Online-Kacheln (Schritt 6).
//      Für den CSV-Export der Kameraspur in der Info.plist "UIFileSharingEnabled" und
//      "LSSupportsOpeningDocumentsInPlace" = YES → Dateien-App → KartoDemo → karto_trace_*.csv
//      → Auswertung/compare_karto_trace.py karto_trace.csv iphone_frame_fits.json
//   Schneller: `brew install xcodegen; cd Demo; xcodegen generate` erzeugt KartoDemo.xcodeproj
//   mit allem hier Beschriebenen (project.yml).
//   8. Demo/Assets.xcassets enthält NavigationArrow.imageset (Navi-Pfeil aus dem
//      Brandkit). Fehlt es, zeichnet KartoKit ersatzweise den Theme-Pfeil.
//      Der Knopf "Nacht"/"Tag" schaltet das KartoKit-Theme mit 425-ms-Überblendung um.
//
// Build & Run auf einem echten Gerät (Metal im Simulator geht, aber langsamer).

import SwiftUI
import KartoCore
import KartoRender

@main
struct KartoDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
