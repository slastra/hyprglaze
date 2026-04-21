#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform float iFill;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

float hash1(float n) {
    return fract(sin(n * 43758.5453123) * 127.1);
}

// 2D hash — avoids the clumping hash1 produces for linearly-spaced inputs.
float hash2(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 res = iResolution.xy;
    float aspect = res.x / res.y;

    float xn = fc.x / res.x;
    float yn = fc.y / res.y;

    // Palette
    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.07, 0.06, 0.1);
    vec3 liquid_deep = (iPaletteSize > 3) ? iPalette[3] : vec3(0.08, 0.22, 0.48);
    vec3 liquid_shallow = (iPaletteSize > 5) ? iPalette[5] : vec3(0.35, 0.65, 0.90);
    vec3 surface_col = (iPaletteSize > 14) ? iPalette[14] : iPaletteFg;

    // --- Drops: N slots, each with its own period + phase so they overlap ---
    // Per slot state packed into: ripple radius (0 = no active ripple),
    //                             ripple x, ripple strength (fades over splash time),
    //                             drop falling (for rendering the bead).
    const int DROP_SLOTS = 1;
    float drop_mask = 0.0;             // accumulated falling-drop bead (above water only)
    float surface_push = 0.0;          // transient bump to waterline around impact

    for (int i = 0; i < DROP_SLOTS; i++) {
        float fi = float(i);
        float period = 1.8 + hash1(fi * 7.31) * 2.8;   // 1.8–4.6s per slot
        float phase  = hash1(fi * 3.77) * period;
        float cycle  = (iTime + phase) / period;
        float cid    = floor(cycle);
        float t      = fract(cycle);                   // 0..1 within this cycle

        float dropX  = 0.05 + 0.90 * hash2(vec2(cid, fi * 1.73 + 0.31));

        const float FALL_FRAC   = 0.58;
        const float SPLASH_FRAC = 1.0 - FALL_FRAC;

        // Waterline (pre-ripple) used as the landing zone.
        float waterline_base = iFill;

        if (t < FALL_FRAC) {
            // Falling bead from top of screen down to the waterline.
            float ft = t / FALL_FRAC;
            float ease = ft * ft;                       // gravity-ish acceleration
            float drop_y = mix(1.02, waterline_base, ease);

            // Teardrop: hemisphere bulb at the bottom (q.y ∈ [-1, 0]) flowing
            // smoothly into a pointy tail on top (q.y ∈ [0, H]). The top
            // profile w = (1 - (y/H)²)^p has zero slope at y=0 so it joins
            // the circle without a corner, and vertical slope at y=H for a
            // sharp tip when p < 1.
            const float DROP_H = 1.8;       // tail length in bulb radii
            const float DROP_P = 0.85;      // tail pointiness (larger = thinner tail / sharper)
            float s = 0.012;                // drop scale (bulb radius in yn)
            vec2 q;
            q.x = (xn - dropX) * aspect / s;
            q.y = (yn - drop_y) / s;
            float w;
            if (q.y <= 0.0) {
                w = sqrt(max(0.0, 1.0 - q.y * q.y));
            } else {
                float tn = q.y / DROP_H;
                w = pow(max(0.0, 1.0 - tn * tn), DROP_P);
            }
            float aa = 1.0 / (res.y * s);
            float bead = 1.0 - smoothstep(w - aa, w + aa, abs(q.x));
            bead *= step(-1.0, q.y) * step(q.y, DROP_H);
            // No depth gate — the water will occlude the drop below the surface.
            drop_mask = max(drop_mask, bead);
        } else {
            // Splash: surface deformation centered at (dropX, waterline).
            float st = (t - FALL_FRAC) / SPLASH_FRAC;   // 0..1
            float ripple_r = st * 0.32;

            // Surface deformation: crater dent + Worthington jet + outgoing ripples.
            float horiz_dist = abs(xn - dropX) * aspect;

            // Impact crater: strong downward dent right at the point, decays fast.
            float crater = -exp(-horiz_dist * horiz_dist * 300.0)
                * exp(-st * 7.0) * 0.050;

            // Worthington jet: thin liquid column rising from the impact point
            // as the crater rebounds. Rise during st ∈ [0.10, 0.42],
            // fall during st ∈ [0.42, 0.82].
            float jet_rise = smoothstep(0.10, 0.42, st);
            float jet_fall = 1.0 - smoothstep(0.42, 0.82, st);
            float jet_amp = jet_rise * jet_fall;                  // 0..1 envelope
            // Super-Gaussian-ish column with a slightly cusped top — reads
            // sharper than a pure Gaussian while staying smooth enough to AA.
            float jet_column = exp(-pow(horiz_dist, 1.4) * 450.0);
            float jet = jet_column * jet_amp * 0.055;             // peak height

            // Outgoing damped sine wave, peak riding the expanding ring.
            float dx = horiz_dist - ripple_r;
            float wave_profile = sin(dx * 45.0);
            float envelope = exp(-dx * dx * 160.0) * (1.0 - st) * 0.030;
            float outgoing = wave_profile * envelope;

            // Trailing secondary ripples behind the leading crest.
            float trail = sin((horiz_dist - ripple_r * 0.5) * 28.0)
                * exp(-horiz_dist * horiz_dist * 25.0)
                * (1.0 - st) * (1.0 - st) * 0.010;

            surface_push += crater + jet + outgoing + trail;
        }
    }

    // --- Surface waves + drop-driven surface push ---
    float amp = 0.012 * (4.0 * iFill * (1.0 - iFill));
    float waves =
        sin(xn * 18.0 + iTime * 1.10) * amp +
        sin(xn *  6.5 - iTime * 0.70) * amp * 0.55 +
        sin(xn * 42.0 + iTime * 2.30) * amp * 0.25;
    float waterline = iFill + waves + surface_push;

    vec3 col;

    if (yn < waterline) {
        float depth = clamp((waterline - yn) * 1.6, 0.0, 1.0);
        col = mix(liquid_shallow, liquid_deep, depth);

        float caustic =
            sin(xn * 28.0 + iTime * 1.8) *
            sin(yn * 14.0 - iTime * 1.3);
        col += liquid_shallow * 0.05 * caustic;

        float shaft = max(sin(xn * 6.0 - iTime * 0.35), 0.0);
        shaft *= smoothstep(0.0, 0.25, waterline - yn) * (1.0 - depth);
        col += surface_col * shaft * 0.08;
    } else {
        col = bg;
        col += 0.015 *
            sin(xn * 3.5 + iTime * 0.12) *
            sin(yn * 2.2 - iTime * 0.09);
        // Falling drop beads — only visible above the water; the surface
        // naturally occludes any part of the drop that has entered the liquid.
        col = mix(col, surface_col, clamp(drop_mask, 0.0, 1.0));
    }

    // Surface highlight along the waterline.
    float band_width = 2.5 / res.y;
    float band = 1.0 - smoothstep(0.0, band_width, abs(yn - waterline));
    col = mix(col, surface_col, band * 0.55);

    fragColor = vec4(col, 1.0);
}
