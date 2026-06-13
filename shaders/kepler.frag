#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iKepTime;
uniform vec4 iMouse;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Orbiting bodies, packed by kepler.zig: (x, y, size, color_idx + 16*age).
// Age 0 is the head; 1..4 are trail samples, dimmer with age.
uniform vec4 iParticles[300];
uniform int iParticleCount;
uniform float iBass;
// 1.0 = wave-packet interference fuzz (default), 0.0 = comet dots + trails.
uniform float iFuzz;

out vec4 fragColor;

// ---------- gravitational deflection ----------

// Aggregate lens deflection at p: each window bends "light" toward itself
// with the classic point-lens 1/r falloff (Plummer-softened). Bass breathes
// the depth. The same field warps the grid, the starfield, and feeds the
// rim glow, so all three layers agree about the geometry.
vec2 deflect(vec2 p) {
    vec2 D = vec2(0.0);
    float depth = 16.0 * (1.0 + iBass * 0.7);
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 8.0 || win.w < 8.0) continue;
        vec2 cen = win.xy + win.zw * 0.5;
        float m = sqrt(win.z * win.w);
        if (i == iFocusedIndex) m *= mix(1.0, 2.0, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    m *= mix(2.0, 1.0, smoothstep(0.0, 1.0, iTransition));
        vec2 d = cen - p;
        float r = length(d) + 1.0;
        D += (d / r) * (m * depth / (r + 140.0));
    }
    // The cursor-comet bends space a little too.
    vec2 dm = iMouse.xy - p;
    float rm = length(dm) + 1.0;
    D += (dm / rm) * (180.0 * depth * 0.6 / (rm + 140.0));
    return D;
}

// Signed interference field at p: sum of each wave-packet's gaussian-enveloped
// radial ripple. Constructive overlaps push positive, destructive negative.
// Sampled at slightly lens-shifted positions per color channel for chromatic
// dispersion (the gravitational lens splits the fringes into rainbow).
float interferenceField(vec2 p) {
    float field = 0.0;
    for (int i = 0; i < iParticleCount && i < 300; i++) {
        vec4 P = iParticles[i];
        if (P.w >= 16.0) continue; // heads only
        vec2 d = p - P.xy;
        if (abs(d.x) > 450.0 || abs(d.y) > 450.0) continue;
        int cid = int(mod(P.w, 16.0));
        float sigma = P.z * 26.0;
        float r = length(d);
        float env = exp(-(r * r) / (2.0 * sigma * sigma));
        float phase = float(cid) * 2.4;
        field += env * sin(r * 0.055 - iKepTime * 2.2 + phase);
    }
    return field;
}

// ---------- main ----------

void main() {
    vec2 fc = gl_FragCoord.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.01, 0.012, 0.025);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.85);
    vec3 accent = (iPaletteSize > 12) ? iPalette[12] : vec3(0.35, 0.5, 0.95);

    vec2 D = deflect(fc);
    float lens = length(D);

    // Deep-space backdrop, slightly darker than the raw theme bg.
    vec3 col = bg * 0.75;

    if (iFuzz > 0.5) {
        // PURE INTERFERENCE: nothing renders but the wave-packet interference
        // pattern itself. The palette tint comes from a center pass; two more
        // passes sampled at lens-shifted positions give per-channel chromatic
        // dispersion, so the fringes split into rainbow where space bends most.
        float field = 0.0;
        vec3 tint = vec3(0.0);
        float env_sum = 0.0;
        for (int i = 0; i < iParticleCount && i < 300; i++) {
            vec4 P = iParticles[i];
            if (P.w >= 16.0) continue; // heads only — trails are comet-mode

            vec2 d = fc - P.xy;
            if (abs(d.x) > 450.0 || abs(d.y) > 450.0) continue;

            int cid = int(mod(P.w, 16.0));
            vec3 pc = (iPaletteSize > cid) ? iPalette[cid] : vec3(0.7, 0.8, 1.0);

            float sigma = P.z * 26.0;
            float r = length(d);
            float env = exp(-(r * r) / (2.0 * sigma * sigma));
            float phase = float(cid) * 2.4;
            field += env * sin(r * 0.055 - iKepTime * 2.2 + phase);
            tint += pc * env;
            env_sum += env;
        }
        vec3 avg = tint / max(env_sum, 1e-3);

        // Palette-colored interference (calm space): constructive fringes bloom
        // quadratically, destructive bands gently darken.
        float bc = max(field, 0.0);
        vec3 mono = avg * bc * bc * 1.6 + avg * min(field, 0.0) * 0.20;

        // Chromatic split: sample the field offset along the lens deflection,
        // a different shift per channel. Identical to mono in calm space (all
        // three sample the same point) but fans into rainbow where D is large.
        float fR = interferenceField(fc + D * 1.1);
        float fB = interferenceField(fc - D * 1.1);
        vec3 rgb = vec3(max(fR, 0.0), bc, max(fB, 0.0));
        rgb = rgb * rgb * 1.6;

        float lensAmt = smoothstep(5.0, 55.0, lens);
        vec3 inter = max(mix(mono, rgb, lensAmt), vec3(0.0));
        // Soft Reinhard so dense overlaps stay colored instead of clipping.
        col += inter / (1.0 + 0.35 * inter);
    } else {
        // Comet mode: tight additive dots with fading trails.
        for (int i = 0; i < iParticleCount && i < 300; i++) {
            vec4 P = iParticles[i];
            vec2 d = fc - P.xy;
            if (abs(d.x) > 60.0 || abs(d.y) > 60.0) continue;

            float age = floor(P.w / 16.0);
            int cid = int(mod(P.w, 16.0));
            vec3 pc = (iPaletteSize > cid) ? iPalette[cid] : vec3(0.7, 0.8, 1.0);

            float fade = 1.0 / (1.0 + age * 1.1);
            float r2 = dot(d, d);
            float sz = P.z * fade;
            float core = exp(-r2 / (sz * sz * 3.5));
            float halo = exp(-r2 / (sz * sz * 30.0)) * 0.4;
            // Heads burn a touch hotter than their palette color.
            vec3 body_col = mix(pc, fg, age < 0.5 ? 0.25 : 0.0);
            col += (body_col * (core + halo)) * fade * 1.35;
        }
    }

    // Whisper of vignette so the field has depth.
    vec2 uv = fc / iResolution.xy;
    col *= 1.0 - 0.25 * dot(uv - 0.5, uv - 0.5) * 4.0 * 0.5;

    fragColor = vec4(col, 1.0);
}
