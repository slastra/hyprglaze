#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;

// [0] = (band0, band1, band2, band3)  — sub-bass, bass, low-mid, mid
// [1] = (band4, band5, beat, flight_time) — high-mid, high, beat, accumulated time
uniform vec4 iParticles[300];
uniform int iParticleCount;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float getBand(int i) {
    if (i < 4) {
        if (i == 0) return iParticles[0].x;
        if (i == 1) return iParticles[0].y;
        if (i == 2) return iParticles[0].z;
        return iParticles[0].w;
    }
    if (i == 4) return iParticles[1].x;
    return iParticles[1].y;
}

float getBeat() { return iParticles[1].z; }
float getFlightTime() { return iParticles[1].w; }

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

    vec2 origin = iMouse.xy;
    float beat = getBeat();
    float flight_time = getFlightTime();

    for (int layer = 0; layer < 4; layer++) {
        float fl = float(layer);
        float layer_speed = 0.06 + fl * 0.05;
        float num_stars = 80.0 + fl * 40.0;
        float star_max_r = 2.0 + fl * 1.5;

        for (float si = 0.0; si < num_stars; si += 1.0) {
            float seed = si + fl * 200.0;
            float angle = hash(vec2(seed, 1.0)) * 6.28318;
            float phase = hash(vec2(seed, 2.0));
            float star_bright = hash(vec2(seed, 3.0));

            // Each star is assigned a palette color (1-6) and responds to that band
            int color_idx = int(mod(seed, 6.0));
            float band_energy = getBand(color_idx);

            float t = fract(phase + flight_time * layer_speed);

            float max_dist = length(iResolution.xy) * 0.8;
            float r = t * t * max_dist;

            vec2 dir = vec2(cos(angle), sin(angle));
            vec2 star_pos = origin + dir * r;

            float wd = windowSDF(star_pos);
            if (wd < 0.0) continue;

            vec2 diff = fc - star_pos;

            // Trail length driven by speed + this star's band energy
            float trail_len = 1.0 + t * t * (10.0 + band_energy * 15.0);
            float along = dot(diff, dir);
            float perp = length(diff - dir * along);
            float head = length(vec2(max(along, 0.0), perp));
            float tail = length(vec2(along / trail_len, perp));
            float dist = (along > 0.0) ? head : tail;

            // Star size pulses with its band energy
            float size = star_max_r * (0.2 + t * 0.8) * (0.5 + star_bright * 0.5);
            size *= 1.0 + band_energy * 0.8;

            // Fade in at birth, fade out before reset — hides the teleport
            float brightness = smoothstep(0.0, 0.1, t) * smoothstep(1.0, 0.9, t) * star_bright;
            // Brightness boost from band energy
            brightness *= 1.0 + band_energy * 1.5;

            float twinkle = 0.75 + 0.25 * sin(iTime * (3.0 + star_bright * 5.0) + seed);

            float core = 1.0 - smoothstep(0.0, size * 0.6, dist);
            float intensity = core * brightness * twinkle;
            intensity *= smoothstep(0.0, 30.0, wd);

            // Color from palette based on assigned band
            int ci = 1 + color_idx;
            vec3 star_col = (iPaletteSize > ci) ? iPalette[ci] : vec3(0.7, 0.8, 1.0);

            // Hot stars (high energy) shift toward foreground
            if (band_energy > 0.5) {
                star_col = mix(star_col, (iPaletteSize > 0) ? iPaletteFg : vec3(1.0),
                    (band_energy - 0.5) * 0.6);
            }

            col += star_col * intensity;
        }
    }

    // Beat flash — brief screen tint
    col += bg * beat * 0.3;

    // Focused window nebula
    if (iWindow.z > 0.0) {
        vec2 win_center = iWindow.xy + iWindow.zw * 0.5;
        float dist = length(fc - win_center);
        float nebula = exp(-dist * 0.003);
        vec3 nebula_col = (iPaletteSize > 5) ? iPalette[5] : vec3(0.3, 0.2, 0.5);
        col += nebula_col * nebula * 0.05 * smoothstep(0.0, 1.0, iTransition);
    }

    // Window outlines
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
