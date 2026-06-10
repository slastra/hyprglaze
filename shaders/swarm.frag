#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iSwarmTime;
uniform vec4 iWindows[32];
uniform int iWindowCount;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Flock field, splatted CPU-side at 160x90: RG = density-weighted velocity
// (biased, ±vel_scale px/s), B = agitation (predator fear), A = density.
// The shader renders this field — never individual boids — which is what
// makes the flock read as one continuous murmuration.
uniform sampler2D iField;
uniform float iBeat;
uniform float iBass;
uniform float iEnergy;

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
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p = p * 2.1 + 17.3;
        a *= 0.5;
    }
    return v;
}

// ---------- field sampling ----------

// Density streaked along local velocity: taps marched upstream and a little
// downstream of the flow direction. This smears the cloud into ribbons that
// follow the flock's motion — feathers, not blobs.
float streakDensity(vec2 uv, vec2 vel_uv) {
    float total = texture(iField, uv).a * 1.2;
    float wsum = 1.2;
    for (int k = 1; k <= 3; k++) {
        float t = float(k) / 3.0;
        float w = 1.0 - t * 0.65;
        total += texture(iField, uv - vel_uv * t).a * w;
        total += texture(iField, uv + vel_uv * t * 0.4).a * w * 0.6;
        wsum += w * 1.6;
    }
    return total / wsum;
}

float sdRoundBox(vec2 p, vec2 center, vec2 half_size, float radius) {
    vec2 d = abs(p - center) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}


// ---------- main ----------

// Block quantization, kept as a dial: 1.0 = smooth contours (the look),
// >1 quantizes everything into sprite blocks — pixelated topography.
const float PIX = 1.0;
// In block mode fwidth is useless (density is constant within a block), so
// the isoline threshold needs a fixed floor wide enough that contour rings
// render as connected chains of blocks instead of scattered dots.
const float ISO_FLOOR = PIX > 1.5 ? 0.09 : 0.006;

void main() {
    vec2 block = floor(gl_FragCoord.xy / PIX);
    vec2 fc = block * PIX + PIX * 0.5;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02, 0.025, 0.04);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    // Hypsometric ramp straight from the theme's ANSI colors — sea-floor
    // blue through cyan and green to yellow, peaks brushing the foreground.
    // The whole map recolors with the theme like every other effect.
    vec3 elev0 = (iPaletteSize > 4) ? iPalette[4] : vec3(0.25, 0.35, 0.70);
    vec3 elev1 = (iPaletteSize > 6) ? iPalette[6] : vec3(0.30, 0.60, 0.80);
    vec3 elev2 = (iPaletteSize > 2) ? iPalette[2] : vec3(0.30, 0.70, 0.40);
    vec3 elev3 = (iPaletteSize > 3) ? iPalette[3] : vec3(0.80, 0.70, 0.30);
    vec3 hot   = (iPaletteSize > 9) ? iPalette[9] : vec3(1.0, 0.4, 0.3);

    // Dusk sky: vertical falloff plus the faintest large-scale drift.
    float sky = 1.0 - uv.y * 0.25;
    vec3 col = bg * (0.8 * sky + 0.06 * fbm(uv * 3.0 + iSwarmTime * 0.02));

    vec4 field = texture(iField, uv);
    vec2 vel = (field.rg - 0.5) * 2.0;
    float agit = field.b;

    // Streak step in uv space, scaled by how fast this patch is moving.
    vec2 vel_uv = vel * 0.08;
    float dens = streakDensity(uv, vel_uv);

    // Feathering: fbm advected against the flow breaks the cloud edge into
    // plumage. Domain offset by velocity so the texture streams with it.
    float feather = fbm(fc * 0.013 - vel * 2.5 + vec2(0.0, iSwarmTime * 0.35));
    dens *= 0.55 + 0.9 * feather;
    dens *= 1.0 + iBass * 0.5; // bass thickens the murmuration

    // ---------- contour-map rendering ----------
    // The flock is an elevation field: density is altitude. Thin isolines
    // ring each density threshold like a topographic map, with faint
    // hypsometric terraces between them. The murmuration reads as a living
    // mountain range forming and eroding.
    float panic = agit * (0.7 + 0.3 * vnoise(fc * 0.05 + iSwarmTime * 9.0));

    const float levels = 4.0;
    float q = dens * levels;
    float level = floor(q);
    float g = fract(q);
    float line_d = min(g, 1.0 - g); // distance to the nearest iso threshold
    float lw = fwidth(q) * 0.6 + ISO_FLOOR;
    float iso = 1.0 - smoothstep(lw, lw * 1.8, line_d);

    // Elevation tint: walk the theme's terrain ramp band by band.
    // Disturbance zones (the unseen predator's wake) ring hot.
    float lt = clamp(level / levels, 0.0, 1.0);
    float e = lt * 4.0;
    vec3 ramp;
    if      (e < 1.0) ramp = mix(elev0, elev1, e);
    else if (e < 2.0) ramp = mix(elev1, elev2, e - 1.0);
    else if (e < 3.0) ramp = mix(elev2, elev3, e - 2.0);
    else              ramp = mix(elev3, fg, min(e - 3.0, 1.0));
    // Mute toward ink: heavily desaturated, leaned into the foreground —
    // printed-map line tones rather than neon. Panic stays vivid.
    float lum = dot(ramp, vec3(0.299, 0.587, 0.114));
    ramp = mix(ramp, vec3(lum), 0.45);
    ramp = mix(ramp, fg, 0.15);
    ramp = mix(ramp, hot, clamp(panic * 1.4, 0.0, 0.75));

    // Pure line-work: no terraced fill, just crisp colored isolines on the
    // bare theme background — the formations read as drawn cartography.
    float present = smoothstep(0.02, 0.10, dens);
    col += ramp * iso * present * (0.8 + iEnergy * 0.4);

    // The predator is deliberately invisible — an unseen force. You read
    // its position only from the holes it tears in the map and the hot
    // contour rings of the birds fleeing it.

    // Window edges catch a faint glow from passing density.
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0 || win.w < 1.0) continue;
        float d = sdRoundBox(fc, win.xy + win.zw * 0.5, win.zw * 0.5, 8.0);
        if (d < 0.0 || d > 60.0) continue;
        col += ramp * exp(-d * d / 800.0) * 0.08 * present * (1.0 + iBeat);
    }

    fragColor = vec4(col, 1.0);
}
