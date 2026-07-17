#version 300 es
precision highp float;

// weft — windows shining through a diffraction weave. Three slightly
// detuned near-vertical stripe lattices (a nod to this effect's origin:
// a broken hash striping windowglow's film grain) interfere into large
// drifting moiré fringes. The fringes are lit by window halos and curve
// around each window through a halo-weighted radial phase term — where
// two halos overlap, their phase terms collide into beat patterns
// between the windows. Everything rests at plain background away from
// the light.

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

uniform float iWeftDrift;  // lattice phase drift (CPU clock)
uniform float iWeftGrainT; // grain reseed clock (treble quickens)
uniform float iWeftEnergy; // slow full-mix envelope
uniform float iWeftBass;   // smoothed low end
uniform float iWeftSeat;   // kick re-seat phase for lattice 0
uniform float iWeftScale;  // base stripe wavelength (px)
uniform float iWeftReach;  // halo radius multiplier
uniform float iWeftGrain;  // grain amplitude

out vec4 fragColor;

const float TAU = 6.28318530718;

// Integer-lattice white noise (pcg3d-style, windowglow's grainHash).
float grainHash(vec2 cell, float seed) {
    uvec3 v = uvec3(uvec2(ivec2(cell) + 8192), uint(seed));
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z;
    v.y += v.z * v.x;
    v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z;
    return float(v.x & 0x00ffffffu) / 16777216.0;
}

float sdRoundBox(vec2 p, vec2 center, vec2 half_size, float radius) {
    vec2 d = abs(p - center) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void main() {
    vec2 fc = gl_FragCoord.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.1, 0.09, 0.14);
    vec3 accent = (iPaletteSize > 5) ? iPalette[5] : vec3(0.77, 0.65, 0.91);

    // ---- window halos: the light behind the weave ----
    // Each window lights the grating around itself; the focused window
    // shines brighter and farther. A halo-weighted radial phase makes
    // fringes curve around their window — overlapping halos interfere.
    float halo = 0.0;
    float phase_w = 0.0;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0 || win.w < 1.0) continue;
        vec2 center = win.xy + win.zw * 0.5;

        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, 1.0 - smoothstep(0.0, 1.0, iTransition));

        float d = sdRoundBox(fc, center, win.zw * 0.5, 12.0);
        float radius = (90.0 + focus_amt * 70.0) * iWeftReach
            * (1.0 + min(iWeftEnergy, 1.0) * 0.5);
        float g = exp(-max(d, 0.0) / radius);
        halo += g * (0.55 + focus_amt * 0.45);
        // Curvature, not domination: strong enough to bend the weave
        // around the window and beat against neighbors, weak enough
        // that the stripe lattices stay legible as a weave.
        phase_w += g * length(fc - center) / iWeftScale * 0.9;
    }
    // Bias-subtract so the far field truly rests at plain background
    // instead of carrying a faint everywhere-fringe.
    halo = min(max(halo - 0.06, 0.0) * 1.06, 1.4);

    // ---- the weave: quantized, detuned stripe lattices ----
    // Bass chunks the sampling cell (1 -> 3px); the quantization is what
    // keeps the fringes crisp and digital rather than smooth waves.
    float cell = 1.0 + floor(min(iWeftBass, 1.2) * 1.8);
    vec2 p = floor(fc / cell) * cell;

    float f = 0.0;
    for (int k = 0; k < 3; k++) {
        float fk = float(k);
        float lam = iWeftScale * (1.0 + fk * 0.023);
        float ang = -0.12 + 0.12 * fk; // near-vertical, slightly fanned
        vec2 dir = vec2(cos(ang), sin(ang));
        float ph = iWeftDrift * (0.7 + 0.35 * fk) + (k == 0 ? iWeftSeat : 0.0);
        f += cos((dot(p, dir) / lam) * TAU + ph + phase_w);
    }
    // Sharpened so bright fringes are narrow threads with dark warp between.
    float fringe = pow(clamp(f / 3.0 * 0.5 + 0.5, 0.0, 1.0), 3.0);

    // ---- grain: the weave's living texture ----
    float seed = floor(iWeftGrainT);
    float g = grainHash(floor(fc / cell), seed) - 0.5;

    // Deep stipple: the threads are MADE of grain — bright fringes break
    // into dancing pointillist dots rather than smooth lines.
    float inten = fringe * halo * max(1.0 + g * iWeftGrain * 1.2, 0.0);
    vec3 col = bg + accent * inten * 0.55 / (1.0 + 0.4 * inten);

    // Additive field grain (multiplicative noise dies below one 8-bit
    // step on a dark surface), so even the plain background is stock.
    col += g * iWeftGrain * 0.022;

    fragColor = vec4(col, 1.0);
}
