#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform float iPrevAlpha;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

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

        // Focus amount animates in on new focus (via iTransition) and animates
        // out on the previously-focused window (via iPrevAlpha). The two glow
        // styles cross-fade so there's no snap when focus leaves.
        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iPrevAlpha));

        // Focused glow: accent, wider radius, stronger at focus_amt=1.
        vec3 focused_col = col;
        if (dist <= 0.0) {
            focused_col = mix(col, accent, 0.25);
        } else {
            float glow_radius = 30.0 + focus_amt * 30.0;
            float glow = exp(-dist / glow_radius);
            focused_col = mix(col, accent, glow * 0.3);
        }

        // Unfocused glow: surface tint, tight edge halo only.
        vec3 unfocused_col = col;
        if (dist >= 0.0) {
            float glow = exp(-dist / 40.0);
            unfocused_col = mix(col, surface, glow * 0.5);
        }

        col = mix(unfocused_col, focused_col, focus_amt);
    }

    fragColor = vec4(col, 1.0);
}
