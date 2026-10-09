#if canImport(SwiftUI) && canImport(UIKit) && canImport(MetalKit)
import SwiftUI
import QuartzCore
import UIKit
import KartoCore

/// SwiftUI-Wrapper um `MapView`.
///
/// ```swift
/// @State var camera = MapCamera(coordinate: .init(latitude: 48.89, longitude: 8.70), zoom: 15, pitch: 60)
/// KartoMap(source: source, style: .openMapTiles, camera: $camera, route: route, userPosition: pos)
/// ```
public struct KartoMap: UIViewRepresentable {
    public let source: TileSource
    public var style: MapStyle
    /// Theme + Schema (bevorzugt gegenüber `style`).
    public var theme: MapTheme?
    public var schema: TileSchema = .openMapTiles
    public var routes: [RouteDisplay]?
    public var annotations: [MapAnnotation] = []
    public var onAnnotationTap: ((MapAnnotation) -> Void)?
    public var highlightedRoadNames: Set<String> = []
    @Binding public var camera: MapCamera
    public var route: [Coordinate]
    public var userPosition: Coordinate?
    public var userHeading: Double
    public var animateCameraChanges: Bool
    /// Navi-Kameraführung; Fixes über `navigation.update(fix:)` einspeisen.
    public var navigation: NavigationController?
    public var onFrame: ((MapRenderer.FrameStats) -> Void)?
    public var onNavigationModeChange: ((NavigationController.Mode) -> Void)?
    /// Zugriff auf die erzeugte MapView (z. B. für `recenter()`), wird nach makeUIView gesetzt.
    public var mapView: ((MapView) -> Void)?
    /// Von Overlays verdeckte Ränder (Puck-Anker bezieht sich auf den Rest).
    public var overlayInsets: UIEdgeInsets = .zero

    public init(source: TileSource, style: MapStyle = .openMapTiles, camera: Binding<MapCamera>,
                route: [Coordinate] = [], userPosition: Coordinate? = nil, userHeading: Double = 0,
                animateCameraChanges: Bool = true, navigation: NavigationController? = nil,
                onFrame: ((MapRenderer.FrameStats) -> Void)? = nil,
                onNavigationModeChange: ((NavigationController.Mode) -> Void)? = nil,
                mapView: ((MapView) -> Void)? = nil, overlayInsets: UIEdgeInsets = .zero) {
        self.overlayInsets = overlayInsets
        self.source = source
        self.style = style
        _camera = camera
        self.route = route
        self.userPosition = userPosition
        self.userHeading = userHeading
        self.animateCameraChanges = animateCameraChanges
        self.navigation = navigation
        self.onFrame = onFrame
        self.onNavigationModeChange = onNavigationModeChange
        self.mapView = mapView
    }

    /// Bevorzugter Initializer: Theme + Kachelschema, Routen mit Verkehrslage, Annotationen.
    public init(source: TileSource, theme: MapTheme, schema: TileSchema = .openMapTiles, camera: Binding<MapCamera>,
                routes: [RouteDisplay] = [], annotations: [MapAnnotation] = [],
                highlightedRoadNames: Set<String> = [], navigation: NavigationController? = nil,
                animateCameraChanges: Bool = true,
                onFrame: ((MapRenderer.FrameStats) -> Void)? = nil,
                onNavigationModeChange: ((NavigationController.Mode) -> Void)? = nil,
                onAnnotationTap: ((MapAnnotation) -> Void)? = nil,
                mapView: ((MapView) -> Void)? = nil, overlayInsets: UIEdgeInsets = .zero) {
        self.source = source
        self.style = schema.style(theme: theme)
        self.theme = theme
        self.schema = schema
        _camera = camera
        self.route = []
        self.routes = routes
        self.annotations = annotations
        self.highlightedRoadNames = highlightedRoadNames
        self.userHeading = 0
        self.animateCameraChanges = animateCameraChanges
        self.navigation = navigation
        self.onFrame = onFrame
        self.onNavigationModeChange = onNavigationModeChange
        self.onAnnotationTap = onAnnotationTap
        self.mapView = mapView
        self.overlayInsets = overlayInsets
    }

