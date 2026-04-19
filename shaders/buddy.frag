#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;

// Buddy: [0] = x, y, scale, facing  [1] = u0, v0, u1, v1
uniform vec4 iParticles[300];
uniform int iParticleCount;
uniform sampler2D iSprite;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

float sdBox(vec2 p, vec2 center, vec2 half_size) {
    vec2 d = abs(p - center) - half_size;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02, 0.01, 0.03);
    vec3 col = bg;

    // Window outlines
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0) continue;
        float dist = sdBox(fc, win.xy + win.zw * 0.5, win.zw * 0.5);
        float edge = 1.0 - smoothstep(0.0, 2.0, abs(dist));
        bool focused = abs(win.x - iWindow.x) < 1.0 && abs(win.y - iWindow.y) < 1.0;
        col += (iPaletteSize > 0 ? iPaletteFg : vec3(0.5)) * edge * (focused ? 0.15 : 0.05);
    }

    // Buddy sprite
    if (iParticleCount >= 2) {
        float bx = iParticles[0].x;
        float by = iParticles[0].y;
        float scale = iParticles[0].z;
        float facing = iParticles[0].w;

        float u0 = iParticles[1].x;
        float v0 = iParticles[1].y;
        float u1 = iParticles[1].z;
        float v1 = iParticles[1].w;

        // Sprite size on screen (32x32 cells)
        float sw = 32.0 * scale;
        float sh = 32.0 * scale;

        // Local coords (origin at bottom-center)
        vec2 local = fc - vec2(bx - sw * 0.5, by);

        // Flip X if facing left
        if (facing < 0.0) local.x = sw - local.x;

        if (local.x >= 0.0 && local.x < sw && local.y >= 0.0 && local.y < sh) {
            // Normalize to [0,1] within the sprite cell
            float lu = local.x / sw;
            float lv = 1.0 - local.y / sh; // flip Y: GL bottom-up → texture top-down

            // Map to sheet UV
            vec2 tex_uv = vec2(
                mix(u0, u1, lu),
                mix(v0, v1, lv)
            );

            vec4 texel = texture(iSprite, tex_uv);

            if (texel.a > 0.1) {
                col = texel.rgb;
            }
        }

        // Shadow
        float sy = fc.y - by;
        float sx = abs(fc.x - bx);
        if (sy < 0.0 && sy > -4.0 && sx < sw * 0.35) {
            col = mix(col, vec3(0.0), smoothstep(-4.0, 0.0, sy) * 0.15 * smoothstep(sw * 0.35, 0.0, sx));
        }
    }

    col *= 1.0 - 0.2 * length(uv - 0.5);
    fragColor = vec4(col, 1.0);
}
