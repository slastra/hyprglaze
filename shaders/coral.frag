#version 300 es
precision highp float;

// coral — the display half of a Gray-Scott reaction-diffusion reef (the
// sim lives in src/effects/coral.zig). The coarse field is resampled
// smoothly and cut at one level, so the folds come out as flat shapes
// with a crisp edge at any resolution. No shading inside a fold: one
// fill, one outline, and a soft shadow on the rock beneath.

uniform vec3 iResolution;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

uniform sampler2D iCoral;   // R = food (U), G = coral (V), B = reach
uniform vec2 iCoralSize;    // grid cells
uniform vec3 iCoralPhase;   // regime drift, as the sim sees it
uniform float iCoralBeat;   // kick envelope
uniform float iCoralBass;   // smoothed low end
uniform float iCoralEnergy; // slow full-mix envelope
uniform float iCoralPulse;      // pulse clock, cycles (0..1)
uniform float iCoralPulseCells; // cells between pulses along a fold
uniform float iCoralVoice;      // pulses' level: 0 while a window moves

out vec4 fragColor;

// V at the waterline in silence: a fold is where the field stands above
// it. Bass lowers the water a little, so the folds swell and narrow
// again as a note dies.
const float LEVEL = 0.2;
const float TAU = 6.2831853;

// Same field the sim reads its feed and kill rates from (keep identical
// to `regime` in coral.zig, which applies the smoothstep itself), so
// colour follows the local growth habit.
float regimeRaw(vec2 p, vec3 ph, float h) {
    vec2 q = p / h;
    float a = sin(dot(q, vec2(2.1, 1.3)) + ph.x);
    float b = sin(dot(q, vec2(-1.7, 2.9)) + ph.y);
    float d = sin(dot(q, vec2(3.4, -2.2)) + ph.z + a * 0.8);
    return (a + b + d) / 3.0;
}

// Cubic B-spline resampling of the field (x = V, y = reach) in four
// bilinear taps. Bilinear alone leaves the grid visible as kinks along
// every edge.
vec2 coralAt(vec2 px) {
    vec2 st = px / iResolution.xy * iCoralSize - 0.5;
    vec2 i = floor(st);
    vec2 f = st - i;
    vec2 f2 = f * f, f3 = f2 * f;
    vec2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    vec2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    vec2 w3 = f3 / 6.0;
    vec2 w2 = 1.0 - w0 - w1 - w3;
    vec2 g0 = w0 + w1;
    vec2 g1 = w2 + w3;
    vec2 h0 = (i + w1 / g0 - 0.5) / iCoralSize;
    vec2 h1 = (i + w3 / g1 + 1.5) / iCoralSize;
    return g0.y * (g0.x * texture(iCoral, vec2(h0.x, h0.y)).gb + g1.x * texture(iCoral, vec2(h1.x, h0.y)).gb)
         + g1.y * (g0.x * texture(iCoral, vec2(h0.x, h1.y)).gb + g1.x * texture(iCoral, vec2(h1.x, h1.y)).gb);
}

float sdBox(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// How strongly a point belongs to the focused window's surroundings,
// handing over from the previous one as the focus transition runs.
float nearFocus(vec2 fc) {
    float t = smoothstep(0.0, 1.0, iTransition);
    float n = 0.0;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        float w = (i == iFocusedIndex) ? t : ((i == iPrevIndex) ? 1.0 - t : 0.0);
        if (w <= 0.0) continue;
        vec4 r = iWindows[i];
        float d = max(sdBox(fc - (r.xy + r.zw * 0.5), r.zw * 0.5), 0.0);
        n = max(n, w * exp(-d / (0.09 * iResolution.y)));
    }
    return n;
}

void main() {
    vec2 fc = gl_FragCoord.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.1, 0.09, 0.14);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.88, 0.87, 0.96);
    vec3 warm = (iPaletteSize > 1) ? iPalette[1] : vec3(0.92, 0.43, 0.57);
    vec3 cool = (iPaletteSize > 6) ? iPalette[6] : vec3(0.61, 0.81, 0.85);
    vec3 accent = (iPaletteSize > 5) ? iPalette[5] : vec3(0.77, 0.65, 0.91);

    float beat = min(iCoralBeat, 1.5);
    float bass = min(iCoralBass, 1.2);
    float energy = min(iCoralEnergy, 1.0);
    float level = LEVEL - 0.045 * bass;

    vec2 field = coralAt(fc);
    float v = field.x;
    // Signed distance to the waterline in pixels, from the field's slope.
    float slope = length(vec2(dFdx(v), dFdy(v)));
    float d = (v - level) / max(slope, 1e-5);

    float fill = smoothstep(-0.75, 0.75, d);
    float line = 1.0 - smoothstep(0.75, 1.75, abs(d - 0.75));

    // The shadow falls down and to the right, on the rock only.
    float px = iResolution.y / 2160.0;
    float sv = coralAt(fc + vec2(-7.0, 9.0) * px).x;
    float shadow = smoothstep(level - 0.12, level + 0.08, sv) * (1.0 - fill);

    float r = smoothstep(-0.55, 0.55, regimeRaw(fc, iCoralPhase, iResolution.y));
    vec3 tint = mix(cool, warm, r);
    tint = mix(tint, accent, nearFocus(fc) * 0.85);

    // Pulses run outward along the reach: down each fold from the
    // windows and the cursor. Faint in silence, lit by the music, and a
    // kick flares whichever are in flight.
    float wave = 0.5 + 0.5 * cos(TAU * (field.y / iCoralPulseCells - iCoralPulse));
    float pulse = pow(wave, 5.0) * (0.16 + 0.55 * energy + 0.35 * bass + 0.45 * beat);
    pulse = min(pulse, 1.0) * iCoralVoice;

    vec3 body = mix(bg, tint, 0.60 + 0.06 * energy);
    body = mix(body, mix(tint, fg, 0.35), pulse * 0.75);
    vec3 rim = mix(tint, fg, min(0.25 + 0.5 * pulse, 0.9));

    vec3 col = bg * (1.0 - 0.32 * shadow);
    col = mix(col, body, fill);
    col = mix(col, rim, line * fill);

    fragColor = vec4(col, 1.0);
}
