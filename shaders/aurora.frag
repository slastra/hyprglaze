#version 300 es
precision highp float;

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

// Music (zero in silence / music = false → the calm night).
uniform float iAuroraFlow;      // CPU pace clock, quickens with energy
uniform float iAuroraEnergy;    // slow full-mix envelope
uniform float iAuroraLayers[3]; // band groups: lows, mids, highs

out vec4 fragColor;

// Smooth noise
float hash(float n) { return fract(sin(n) * 43758.5453); }

float noise(float x) {
    float i = floor(x);
    float f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(hash(i), hash(i + 1.0), f);
}

float fbm(float x) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * noise(x);
        x *= 2.0;
        a *= 0.5;
    }
    return v;
}

// SDF to nearest window edge
float windowSDF(vec2 p) {
    float d = 1e6;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0) continue;
        vec2 center = win.xy + win.zw * 0.5;
        vec2 half_size = win.zw * 0.5;
        vec2 q = abs(p - center) - half_size;
        float wd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        d = min(d, wd);
    }
    return d;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.01, 0.01, 0.02);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.85);
    vec3 col = bg;

    float t = iAuroraFlow;

    // Aurora ramp in theme tones: pine depths, foam body, iris ray tips,
    // a whisper of love at the bottom fringe. Never averaged — a real
    // emission gradient, applied additively over a dark sky.
    vec3 deep = (iPaletteSize > 4) ? iPalette[4] : vec3(0.10, 0.35, 0.30);
    vec3 body = (iPaletteSize > 2) ? iPalette[2] : vec3(0.35, 0.80, 0.65);
    vec3 tips = (iPaletteSize > 5) ? iPalette[5] : vec3(0.55, 0.45, 0.85);
    vec3 fringe = (iPaletteSize > 1) ? iPalette[1] : vec3(0.9, 0.4, 0.55);

    // Sparse stars, twinkling far too slowly to flicker; the night the
    // curtains hang in.
    vec2 sc = floor(fc / 4.0);
    float sh = fract(sin(dot(sc, vec2(12.9898, 78.233))) * 43758.5453);
    if (sh > 0.9968) {
        float tw = 0.7 + 0.3 * sin(t * 1.7 + sh * 60.0);
        col += fg * ((sh - 0.9968) / 0.0032) * 0.14 * tw * smoothstep(0.3, 0.75, uv.y);
    }

    // Window proximity — curtains brighten and bend near windows
    float wd = windowSDF(fc);
    float win_influence = exp(-wd * 0.005);

    // Cursor influence — gentle distortion
    float cursor_dist = length(fc - iMouse.xy);
    float cursor_warp = exp(-cursor_dist * 0.003) * 30.0;

    // Three curtain arcs, back to front. Each: a slowly wandering base
    // line across the sky, tall vertical ray striations above it with a
    // crisp lower edge, folded like fabric by a slow domain warp.
    vec3 acc = vec3(0.0);
    for (int layer = 0; layer < 3; layer++) {
        float fl = float(layer);
        float band = min(iAuroraLayers[layer], 1.2);

        // Folded x: fabric folds travel slowly; windows and cursor bend them.
        float xw = uv.x
            + 0.10 * (fbm(uv.y * (1.8 + fl * 0.5) + t * (0.22 + fl * 0.07) + fl * 7.0) - 0.5) * 2.0
            + win_influence * 0.05 * sin(uv.y * 5.0 + t + fl * 2.0)
            + cursor_warp * 0.002 * sin(uv.y * 2.0 + fl);

        // Arc base height: back layers hang higher, all wander slowly.
        float yb = 0.38 + fl * 0.16
            + 0.11 * (fbm(xw * 1.4 + t * 0.12 + fl * 3.1) - 0.5) * 2.0;
        float h = uv.y - yb;

        // Vertical ray striations along the curtain.
        float rays = fbm(xw * (15.0 + fl * 6.0) + fl * 11.0);
        rays = pow(smoothstep(0.28, 0.85, rays), 1.4);

        // Slow luminous waves sweeping along the arc.
        float sweep = 0.4 + 0.6 * (0.5 + 0.5 * sin(xw * 6.0 - t * (0.8 + fl * 0.25) + fl * 2.3));

        // Profile: crisp bottom edge, ray-length fade above. Music energy
        // and this layer's band group stretch the rays taller.
        float raylen = (0.09 + 0.30 * rays) * (1.0 + iAuroraEnergy * 0.6 + band * 0.4);
        float prof = smoothstep(-0.012, 0.012, h) * exp(-max(h, 0.0) / raylen);

        float inten = prof * (0.20 + 0.80 * rays) * sweep
            * (1.0 + win_influence * 0.6) * (1.0 + band * 0.5);

        // Focused window crown: the curtain gathers over the focused window.
        if (iWindow.z > 0.0) {
            vec2 fw_top = vec2(iWindow.x + iWindow.z * 0.5, iWindow.y + iWindow.w);
            float crown = exp(-length(fc - fw_top) * 0.003) * 0.5;
            inten += crown * rays * smoothstep(0.0, 1.0, iTransition) * prof;
        }

        // Emission ramp: pine->foam body by ray strength, iris toward the
        // fading tips, love only in the thin bottom fringe. Rosé Pine's
        // pastels wash gray under additive blending, so the ramp leans on
        // pine's saturation and the whole emission gets a chroma push.
        float ht = clamp(h / max(raylen * 2.0, 1e-3), 0.0, 1.0);
        vec3 cc = mix(mix(deep, body, 0.15 + 0.55 * rays), tips, ht * 0.5);
        cc += fringe * smoothstep(-0.012, 0.008, h) * exp(-max(h, 0.0) / 0.025) * 0.4;
        float lum = dot(cc, vec3(0.299, 0.587, 0.114));
        cc = max(mix(vec3(lum), cc, 1.5), 0.0);

        acc += cc * inten * (1.0 - fl * 0.22);
    }

    // Additive glow over the dark sky — never normalized, never fog.
    col += acc * 0.70;

    // Subtle window outlines
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0) continue;
        vec2 center = win.xy + win.zw * 0.5;
        vec2 half_size = win.zw * 0.5;
        vec2 q = abs(fc - center) - half_size;
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        float edge = 1.0 - smoothstep(0.0, 2.0, abs(d));
        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, 1.0 - smoothstep(0.0, 1.0, iTransition));
        col += (iPaletteSize > 0 ? iPaletteFg : vec3(0.5)) * edge * mix(0.04, 0.12, focus_amt);
    }

    // Soft vignette
    col *= 1.0 - 0.15 * length(uv - 0.5);

    fragColor = vec4(col, 1.0);
}
