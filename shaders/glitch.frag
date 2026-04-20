#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;

// [0] = (band0, band1, band2, band3)  sub-bass, bass, low-mid, mid
// [1] = (band4, band5, beat, flight_time)  high-mid, high, beat, time
// [2] = (glitch_seed, total_energy, bass_smooth, 0)
uniform vec4 iParticles[300];
uniform int iParticleCount;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

// --- Audio helpers ---
float getBand(int i) {
    if (i < 4) {
        if (i == 0) return iParticles[0].x;
        if (i == 1) return iParticles[0].y;
        if (i == 2) return iParticles[0].z;
        return iParticles[0].w;
    }
    if (i == 4) return iParticles[1].x;
    return iParticles[1].y;
}
float getBeat()      { return iParticles[1].z; }
float getTime()      { return iParticles[1].w; }
float getSeed()      { return iParticles[2].x; }
float getEnergy()    { return iParticles[2].y; }
float getBassSm()    { return iParticles[2].z; }

// --- Hash / noise ---
float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float hash1(float n) {
    return fract(sin(n) * 43758.5453);
}

vec2 hash2(vec2 p) {
    return vec2(hash(p), hash(p + vec2(37.0, 91.0)));
}

float noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    float a = 0.5;
    vec2 shift = vec2(100.0);
    for (int i = 0; i < 5; i++) {
        v += a * noise(p);
        p = p * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

vec2 domainWarp(vec2 p, float t, float strength) {
    float wx = fbm(p + vec2(t * 0.3, 0.0));
    float wy = fbm(p + vec2(0.0, t * 0.2) + vec2(5.2, 1.3));
    return p + vec2(wx, wy) * strength;
}

// --- Palette sampling ---
// Chromatic indices: normal 1-6, bright 9-14 (skip neutrals 0,7,8,15)
const int PAL_IDX[12] = int[12](1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14);

vec3 samplePalette(float t) {
    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.1, 0.09, 0.14);
    if (iPaletteSize < 2) return bg;

    // Map through all 12 chromatic colors (normal + bright)
    t = clamp(t, 0.0, 1.0);
    int count = min(iPaletteSize > 9 ? 12 : 6, 12);
    float idx = t * float(count - 1);
    int i0 = int(floor(idx));
    int i1 = min(i0 + 1, count - 1);
    float f = fract(idx);

    int p0 = PAL_IDX[i0];
    int p1 = PAL_IDX[i1];

    vec3 c0 = (iPaletteSize > p0) ? iPalette[p0] : vec3(0.5);
    vec3 c1 = (iPaletteSize > p1) ? iPalette[p1] : vec3(0.5);
    return mix(c0, c1, f);
}

// Base pattern: domain-warped FBM mapped through palette
vec3 basePattern(vec2 uv, float t) {
    vec2 p = uv * 3.0;
    vec2 warped = domainWarp(p, t, 0.4 + getBassSm() * 0.3);
    float n = fbm(warped);
    return samplePalette(n);
}

// --- Window SDF ---
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

