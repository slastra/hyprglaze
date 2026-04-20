#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;

// [0..15] = frequency bins (4 per vec4, 64 total)
// [16..31] = peak hold values
uniform vec4 iParticles[300];
uniform int iParticleCount;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

float getBin(int i) {
    int slot = i / 4;
    int sub = i - slot * 4;
    if (sub == 0) return iParticles[slot].x;
    if (sub == 1) return iParticles[slot].y;
    if (sub == 2) return iParticles[slot].z;
    return iParticles[slot].w;
}

float getPeak(int i) {
    int slot = 16 + i / 4;
    int sub = i - (i / 4) * 4;
    if (sub == 0) return iParticles[slot].x;
    if (sub == 1) return iParticles[slot].y;
    if (sub == 2) return iParticles[slot].z;
    return iParticles[slot].w;
}

float sdBox(vec2 p, vec2 center, vec2 half_size) {
    vec2 d = abs(p - center) - half_size;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.01);
    vec3 col = bg;

    // Compute bass energy for global pulse
    float bass = 0.0;
    for (int i = 0; i < 8; i++) bass += getBin(i);
    bass /= 8.0;

    // --- Bottom bar visualizer ---
    float bar_region = 0.25; // bottom 25% of screen
    float bar_y = uv.y / bar_region;

    if (uv.y < bar_region) {
        // Which bin?
        int bin_idx = int(uv.x * 64.0);
        if (bin_idx >= 64) bin_idx = 63;

        float val = getBin(bin_idx);
        float peak = getPeak(bin_idx);

        // Bar height
        float bar_h = val;
        float peak_h = peak;

        // Color by frequency - low = warm, high = cool
        int ci = 1 + (bin_idx * 5 / 64) % 6;
        vec3 bar_col = (iPaletteSize > ci) ? iPalette[ci] : vec3(0.5);

        // Main bar
        if (bar_y < bar_h) {
            float intensity = 0.7 + 0.3 * (1.0 - bar_y / max(bar_h, 0.01));
            col = bar_col * intensity;
        }

        // Peak line
        if (abs(bar_y - peak_h) < 0.02) {
            col = mix(col, iPaletteSize > 0 ? iPaletteFg : vec3(0.9), 0.8);
        }

        // Bar separation lines
        float bar_fract = fract(uv.x * 64.0);
        if (bar_fract < 0.08 || bar_fract > 0.92) {
            col *= 0.5;
        }
    }

    // --- Circular visualizer around focused window ---
    if (iWindow.z > 0.0) {
        vec2 win_center = iWindow.xy + iWindow.zw * 0.5;
        float win_radius = length(iWindow.zw * 0.5) + 20.0;
        float dist = length(fc - win_center);

        // Ring region
        float ring_width = 60.0 + bass * 30.0;
        if (dist > win_radius && dist < win_radius + ring_width) {
            // Angle -> bin
            float angle = atan(fc.y - win_center.y, fc.x - win_center.x);
            float norm_angle = (angle + 3.14159) / 6.28318; // 0-1
            int bin_idx = int(norm_angle * 64.0);
            if (bin_idx >= 64) bin_idx = 63;

            float val = getBin(bin_idx);
            float ring_pos = (dist - win_radius) / ring_width;

            if (ring_pos < val) {
                int ci = 1 + (bin_idx * 5 / 64) % 6;
                vec3 ring_col = (iPaletteSize > ci) ? iPalette[ci] : vec3(0.5);
                float fade = smoothstep(win_radius + ring_width, win_radius, dist);
                col = mix(col, ring_col, 0.6 * (1.0 - ring_pos));
            }

            // Ring outline
            float ring_edge = 1.0 - smoothstep(0.0, 3.0, abs(dist - win_radius));
            col = mix(col, iPaletteSize > 0 ? iPaletteFg : vec3(0.5), ring_edge * 0.15);
        }
    }

    // --- Cursor ripple ---
    float cursor_dist = length(fc - iMouse.xy);
    float ripple_r = 80.0 + bass * 60.0;
    float ripple = 1.0 - smoothstep(0.0, 3.0, abs(cursor_dist - ripple_r));
    col += (iPaletteSize > 3 ? iPalette[3] : vec3(0.3)) * ripple * 0.2;

    // --- Window outlines pulse with bass ---
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0) continue;
        float dist = sdBox(fc, win.xy + win.zw * 0.5, win.zw * 0.5);
        float edge = 1.0 - smoothstep(0.0, 2.0 + bass * 2.0, abs(dist));
        bool focused = abs(win.x - iWindow.x) < 1.0 && abs(win.y - iWindow.y) < 1.0;
        float glow = focused ? 0.15 + bass * 0.15 : 0.04 + bass * 0.04;
        col += (iPaletteSize > 0 ? iPaletteFg : vec3(0.5)) * edge * glow;
    }

    // Vignette
    col *= 1.0 - 0.15 * length(uv - 0.5);

    fragColor = vec4(col, 1.0);
}
