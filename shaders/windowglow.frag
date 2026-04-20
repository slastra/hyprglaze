#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;

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
        bool is_focused = abs(win.x - iWindow.x) < 1.0 && abs(win.y - iWindow.y) < 1.0;

        if (is_focused) {
            // Focused: accent glow fades in with transition
            if (dist <= 0.0) {
                col = mix(col, accent, 0.25 * t);
            } else {
                float glow_radius = 30.0 + t * 30.0; // glow expands during transition
                float glow = exp(-dist / glow_radius);
                col = mix(col, accent, glow * 0.3 * t);
            }
        } else {
            if (dist < 0.0) continue;
            float glow = exp(-dist / 40.0);
            col = mix(col, surface, glow * 0.5);
        }
    }

    fragColor = vec4(col, 1.0);
}