    public func makeUIView(context: Context) -> MapView {
        // swiftlint:disable:next force_try
        let view: MapView
        if let theme {
            view = try! MapView(frame: .zero, source: source, theme: theme, schema: schema, camera: camera)
        } else {
            view = try! MapView(frame: .zero, source: source, style: style, camera: camera)
        }
        if let routes { view.routes = routes } else { view.route = route }
        view.annotations = annotations
        view.onAnnotationTap = onAnnotationTap
        view.highlightedRoadNames = highlightedRoadNames
        view.navigation = navigation
        if navigation == nil {
            view.userPosition = userPosition
            view.userHeading = userHeading
        }
        view.onNavigationModeChange = onNavigationModeChange
        view.overlayInsets = overlayInsets
        let binding = $camera
        let onFrame = self.onFrame
        view.onFrame = { [weak view] stats in
            guard let view else { return }
            // Statistik gedrosselt (5 Hz) weiterreichen – sonst rendert SwiftUI mit 120 Hz mit.
            let tNow = CACurrentMediaTime()
            if tNow - context.coordinator.lastStatsTime > 0.2 {
                context.coordinator.lastStatsTime = tNow
                onFrame?(stats)
            }
            // Kamera-Änderungen durch Gesten zurück in das Binding spiegeln.
            // Gedrosselt (10 Hz): im Navi-Modus ändert sich die Kamera jedes Frame,
            // SwiftUI muss das nicht mit 120 Hz sehen.
            let cam = view.camera
            let now = CACurrentMediaTime()
            if cam != context.coordinator.lastPushed, now - context.coordinator.lastPushTime > 0.1 {
                context.coordinator.lastPushed = cam
                context.coordinator.lastPushTime = now
                let coordinator = context.coordinator
                // `expectedEcho` erst unmittelbar vor dem Schreiben setzen: SwiftUI ruft updateUIView
                // synchron danach auf, und nur genau dieser Wert darf als Echo ignoriert werden.
                DispatchQueue.main.async { coordinator.expectedEcho = cam; binding.wrappedValue = cam }
            }
        }
        context.coordinator.lastPushed = camera
        // Nicht während des SwiftUI-Updates in @State schreiben lassen.
        if let cb = mapView { DispatchQueue.main.async { cb(view) } }
        return view
    }

    public func updateUIView(_ view: MapView, context: Context) {
        // Nur echte Änderungen von außen an die Karte geben – Echos der eigenen Kamera-Spiegelung
        // (Gesten/Navi) nicht, sonst würde ein veralteter Wert zurückgespielt und das Navi
        // fiele in den Freilauf (flyTo zählt als Nutzereingriff).
        if camera != context.coordinator.expectedEcho, camera != context.coordinator.lastPushed {
            context.coordinator.lastPushed = camera
            context.coordinator.expectedEcho = camera
            view.setCamera(camera, animated: animateCameraChanges, duration: 0.35)
        }
        if let routes { if view.routes != routes { view.routes = routes } } else if view.route != route { view.route = route }
        if view.annotations != annotations { view.annotations = annotations }
        if let theme, view.theme != theme { view.setTheme(theme, animated: true) }
        if view.highlightedRoadNames != highlightedRoadNames { view.highlightedRoadNames = highlightedRoadNames }
        view.onAnnotationTap = onAnnotationTap
        if view.navigation !== navigation { view.navigation = navigation }
        if view.overlayInsets != overlayInsets { view.overlayInsets = overlayInsets }
        if navigation == nil {
            if view.userPosition != userPosition { view.userPosition = userPosition }
            if view.userHeading != userHeading { view.userHeading = userHeading }
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var lastPushed: MapCamera?
        var expectedEcho: MapCamera?
        var lastPushTime: CFTimeInterval = 0
        var lastStatsTime: CFTimeInterval = 0
    }
}
#endif
