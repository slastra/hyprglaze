#version 300 es
precision highp float;

// whorl — cyclic cellular automaton, rendered from the CPU grid in iGrid.
// R = state, G = previous state, B = freshness (wavefront glow), A = wall.
// The CA is chunky and discrete; everything smooth here is manufactured:
// bilinear blending of per-cell colors, a temporal crossfade between ticks
// (iTickFrac), and freshness-driven glow so traveling fronts burn brighter
// than settled domains.

uniform vec3 iResolution;
uniform vec4 iMouse;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;
uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

uniform sampler2D iGrid;
uniform vec2 iGridDim;
uniform float iCellPx;
uniform float iStates;
uniform float iTickFrac;
uniform float iWhorlTime;

out vec4 fragColor;

const float TAU = 6.28318530718;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Hue around the state ring. Terminal palettes aren't stored in hue order,
// but the ANSI slots are known — red(1) yellow(3) green(2) cyan(6) blue(4)
// magenta(5) walks a hue circle in the theme's own tones. Fallback is an
// iridescent wheel.
vec3 ringColor(float t) {
    if (iPaletteSize >= 8) {
        int ring[6] = int[6](1, 3, 2, 6, 4, 5);
        float f = t * 6.0;
        int i0 = int(f) % 6;
        int i1 = (i0 + 1) % 6;
        return mix(iPalette[ring[i0]], iPalette[ring[i1]], fract(f));
    }
    return 0.5 + 0.5 * cos(TAU * (t + vec3(0.0, 0.33, 0.67)));
}

vec3 bgColor() {
    return iPaletteSize > 0 ? iPaletteBg : vec3(0.05, 0.05, 0.08);
}

// A wave train carries consecutive states, so a sawtooth luminance ramp
// around the ring gives every wave a dark tail and a bright head — that
// gradient is what makes spiral arms read as rotating. The body of the
// effect stays in the surface background color (embossed relief); only a
// whisper of the theme's hue ring keeps the arms traceable.
vec3 stateColor(float s) {
    float t = fract((s + 0.5) / iStates);
    float ramp = pow(t, 2.2);
    vec3 col = bgColor() * (0.66 + 1.40 * ramp);
    return mix(col, ringColor(t) * (0.30 + 0.65 * ramp), 0.14);
}

// One cell resolved to a display color. rgb = lit color, a = wallness.
// Motion smoothness comes from here, not from spatial blur: each cell
// crossfades linearly from its pre-tick color (G) to its current one (R),
// and the wavefront glow decays continuously between ticks.
vec4 cellColor(ivec2 p) {
    p = clamp(p, ivec2(0), ivec2(iGridDim) - 1);
    vec4 d = texelFetch(iGrid, p, 0);
    if (d.a > 0.5) return vec4(0.0, 0.0, 0.0, 1.0);

    float sc = floor(d.r * 255.0 + 0.5);
    float sp = floor(d.g * 255.0 + 0.5);
    vec3 col = mix(stateColor(sp), stateColor(sc), iTickFrac);

    // Anti-flicker: glow eases IN across the tick on a flip (never pops),
    // and between flips it decays at exactly the CPU rate (20/255 per tick,
    // keep in sync with fresh_decay in whorl.zig) so there is no luminance
    // discontinuity at tick boundaries.
    float fresh = (sc != sp) ? d.b * iTickFrac
                             : max(d.b - 0.078 * iTickFrac, 0.0);
    return vec4(col * (1.0 + 0.5 * fresh * fresh), 0.0);
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 g = fc / iCellPx;
    ivec2 ci = ivec2(floor(g));
    vec2 f = fract(g);

    // Crisp cells — one phosphor block each, no spatial blending. Thin
    // seams between blocks read as the CRT's shadow-mask structure.
    vec4 s = cellColor(ci);
    vec3 col = mix(s.rgb, bgColor(), s.a);
    vec2 seam = smoothstep(0.0, 0.10, f) * smoothstep(1.0, 0.90, f);
    col *= 0.74 + 0.26 * seam.x * seam.y;

    // Phosphor bloom: bright cells leak a round halo over their neighbors,
    // additive on top of the crisp base so edges stay sharp underneath.
    vec3 bloom = vec3(0.0);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            ivec2 p = ci + ivec2(dx, dy);
            vec4 nb = cellColor(p);
            vec2 d = g - (vec2(p) + 0.5);
            bloom += nb.rgb * (1.0 - nb.a) * exp(-dot(d, d) * 2.2);
        }
    }
    col += bloom * 0.16;

    // Scanlines and a gentle aperture-grille mask. Deliberately no barrel
    // distortion — walls must stay aligned with real window rects.
    col *= 0.92 + 0.08 * sin(fc.y * TAU / 3.0);
    int m = int(mod(fc.x, 3.0));
    vec3 grille = m == 0 ? vec3(1.03, 0.985, 0.985)
                : m == 1 ? vec3(0.985, 1.03, 0.985)
                         : vec3(0.985, 0.985, 1.03);
    col *= grille;

    // Static dither kills banding in the dim domains and bloom halos.
    // (Time-varying dither reads as full-screen shimmer — keep it frozen.)
    col += (hash21(fc) - 0.5) * 0.008;

    fragColor = vec4(col, 1.0);
}
