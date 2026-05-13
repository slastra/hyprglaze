#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// meshflow-specific uniforms, populated by src/effects/meshflow/context.zig
uniform float iBands[6];      // [0]=sub-bass, [1]=bass, [2]=low-mid, [3]=mid, [4]=high-mid, [5]=air
uniform float iOnsets[6];     // per-band decaying onset flashes
uniform float iBeatPhase;     // [0,1) — current beat phase
uniform float iDownPhase;     // [0,1) — current downbeat phase (4x slower)
uniform float iTempo;         // BPM (currently informational only)
uniform float iIntensity;     // global displacement multiplier (config)

out vec4 fragColor;

// 5x5 anchor concentric class:
//   0 = center  (1 anchor)  → bass + sub-bass: kick bloom
//   1 = cardinal (4 anchors) → mid: swell
//   2 = diagonal (4 anchors) → high-mid: shimmer
//   3 = edge    (12 anchors) → low-mid: warm bed
//   4 = corner  (4 anchors)  → air: sparkle
int anchorClass(int r, int c) {
    int dr = abs(r - 2);
    int dc = abs(c - 2);
    if (dr == 0 && dc == 0) return 0;
    if ((dr == 1 && dc == 0) || (dr == 0 && dc == 1)) return 1;
    if (dr == 1 && dc == 1) return 2;
    if (dr == 2 && dc == 2) return 4;
    return 3;
}

// Band index that drives a given anchor class.
int anchorBand(int cls) {
    if (cls == 0) return 1; // bass (center also picks up sub-bass below)
    if (cls == 1) return 3; // mid
    if (cls == 2) return 4; // high-mid
    if (cls == 3) return 2; // low-mid
    return 5;               // air
}

// Rotate an RGB color around the gray axis by `angle` radians.
// Lifted from the well-known "hue rotation matrix" identity.
vec3 rotateHue(vec3 c, float angle) {
    const float k = 0.57735026; // 1/sqrt(3)
    const vec3 axis = vec3(k, k, k);
    float ca = cos(angle);
    float sa = sin(angle);
    return c * ca + cross(axis, c) * sa + axis * dot(axis, c) * (1.0 - ca);
}

vec3 paletteColor(int i) {
    int ps = max(iPaletteSize, 1);
    return iPalette[i % ps];
}

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;

    // Global beat-locked breathing — gentle scale around center.
    float breath = 1.0 + 0.03 * sin(6.2831853 * iBeatPhase);
    vec2 c_uv = (uv - 0.5) * breath + 0.5;

    // Downbeat hue offset, ±15° (≈0.26 rad) so the palette feels alive but recognizable.
    float hue_offset = 0.26 * sin(6.2831853 * iDownPhase);

    // Center anchor gets sub-bass + bass piled on for the "kick bloom" feel.
    float center_kick = iBands[0] + iBands[1] + 0.5 * (iOnsets[0] + iOnsets[1]);

    // Palette-derived surface color: bg lifted slightly toward fg. Works on
    // any theme (dark or light). Knob: raise the 0.06 for a more dramatic lift.
    vec3 col = mix(iPaletteBg, iPaletteFg, 0.06);

    // 5x5 anchor grid. Additive accumulation — anchors with no band activity
    // contribute zero, so the field stays dark until music drives it. This
    // also avoids the muddy-gray look that weighted-averaging 25 distinct
    // palette colors produces.
    // Sharp outward pulse that peaks at the moment of every beat. Quartic
    // falloff so the snap is felt, not smeared.
    float beat_snap = pow(max(0.0, 1.0 - iBeatPhase * 3.0), 3.0);
    // Bigger snap on the downbeat (every 4 beats).
    float down_snap = pow(max(0.0, 1.0 - iDownPhase * 1.5), 3.0);

    for (int r = 0; r < 5; r++) {
        for (int c = 0; c < 5; c++) {
            int cls = anchorClass(r, c);
            int bi = anchorBand(cls);
            int idx = r * 5 + c;
            vec2 base = vec2(float(c), float(r)) / 4.0;

            float env = iBands[bi];
            float onset = iOnsets[bi];

            // Push anchor outward on loud bands or onset hits (audio-reactive).
            vec2 to_center = base - vec2(0.5);
            float displace = (0.06 * env + 0.12 * onset) * iIntensity;
            if (cls == 0) displace += 0.10 * center_kick * iIntensity;

            // On-beat snap — adds a punchy outward push every beat, scaled by
            // concentric class so outer anchors snap further. Bumped on downbeats.
            float snap_amount = (cls == 0 ? 0.018 :
                                 cls == 1 ? 0.022 :
                                 cls == 2 ? 0.030 :
                                 cls == 3 ? 0.034 :
                                            0.042);
            float snap_strength = beat_snap + 0.45 * down_snap;
            float snap_disp = snap_amount * snap_strength * iIntensity;

            // Beat-driven circular sway — each anchor orbits a small ellipse
            // once per beat, with a per-anchor phase offset that makes the
            // field flow as a wave rather than moving in unison. Outer rings
            // sway more than the center.
            float sway_radius = (cls == 0 ? 0.000 :
                                 cls == 1 ? 0.010 :
                                 cls == 2 ? 0.014 :
                                 cls == 3 ? 0.016 :
                                            0.020) * iIntensity;
            float sway_phase = 6.2831853 * iBeatPhase + float(idx) * 0.55;
            vec2 sway = vec2(cos(sway_phase), sin(sway_phase * 1.3)) * sway_radius;

            // Subtle iTime wiggle kept at low magnitude so the field never feels
            // frozen between beats. Beat-driven motion does the heavy lifting now.
            float wig_phase = iTime * 0.45 + float(idx) * 1.7;
            vec2 wig = vec2(cos(wig_phase), sin(wig_phase * 1.3)) *
                       0.005 * (env * 0.4 + 0.6);

            vec2 pos = base + to_center * (displace + snap_disp) + sway + wig;

            // Gaussian blob influence — tighter sigma so anchors stay distinct.
            float d = distance(c_uv, pos);
            float sigma = 0.20;
            float w = exp(-d * d / (sigma * sigma));

            vec3 anchor_col = paletteColor(idx);
            anchor_col = rotateHue(anchor_col, hue_offset);

            // Strength is purely activity-driven: silent → 0 contribution.
            float strength = 0.35 * env + 0.9 * onset;
            if (cls == 0) strength += 0.5 * center_kick;

            col += anchor_col * w * strength;
        }
    }

    // Soft vignette.
    col *= 1.0 - 0.20 * length(uv - 0.5);

    fragColor = vec4(col, 1.0);
}
