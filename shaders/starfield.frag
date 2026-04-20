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

vec2 hash2(vec2 p) {
    return vec2(hash(p), hash(p + vec2(37.0, 91.0)));
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

    // Radial coordinates from cursor
    vec2 from_origin = fc - origin;
    float pixel_angle = atan(from_origin.y, from_origin.x);
    float pixel_dist = length(from_origin);
    float max_dist = length(iResolution.xy) * 1.3;

    // Grid-based starfield: tile in (angle, depth) space
    // Each pixel checks only its local cell — O(1) per star layer
    for (int layer = 0; layer < 4; layer++) {
        float fl = float(layer);
        float layer_speed = 0.06 + fl * 0.05;
        float star_max_r = 2.0 + fl * 1.5;

        // Tile the radial space into angular slices and depth rings
        float num_slices = 60.0 + fl * 20.0;
        float num_rings = 30.0 + fl * 10.0;
        float slice_size = 6.28318 / num_slices;
        float ring_size = max_dist / num_rings;

        // Flight offset — negative so stars stream outward from origin
        float depth_offset = -flight_time * layer_speed * max_dist;

        // Which cell is this pixel in?
        float depth_shifted = pixel_dist + depth_offset;
        float ring_idx = floor(depth_shifted / ring_size);
        float slice_idx = floor(pixel_angle / slice_size);

        // Check 3x3 neighborhood
        for (int dr = -1; dr <= 1; dr++) {
            for (int ds = -1; ds <= 1; ds++) {
                float ri = ring_idx + float(dr);
                float si = slice_idx + float(ds);

                // Star identity from cell coords + layer
                vec2 cell_id = vec2(ri, si + fl * 100.0);
                vec2 h = hash2(cell_id);

                // Star position in radial space
                float star_depth = (ri + h.x) * ring_size - depth_offset;
                float star_angle = (si + h.y) * slice_size;

                // Linear radial motion
                float star_r = star_depth;
                if (star_r < 0.0 || star_r > max_dist) continue;
                float t_life = star_r / max_dist;

                float warped_angle = star_angle;
                vec2 star_pos = origin + vec2(cos(warped_angle), sin(warped_angle)) * star_r;

                // Skip inside windows
                float wd = windowSDF(star_pos);
                if (wd < 0.0) continue;

                // Distance from this pixel to star
                vec2 diff = fc - star_pos;
                vec2 dir = vec2(cos(warped_angle), sin(warped_angle));

                // Band-reactive properties
                int color_idx = int(mod(hash(cell_id + vec2(53.0, 17.0)) * 6.0, 6.0));
                float band_energy = getBand(color_idx);
                float star_bright = hash(cell_id + vec2(7.0, 13.0));

                // Trail stretches dramatically at edges
                float t_norm = star_r / max_dist;
                float trail_len = 1.0 + t_life * t_life * (10.0 + band_energy * 8.0);
                float along = dot(diff, dir);
                float perp = length(diff - dir * along);
                float head = length(vec2(max(along, 0.0), perp));
                float tail = length(vec2(along / trail_len, perp));
                float dist = (along > 0.0) ? head : tail;

                // Size grows as stars approach — tiny at origin, large at edges
                float size = star_max_r * (0.1 + t_life * t_life * 2.0) * (0.5 + star_bright * 0.5);
                size *= 1.0 + band_energy * 0.6;

                // Brightness: fade edges, pulse with band
                float brightness = smoothstep(0.0, 0.05, t_life);
                brightness *= star_bright * (1.0 + band_energy * 1.2);

                float twinkle = 0.8 + 0.2 * sin(iTime * (3.0 + star_bright * 4.0) + hash(cell_id) * 100.0);

                // Crisp head
                float core = 1.0 - smoothstep(0.0, size * 0.5, head);
                // Soft trail behind
                float trail = 1.0 - smoothstep(0.0, size * 0.8, tail);
                float intensity = max(core, trail * 0.5) * brightness * twinkle;
                intensity *= smoothstep(0.0, 30.0, wd);

                int ci = 1 + color_idx;
                vec3 star_col = (iPaletteSize > ci) ? iPalette[ci] : vec3(0.7, 0.8, 1.0);
                if (band_energy > 0.5) {
                    star_col = mix(star_col, (iPaletteSize > 0) ? iPaletteFg : vec3(1.0),
                        (band_energy - 0.5) * 0.6);
                }

                col += star_col * intensity;
            }
        }
    }

    // Beat flash
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
