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
// Sharp beat-pulse envelope — flashes brightness and pops the rings outward.
uniform float iBeat;
// Per-body velocity (px/s), indexed by body = particle_index / 5. Drives the
// Doppler wavefront compression.
uniform vec2 iVel[60];

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
    // Constant well depth — the warp holds a steady shape and does not react
    // to the music (only the rings/brightness/shockwaves/bodies do). Kept
    // moderate so the bending frames the field without overpowering it.
    float depth = 20.0;
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
        vec2 d = p - P.xy;
        if (abs(d.x) > 450.0 || abs(d.y) > 450.0) continue;
        // Doppler streak: trail samples (age>0) add dimmer smears behind the
        // head, so fast bodies blur into arcs along their motion.
        float age = floor(P.w / 16.0);
        float aw = exp(-age * 0.45);
        int cid = int(mod(P.w, 16.0));
        // This body's band loosens its ring spacing — it breathes on its slice.
        // The beat punch pops every ring outward briefly.
        float be = min(iBands[cid % 6], 1.4);
        float rf = RING_FREQ * (1.0 - be * 0.30 - min(iBeat, 1.6) * 0.18);
        float sigma = P.z * 26.0;
        float r = length(d);
        float env = exp(-(r * r) / (2.0 * sigma * sigma)) * aw;
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

    vec2 D = deflect(fc);
    // Gravitationally-warped sample position: the interference pattern is read
    // through the lens, so its rings bend and magnify toward heavy windows.
    vec2 wfc = fc + D * 1.4;

    // Backdrop aligned to the theme's surface tone — the base lifted slightly
    // toward the foreground — so the wallpaper sits cohesively with the window
    // surfaces instead of reading as a separate darker void.
    vec3 surface = mix(bg, fg, 0.06);
    vec3 col = surface;

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

            vec2 d = wfc - P.xy; // read through the gravitational lens
            if (abs(d.x) > 600.0 || abs(d.y) > 600.0) continue;

            // Doppler streak: include trail samples (age>0) as dimmer smears so
            // fast bodies blur into motion arcs behind their heads.
            float age = floor(P.w / 16.0);
            float aw = exp(-age * 0.45);
            int cid = int(mod(P.w, 16.0));
            vec3 pc = (iPaletteSize > cid) ? iPalette[cid] : vec3(0.7, 0.8, 1.0);

            // Each body breathes on its assigned band: that slice loosens its
            // ring spacing, so bass bodies pulse on kicks, treble on hats.
            // The beat punch pops every ring outward briefly.
            float be = min(iBands[cid % 6], 1.4);
            float rf = RING_FREQ * (1.0 - be * 0.30 - min(iBeat, 1.6) * 0.18);
            float sigma = P.z * 26.0;
            float r = length(d);

            // Real Doppler: a moving source bunches its wavefronts ahead of its
            // motion and stretches them behind. Scale the ring frequency by the
            // velocity component along the body->point direction.
            vec2 vel = iVel[i / 5];
            float sp = length(vel);
            float dopp = 1.0 + clamp(sp / 1100.0, 0.0, 0.45)
                       * dot(d / max(r, 1.0), vel / max(sp, 1.0));

            // Lorentzian envelope (long 1/r^2 tail, not a tight gaussian) so each
            // source radiates far across the medium and interferes everywhere —
            // the field reads as one rippling surface, not separate packets.
            float env = (1.0 / (1.0 + (r * r) / (sigma * sigma * 4.0))) * aw;
            float phase = float(cid) * 2.4;
            field += env * sin(r * rf * dopp - iFlow + phase);
            tint += pc * env;
            env_sum += env;
        }
        vec3 avg = tint / max(env_sum, 1e-3);

        // Palette-colored interference (calm space): constructive fringes bloom
        // quadratically, destructive bands gently darken.
        float bc = max(field, 0.0);
        vec3 mono = avg * bc * bc * 1.6 + avg * min(field, 0.0) * 0.20;

        // Chromatic dispersion disabled — just the palette-colored interference.
        vec3 inter = max(mono, vec3(0.0));

        // Enhance the fringes with crisp iso-amplitude contour lines: thin,
        // constant-width (fwidth-AA) lines trace the wavefronts and weave
        // through the field, sharpening the wave structure into a fine web.
        // Gated by env_sum so the empty background (field ~ 0 everywhere)
        // doesn't flood with the zero-level line.
        float g = field / 0.5 - 0.5; // offset so lines sit between the nodes
        float di = abs(g - floor(g + 0.5));
        float aa = fwidth(g) + 1e-4;
        float contour = (1.0 - smoothstep(0.0, aa * 1.5, di)) * smoothstep(0.05, 0.45, env_sum);
        inter += mix(avg, vec3(1.0), 0.25) * contour * 0.6;

        // Antinodes: only the very strongest constructive peaks flare into
        // bright near-white focal sparks (sharp cubic so the field stays calm
        // elsewhere) — gives the kaleidoscope sparkle and depth.
        float anti = bc * bc * bc;
        inter += mix(avg, vec3(1.0), 0.6) * anti * 1.1;

        // Beat punch: the whole field flares brighter on the hit.
        inter *= 1.0 + min(iBeat, 1.6) * 0.75;

        // Soft Reinhard so dense overlaps stay colored instead of clipping.
        col += inter / (1.0 + 0.35 * inter);

        // Fringe duality: carve dark nodal lines where the waves cancel
        // (field ~ 0), so bright fringes alternate with true dark minima — the
        // Young's-interference signature. Gated by wave presence so the empty
        // background isn't darkened.
        float node = exp(-field * field * 7.0) * smoothstep(0.1, 0.5, env_sum);
        col = mix(col, col * 0.35, node * 0.6);
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
