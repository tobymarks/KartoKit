# KartoKit

A lightweight vector map renderer for iOS and CarPlay, written in pure **Swift + Metal**.
No C++ core, no FFI layer, no proprietary SDK.

KartoKit draws Mapbox Vector Tiles (from PMTiles archives or any XYZ tile server) with its own
tessellation and a small Metal pipeline: 2.5D view with extruded buildings, pitch up to 70°,
rotation, routes with traffic, a navigation puck and a camera tuned for turn-by-turn navigation.

> **Status: unmaintained prototype.** KartoKit was built as the map layer for a navigation app
> that has since been discontinued. The code is published as-is so others can learn from it,
> fork it and continue it. Issues and pull requests are welcome, but there is no active
> maintainer and no release schedule.
>
> Most code comments and some identifiers are in **German**.

## Why

The usual options for custom maps on iOS each have a catch: MapKit is hard to style, commercial
SDKs get expensive at scale, and MapLibre Native brings a large C++ core that is hard to debug.
KartoKit explores the other end: a small, readable renderer (~10k lines) that you can fully
understand and change.

## Features

| Area | Status |
|---|---|
| PMTiles v3 (local + HTTP range requests, gzip, leaf directories) | ✅ tested |
| XYZ tile URLs (OpenFreeMap, MapTiler, Stadia, own server) | ✅ |
| MVT decoder (hand-written protobuf reader, no dependencies) | ✅ tested |
| Camera: fractional zoom, bearing, pitch, projection/unprojection | ✅ tested |
| Tile coverage with distance-based LOD (fine in front, coarse far away) | ✅ tested |
| Earcut triangulation (port of mapbox/earcut) | ✅ tested |
| Lines with miter joins, constant pixel width across zoom | ✅ |
| Building extrusion with flat shading (walls, roofs, courtyards) | ✅ |
| Metal renderer: 4× MSAA, depth for buildings, premultiplied blending | ✅ |
| Background loading, LRU GPU cache, parent-tile fallback while zooming | ✅ |
| Gestures: pan with inertia, pinch around focus, rotate, two-finger pitch, double tap, quick zoom | ✅ |
| Navigation camera: route snapping, smooth gliding puck, zoom by look-ahead, maneuver view, auto-recenter | ✅ tested with a replayed real drive |
| Themes (`MapTheme`) incl. day/night crossfade, design tokens (designtokens.org JSON) | ✅ tested |
| Routes: driven part, traffic sections, alternatives, maneuver arrow (one mesh, colors in shader) | ✅ tested |
| Annotations: pins, circles, images, text, pills, segment rings, collision handling, tap callback | ✅ |
| Labels v1: place names, straight road labels, highway shields, collision grid | ✅ |
| Disk tile cache with offline fallback (`CachedTileSource`) | ✅ tested |
| SwiftUI wrapper `KartoMap` | ✅ |
| ProMotion (120 Hz), prefetching in driving direction | ✅ |
| Labels v2 (text along curves, SDF glyphs, custom fonts) | ❌ |
| Raster tiles, terrain, globe, antimeridian | ❌ |

## Requirements

- iOS 17+ (macOS 14+ for `KartoCore` tests)
- Swift 5.9+, Xcode with the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`)

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/tobymarks/KartoKit.git", branch: "main")
```

Products:

- **`KartoCore`**: platform independent (tile math, camera, MVT/PMTiles decoding, styles,
  tessellation, navigation logic). Builds and tests on Linux too.
- **`KartoRender`**: Apple only (Metal renderer, shaders, `MapView`, gestures, SwiftUI wrapper).

## Quick start

```swift
import SwiftUI
import KartoCore
import KartoRender

struct ContentView: View {
    @State private var camera = MapCamera(
        coordinate: Coordinate(latitude: 48.7758, longitude: 9.1829),
        zoom: 15, bearing: 0, pitch: 55)

    var body: some View {
        KartoMap(source: OpenFreeMap.source(),   // free OSM vector tiles, no API key
                 theme: .kartoKit(dark: false),
                 schema: .openMapTiles,
                 camera: $camera)
            .ignoresSafeArea()
    }
}
```

Feeding CoreLocation into the navigation camera:

```swift
func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
    for l in locs {
        mapView.updateLocation(LocationFix(
            coordinate: .init(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude),
            course: l.course >= 0 ? l.course : nil,
            speed: l.speed >= 0 ? l.speed : nil,
            horizontalAccuracy: l.horizontalAccuracy,
            timestamp: l.timestamp.timeIntervalSince1970 - Date().timeIntervalSince1970 + CACurrentMediaTime()))
    }
}
```

If your routing engine already delivers snapped positions, set `isSnapped: true`; KartoKit then
only does smoothing and camera work.

## Tile sources

`TileSource` is a protocol. Included:

