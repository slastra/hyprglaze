#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iVoltTime;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Bolt geometry from voltaic.zig: midpoint-displaced segments regenerated
// each re-strike tick. iSegs holds (x1, y1, x2, y2); brightness is packed
// four-per-vec4 in iSegB and unpacked with [i>>2][i&3]. Branch segments
// arrive dimmer and taper to nothing, so width can derive from brightness.
uniform vec4 iSegs[240];
uniform vec4 iSegB[60];
uniform int iSegCount;
uniform float iBeat;
uniform float iBass;
uniform float iTreble;

out vec4 fragColor;

// ---------- noise ----------

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// ---------- palette ----------

// Electric blue/cyan pulled from the theme's bright accents; near-white core.
vec3 glowColor() {
    if (iPaletteSize > 12) return mix(iPalette[12], iPalette[14], 0.4);
    return vec3(0.30, 0.55, 1.0);
}

vec3 coreColor() {
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    return mix(fg, vec3(1.0), 0.6);
}

// ---------- focus rim ----------

float windowSdf(vec2 p, vec4 win) {
    vec2 cen = win.xy + win.zw * 0.5;
    vec2 q = abs(p - cen) - win.zw * 0.5;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Whisper of steady glow on the focused frame — the crawling arcs (CPU-side
// bolt segments hugging the border) carry the show; this just keeps focus
// readable in the gaps between crawls.
float focusRim(vec2 fc, vec4 win, float focus_amt) {
    if (focus_amt < 0.01 || win.z < 1.0) return 0.0;
    float bd = abs(windowSdf(fc, win));
    if (bd > 70.0) return 0.0;
    return exp(-bd * 0.07) * 0.12 * focus_amt * (0.8 + iTreble * 0.5);
}

// ---------- main ----------

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.015, 0.018, 0.030);
    vec3 gcol = glowColor();
    vec3 ccol = coreColor();

    // Dark bench, slight vignette, faint ambient hum from the bass.
    float vig = 1.0 - 0.35 * length(uv - 0.5);
    vec3 col = bg * (0.85 * vig + iBass * 0.06);

    // Bolt segments. Brightness already carries the CPU-side envelope,
    // flicker, and branch taper. max() instead of += keeps the channel
    // continuous across segment joints (no beading) while branch tips
    // still read against the main channel via their own brightness.
    vec2 light = vec2(0.0);
    for (int i = 0; i < iSegCount && i < 240; i++) {
        vec4 s = iSegs[i];

        // Bounding-box reject covers the halo falloff width.
        vec2 lo = min(s.xy, s.zw) - 110.0;
        vec2 hi = max(s.xy, s.zw) + 110.0;
        if (fc.x < lo.x || fc.x > hi.x || fc.y < lo.y || fc.y > hi.y) continue;

        float b = iSegB[i >> 2][i & 3];
        if (b < 0.004) continue;

        vec2 pa = fc - s.xy;
        vec2 ba = s.zw - s.xy;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
        float d = length(pa - ba * h);

        // Dimmer (branch) segments are also thinner; bass fattens everything.
        float w = mix(0.55, 1.0, min(b, 1.0)) * (1.0 + iBass * 0.35);
        light.x = max(light.x, exp(-d * 0.045 / w) * b);
        light.y = max(light.y, exp(-d * d * 0.30 / (w * w)) * b);
    }

    // Steady rim on the focused window (cross-fading through transitions).
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, 1.0 - smoothstep(0.0, 1.0, iTransition));
        light.x += focusRim(fc, iWindows[i], focus_amt);
    }

    col += gcol * light.x * 0.85;
    col += ccol * min(light.y, 1.6);

    // Beat: the whole bench flashes faintly, like a capacitor letting go.
    col += gcol * iBeat * 0.045;

    // Fine static grain so the dark field never looks flat.
    col += (hash21(fc + fract(iVoltTime) * 100.0) - 0.5) * 0.012;

    fragColor = vec4(col, 1.0);
}
