#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;      // focused window: xy = bottom-left, zw = size
uniform vec4 iWindows[32];  // all visible windows
uniform int iWindowCount;
uniform float iTransition;  // 0 = focus just changed, 1 = settled

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

vec3 samplePalette(float t) {
    if (iPaletteSize <= 0) return vec3(t);
    float idx = t * float(iPaletteSize - 1);
    int i0 = int(floor(idx));
    int i1 = min(i0 + 1, iPaletteSize - 1);
    float frac = idx - float(i0);
    return mix(iPalette[i0], iPalette[i1], frac);
}

// Signed distance to a rounded rectangle
float sdRoundBox(vec2 p, vec2 center, vec2 half_size, float radius) {
    vec2 d = abs(p - center) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

// Compute glow contribution from a single window
float windowGlow(vec2 fragCoord, vec4 win, float radius, float glow_range) {
    vec2 center = win.xy + win.zw * 0.5;
    vec2 half_size = win.zw * 0.5;
    float dist = sdRoundBox(fragCoord, center, half_size, radius);
    return 1.0 - smoothstep(0.0, glow_range, dist);
}

float windowEdge(vec2 fragCoord, vec4 win, float radius) {
    vec2 center = win.xy + win.zw * 0.5;
    vec2 half_size = win.zw * 0.5;
    float dist = sdRoundBox(fragCoord, center, half_size, radius);
    return 1.0 - smoothstep(0.0, 2.5, abs(dist));
}

void main() {
    vec2 fragCoord = gl_FragCoord.xy;
    vec2 uv = fragCoord / iResolution.xy;

    // Background
    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02, 0.02, 0.06);
    vec3 col = bg;

    float corner_radius = 10.0;

    // Pick colors for focused vs unfocused windows
    float cycle = fract(iTime * 0.08);
    vec3 focused_color = (iPaletteSize > 0) ? samplePalette(cycle) : vec3(0.2, 0.4, 1.0);
    vec3 unfocused_color = (iPaletteSize > 0) ? samplePalette(fract(cycle + 0.5)) : vec3(0.15, 0.2, 0.35);
    vec3 edge_color = (iPaletteSize > 0) ? iPaletteFg : vec3(0.8, 0.85, 0.9);

    // --- Unfocused windows: subtle glow ---
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0 || win.w < 1.0) continue;

        // Check if this is the focused window — skip, handle separately
        if (abs(win.x - iWindow.x) < 1.0 && abs(win.y - iWindow.y) < 1.0 &&
            abs(win.z - iWindow.z) < 1.0 && abs(win.w - iWindow.w) < 1.0) continue;

        float glow = windowGlow(fragCoord, win, corner_radius, 60.0);
        float edge = windowEdge(fragCoord, win, corner_radius);

        col += unfocused_color * glow * 0.08;
        col += edge_color * edge * 0.15;
    }

    // --- Focused window: stronger glow + transition effects ---
    if (iWindow.z > 1.0 && iWindow.w > 1.0) {
        vec2 win_center = iWindow.xy + iWindow.zw * 0.5;

        float glow = windowGlow(fragCoord, iWindow, corner_radius, 120.0);
        float edge = windowEdge(fragCoord, iWindow, corner_radius);

        // Transition effects
        float transition_inv = 1.0 - iTransition;
        float aura_boost = 1.0 + transition_inv * 2.0;
        float edge_boost = 1.0 + transition_inv * 3.0;

        // Expanding ring on focus change
        float ring_radius = iTransition * max(iResolution.x, iResolution.y) * 0.4;
        float ring_dist = abs(length(fragCoord - win_center) - ring_radius);
        float focus_ring = smoothstep(6.0, 0.0, ring_dist) * transition_inv;

        // Scan lines
        float angle = atan(fragCoord.y - win_center.y, fragCoord.x - win_center.x);
        float scan = 0.5 + 0.5 * sin(angle * 30.0 + iTime * 3.0);
        float scan_mask = glow * (1.0 - smoothstep(0.0, 40.0,
            sdRoundBox(fragCoord, win_center, iWindow.zw * 0.5, corner_radius))) * 0.1;

        col += focused_color * glow * 0.2 * aura_boost;
        col += focused_color * scan * scan_mask;
        col += edge_color * edge * 0.4 * edge_boost;
        col += focused_color * focus_ring * 0.3;

        // Cursor proximity boost near focused window
        float cursor_dist = distance(fragCoord, iMouse.xy);
        col += focused_color * smoothstep(200.0, 0.0, cursor_dist) * glow * 0.25;
    }

    // Vignette
    col *= 1.0 - 0.25 * length(uv - 0.5);

    fragColor = vec4(col, 1.0);
}
