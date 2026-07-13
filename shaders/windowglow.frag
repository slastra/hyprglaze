#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Music breath (both zero in silence / music = false → classic look).
uniform float iGlowEnergy; // slow full-mix envelope
uniform float iGlowBass;   // smoothed low end
uniform float iGlowGrain;  // film-grain amplitude (0 disables)

out vec4 fragColor;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float sdRoundBox(vec2 p, vec2 center, vec2 half_size, float radius) {
    vec2 d = abs(p - center) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    // Rosé Pine: bg=#191724, surface=#26233A, muted=#6E6A86, iris=#C4A7E7
    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.1, 0.09, 0.14);
    vec3 surface = (iPaletteSize > 0) ? iPalette[0] : vec3(0.15, 0.14, 0.23);
    vec3 muted = (iPaletteSize > 8) ? iPalette[8] : vec3(0.43, 0.42, 0.53);
    vec3 accent = (iPaletteSize > 5) ? iPalette[5] : vec3(0.77, 0.65, 0.91);

    vec3 col = bg;
    float corner = 12.0;

    // Smooth transition curve (ease in-out)
    float t = iTransition * iTransition * (3.0 - 2.0 * iTransition);

    // --- All windows ---
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0 || win.w < 1.0) continue;

        float dist = sdRoundBox(fc, win.xy + win.zw * 0.5, win.zw * 0.5, corner);

        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, 1.0 - smoothstep(0.0, 1.0, iTransition));

        // Focused glow: accent, wider radius, stronger at focus_amt=1.
        // Music makes only this halo breathe — the energy envelope swells
        // its reach and depth, a whisper of bass pulses it like a candle.
        // Unfocused windows never react; silence renders the classic look.
        float breathe = 1.0 + min(iGlowEnergy, 1.0) * 0.45 + min(iGlowBass, 1.2) * 0.2;
        vec3 focused_col = col;
        if (dist <= 0.0) {
            focused_col = mix(col, accent, 0.25);
        } else {
            float glow_radius = (30.0 + focus_amt * 30.0) * (1.0 + min(iGlowEnergy, 1.0) * 0.5);
            float glow = exp(-dist / glow_radius);
            focused_col = mix(col, accent, min(glow * 0.3 * breathe, 0.5));
        }

        // Unfocused glow: surface tint, tight edge halo only.
        vec3 unfocused_col = col;
        if (dist >= 0.0) {
            float glow = exp(-dist / 40.0);
            unfocused_col = mix(col, surface, glow * 0.5);
        }

        col = mix(unfocused_col, focused_col, focus_amt);
    }

    // Film grain: fine luminance-only noise, reseeded at ~10fps like
    // film stock — texture, not shimmer. Slightly stronger where the
    // glow lives so the halo reads matte rather than airbrushed.
    if (iGlowGrain > 0.0) {
        float seed = floor(iTime * 10.0);
        float g = hash21(fc + seed * 17.31) - 0.5;
        float lift = length(col - bg);
        col *= 1.0 + g * iGlowGrain * (0.035 + lift * 0.10);
    }

    fragColor = vec4(col, 1.0);
}
