#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform vec4 iMouse;   // cursor, GL pixel space (y up)

uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Circle list from amorphous.zig, laid out once per frame: (x, y, r, k).
// Screen units: short edge = 1.0, origin at the center. Two layers of 32:
// four blobs of eight circles each, the first of each eight being the core.
// k is the blob's blend radius.
const int BLOBS_PER_LAYER = 4;
const int BALLS_PER_BLOB = 8;
const int BALLS_PER_LAYER = BLOBS_PER_LAYER * BALLS_PER_BLOB;
uniform vec4 iBalls[64];
uniform vec3 iBlobFront;   // layer colors, chosen in amorphous.zig
uniform vec3 iBlobBack;
uniform float iBlobOpacity;  // front over back: 1 opaque, 0 fully tinted
uniform float iBlobGoo;      // blend radius between blobs of one layer

out vec4 fragColor;

// Signed distance to one layer's liquid, negative inside. A blob is the
// smooth union of its circles (log-sum-exp, which unlike the polynomial
// smooth minimum does not depend on the order of the circles): every joint
// rounds into a fillet about k wide, so the outline has no creases and the
// circles never show. The layer is the smooth union of its blobs with a
// smaller radius, so two blobs that drift together grow a neck, merge, and
// pinch apart again.
//
// The screen is a torus: each blob is measured the shortest way round, so
// one leaving an edge is already coming in the opposite one.
float layerDist(vec2 p, int first, vec2 wrap) {
    float acc = 0.0;
    for (int b = 0; b < BLOBS_PER_LAYER; b++) {
        int at = first + b * BALLS_PER_BLOB;
        vec4 core = iBalls[at];
        float k = core.w;
        vec2 dc = p - core.xy;
        vec2 q = p - round(dc / wrap) * wrap;
        // Too far to matter: beyond the blob's reach plus a few blend radii.
        float far = length(q - core.xy) - core.z * 3.4;
        if (far > iBlobGoo * 8.0) continue;
        float sum = 0.0;
        for (int i = 0; i < BALLS_PER_BLOB; i++) {
            vec4 c = iBalls[at + i];
            sum += exp(-(length(q - c.xy) - c.z) / k);
        }
        float d = -k * log(max(sum, 1e-30));
        acc += exp(-d / iBlobGoo);
    }
    return -iBlobGoo * log(max(acc, 1e-30));
}

// Coverage of one layer at this pixel: the distance is in screen units, so
// the edge is 1.5px wide whatever the blob.
float coverage(float d, float px) {
    return 1.0 - smoothstep(-0.75 * px, 0.75 * px, d);
}

// Rim light. Only the outline is lit: a thin band just inside the edge,
// brighter where the edge faces the cursor, as if the pointer were a small
// lamp held over the surface. The outline normal is the distance gradient,
// taken from screen-space derivatives, so it costs nothing extra; and
// since only pixels within a few px of the edge are touched, the interior
// stays flat.
float rim(float d, vec2 to_light, float px) {
    vec2 g = vec2(dFdx(d), dFdy(d));
    float gl = length(g);
    if (gl < 1e-9) return 0.0;
    vec2 n = g / gl;                    // points outward
    float facing = max(dot(n, to_light), 0.0);
    float band = smoothstep(-4.5 * px, -1.0 * px, d) * coverage(d, px);
    return band * facing * facing;
}

void main() {
    vec2 res = iResolution.xy;
    float unit = min(res.x, res.y);
    vec2 p = (gl_FragCoord.xy - res * 0.5) / unit;
    vec2 wrap = res / unit;   // screen size in blob units

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.07, 0.06, 0.1);

    vec3 front = iBlobFront;
    vec3 back = iBlobBack;

    // Light direction from this pixel toward the cursor, with a falloff so
    // the lamp only reaches a couple of screen-heights out.
    vec2 light_px = (iMouse.xy - res * 0.5) / unit;
    vec2 to_light = light_px - p;
    float light_dist = length(to_light);
    to_light /= max(light_dist, 1e-4);
    float lamp = exp(-light_dist * 1.6);

    // Flat silhouettes, one color per layer, back layer painted first.
    // Layers are composited, not summed, so their blobs pass over each
    // other without merging.
    float px = 1.0 / unit;
    float db = layerDist(p, BALLS_PER_LAYER, wrap);
    float df = layerDist(p, 0, wrap);
    float cb = coverage(db, px);
    float cf = coverage(df, px);
    // Soft shadow of the front layer, cast a little down and right onto
    // whatever is behind it. One more distance, at the offset point.
    float ds = layerDist(p - vec2(-0.012, 0.014), 0, wrap);
    float shadow = smoothstep(0.016, -0.014, ds) * (1.0 - cf);

    // Translucent overlap: where the front layer passes over the back one
    // the front reads as tinted glass, taking on some of the back color.
    vec3 front_here = mix(front, mix(front, back, 1.0 - iBlobOpacity), cb);
    vec3 col = bg;
    col = mix(col, back, cb);
    col = mix(col, col * 0.82, shadow);
    col = mix(col, front_here, cf);
    // Rim light on both outlines, tinted toward the theme foreground.
    col = mix(col, iPaletteFg, rim(db, to_light, px) * lamp * 0.35 * cb * (1.0 - cf));
    col = mix(col, iPaletteFg, rim(df, to_light, px) * lamp * 0.35 * cf);

    fragColor = vec4(col, 1.0);
}
