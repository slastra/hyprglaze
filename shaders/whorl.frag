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
uniform float iWhorlAccent;
uniform float iWhorlAccent2;

out vec4 fragColor;

const float TAU = 6.28318530718;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

vec3 bgColor() {
    return iPaletteSize > 0 ? iPaletteBg : vec3(0.05, 0.05, 0.08);
}

// The two phosphor colors. Each picks a palette slot; anything out of
// range falls back to the theme foreground, and with no palette at all
// this is a green/amber two-gun tube.
vec3 phosphor(float slot, vec3 fallback) {
    if (iPaletteSize > 0) {
        int idx = int(slot);
        if (idx >= 0 && idx < iPaletteSize) return iPalette[idx];
        return iPaletteFg;
    }
    return fallback;
}

// Phosphor persistence for one cell, split by color gun. In a developed
// wave train every cell flips every tick, so lighting every flip floods
// the field solid. Instead only two marker crossings per ring cycle glow:
// entering state 0 fires gun x (accent), entering the opposite state
// fires gun y (accent2) — each spiral renders as two thin interleaved
// arms over a mostly-background field. The state itself ages the trace
// (0 = at the crossing, 1 = one tick past), stacking with persistence
// so packet edges and frozen zones stay dark. Persistence lerps from its
// pre-tick value (A) to its current one (B) so nothing snaps at ticks.
vec2 cellTrace(ivec2 p) {
    p = clamp(p, ivec2(0), ivec2(iGridDim) - 1);
    vec4 d = texelFetch(iGrid, p, 0);
    if (d.r > 0.999) return vec2(0.0);
    float fresh = mix(d.a, d.b, iTickFrac);
    float glow = pow(fresh, 1.7);
    float sc = floor(d.r * 255.0 + 0.5);
    float opp = floor(iStates * 0.5);
    if (sc < 2.0) return vec2(glow * (1.0 - sc * 0.5), 0.0);
    if (sc >= opp && sc < opp + 2.0) return vec2(0.0, glow * (1.0 - (sc - opp) * 0.5));
    return vec2(0.0);
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 g = fc / iCellPx;
    ivec2 ci = ivec2(floor(g));
    vec2 f = fract(g);

    // Flat two-color phosphor: the whole field is the surface background
    // (walls included — windows sit on the same tone), and only the traces
    // light up. Crisp cells, thin shadow-mask seams between blocks.
    vec3 gunA = phosphor(iWhorlAccent, vec3(0.55, 1.0, 0.65));
    vec3 gunB = phosphor(iWhorlAccent2, vec3(1.0, 0.75, 0.35));
    vec2 tr = cellTrace(ci);
    vec3 col = bgColor();
    vec2 seam = smoothstep(0.0, 0.10, f) * smoothstep(1.0, 0.90, f);
    float mask = 0.86 + 0.14 * seam.x * seam.y;
    col += (gunA * tr.x + gunB * tr.y) * 0.85 * mask;
    col *= mix(1.0, mask, 0.35);

    // Phosphor bloom: the traces leak a round halo over neighboring cells,
    // additive on top of the crisp base so edges stay sharp underneath.
    vec2 bloom = vec2(0.0);
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            ivec2 p = ci + ivec2(dx, dy);
            vec2 d = g - (vec2(p) + 0.5);
            bloom += cellTrace(p) * exp(-dot(d, d) * 2.2);
        }
    }
    col += (gunA * bloom.x + gunB * bloom.y) * 0.14;

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
