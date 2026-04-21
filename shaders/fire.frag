#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform float iPrevAlpha;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Per-window velocity (pixels/sec), for wake-driven warping.
uniform vec2 iWindowVel[32];
// Asymmetric motion fade — 1 = stationary (full flame), 0 = moving (hidden).
// Fast attack, slow release; computed CPU-side.
uniform float iWindowFade[32];
// Latched motion direction (unit vector). Stable across the full fade-in so
// the directional wipe doesn't glitch when the velocity filter drops below
// its own activity threshold.
uniform vec2 iWindowDir[32];

out vec4 fragColor;

// ---------- noise ----------

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p *= 2.0;
        a *= 0.5;
    }
    return v;
}

// ---------- heat ramps ----------

// Hardcoded fallback when no palette is loaded.
vec3 heatRamp(float h) {
    h = clamp(h, 0.0, 1.0);
    const vec3 black = vec3(0.02, 0.01, 0.0);
    const vec3 deep  = vec3(0.45, 0.03, 0.02);
    const vec3 red   = vec3(0.95, 0.18, 0.03);
    const vec3 org   = vec3(1.00, 0.55, 0.08);
    const vec3 yel   = vec3(1.00, 0.92, 0.35);
    const vec3 wht   = vec3(1.00, 0.98, 0.88);
    if (h < 0.20) return mix(black, deep, h / 0.20);
    if (h < 0.40) return mix(deep,  red, (h - 0.20) / 0.20);
    if (h < 0.65) return mix(red,   org, (h - 0.40) / 0.25);
    if (h < 0.85) return mix(org,   yel, (h - 0.65) / 0.20);
    return                mix(yel,  wht, (h - 0.85) / 0.15);
}

// Palette-driven ramp: the fire takes on the theme's colors.
// Gogh/ANSI: 1=red, 3=yellow, 9=bright red, 11=bright yellow.
vec3 paletteHeat(float h) {
    if (iPaletteSize < 4) return heatRamp(h);

    vec3 c0 = iPaletteBg;
    vec3 c1 = iPalette[1];
    vec3 c2 = (iPaletteSize > 9)  ? iPalette[9]  : c1 * 1.25;
    vec3 c3 = (iPaletteSize > 3)  ? iPalette[3]  : c2;
    vec3 c4 = (iPaletteSize > 11) ? iPalette[11] : c3 * 1.15;
    vec3 c5 = mix(iPaletteFg, vec3(1.0), 0.55);

    h = clamp(h, 0.0, 1.0);
    if (h < 0.20) return mix(c0, c1, h / 0.20);
    if (h < 0.45) return mix(c1, c2, (h - 0.20) / 0.25);
    if (h < 0.65) return mix(c2, c3, (h - 0.45) / 0.20);
    if (h < 0.85) return mix(c3, c4, (h - 0.65) / 0.20);
    return                mix(c4, c5, (h - 0.85) / 0.15);
}

// ---------- wind field ----------

// Signed distance to a window's interior; negative inside, positive outside.
float windowSdf(vec2 p, vec4 win) {
    vec2 cen = win.xy + win.zw * 0.5;
    vec2 q = abs(p - cen) - win.zw * 0.5;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Exponential wake falloff — 1 at the window edge, ~0.25 at 400px away.
float wakeStrength(float sd) {
    return exp(-max(sd, 0.0) * 0.0035);
}

// Ambient wind: each moving window drags a pocket of air with it.
vec2 windAt(vec2 p) {
    vec2 w = vec2(0.0);
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0) continue;
        w += iWindowVel[i] * (wakeStrength(windowSdf(p, win)) * 0.8);
    }
    return w;
}

