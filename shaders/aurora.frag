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

out vec4 fragColor;

// Smooth noise
float hash(float n) { return fract(sin(n) * 43758.5453); }

float noise(float x) {
    float i = floor(x);
    float f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(hash(i), hash(i + 1.0), f);
}

float fbm(float x) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * noise(x);
        x *= 2.0;
        a *= 0.5;
    }
    return v;
}

// SDF to nearest window edge
float windowSDF(vec2 p) {
    float d = 1e6;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0) continue;
        vec2 center = win.xy + win.zw * 0.5;
        vec2 half_size = win.zw * 0.5;
        vec2 q = abs(p - center) - half_size;
        float wd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        d = min(d, wd);
    }
    return d;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.01, 0.01, 0.02);
    vec3 col = bg;

    float t = iTime * 0.15;

    // Vertical gradient — aurora concentrated in upper 70%
    float vert = smoothstep(0.0, 0.7, uv.y);

    // Window proximity — aurora brightens and bends near windows
    float wd = windowSDF(fc);
    float win_influence = exp(-wd * 0.005);

    // Cursor influence — gentle distortion
    float cursor_dist = length(fc - iMouse.xy);
    float cursor_warp = exp(-cursor_dist * 0.003) * 30.0;

    // Build aurora curtains — multiple overlapping layers
    float aurora_total = 0.0;
    vec3 aurora_color = vec3(0.0);

    for (int layer = 0; layer < 4; layer++) {
        float fl = float(layer);
        float speed = 0.3 + fl * 0.15;
        float freq = 1.5 + fl * 0.7;
        float phase = fl * 1.7;

        // Horizontal wave — the curtain shape
        float wave_x = uv.x * freq + t * speed + phase;
        wave_x += sin(uv.y * 3.0 + t * 0.5 + fl) * 0.3;
        wave_x += cursor_warp * 0.003 * sin(uv.y * 2.0 + fl);

        // Window bending — aurora wraps around windows
        wave_x += win_influence * sin(uv.y * 5.0 + t + fl * 2.0) * 0.4;

        // Curtain intensity from fbm
        float curtain = fbm(wave_x * 3.0 + t * 0.2);
        curtain = smoothstep(0.3, 0.7, curtain);

        // Vertical shimmer
        float shimmer = fbm(uv.y * 8.0 + t * 1.5 + fl * 3.0);
        shimmer = smoothstep(0.35, 0.65, shimmer);

        float intensity = curtain * shimmer * vert;

        // Brighter near windows
        intensity *= 1.0 + win_influence * 1.5;

        // Focused window crown
        if (iWindow.z > 0.0) {
            vec2 fw_top = vec2(iWindow.x + iWindow.z * 0.5, iWindow.y + iWindow.w);
            float crown_dist = length(fc - fw_top);
            float crown = exp(-crown_dist * 0.003) * 0.5;
            crown *= smoothstep(0.0, 1.0, iTransition);
            intensity += crown * curtain;
        }

        // Color from palette — each layer picks a different chromatic color
        int ci = 1 + (layer * 2) % 6;
        vec3 layer_col = (iPaletteSize > ci) ? iPalette[ci] : vec3(0.2, 0.8, 0.4);

        aurora_total += intensity * (0.7 - fl * 0.1);
        aurora_color += layer_col * intensity * (0.7 - fl * 0.1);
    }

    // Normalize and apply
    if (aurora_total > 0.001) {
        vec3 final_aurora = aurora_color / aurora_total;
        col = mix(col, final_aurora, aurora_total * 0.6);
    }

    // Subtle window outlines
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0) continue;
        vec2 center = win.xy + win.zw * 0.5;
        vec2 half_size = win.zw * 0.5;
        vec2 q = abs(fc - center) - half_size;
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        float edge = 1.0 - smoothstep(0.0, 2.0, abs(d));
        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, 1.0 - smoothstep(0.0, 1.0, iTransition));
        col += (iPaletteSize > 0 ? iPaletteFg : vec3(0.5)) * edge * mix(0.04, 0.12, focus_amt);
    }

    // Soft vignette
    col *= 1.0 - 0.15 * length(uv - 0.5);

    fragColor = vec4(col, 1.0);
}
