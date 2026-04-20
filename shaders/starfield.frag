#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;       // xy = current pos, zw = previous pos (smoothed)
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

// Hash functions
float hash(vec2 p) {
    float h = dot(p, vec2(127.1, 311.7));
    return fract(sin(h) * 43758.5453);
}

vec2 hash2(vec2 p) {
    return vec2(hash(p), hash(p + vec2(37.0, 91.0)));
}

// SDF to nearest window (negative = inside)
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

// Gravitational lensing: offset star position toward nearest window edge
vec2 gravLens(vec2 p) {
    vec2 offset = vec2(0.0);
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0) continue;
        vec2 center = win.xy + win.zw * 0.5;
        vec2 half_size = win.zw * 0.5;
        vec2 q = abs(p - center) - half_size;
        float wd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
        float influence = 40.0 / (wd + 40.0);
        vec2 dir = normalize(center - p + 0.001);
        offset += dir * influence * 8.0;
    }
    return offset;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.01, 0.01, 0.02);
    vec3 col = bg;

    // Cursor velocity (iMouse.xy = current, approximate velocity from position delta)
    // We use iMouse for current position; velocity approximated from time derivatives
    vec2 cursor = iMouse.xy;
    // Velocity direction: stars flow away from cursor movement
    // We derive a drift from cursor position relative to screen center
    vec2 cursor_norm = (cursor / iResolution.xy - 0.5) * 2.0;
    float cursor_speed = length(cursor_norm);

    // Base drift direction (gentle when cursor is centered)
    vec2 drift = cursor_norm * 0.3;

    // --- Star layers ---
    for (int layer = 0; layer < 4; layer++) {
        float fl = float(layer);
        float depth = 1.0 + fl * 1.5; // parallax depth
        float grid_size = 50.0 + fl * 40.0; // cell size in pixels
        float star_size = (1.5 + fl * 1.0); // base star radius
        float speed = 0.2 + fl * 0.15;
        float brightness_mult = 0.5 + fl * 0.2;

        // Scroll offset from drift + time
        vec2 scroll = drift * iTime * speed * 60.0 + vec2(iTime * 8.0 * speed, 0.0);

        // Grid cell for this pixel
        vec2 shifted = fc + scroll / depth;
        vec2 cell = floor(shifted / grid_size);

        // Check 3x3 neighborhood for stars
        for (int dx = -1; dx <= 1; dx++) {
            for (int dy = -1; dy <= 1; dy++) {
                vec2 neighbor = cell + vec2(float(dx), float(dy));
                vec2 h = hash2(neighbor);

                // Star position in pixel space
                vec2 star_pixel = (neighbor + h) * grid_size - scroll / depth;

                // Gravitational lensing near windows
                star_pixel += gravLens(star_pixel);

                // Skip if inside any window
                float wd = windowSDF(star_pixel);
                if (wd < 0.0) continue;

                // Distance from this pixel to star
                vec2 diff = fc - star_pixel;

                // Streak effect: elongate along drift direction when moving
                float streak = 1.0 + cursor_speed * 4.0 * speed;
                vec2 streak_dir = normalize(drift + 0.001);
                float along = dot(diff, streak_dir);
                float perp = length(diff - streak_dir * along);
                float dist = length(vec2(along / streak, perp));

                // Star properties from hash
                float star_bright = hash(neighbor + vec2(53.0, 17.0));
                float twinkle = 0.7 + 0.3 * sin(iTime * (2.0 + star_bright * 4.0) + star_bright * 100.0);

                // Render
                float r = star_size * (0.5 + star_bright * 0.5);
                float glow = 1.0 - smoothstep(0.0, r * 3.0, dist);
                float core = 1.0 - smoothstep(0.0, r * 0.5, dist);

                float intensity = (glow * 0.3 + core * 0.7) * twinkle * brightness_mult * star_bright;

                // Fade near window edges (stars dim near gravity wells)
                intensity *= smoothstep(0.0, 30.0, wd);

                // Color: hash picks chromatic palette index
                int ci = 1 + int(mod(star_bright * 100.0, 6.0));
                vec3 star_col = (iPaletteSize > ci) ? iPalette[ci] : vec3(0.7, 0.8, 1.0);

                // Bright stars shift toward foreground color
                if (star_bright > 0.85) {
                    star_col = mix(star_col, (iPaletteSize > 0) ? iPaletteFg : vec3(1.0), 0.5);
                }

                col += star_col * intensity;
            }
        }
    }

    // --- Focused window nebula glow ---
    if (iWindow.z > 0.0) {
        vec2 win_center = iWindow.xy + iWindow.zw * 0.5;
        float dist = length(fc - win_center);
        float win_r = length(iWindow.zw * 0.5);
        float nebula = exp(-dist * 0.003 / (win_r * 0.01 + 0.5));
        vec3 nebula_col = (iPaletteSize > 5) ? iPalette[5] : vec3(0.3, 0.2, 0.5);
        col += nebula_col * nebula * 0.06 * smoothstep(0.0, 1.0, iTransition);
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

    // Vignette
    col *= 1.0 - 0.15 * length(uv - 0.5);

    fragColor = vec4(col, 1.0);
}
