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
// Outward-ripple phase clock, accumulated CPU-side; speeds up with energy.
uniform float iFlow;
// Six-band spectrum; each body breathes on the band picked by its color index.
uniform float iBands[6];

out vec4 fragColor;

// Wave-packet ring frequency — higher packs more concentric rings into each
// body, so overlaps moiré into denser kaleidoscopic interference.
const float RING_FREQ = 0.13;

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
        // This body's band loosens its ring spacing — it breathes on its slice.
        float be = min(iBands[cid % 6], 1.4);
        float rf = RING_FREQ * (1.0 - be * 0.30);
        float sigma = P.z * 26.0;
        float r = length(d);
        float env = exp(-(r * r) / (2.0 * sigma * sigma));
        float phase = float(cid) * 2.4;
        field += env * sin(r * rf - iFlow + phase);
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

            // Each body breathes on its assigned band: that slice loosens its
            // ring spacing, so bass bodies pulse on kicks, treble on hats.
            float be = min(iBands[cid % 6], 1.4);
            float rf = RING_FREQ * (1.0 - be * 0.30);
            float sigma = P.z * 26.0;
            float r = length(d);
            float env = exp(-(r * r) / (2.0 * sigma * sigma));
            float phase = float(cid) * 2.4;
            field += env * sin(r * rf - iFlow + phase);
            tint += pc * env;
            env_sum += env;
        }
        vec3 avg = tint / max(env_sum, 1e-3);

        // Palette-colored interference (calm space): constructive fringes bloom
        // quadratically, destructive bands gently darken.
        float bc = max(field, 0.0);
        vec3 mono = avg * bc * bc * 1.6 + avg * min(field, 0.0) * 0.20;

        // Chromatic split: sample the field offset along the lens deflection,
        // a different shift per "wavelength". Identical to mono in calm space
        // (all three sample the same point) but fans apart where D is large.
        // The offset axis slowly rotates so the dispersion fringes swirl around
        // the bodies rather than sitting static along the lens direction.
        float sw = iKepTime * 0.5;
        mat2 swirl = mat2(cos(sw), -sin(sw), sin(sw), cos(sw));
        vec2 disp = swirl * D * 1.1;
        float fR = interferenceField(fc + disp);
        float fB = interferenceField(fc - disp);

        // Theme-colored dispersion: tint the three lens-shifted samples with
        // palette colors spanning warm→cool instead of pure R/G/B primaries,
        // so the "rainbow" is the scheme's own spectrum.
        vec3 cWarm = (iPaletteSize > 9)  ? iPalette[9]  : vec3(1.0, 0.35, 0.35);
        vec3 cMid  = (iPaletteSize > 11) ? iPalette[11] : vec3(0.5, 1.0, 0.4);
        vec3 cCool = (iPaletteSize > 12) ? iPalette[12] : vec3(0.35, 0.5, 1.0);
        float rR = max(fR, 0.0);
        float rB = max(fB, 0.0);
        vec3 rgb = (cWarm * rR * rR + cMid * bc * bc + cCool * rB * rB) * 1.6;

        float lensAmt = smoothstep(5.0, 55.0, lens);
        vec3 inter = max(mix(mono, rgb, lensAmt), vec3(0.0));

        // Antinodes: only the very strongest constructive peaks flare into
        // bright near-white focal sparks (sharp cubic so the field stays calm
        // elsewhere) — gives the kaleidoscope sparkle and depth.
        float anti = bc * bc * bc;
        inter += mix(avg, vec3(1.0), 0.6) * anti * 1.1;

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
