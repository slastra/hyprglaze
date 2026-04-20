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

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

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

    // Vanishing point follows cursor
    vec2 origin = iMouse.xy;

    // --- Radial starfield: stars fly outward from origin ---
    for (int layer = 0; layer < 4; layer++) {
        float fl = float(layer);
        float layer_speed = 0.15 + fl * 0.12;
        float num_stars = 80.0 + fl * 40.0;
        float star_max_r = 2.0 + fl * 1.5;

        for (float si = 0.0; si < num_stars; si += 1.0) {
            // Deterministic star identity
            float seed = si + fl * 200.0;
            float angle = hash(vec2(seed, 1.0)) * 6.28318;
            float phase = hash(vec2(seed, 2.0)); // where in the flight path
            float star_bright = hash(vec2(seed, 3.0));

            // Star flies outward over time — phase cycles 0->1
            float t = fract(phase + iTime * layer_speed);

            // Radial distance from origin grows with t (accelerating)
            float max_dist = length(iResolution.xy) * 0.8;
            float r = t * t * max_dist; // quadratic: slow near origin, fast at edges

            // Star position
            vec2 dir = vec2(cos(angle), sin(angle));
            vec2 star_pos = origin + dir * r;

            // Skip if inside window
            float wd = windowSDF(star_pos);
            if (wd < 0.0) continue;

            // Distance from pixel to star
            vec2 diff = fc - star_pos;

            // Streak: elongate along radial direction based on speed (t)
            float streak = 1.0 + t * t * 8.0; // more streak as star flies outward
            float along = dot(diff, dir);
            float perp = length(diff - dir * along);
            float dist = length(vec2(along / streak, perp));

            // Star size grows as it approaches (parallax)
            float size = star_max_r * (0.2 + t * 0.8) * (0.5 + star_bright * 0.5);

            // Brightness: fades in, peaks, stays
            float brightness = smoothstep(0.0, 0.1, t) * star_bright;

            // Twinkle
            float twinkle = 0.75 + 0.25 * sin(iTime * (3.0 + star_bright * 5.0) + seed);

            // Render
            float glow = 1.0 - smoothstep(0.0, size * 3.0, dist);
            float core = 1.0 - smoothstep(0.0, size * 0.4, dist);
            float intensity = (glow * 0.25 + core * 0.75) * brightness * twinkle;

            // Dim near windows
            intensity *= smoothstep(0.0, 30.0, wd);

            // Color from palette
            int ci = 1 + int(mod(seed, 6.0));
            vec3 star_col = (iPaletteSize > ci) ? iPalette[ci] : vec3(0.7, 0.8, 1.0);
            if (star_bright > 0.85) {
                star_col = mix(star_col, (iPaletteSize > 0) ? iPaletteFg : vec3(1.0), 0.5);
            }

            col += star_col * intensity;
        }
    }

    // --- Focused window nebula glow ---
    if (iWindow.z > 0.0) {
        vec2 win_center = iWindow.xy + iWindow.zw * 0.5;
        float dist = length(fc - win_center);
        float nebula = exp(-dist * 0.003);
        vec3 nebula_col = (iPaletteSize > 5) ? iPalette[5] : vec3(0.3, 0.2, 0.5);
        col += nebula_col * nebula * 0.05 * smoothstep(0.0, 1.0, iTransition);
    }

    // --- Window outlines ---
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0) continue;
        vec2 center = win.xy + win.zw * 0.5;
        vec2 half_size = win.zw * 0.5;
        vec2 q = abs(fc - center) - half_size;
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        float edge = 1.0 - smoothstep(0.0, 2.0, abs(d));
        bool focused = abs(win.x - iWindow.x) < 1.0 && abs(win.y - iWindow.y) < 1.0;
        col += (iPaletteSize > 0 ? iPaletteFg : vec3(0.5)) * edge * (focused ? 0.12 : 0.04);
    }

    col *= 1.0 - 0.12 * length(uv - 0.5);
    fragColor = vec4(col, 1.0);
}
