#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindows[32];
uniform int iWindowCount;

uniform vec4 iParticles[300];
uniform int iParticleCount;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

uniform float iBands[6];
uniform float iBeat;
uniform float iBass;

out vec4 fragColor;

float sdRoundBox(vec2 p, vec2 center, vec2 half_size, float radius) {
    vec2 d = abs(p - center) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

vec3 paletteColor(float seed) {
    int ps = max(iPaletteSize, 1);
    int ci = 1 + int(mod(seed * 5.99, float(min(ps - 1, 6))));
    return iPalette[ci];
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec3 col = iPaletteBg;

    // Subtle window proximity glow — boids "illuminate" edges as they pass
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0 || win.w < 1.0) continue;
        float d = sdRoundBox(fc, win.xy + win.zw * 0.5, win.zw * 0.5, 8.0);
        if (d < 0.0 || d > 60.0) continue;
        float edge_glow = exp(-d * d / 800.0) * 0.03 * (1.0 + iBass * 2.0);
        col += iPaletteFg * edge_glow;
    }

    // Render boids — 5 slots per boid (head + 4 trail positions)
    float r_max = 50.0;
    const int SLOTS = 5;

    for (int gi = 0; gi + SLOTS - 1 < iParticleCount && gi < 300; gi += SLOTS) {
        vec4 head = iParticles[gi];
        vec2 pts[5];
        pts[0] = head.xy;
        for (int k = 1; k < SLOTS; k++) pts[k] = iParticles[gi + k].xy;

        float color_seed = head.w;
        vec3 boid_col = paletteColor(color_seed);
        float sz = 6.0;

        // Bounding box early-out over all points
        vec2 lo = pts[0];
        vec2 hi = pts[0];
        for (int k = 1; k < SLOTS; k++) {
            lo = min(lo, pts[k]);
            hi = max(hi, pts[k]);
        }
        if (fc.x < lo.x - r_max || fc.x > hi.x + r_max ||
            fc.y < lo.y - r_max || fc.y > hi.y + r_max) continue;

        // --- Streak: tapered line segments through trail points ---
        float streak_alpha = 0.0;
        const float widths[5] = float[5](0.55, 0.38, 0.24, 0.12, 0.02);
        const float opacities[5] = float[5](0.55, 0.42, 0.30, 0.16, 0.03);

        for (int seg = 0; seg < SLOTS - 1; seg++) {
            vec2 a = pts[seg];
            vec2 b = pts[seg + 1];
            float wa = sz * widths[seg];
            float wb = sz * widths[seg + 1];

            vec2 ab = b - a;
            float seg_len = length(ab);
            if (seg_len < 0.5 || seg_len > 200.0) continue;

            vec2 af = fc - a;
            float t = clamp(dot(af, ab) / (seg_len * seg_len), 0.0, 1.0);
            vec2 closest = a + ab * t;
            float dist = length(fc - closest);

            float hw = mix(wa, wb, t);
            float fw = fwidth(dist);
            float seg_fill = 1.0 - smoothstep(hw - fw, hw + fw, dist);
            float opacity = mix(opacities[seg], opacities[seg + 1], t);
            streak_alpha = max(streak_alpha, seg_fill * opacity);
        }
        if (streak_alpha > 0.0) {
            col = mix(col, boid_col, streak_alpha);
        }

        // --- Reversed teardrop head (round front, pointed back) ---
        float heading = head.z;
        float ca = cos(-heading);
        float sa = sin(-heading);
        vec2 d = fc - pts[0];
        vec2 local = vec2(ca * d.x - sa * d.y, sa * d.x + ca * d.y);

        float t_drop = -local.x / (sz * 3.0) + 0.5;
        float r = sz * sqrt(max(t_drop, 0.0)) * (1.0 - t_drop) * 2.8;
        float e = abs(local.y) - r;

        float fw = fwidth(e);
        float alpha = 1.0 - smoothstep(-fw, fw, e);
        alpha *= step(-sz * 1.5, local.x) * step(local.x, sz * 1.5);
        if (alpha > 0.0) {
            float lead = 0.7 + 0.3 * clamp(1.0 - t_drop, 0.0, 1.0);
            float shimmer = 1.0 + (iBands[3] + iBands[4]) * 0.4;
            col = mix(col, boid_col * lead * shimmer, alpha);
        }
    }

    // Beat flash
    col += iPaletteFg * iBeat * 0.12;

    // Soft vignette
    vec2 uv = fc / iResolution.xy;
    col *= 1.0 - 0.15 * length(uv - 0.5);

    fragColor = vec4(col, 1.0);
}
