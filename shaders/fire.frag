#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iFireTime;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// The fire itself is a fluid simulated on a coarse grid (src/effects/
// fire.zig): rg = gas velocity in px/s, b = temperature, a = smoke (-1
// inside a window). iFireSpan is the grid's extent in px.
uniform sampler2D iFire;
uniform vec2 iFireSpan;
uniform float iSmoke;      // how much smoke to show, 0 for none
// The light the fire throws: its heat blurred at several widths at once,
// over the same extent as iFire.
uniform sampler2D iFireLight;
uniform float iGlow;       // how much of it to show, 0 for none

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

// Palette-driven ramp: the fire takes on the theme's colors and nothing
// else, from its background up through its reds and yellows to its white.
// Gogh/ANSI slots: 1=red, 3=yellow, 9=bright red, 11=bright yellow,
// 15=bright white.
vec3 paletteHeat(float h) {
    if (iPaletteSize < 4) return heatRamp(h);

    vec3 c0 = iPaletteBg;
    vec3 c1 = iPalette[1];
    vec3 c2 = (iPaletteSize > 9)  ? iPalette[9]  : c1 * 1.25;
    vec3 c3 = (iPaletteSize > 3)  ? iPalette[3]  : c2;
    vec3 c4 = (iPaletteSize > 11) ? iPalette[11] : c3 * 1.15;
    vec3 c5 = (iPaletteSize > 15) ? iPalette[15] : iPaletteFg;

    h = clamp(h, 0.0, 1.0);
    // The white is kept to the very hottest core: most schemes' white is a
    // light gray, and a flame that is mostly gray looks cold.
    if (h < 0.18) return mix(c0, c1, h / 0.18);
    if (h < 0.42) return mix(c1, c2, (h - 0.18) / 0.24);
    if (h < 0.66) return mix(c2, c3, (h - 0.42) / 0.24);
    if (h < 0.90) return mix(c3, c4, (h - 0.66) / 0.24);
    return                mix(c4, mix(c4, c5, 0.6), (h - 0.90) / 0.10);
}

// Integer hash for the dither: a fract-multiply hash lines up into
// streaks on a pixel lattice.
float dither(ivec2 p) {
    uint h = uint(p.x) * 0x8da6b343u + uint(p.y) * 0xd8163841u;
    h ^= h >> 15; h *= 0x2c1b3c6du;
    h ^= h >> 12; h *= 0x297a2d39u;
    h ^= h >> 15;
    return float(h >> 8) / 16777216.0;
}

// ---------- main ----------

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;
    float t = iFireTime;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02, 0.012, 0.008);
    vec3 col = bg;

    vec4 gas = texture(iFire, fc / iFireSpan);
    float temp = gas.b;

    // The fire lights what is around it. The light is a tint toward the
    // scheme's own red, never added on top, so however much fire there is
    // the glow tops out at a scheme color. It warms toward the flame's
    // next color close in, but only part of the way: that one is often a
    // pale yellow, and a pale color at half strength is khaki, not light.
    float lum = 1.0 - exp(-texture(iFireLight, fc / iFireSpan).r * 3.2 * iGlow);
    vec3 ember = (iPaletteSize > 1) ? iPalette[1] : vec3(0.75, 0.16, 0.04);
    vec3 flare = (iPaletteSize > 9) ? iPalette[9] : vec3(1.0, 0.36, 0.08);
    vec3 light = mix(ember, flare, 0.45 * smoothstep(0.35, 1.0, lum));
    col = mix(col, light, 0.72 * lum);

    // Smoke goes down next, behind the flame: the scheme's bright black,
    // its gray, lit by the fire below it. A slow rising noise pulls it
    // into wisps.
    float smoke = max(gas.a, 0.0) * iSmoke;
    if (smoke > 0.002) {
        vec2 sp = vec2(fc.x * 0.0045, fc.y * 0.0035 - t * 0.22) - gas.xy * 0.0012;
        float wisp = fbm(sp) * 0.7 + fbm(sp * 2.7 + 5.3) * 0.3;
        float veil = 1.0 - exp(-smoke * (0.25 + 2.6 * wisp * wisp));
        vec3 gray = (iPaletteSize > 8) ? iPalette[8] : mix(bg, vec3(0.5), 0.5);
        float lit = (iGlow > 0.0) ? lum : smoothstep(0.0, 0.25, temp);
        vec3 smoke_col = mix(gray, light, 0.6 * lit);
        col = mix(col, smoke_col, veil * 0.5);
    }

    // The grid is coarse, so the flame's fine edge is drawn here: a noise
    // that streams up with the gas tears the smooth temperature field into
    // licks and tongues. It only ever modulates heat that is there.
    vec2 np = vec2(fc.x * 0.012, fc.y * 0.007 - t * 1.5) - gas.xy * 0.0006;
    float n = mix(fbm(np), fbm(np * 2.5 + vec2(3.1, -t * 0.6)), 0.4);
    float heat = clamp(temp * (0.4 + 1.3 * n), 0.0, 1.0);

    // Fire over smoke and background.
    col = mix(col, paletteHeat(heat), smoothstep(0.06, 0.36, heat));

    // Subtle vignette.
    col *= 1.0 - 0.22 * length(uv - vec2(0.5, 0.55));

    // The glow's long falloff is too shallow for 8 bits and would band.
    col += (dither(ivec2(fc)) - 0.5) / 255.0;

    fragColor = vec4(col, 1.0);
}
