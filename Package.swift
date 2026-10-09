// swift-tools-version:5.9
import PackageDescription

// KartoKit – performante Karten-Anzeigeschicht für iOS/CarPlay (Metal).
//
// Modulschnitt:
//   KartoCore    plattformunabhängig: Tile-Mathe, Kamera, MVT-/PMTiles-Decoder,
//                Style, Tessellation (Linien, Earcut, Gebäude-Extrusion).
//                Kompiliert & testet auch unter Linux (kein Metal, kein UIKit).
//   KartoRender  Apple-only: Metal-Renderer, Shader, Tile-Manager, MapView,
//                Gesten, SwiftUI-Wrapper.
let package = Package(
    name: "KartoKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "KartoCore", targets: ["KartoCore"]),
        .library(name: "KartoRender", targets: ["KartoRender"]),
    ],
    targets: [
        // zlib ist auf iOS/macOS (libz.tbd) und Linux (zlib1g-dev) vorhanden.
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "KartoCore",
            dependencies: ["CZlib"],
            path: "Sources/KartoCore"
        ),
        .target(
            name: "KartoRender",
            dependencies: ["KartoCore"],
            path: "Sources/KartoRender",
            // Die Textdatei erzwingt ein Resource-Bundle (Bundle.module), in das Xcode
            // die aus Shaders.metal kompilierte default.metallib legt.
            resources: [.copy("Resources/KartoRender.txt")]
        ),
        .testTarget(
            name: "KartoCoreTests",
            dependencies: ["KartoCore"],
            path: "Tests/KartoCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