float focusedSDF(vec2 p) {
    if (iWindow.z < 1.0) return 1e6;
    vec2 center = iWindow.xy + iWindow.zw * 0.5;
    vec2 half_size = iWindow.zw * 0.5;
    vec2 q = abs(p - center) - half_size;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// --- Glitch effects ---

// Block displacement: random rectangular regions shift
vec2 blockDisplace(vec2 uv, vec2 res, float seed, float intensity) {
    if (intensity < 0.01) return uv;

    // Divide into block grid, hash determines which blocks are "corrupt"
    float block_h = 0.02 + hash1(seed * 7.0) * 0.08;
    float row = floor(uv.y / block_h);
    float block_hash = hash(vec2(row, seed));

    // Only corrupt some blocks
    if (block_hash > 0.3 + (1.0 - intensity) * 0.5) return uv;

    // Horizontal shift amount
    float shift = (hash(vec2(row, seed + 1.0)) - 0.5) * 0.15 * intensity;
    return vec2(uv.x + shift, uv.y);
}

// VHS wobble: sinusoidal horizontal displacement
vec2 vhsWobble(vec2 uv, float intensity, float t) {
    if (intensity < 0.01) return uv;
    float wobble = sin(uv.y * 15.0 + t * 2.0) * 0.008 * intensity;
    wobble += sin(uv.y * 40.0 + t * 5.0) * 0.003 * intensity;
    return vec2(uv.x + wobble, uv.y);
}

// Horizontal jitter: per-row random offset
vec2 horizontalJitter(vec2 uv, float fc_y, float seed, float probability) {
    if (probability < 0.01) return uv;
    float row = floor(fc_y / 2.0); // 2px row groups
    float h = hash(vec2(row, seed + 3.0));
    if (h > probability) return uv;
    float offset = (hash(vec2(row, seed + 4.0)) - 0.5) * 0.04 * probability;
    return vec2(uv.x + offset, uv.y);
}

// RGB split / chromatic aberration
vec3 rgbSplit(vec2 uv, float t, float intensity) {
    float offset = 0.005 * intensity;
    float angle = t * 0.5;
    vec2 dir = vec2(cos(angle), sin(angle)) * offset;

    vec3 r = basePattern(uv + dir, t);
    vec3 g = basePattern(uv, t);
    vec3 b = basePattern(uv - dir, t);
    return vec3(r.r, g.g, b.b);
}

// Posterize: quantize color levels
vec3 posterize(vec3 col, float intensity) {
    if (intensity < 0.01) return col;
    float levels = mix(16.0, 3.0, clamp(intensity, 0.0, 1.0));
    return floor(col * levels + 0.5) / levels;
}

// Scanlines: darken every Nth row
float scanlines(float fc_y, float intensity) {
    if (intensity < 0.01) return 1.0;
    float gap = mix(4.0, 2.0, clamp(intensity, 0.0, 1.0));
    float line = mod(fc_y, gap);
    float mask = smoothstep(0.0, 1.0, line);
    return mix(1.0, mask, intensity * 0.5);
}

// Static noise overlay
vec3 staticNoise(vec2 uv, float t, float intensity) {
    float n = hash(uv * iResolution.xy + vec2(t * 1000.0));
    return vec3(n) * intensity * 0.15;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.1, 0.09, 0.14);

    // Audio values
    float sub_bass = getBand(0);
    float bass = getBand(1);
    float low_mid = getBand(2);
    float mid = getBand(3);
    float high_mid = getBand(4);
    float high = getBand(5);
    float beat = getBeat();
    float t = iTime;
    float seed = getSeed();
    float energy = getEnergy();

    // Spatial modulation
    float wd = windowSDF(fc);
    float fd = focusedSDF(fc);
    bool inside_window = wd < 0.0;

    // Glitch intensity: amplified near window edges, reduced near focused window and cursor
    float edge_boost = 1.0 + smoothstep(80.0, 0.0, abs(wd)) * 0.5;
    float focus_calm = 1.0 - smoothstep(200.0, 0.0, fd) * 0.4 * iTransition;
    float cursor_dist = length(fc - iMouse.xy);
    float cursor_calm = 1.0 - smoothstep(200.0, 0.0, cursor_dist) * 0.3;
    float spatial = edge_boost * focus_calm * cursor_calm;

    // Scale glitch intensities by audio bands and spatial factor
    float block_i = bass * 1.2 * spatial + beat * 0.5;
    float wobble_i = sub_bass * spatial;
    float jitter_p = high_mid * spatial + beat * 0.3;
    float split_i = bass * 0.8 * spatial + beat * 0.6;
    float poster_i = mid * 0.6 * spatial;
    float scan_i = low_mid * 0.7 * spatial;
    float noise_i = high * spatial + beat * 0.2;

    // Apply UV distortions
    vec2 guv = uv;
    guv = blockDisplace(guv, iResolution.xy, seed, block_i);
    guv = vhsWobble(guv, wobble_i, t);
    guv = horizontalJitter(guv, fc.y, seed, jitter_p);

    // Color: RGB split (samples base pattern 3x) or straight base
    vec3 col;
    if (split_i > 0.01) {
        col = rgbSplit(guv, t, split_i);
    } else {
        col = basePattern(guv, t);
    }

    // Ghost echo: sample at time offsets
    float ghost_strength = energy * 0.3 + beat * 0.4;
    if (ghost_strength > 0.02) {
        vec3 g1 = basePattern(guv + vec2(0.003), t - 0.08);
        vec3 g2 = basePattern(guv - vec2(0.005), t - 0.16);
        col = mix(col, g1, ghost_strength * 0.25);
        col = mix(col, g2, ghost_strength * 0.12);
    }

    // Post-processing
    col = posterize(col, poster_i);
    col *= scanlines(fc.y, scan_i);
    col += staticNoise(uv, t, noise_i);

    // Beat flash
    col += bg * beat * 0.25;

    // Vignette
    col *= 1.0 - 0.15 * length(uv - 0.5);

    fragColor = vec4(col, 1.0);
}
