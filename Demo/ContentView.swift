import SwiftUI
import QuartzCore
import KartoCore
import KartoRender

/// Kachelquelle: MapTiler-Key (falls gesetzt) → `karte.pmtiles` im Bundle (Offline-Region, siehe
/// Demo/kacheln-holen.sh) → sonst OpenFreeMap online (weltweit, kostenlos, ohne Schlüssel).
/// `--florenz` als Launch-Argument erzwingt das Offline-Archiv `firenze.pmtiles`.
private let MAPTILER_KEY = ""

@MainActor
struct ContentView: View {
    @State private var source: TileSource?
    @State private var camera = MapCamera(
        coordinate: Coordinate(latitude: 43.7731, longitude: 11.2560), // Florenz, Dom
        zoom: 16, bearing: 20, pitch: 60
    )
    @State private var stats = MapRenderer.FrameStats()
    @State private var simulating = false
    @State private var replaying = false
    @State private var replaySpeed = 1.0
    @State private var player: ReferenceDrivePlayer? = ReferenceDrivePlayer()
    @State private var navMode: NavigationController.Mode = .following
    @State private var error: String?
    @State private var mapView: MapView?
    @State private var dark = false
    /// Referenzfahrt möglich: online oder mit regionalem Archiv.
    @State private var regionVerfuegbar = false
    @State private var schema: TileSchema = .protomaps
    /// Design: KartoKit-Theme (Kartenfarben + eigener Pfeil "NavigationArrow" aus dem Asset-Katalog).
    /// Alternativen: `.nightDrive`, `.cleanWhite`, oder eigene `MapTheme`-Instanz / `ThemeTokens.apply`.
    private var theme: MapTheme { .kartoKit(dark: dark) }

    /// Ein Controller pro Karte; hält Glättungs-/Kamerazustand.
    @State private var navigation = NavigationController()

    /// Beispielroute quer durch die Florentiner Altstadt (Bahnhof → Dom → Uffizien).
    private let florenzRoute: [Coordinate] = [
        .init(latitude: 43.7765, longitude: 11.2478), .init(latitude: 43.7757, longitude: 11.2497),
        .init(latitude: 43.7746, longitude: 11.2520), .init(latitude: 43.7738, longitude: 11.2540),
        .init(latitude: 43.7733, longitude: 11.2556), .init(latitude: 43.7726, longitude: 11.2565),
        .init(latitude: 43.7714, longitude: 11.2563), .init(latitude: 43.7700, longitude: 11.2558),
        .init(latitude: 43.7687, longitude: 11.2554), .init(latitude: 43.7678, longitude: 11.2556),
    ]

    /// Demo-Route: in Florenz die feste Altstadtroute, mit regionalem Archiv/online die Referenzfahrt.
    private var demoRoute: [Coordinate] {
        if regionVerfuegbar, let r = player?.route, r.count >= 2 { return r }
        return florenzRoute
    }

    /// Aktive Route mit Beispiel-Verkehrslage (zäh 250–400 m, Stau 600–700 m).
    private var activeRoute: RouteDisplay {
        let coords = replaying ? (player?.route ?? demoRoute) : demoRoute
        var r = RouteDisplay(id: "aktiv", coordinates: coords)
        // Der Verkehrssaum haengt an trafficKnown, nicht an den Abschnitten:
        // ohne Verkehrsdaten wird gar kein Saum gezeichnet.
        r.trafficKnown = true
        if !replaying {
            r.segments = [RouteDisplay.Segment(from: 250, to: 400, kind: .slow),
                          RouteDisplay.Segment(from: 600, to: 700, kind: .jam)]
        }
        return r
    }

