#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform vec4 iMouse;   // cursor, GL pixel space (y up)

uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Circle list from amorphous.zig, laid out once per frame: (x, y, r^2, -).
// Screen units: short edge = 1.0, origin at the center. Two layers of 24:
// three blobs of eight circles each.
const int BALLS_PER_LAYER = 24;
uniform vec4 iBalls[48];
uniform vec3 iBlobFront;   // layer colors, chosen in amorphous.zig
uniform vec3 iBlobBack;
uniform float iBlobOpacity;  // front over back: 1 opaque, 0 fully tinted

out vec4 fragColor;

// A metaball field with compact support: each circle contributes
// k * (1 - d^2/S^2)^2 out to S = 2.2 r and nothing beyond, scaled so an
// isolated circle's outline (f = 1) sits at d = r. Circles merge with a
// neck as they approach, which is what liquid does, but a blob on the far
// side of the screen adds nothing, which matters on a torus where nothing
// is ever far away.
const float SUPPORT = 2.2;
const float NORM = 1.0 / ((1.0 - 1.0 / (SUPPORT * SUPPORT)) * (1.0 - 1.0 / (SUPPORT * SUPPORT)));

// The screen is a torus: distance to a circle is the shortest way round,
// so a blob leaving one edge is already coming in the opposite one.
float layerField(vec2 p, int first, vec2 wrap) {
    float f = 0.0;
    for (int i = 0; i < BALLS_PER_LAYER; i++) {
        vec4 b = iBalls[first + i];
        vec2 d = p - b.xy;
        d -= round(d / wrap) * wrap;
        float s2 = b.z * SUPPORT * SUPPORT;
        float q = max(0.0, 1.0 - dot(d, d) / s2);
        f += NORM * q * q;
    }
    return f;
}

// Coverage of one layer at this pixel, anti-aliased in field units:
// fwidth(f) is how much f changes across one pixel here, so the outline is
// always ~1.5px wide whatever the blob.
float coverage(float f) {
    float w = fwidth(f);
    return smoothstep(1.0 - 0.75 * w, 1.0 + 0.75 * w, f);
}

// Rim light. Only the outline is lit: a thin band just inside the edge,
// brighter where the edge faces the cursor, as if the pointer were a small
// lamp held over the surface. The outline normal is the field gradient,
// taken from screen-space derivatives, so it costs nothing extra; and
// since only pixels within a few px of f = 1 are touched, the interior
// stays flat and the sub-circles never print through.
float rim(float f, vec2 to_light) {
    vec2 g = vec2(dFdx(f), dFdy(f));
    float gl = length(g);
    if (gl < 1e-6) return 0.0;
    vec2 n = g / gl;                    // points inward (f grows inward)
    float facing = max(dot(-n, to_light), 0.0);
    // Band: f from 1 to about 1 + 4px worth of field change.
    float w = fwidth(f);
    float band = smoothstep(1.0 + 4.5 * w, 1.0 + 1.0 * w, f) * smoothstep(1.0 - 0.75 * w, 1.0 + 0.75 * w, f);
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
    float fb = layerField(p, BALLS_PER_LAYER, wrap);
    float ff = layerField(p, 0, wrap);
    // Soft shadow of the front layer, cast a little down and right onto
    // whatever is behind it. One more field sum, at the offset point.
    float fs = layerField(p - vec2(-0.012, 0.014), 0, wrap);
    float shadow = smoothstep(0.6, 1.4, fs) * (1.0 - coverage(ff));

    // Translucent overlap: where the front layer passes over the back one
    // the front reads as tinted glass, taking on some of the back color.
    float cb = coverage(fb);
    float cf = coverage(ff);
    vec3 front_here = mix(front, mix(front, back, 1.0 - iBlobOpacity), cb);
    vec3 col = bg;
    col = mix(col, back, cb);
    col = mix(col, col * 0.82, shadow);
    col = mix(col, front_here, cf);
    // Rim light on both outlines, tinted toward the theme foreground.
    col = mix(col, iPaletteFg, rim(fb, to_light) * lamp * 0.35 * cb * (1.0 - cf));
    col = mix(col, iPaletteFg, rim(ff, to_light) * lamp * 0.35 * cf);

    fragColor = vec4(col, 1.0);
}