- `OpenFreeMap.source()`: free OSM vector tiles, OpenMapTiles schema, worldwide, z0–14, no key
- `XYZTileSource(template:)`: MapTiler, Stadia or your own server
- `PMTilesSource`: local archive or HTTP range requests (e.g. on S3/R2, built with Planetiler)
- `CachedTileSource`: disk LRU cache with offline fallback
- `LazyTileSource`: create synchronously, open asynchronously

`TileSchema.openMapTiles` and `TileSchema.protomaps` (v3 + v4) turn a theme into a `MapStyle`.

## Themes

Everything visible comes from a `MapTheme` value: land, water, land use, road colors per class,
buildings, route colors, labels and the puck. Built-in: `.kartoKit(dark:)`, `.cleanWhite`,
`.nightDrive`.

```swift
var theme = try ThemeTokens.apply(json: tokensData, to: .cleanWhite, dark: false) // designtokens.org JSON
theme.puck = PuckDesign(shape: .image(name: "MyArrow"), size: 40,
                        fill: .transparent, stroke: .transparent, halo: nil)
mapView.setTheme(theme, animated: true)                                 // 425 ms crossfade
```

The layer structure does not depend on the theme, so themes switch without rebuilding tiles and
can be interpolated with `MapStyle.blend`.

## Architecture

```
Sources/
├─ CZlib/          system zlib (gzip for PMTiles/MVT)
├─ KartoCore/      platform independent
│  ├─ Math/        Vec2/3/4, Mat4 (double precision, column-major)
│  ├─ Geo/         Web Mercator, tile IDs, Hilbert IDs, polyline smoothing
│  ├─ Camera/      MapCamera, view projection, tile coverage with LOD
│  ├─ Tiles/       protobuf reader, MVT decoder, PMTiles, tile sources, cache
│  ├─ Style/       MapStyle, MapTheme, design tokens, default styles
│  ├─ Labels/      label candidates and placement
│  ├─ Annotations/ map annotations
│  ├─ Navigation/  NavigationController, RouteSnapper, ManeuverDetector, GPX replay
│  └─ Tessellation/ Earcut, lines, polygons/extrusion, TileMeshBuilder
└─ KartoRender/    Apple only: Shaders.metal, MapRenderer, TileManager, MapView,
                   PuckRenderer, RouteRenderer, LabelRenderer, KartoMap (SwiftUI)
Tests/KartoCoreTests/   77 tests incl. real PMTiles/MVT fixtures and a replayed drive
Demo/                   SwiftUI demo app (XcodeGen project)
```

Per tile, all on background tasks:
`TileSource` → `VectorTileDecoder` → `TileMeshBuilder` (style, Earcut, lines, extrusion) →
`GPUTile` (one `MTLBuffer` per style layer) → `TileManager` cache. Per frame only matrices and
draw calls (typically 30–80).

Three decisions carry the performance:

1. **Tile-local coordinates + double-precision matrices on the CPU.** Vertices are stored as
   floats in tile units (0…4096); the tile→clip matrix is computed in double precision every
   frame. No jitter at zoom 18+, no vertex updates while moving.
2. **One mesh for all zoom levels.** Line widths and extrusion heights are computed in the vertex
   shader from uniforms. Zooming never re-tessellates.
3. **LOD by distance, not by zoom.** At 60° pitch distant areas automatically get coarser tiles,
   which is the difference between ~8 and ~60 tiles per frame in navigation mode.

## Demo app

```
cd Demo
brew install xcodegen && xcodegen generate
open KartoDemo.xcodeproj
```

By default the demo uses OpenFreeMap (no key). Optional: set `MAPTILER_KEY` in
`Demo/ContentView.swift`, or build a regional offline archive with `Demo/kacheln-holen.sh`.
The demo can replay a recorded 53 km drive (`Demo/referenzfahrt.gpx`) through the navigation
camera.

## Tests

```
swift test
```

Runs on macOS and Linux (`zlib1g-dev` required). The tests decode real tiles, build meshes,
check Earcut quality on every building of a z15 tile and replay a recorded drive through the
`NavigationController`.

## Ideas for continuing

1. **Labels v2**: glyph quads along curves, SDF glyphs, custom fonts, fade in/out, POI icons
2. **Roads**: round joins/caps, bridge/tunnel layering, lane arrows
3. **CarPlay**: host `MapView` in the `CPMapTemplate` window, map CarPlay pan/zoom callbacks to
   the camera, share `TileSource` between phone and car renderer
4. **Robustness**: retry strategy, offline regions as PMTiles downloads, memory pressure handling,
   profiling on older devices

## License

KartoKit is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for
third-party components and data:

- Earcut port based on [mapbox/earcut](https://github.com/mapbox/earcut) (ISC)
- Test and demo map data © [OpenStreetMap contributors](https://www.openstreetmap.org/copyright)
  (ODbL), via [Protomaps](https://protomaps.com) and [OpenFreeMap](https://openfreemap.org)
