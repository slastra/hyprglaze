#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iFableTime;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Story threads from fable.zig. Trail points are packed two per vec4
// (x1, y1, x2, y2), indexed thread*M + k with k=0 at the head.
const int NT = 8;   // max threads   — keep in sync with fable.zig max_threads
const int M  = 24;  // points/thread — keep in sync with fable.zig trail_points
uniform vec4 iFablePts[96];
uniform vec4 iThreadMeta[8];  // (color_idx, half_width, brightness, _)
uniform vec4 iMotes[24];      // (x, y, size*env, color_idx) — size 0 = inactive
uniform vec4 iFlPts[8];       // flourish swash, 2 points per vec4
uniform vec4 iFlMeta;         // (color_idx, env, _, _)
uniform int iThreadCount;
uniform float iBass;
uniform float iMid;
uniform float iTreble;
uniform float iBeat;
uniform float iSwell;

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
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p) {
    return vnoise(p) + 0.5 * vnoise(p * 2.13 + 7.7);
}

// ---------- palette ----------

vec3 paletteColor(int cid) {
    return (iPaletteSize > cid) ? iPalette[cid] : vec3(0.62, 0.68, 0.95);
}

// Ambient accent for the background shimmer and beat swell.
vec3 accentColor() {
    if (iPaletteSize > 12) return mix(iPalette[4], iPalette[12], 0.5);
    return vec3(0.35, 0.40, 0.75);
}

// ---------- geometry ----------

vec2 pt(int i) {
    vec4 v = iFablePts[i >> 1];
    return ((i & 1) == 0) ? v.xy : v.zw;
}

vec2 flpt(int i) {
    vec4 v = iFlPts[i >> 1];
    return ((i & 1) == 0) ? v.xy : v.zw;
}

float segDist(vec2 fc, vec2 a, vec2 b) {
    vec2 pa = fc - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h);
}

// ---------- main ----------

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.012, 0.014, 0.028);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.88);
    vec3 accent = accentColor();

    // Calm parchment-dark backdrop: vignette, a slow accent shimmer like
    // candlelight on a page, and a faint breath from the bass.
    float vig = 1.0 - 0.35 * length(uv - 0.5);
    vec3 col = bg * (0.85 * vig + iBass * 0.05);
    float wash = fbm(uv * 2.2 + vec2(iFableTime * 0.015, -iFableTime * 0.011));
    col += mix(bg, accent, 0.35) * wash * 0.10 * vig;

    // ---- story threads ----
    // Glowing polylines via capsule SDFs: a colored halo plus a bright
    // near-fg core, tapering thick head -> thin tail. Reject box padded to
    // where the widest halo falls below the grain floor (~180 px).
    vec3 thread_light = vec3(0.0);
    for (int t = 0; t < iThreadCount && t < NT; t++) {
        vec4 meta = iThreadMeta[t];
        if (meta.z < 0.01) continue;
        vec3 tc = paletteColor(int(meta.x));
        float glow = 0.0;
        float core = 0.0;
        for (int k = 0; k < M - 1; k++) {
            vec2 a = pt(t * M + k);
            vec2 b = pt(t * M + k + 1);
            vec2 lo = min(a, b) - 100.0;
            vec2 hi = max(a, b) + 100.0;
            if (fc.x < lo.x || fc.x > hi.x || fc.y < lo.y || fc.y > hi.y) continue;
            float d = segDist(fc, a, b);
            float taper = 1.0 - float(k) / float(M);
            // Width thins toward the tail; brightness keeps a floor so the
            // ribbon reads as a full stroke, not a comet with a stub.
            float w = max(meta.y * (0.35 + 0.65 * taper), 0.4);
            float amp = 0.30 + 0.70 * taper;
            // Subtract the falloff's value at the reject-box edge so the
            // glow lands on exactly zero there — no visible square cutoff.
            float cut = exp(-100.0 * 0.30 / w);
            glow = max(glow, (exp(-d * 0.30 / w) - cut) * amp);
            core = max(core, exp(-d * d * 0.5 / (w * w)) * amp);
        }
        thread_light += tc * glow * meta.z * 0.85;
        thread_light += mix(tc, fg, 0.35) * core * meta.z * 1.15;
    }

    // ---- beat flourish: a calligraphic swash curling off one thread ----
    if (iFlMeta.y > 0.01) {
        vec3 flc = mix(paletteColor(int(iFlMeta.x)), fg, 0.35);
        float fglow = 0.0;
        float fcore = 0.0;
        for (int k = 0; k < 15; k++) {
            vec2 a = flpt(k);
            vec2 b = flpt(k + 1);
            vec2 lo = min(a, b) - 60.0;
            vec2 hi = max(a, b) + 60.0;
            if (fc.x < lo.x || fc.x > hi.x || fc.y < lo.y || fc.y > hi.y) continue;
            float d = segDist(fc, a, b);
            // Thin toward the tip of the swash.
            float w = max(1.7 * (1.0 - float(k) / 15.0 * 0.6), 0.5);
            float cut = exp(-60.0 * 0.30 / w);
            fglow = max(fglow, exp(-d * 0.30 / w) - cut);
            fcore = max(fcore, exp(-d * d * 0.5 / (w * w)));
        }
        thread_light += flc * (fglow * 0.9 + fcore * 1.6) * iFlMeta.y;
    }

    // ---- sparkle motes shed on treble ----
    for (int i = 0; i < 24; i++) {
        vec4 m = iMotes[i];
        if (m.z < 0.05) continue;
        vec2 dm = fc - m.xy;
        float r2 = dot(dm, dm);
        float sz = m.z * 2.2;
        if (r2 > sz * sz * 30.0) continue;
        // Bias-subtracted so the gaussian hits zero at the reject radius.
        float dot_env = max(exp(-r2 / (sz * sz * 3.0)) - 4.54e-5, 0.0);
        // Gentle twinkle so sparks feel alive.
        float tw = 0.8 + 0.2 * sin(iFableTime * 9.0 + float(i) * 2.7);
        thread_light += mix(paletteColor(int(m.w)), fg, 0.5) * dot_env * tw * 0.9;
    }

    // Soft Reinhard on the accumulated thread light so overlapping ribbons
    // stay colored instead of clipping to white.
    col += thread_light / (1.0 + 0.35 * thread_light);

    // Beat swell: the whole page brightens a breath on the downbeat.
    col += accent * iSwell * 0.05 * vig;

    // Fine grain so the dark field never looks flat.
    col += (hash21(fc + fract(iFableTime) * 100.0) - 0.5) * 0.012;

    fragColor = vec4(col, 1.0);
}