// ---------- main ----------

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;
    float t = iTime;

    // Background from theme, with a faint warm floor glow.
    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02, 0.012, 0.008);
    vec3 floor_tint = (iPaletteSize > 1) ? iPalette[1] * 0.55 : vec3(0.35, 0.12, 0.03);
    float floor_glow = smoothstep(0.0, 0.25, 1.0 - uv.y) * 0.08;
    vec3 col = bg + floor_tint * floor_glow;

    vec2 wind = windAt(fc);

    float heat = 0.0;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0 || win.w < 1.0) continue;

        // Cheap early-out — if this window's flame is fully faded, skip fbm.
        float fade = iWindowFade[i];
        if (fade < 0.001) continue;

        float x0 = win.x;
        float x1 = win.x + win.z;
        float y_top = win.y + win.w;
        float above = fc.y - y_top;
        if (above < -30.0) continue; // small bleed below so embers sit on edge

        // Focus amount — matched by index so rapid motion doesn't flip focus
        // (smoothed iWindow.xy lags raw positions mid-drag).
        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iPrevAlpha));

        // Focused windows burn taller.
        float flame_height = mix(160.0, 320.0, focus_amt);

        // Attenuate this window's own wake so its own flame warps only as
        // subtly as a distant neighbor does (~400px-wake strength ≈ 0.25× self).
        float f_self = wakeStrength(windowSdf(fc, win));
        vec2 flame_wind = wind - iWindowVel[i] * (f_self * 0.6); // 0.8 * (1 - 0.25)

        // Normalized vertical position and whip curve (tip sways more).
        float yn = clamp(above / flame_height, 0.0, 1.2);
        float yn_curve = pow(yn, 1.4);

        // Lean: soft-saturate wind, then scale by the whip curve so the shape
        // is identical at every wind magnitude (just scaled).
        const float lean_max = 180.0;
        const float lean_k   = 400.0;
        float lean_x =  lean_max * tanh(flame_wind.x / lean_k) * yn_curve;
        float lean_y = -lean_max * 0.45 * tanh(flame_wind.y / lean_k) * yn_curve;

        // Horizontal position within the window span, shifted by lean.
        float shifted_x = fc.x - lean_x;
        float along = clamp((shifted_x - x0) / max(win.z, 1.0), 0.0, 1.0);

        // Mask bleed grows with lean so dramatic sways don't get clipped.
        float bleed = 80.0 + abs(lean_x) * 1.2;
        float edge_mask = smoothstep(-bleed, 20.0, shifted_x - x0) *
                          smoothstep(-bleed, 20.0, x1 - shifted_x);

        // Noise advection: wind smears the pattern sideways so the flame
        // streaks with side motion rather than sliding rigidly.
        vec2 np = vec2(
            (fc.x - win.x - lean_x) * 0.012 + flame_wind.x * 0.00018 * yn_curve,
            (fc.y + lean_y)         * 0.006 - t * 1.4 + flame_wind.y * 0.00005 * yn_curve
        );
        float n = mix(fbm(np), fbm(np * 2.5 + vec2(3.1, -t * 0.6)), 0.4);

        // Horizontal taper — column pinches toward the tip.
        float taper_w    = 1.0 - yn * 0.55;
        float center_dst = abs(along - 0.5) * 2.0;
        float horiz      = smoothstep(taper_w, taper_w * 0.55, center_dst);

        // Vertical profile — soft fade-in at the window edge, taper at tip.
        float vert = smoothstep(0.0, 0.08, yn) * (1.0 - smoothstep(0.55, 1.05, yn));

        // Flicker — noise threshold rises with height so tips break into tongues.
        float threshold = mix(0.28, 0.72, yn);
        float flame     = smoothstep(threshold, threshold + 0.18, n);

        // Base is hotter than the tip.
        float core_boost = mix(1.3, 0.55, yn);

        float contrib = flame * horiz * vert * edge_mask * core_boost * fade;

        // Directional wipe: flame dissipates from the trailing edge first as
        // the window outruns it. Uses the CPU-latched wipe axis so there's no
        // pop when velocity drops below the filter's activity threshold.
        if (fade < 0.999) {
            float extent = max(win.z, flame_height) + 60.0;
            vec2  center = win.xy + win.zw * 0.5 + vec2(0.0, flame_height * 0.3);
            float u      = clamp(dot(fc - center, iWindowDir[i]) / extent + 0.5, 0.0, 1.0);
            float wipe_p = 1.0 - fade;
            contrib *= smoothstep(wipe_p, wipe_p + 0.25, u);
        }

        heat += contrib;
    }

    heat = clamp(heat, 0.0, 1.4);
    vec3 fire_col = paletteHeat(heat);

    // Blend fire over background — cold areas stay dark.
    col = mix(col, fire_col, smoothstep(0.05, 0.45, heat));
    // Additive bloom on the hottest parts.
    col += fire_col * smoothstep(0.55, 1.2, heat) * 0.35;

    // Subtle vignette.
    col *= 1.0 - 0.22 * length(uv - vec2(0.5, 0.55));

    fragColor = vec4(col, 1.0);
}