    /// Ziel-Pin und ein Ladepunkt als Beispiel-Annotationen.
    private var demoAnnotations: [MapAnnotation] {
        let gruen = theme.extra["chargingAvailable"] ?? RGBA(hex: 0x2FB36B)
        return [MapAnnotation(id: "ziel", coordinate: demoRoute.last!, style: .pin(color: theme.route.active), priority: 100),
         // Ladepark-Marker: Segmentring, ein Segment je Ladepunkt (grün frei, grau belegt, rot defekt)
         MapAnnotation(id: "laden", coordinate: Coordinate(latitude: 43.7726, longitude: 11.2565),
                       style: .ring(symbolName: "bolt.fill", fill: theme.route.active,
                                    segments: [gruen, gruen, gruen, RGBA(hex: 0xB9B6AE), theme.route.trafficJam],
                                    track: RGBA(hex: 0xD6D3CB)),
                       size: 30, label: "Ionity · 3/5 frei")]
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let source {
                KartoMap(source: source,
                         theme: theme,
                         schema: schema,
                         camera: $camera,
                         routes: [activeRoute],
                         annotations: demoAnnotations,
                         navigation: navigation,
                         onFrame: { stats = $0 },
                         onNavigationModeChange: { navMode = $0 },
                         onAnnotationTap: { print("Annotation getippt: \($0.id)") },
                         mapView: { mapView = $0 },
                         // Typische Overlays: Karte oben ~135 pt, Bottom-Sheet ~120 pt → Puck bei 88 % des Rests
                         overlayInsets: UIEdgeInsets(top: 135, left: 0, bottom: 120, right: 0))
                    .ignoresSafeArea()
            } else if let error {
                Text(error).padding()
            } else {
                ProgressView("Lade Kachelquelle…")
            }
            overlay
        }
        .overlay(alignment: .bottomTrailing) { recenterButton }
        .task { await loadSource(); applyLaunchArguments() }
        .task(id: simulating) { await simulateGPS() }
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(format: "z %.2f  pitch %.0f°  bearing %.0f°", camera.zoom, camera.pitch, camera.bearing))
            Text("\(stats.tilesDrawn) Kacheln · \(stats.drawCalls) Draw-Calls · \(stats.tilesLoading) ladend · \(stats.cacheBytes / 1_048_576) MB")
            Text(String(format: "CPU %.2f ms/Frame · Modus: %@", stats.cpuMillis, "\(navMode)"))
            HStack {
                Button(simulating ? "Fahrt stoppen" : "Fahrt simulieren") { simulating.toggle() }
                Button("Übersicht") { mapView?.showRouteOverview() }
                Button("Norden") { mapView?.resetNorth() }
                Button(dark ? "Tag" : "Nacht") { dark.toggle() }   // 425-ms-Überblendung
            }
            .buttonStyle(.bordered)
            if player != nil, regionVerfuegbar {
                HStack {
                    Button(replaying ? "Referenzfahrt stoppen" : "Referenzfahrt abspielen") { toggleReplay() }
                    Picker("Tempo", selection: $replaySpeed) {
                        Text("1×").tag(1.0); Text("4×").tag(4.0); Text("10×").tag(10.0)
                    }.pickerStyle(.segmented).frame(width: 150)
                }
                .buttonStyle(.bordered)
                if let url = player?.logURL, !replaying {
                    Text("Spur: \(url.lastPathComponent) (Dateien-App → KartoDemo)").font(.system(size: 10))
                }
            } else if player != nil {
                Text("Referenzfahrt: karte.pmtiles (Demo/kacheln-holen.sh) bündeln oder MAPTILER_KEY setzen").font(.system(size: 10))
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }

    /// Erscheint, sobald der Nutzer die Karte verschoben hat.
    @ViewBuilder private var recenterButton: some View {
        if simulating, navMode != .following {
            Button {
                mapView?.recenter()
            } label: {
                Label("Zentrieren", systemImage: "location.fill")
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(24)
        }
    }

    /// Referenzfahrt Stuttgart→Pforzheim abspielen; die Kameraspur landet als CSV in
    /// Documents (Info.plist: UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace = YES,
    /// dann per Dateien-App/Finder auslesen) → Auswertung/compare_karto_trace.py.
    private func toggleReplay() {
        guard let player, let mapView else { return }
        if replaying {
            player.stop(); replaying = false
        } else {
            simulating = false
            navigation.maneuverDistancesAlong = player.maneuvers
            camera = MapCamera(coordinate: player.startCoordinate, zoom: 15.5, bearing: 0, pitch: 58)
            player.start(on: mapView, speed: replaySpeed)
            replaying = true
        }
    }

    /// Automatisierung (Simulator/CI): `--night`, `--simulate`, `--overview`, `--replay`.
    private func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--night") { dark = true }
        if args.contains("--simulate") { simulating = true }
        if args.contains("--overview") { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { mapView?.showRouteOverview() } }
        // Gleicher Pfad wie in einer App-Integration (CarPlay/Telefon): Einpassen in die freie Fläche.
        if args.contains("--overview-insets") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                mapView?.showRouteOverview(insets: UIEdgeInsets(top: 120, left: 200, bottom: 100, right: 112))
            }
        }
        if args.contains("--replay"), regionVerfuegbar { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { toggleReplay() } }
    }

    private func loadSource() async {
        do {
            if !MAPTILER_KEY.isEmpty {
                schema = .openMapTiles
                source = XYZTileSource(template: "https://api.maptiler.com/tiles/v3/{z}/{x}/{y}.pbf?key=\(MAPTILER_KEY)", maxZoom: 14)
                camera = MapCamera(coordinate: Coordinate(latitude: 48.8917, longitude: 8.6981), zoom: 16, bearing: 0, pitch: 60) // Pforzheim
                regionVerfuegbar = true
            } else if let url = Bundle.main.url(forResource: "karte", withExtension: "pmtiles") {
                schema = .protomaps
                source = try await PMTilesSource(url: url)
                camera = MapCamera(coordinate: Coordinate(latitude: 48.8917, longitude: 8.6981), zoom: 16, bearing: 0, pitch: 60) // Pforzheim
                regionVerfuegbar = true
            } else if let url = Bundle.main.url(forResource: "firenze", withExtension: "pmtiles"), ProcessInfo.processInfo.arguments.contains("--florenz") {
                source = try await PMTilesSource(url: url)
            } else {
                // Standard: OpenFreeMap – weltweit, kostenlos, ohne Schlüssel (OpenMapTiles-Schema).
                schema = .openMapTiles
                source = CachedTileSource(wrapping: OpenFreeMap.source(), name: "KartoDemoTiles")
                camera = MapCamera(coordinate: Coordinate(latitude: 48.8917, longitude: 8.6981), zoom: 16, bearing: 0, pitch: 60) // Pforzheim
                regionVerfuegbar = true
            }
        } catch {
            self.error = "Kachelquelle konnte nicht geöffnet werden: \(error)"
        }
    }

    /// Simuliert einen echten GPS-Empfänger: 1 Hz, ±6 m Rauschen, Kurs verrauscht,
    /// Tempo 30–50 km/h. Alles Weitere (Snapping, Gleiten, Kamera) macht der
    /// NavigationController – genau wie später mit CLLocationManager.
    private func simulateGPS() async {
        guard simulating else { return }
        let snapper = RouteSnapper(route: demoRoute)
        var along = 0.0
        var t = CACurrentMediaTime()
        var seed: UInt64 = 42
        func rand() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        // Nächstes Manöver: die Kurve am Dom (ca. 900 m)
        navigation.nextManeuverDistanceAlong = 900
        while simulating, along < snapper.totalLength {
            let speed = 8.3 + 5.5 * sin(along / 300) // 30–50 km/h
            let p = snapper.coordinate(atDistance: along)!
            let noisy = GeoMath.destination(from: p, bearing: rand() * 360, meters: rand() * 6)
            let course = snapper.bearing(atDistance: along) + (rand() - 0.5) * 20
            mapView?.updateLocation(LocationFix(coordinate: noisy, course: course, speed: speed,
                                                horizontalAccuracy: 8, timestamp: t))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            t = CACurrentMediaTime()
            along += speed
        }
        simulating = false
    }
}
