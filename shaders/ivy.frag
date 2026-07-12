#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iIvyTime;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Ivy geometry from ivy.zig, rebuilt every frame.
uniform vec4 iSegs[200];   // stem segments (x1, y1, x2, y2)
uniform vec4 iSegB[50];    // per-segment brightness, packed 4 per vec4
uniform int iSegCount;
uniform vec4 iLeaf[80];    // (x, y, angle, size)
uniform int iLeafCount;
uniform vec4 iBloom[16];   // (x, y, size, color_idx + phase/10)
uniform vec4 iPetal[40];   // (x, y, angle + color_idx*10, size)
uniform float iBass;
uniform float iTreble;
uniform float iBeat;
uniform float iEnergy;
uniform float iBright;

out vec4 fragColor;

// ---------- noise ----------

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// ---------- palette ----------

// Foliage: ANSI green slots when the theme has them, moss-teal fallback.
vec3 leafColor() {
    if (iPaletteSize > 10) return mix(iPalette[2], iPalette[10], 0.45);
    return vec3(0.25, 0.65, 0.42);
}

vec3 stemColor() {
    vec3 leaf = leafColor();
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.85);
    return mix(leaf, fg, 0.25);
}

vec3 paletteColor(int cid) {
    return (iPaletteSize > cid) ? iPalette[cid] : vec3(0.85, 0.55, 0.75);
}

// ---------- main ----------

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.012, 0.016, 0.022);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.88);
    vec3 leaf_c = leafColor();
    vec3 stem_c = stemColor();

    // Night-garden backdrop: dark bg with a whisper of moss toward the
    // bottom, as if the foliage lights the ground it grows from.
    float vig = 1.0 - 0.35 * length(uv - 0.5);
    vec3 col = bg * (0.85 * vig + iBass * 0.04);
    col += leaf_c * (1.0 - uv.y) * (1.0 - uv.y) * 0.020;

    vec3 light = vec3(0.0);

    // ---- stems: thin glowing tendrils, the growing tip brightest ----
    for (int i = 0; i < iSegCount && i < 200; i++) {
        vec4 s = iSegs[i];
        vec2 lo = min(s.xy, s.zw) - 40.0;
        vec2 hi = max(s.xy, s.zw) + 40.0;
        if (fc.x < lo.x || fc.x > hi.x || fc.y < lo.y || fc.y > hi.y) continue;
        float b = iSegB[i >> 2][i & 3];
        if (b < 0.01) continue;

        vec2 pa = fc - s.xy;
        vec2 ba = s.zw - s.xy;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
        float d = length(pa - ba * h);

        float w = 1.1 + iBass * 0.4;
        // Bias-subtracted so the reject box never shows as a square edge.
        float cut = exp(-40.0 * 0.35 / w);
        light += stem_c * (exp(-d * 0.35 / w) - cut) * b * 0.62;
        light += mix(stem_c, fg, 0.4) * exp(-d * d * 0.6 / (w * w)) * b * 0.95;
    }

    // ---- leaves: soft rotated-ellipse glow, treble makes them shimmer ----
    for (int i = 0; i < iLeafCount && i < 80; i++) {
        vec4 L = iLeaf[i];
        if (L.w < 0.5) continue;
        vec2 dp = fc - L.xy;
        float rr = L.w * 3.5;
        if (dot(dp, dp) > rr * rr) continue;
        float ca = cos(L.z), sa = sin(L.z);
        // Leaf frame: x along the leaf, y across. Offset so the leaf grows
        // outward from its stem node rather than centered on it.
        vec2 q = vec2(ca * dp.x + sa * dp.y, -sa * dp.x + ca * dp.y);
        q.x -= L.w * 0.9;
        float d = length(q / vec2(L.w, L.w * 0.42)) - 1.0;
        float fill = smoothstep(0.15, -0.25, d);
        // Central vein, faintly brighter.
        float vein = exp(-abs(q.y) * 1.2) * fill * 0.5;
        float tw = 0.75 + 0.25 * sin(iIvyTime * 3.0 + float(i) * 1.7);
        float shine = tw * (0.55 + iTreble * 0.8);
        light += leaf_c * (fill * 0.55 + vein) * shine;
        light += leaf_c * max(-d, 0.0) * 0.15 * shine; // inner glow
    }

    // ---- blossoms: five-petal polar flowers, beat-born ----
    for (int i = 0; i < 16; i++) {
        vec4 B = iBloom[i];
        if (B.z < 0.4) continue;
        vec2 dp = fc - B.xy;
        float r2 = dot(dp, dp);
        float rr = B.z * 2.6;
        if (r2 > rr * rr) continue;
        int cid = int(B.w);
        float phase = fract(B.w) * 10.0;
        vec3 pc = paletteColor(cid);
        float r = sqrt(r2);
        float th = atan(dp.y, dp.x);
        float petal = pow(abs(cos(2.5 * th + phase)), 0.65);
        float target = B.z * (0.45 + 0.55 * petal);
        float d = r - target;
        float fill = smoothstep(1.5, -1.5, d);
        float heart = exp(-r2 / (B.z * B.z * 0.12));
        light += pc * fill * 0.85;
        light += mix(pc, fg, 0.65) * heart * 1.1;
        light += pc * exp(-max(d, 0.0) * 0.12) * 0.10; // soft halo
    }

    // ---- petals adrift ----
    for (int i = 0; i < 40; i++) {
        vec4 P = iPetal[i];
        if (P.w < 0.4) continue;
        vec2 dp = fc - P.xy;
        float rr = P.w * 3.0;
        if (dot(dp, dp) > rr * rr) continue;
        float ang = mod(P.z, 10.0);
        int cid = int(P.z / 10.0);
        float ca = cos(ang), sa = sin(ang);
        vec2 q = vec2(ca * dp.x + sa * dp.y, -sa * dp.x + ca * dp.y);
        float d = length(q / vec2(P.w, P.w * 0.55)) - 1.0;
        light += paletteColor(cid) * smoothstep(0.2, -0.3, d) * 0.5;
    }

    // Soft Reinhard so dense foliage stays colored instead of clipping.
    col += light * iBright / (1.0 + 0.35 * light * iBright);

    // Beat: the garden breathes.
    col += leaf_c * iBeat * 0.03 * vig;

    // Fine grain so the dark field never looks flat.
    col += (hash21(fc + fract(iIvyTime) * 100.0) - 0.5) * 0.012;

    fragColor = vec4(col, 1.0);
}
