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

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.1, 0.09, 0.14);
    vec3 surface = (iPaletteSize > 0) ? iPalette[0] : vec3(0.15, 0.14, 0.23);
    vec3 muted = (iPaletteSize > 8) ? iPalette[8] : vec3(0.43, 0.42, 0.53);
    vec3 accent = (iPaletteSize > 5) ? iPalette[5] : vec3(0.77, 0.65, 0.91);

    vec3 pal[6];
    pal[0] = (iPaletteSize > 1) ? iPalette[1] : vec3(0.9, 0.4, 0.6);
    pal[1] = (iPaletteSize > 2) ? iPalette[2] : vec3(0.6, 0.8, 0.8);
    pal[2] = (iPaletteSize > 3) ? iPalette[3] : vec3(0.9, 0.7, 0.5);
    pal[3] = (iPaletteSize > 4) ? iPalette[4] : vec3(0.2, 0.4, 0.6);
    pal[4] = (iPaletteSize > 5) ? iPalette[5] : vec3(0.7, 0.6, 0.9);
    pal[5] = (iPaletteSize > 6) ? iPalette[6] : vec3(0.9, 0.7, 0.7);

    float spacing = 50.0;
    float t = iTime * 0.4;

    vec3 col = bg;

    // --- Concentric rings from each window (SDF-based) ---
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0 || win.w < 1.0) continue;

        float d = sdRoundBox(fc, win.xy + win.zw * 0.5, win.zw * 0.5, 12.0);
        if (d < 0.0) continue; // skip inside windows

        // Focus amount — animates in via iTransition on newly-focused window,
        // out via iPrevAlpha on the prior one. Continuous value so phase speed,
        // tint, and intensity all interpolate rather than snap.
        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iPrevAlpha));

        // Rings expand outward over time (focused rings run faster)
        float phase = t * mix(1.0, 1.5, focus_amt);
        float rings = abs(fract((d - phase * spacing) / spacing) - 0.5) * 2.0;
        float line = 1.0 - smoothstep(0.0, 0.04, rings);

        // Fade out with distance
        float fade = exp(-d / 400.0);

        int ci = int(mod(float(i), 6.0));
        vec3 tint = mix(pal[ci], accent, focus_amt);

        col = mix(col, tint, line * fade * mix(0.25, 0.5, focus_amt));
    }

    // --- Cursor rings ---
    float cd = distance(fc, iMouse.xy);
    float cursor_rings = abs(fract((cd - t * spacing * 0.8) / spacing) - 0.5) * 2.0;
    float cursor_line = 1.0 - smoothstep(0.0, 0.04, cursor_rings);
    float cursor_fade = exp(-cd / 300.0);
    col = mix(col, muted, cursor_line * cursor_fade * 0.4);

    // --- Focus transition pulse ---
    if (iWindow.z > 1.0 && iWindow.w > 1.0) {
        float fd = sdRoundBox(fc, iWindow.xy + iWindow.zw * 0.5, iWindow.zw * 0.5, 12.0);
        if (fd > 0.0) {
            float t_inv = 1.0 - iTransition;
            float pulse_r = t_inv * 500.0;
            float pulse = 1.0 - smoothstep(0.0, 3.0, abs(fd - pulse_r));
            col = mix(col, accent, pulse * t_inv * 0.7);
        }
    }

    fragColor = vec4(col, 1.0);
}
