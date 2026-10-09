#include <metal_stdlib>
using namespace metal;

// Layouts müssen exakt zu KartoCore.Mesh.swift und Renderer.swift passen.

struct FillVertexIn {
    float2 position [[attribute(0)]];
};

struct LineVertexIn {
    float2 position [[attribute(0)]];
    float2 normal   [[attribute(1)]];
};

struct ExtrusionVertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float  ton      [[attribute(2)]];
};

struct DrawUniforms {
    float4x4 mvp;        // Tile-lokal → Clip
    float4   color;      // RGBA (premultiplied wird im Fragment erzeugt)
    float4   light;      // xyz: Lichtrichtung (Tile-Raum, z↑)
                         // w:   shaderabhaengig - Linien: halbe Breite in Tile-Einheiten,
                         //      Gebaeude: Tonstreuung je Gebaeude. Flaechen lesen ihn nicht.
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

// MARK: - Flächen

vertex VertexOut fill_vertex(FillVertexIn in [[stage_in]],
                             constant DrawUniforms &u [[buffer(1)]]) {
    VertexOut out;
    out.position = u.mvp * float4(in.position, 0.0, 1.0);
    out.color = u.color;
    return out;
}

// MARK: - Linien
// Die Extrusion entlang der Normale passiert hier – ein Mesh gilt für alle Zoomstufen,
// die Breite bleibt in Pixeln konstant (halfWidth wird pro Frame in Tile-Einheiten
// umgerechnet). Miter-Länge steckt bereits in der Normale.

vertex VertexOut line_vertex(LineVertexIn in [[stage_in]],
                             constant DrawUniforms &u [[buffer(1)]]) {
    VertexOut out;
    float2 p = in.position + in.normal * u.light.w;
    out.position = u.mvp * float4(p, 0.0, 1.0);
    out.color = u.color;
    return out;
}

// MARK: - Extrusion (Gebäude)
// Lambert + Ambient, Flat-Shading über per-Wand-Normalen. Leichte Höhenabdunklung am
// Boden ("ambient occlusion light") gibt den Blöcken Plastizität ohne Extra-Pass.

vertex VertexOut extrusion_vertex(ExtrusionVertexIn in [[stage_in]],
                                  constant DrawUniforms &u [[buffer(1)]]) {
    VertexOut out;
    out.position = u.mvp * float4(in.position, 1.0);
    float3 n = normalize(in.normal);
    float3 l = normalize(u.light.xyz);
    float diffuse = max(dot(n, l), 0.0);
    float shade = 0.62 + 0.38 * diffuse;
    // Dächer minimal heller als Wände, Wände zum Boden hin leicht dunkler
    if (n.z > 0.9) { shade += 0.06; }
    // Streuung je Gebäude: Ohne sie teilen sich Nachbarn mit gleicher
    // Wandausrichtung exakt denselben Ton und eine Siedlung wird zur
    // Fläche. Die Stärke kommt aus dem Theme (light.w) — sie muss dunklen
    // Themes mehr Anteil geben, weil derselbe Prozentsatz auf einer
    // dunklen Farbe kaum Helligkeitsstufen ergibt.
    shade *= 1.0 + in.ton * u.light.w;
    out.color = float4(u.color.rgb * shade, u.color.a);
    return out;
}

// MARK: - Fragment

fragment float4 color_fragment(VertexOut in [[stage_in]]) {
    // Premultiplied Alpha für korrektes Blending halbtransparenter Layer.
    return float4(in.color.rgb * in.color.a, in.color.a);
}

// MARK: - Halo unter dem Puck
// Ein weicher Schein statt einer harten Scheibe. Die Modellkoordinate der
// Einheitsscheibe ist zugleich der Abstand zur Mitte — das Fragment braucht
// also nichts ausser sich selbst, keine Textur und kein zweites Mesh.
//
// Der Abfall ist quadratisch: linear sieht aus wie ein Kegel, quadratisch
// wie Licht. Am Rand wird er exakt null, damit keine sichtbare Kante bleibt.

struct HaloOut {
    float4 position [[position]];
    float2 lokal;
    float4 farbe;
};

vertex HaloOut halo_vertex(FillVertexIn in [[stage_in]],
                           constant DrawUniforms &u [[buffer(1)]]) {
    HaloOut out;
    out.position = u.mvp * float4(in.position, 0.0, 1.0);
    out.lokal = in.position;
    // Die Farbe reist als Varying mit, sie wird NICHT im Fragment aus den
    // Uniforms gelesen. Genau daran ist der erste Anlauf gescheitert:
    // setVertexBytes bindet nur die Vertex-Argumenttabelle, die des
    // Fragments blieb leer. Das Fragment las, was gerade dort stand — der
    // Schein kam mal lila wie die Route, mal rot wie der Pfeilrand.
    out.farbe = u.color;
    return out;
}

fragment float4 halo_fragment(HaloOut in [[stage_in]]) {
    float r = min(length(in.lokal), 1.0);
    float k = 1.0 - r;
    float a = in.farbe.a * k * k;
    return float4(in.farbe.rgb * a, a);
}

// MARK: - Route (Fortschritt + Abschnittsfarben im Shader, Mesh bleibt unverändert)

struct RouteVertexIn {
    float2 position [[attribute(0)]];
    float2 normal   [[attribute(1)]];
    float  distance [[attribute(2)]];   // Meter entlang der Route
};

struct RouteSegment {
    float from;
    float to;
    // Laenge eines Streifenpaars in Metern; 0 = einfarbig.
    float hatch;
    float _pad;
    float4 color;
};

struct RouteUniforms {
    float4x4 mvp;
    float4   color;          // aktiver Teil
    float4   drivenColor;    // gefahrener Teil
    float4   hatchColor;     // zweite Farbe der Sperrschraffur
    float    halfWidth;      // lokale Einheiten
    float    driven;         // Meter
    uint     segmentCount;   // 0 = keine Abschnittsfarben (Casing)
    float    _pad;
    RouteSegment segments[16];
};

struct RouteOut {
    float4 position [[position]];
    float  distance;
};

vertex RouteOut route_vertex(RouteVertexIn in [[stage_in]],
                             constant RouteUniforms &u [[buffer(1)]]) {
    RouteOut out;
    float2 p = in.position + in.normal * u.halfWidth;
    out.position = u.mvp * float4(p, 0.0, 1.0);
    out.distance = in.distance;
    return out;
}

// Farbe pro Fragment nach interpolierter Distanz → scharfe Kanten an Abschnitts- und
// Fortschrittsgrenzen, unabhängig davon, wie weit die Routenpunkte auseinanderliegen.
fragment float4 route_fragment(RouteOut in [[stage_in]],
                               constant RouteUniforms &u [[buffer(1)]]) {
    float4 c = u.color;
    if (in.distance < u.driven) {
        c = u.drivenColor;
    } else {
        for (uint i = 0; i < u.segmentCount; i++) {
            if (in.distance >= u.segments[i].from && in.distance <= u.segments[i].to) {
                c = u.segments[i].color;
                // Sperrung: Streifen quer zur Fahrtrichtung, aufgehaengt
                // an den Metern entlang der Route - so haften sie an der
                // Strasse und wandern beim Schieben nicht mit.
                float h = u.segments[i].hatch;
                if (h > 0.0 && fract(in.distance / h) < 0.5) {
                    c = u.hatchColor;
                }
                break;
            }
        }
    }
    return float4(c.rgb * c.a, c.a);
}

// MARK: - Sprites (Bildschirm-Quads mit Textur: Marker, Labels, Bild-Puck)

struct SpriteVertexIn {
    float2 position [[attribute(0)]];   // Bildschirm-Punkte
    float2 uv       [[attribute(1)]];
    float4 color    [[attribute(2)]];   // Multiplikator (Alpha = Deckkraft)
};

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

struct SpriteUniforms {
    float4x4 screenToClip;
};

vertex SpriteOut sprite_vertex(SpriteVertexIn in [[stage_in]],
                               constant SpriteUniforms &u [[buffer(1)]]) {
    SpriteOut out;
    out.position = u.screenToClip * float4(in.position, 0.0, 1.0);
    out.uv = in.uv;
    out.color = in.color;
    return out;
}

fragment float4 sprite_fragment(SpriteOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                sampler smp [[sampler(0)]]) {
    // Atlas ist premultiplied gespeichert; Farbmultiplikator ebenfalls premultiplied anwenden.
    float4 t = tex.sample(smp, in.uv);
    return float4(t.rgb * in.color.rgb * in.color.a, t.a * in.color.a);
}

// Farbige Quads ohne Textur (Schilder-Hintergrund, Text-Halo-Boxen, Vektor-Puck im Screen-Space)
fragment float4 sprite_solid_fragment(SpriteOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}
