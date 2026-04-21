#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform int iFocusedIndex;
uniform int iPrevIndex;
uniform float iPrevAlpha;
uniform float iTransition;

// [0] = x, y, scale, facing  [1] = u0, v0, u1, v1
// [2] = text_len, timer, duration, 0  [3..] = packed chars (4 per vec4)
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

// 4x5 embedded pixel font — uppercase A-Z, space, ! ? .
int fontData(int ascii) {
    if (ascii == 32) return 0;       // space
    if (ascii == 33) return 279556;  // !
    if (ascii == 46) return 4;       // .
    if (ascii == 63) return 430596;  // ?
    if (ascii < 65 || ascii > 90) return 0;
    int d[26];
    d[0]  = 434073;  d[1]  = 958110;  d[2]  = 493711;  d[3]  = 956830;
    d[4]  = 1019535; d[5]  = 1019528; d[6]  = 494487;  d[7]  = 630681;
    d[8]  = 410694;  d[9]  = 201110;  d[10] = 634025;  d[11] = 559247;
    d[12] = 655257;  d[13] = 647097;  d[14] = 432534;  d[15] = 958088;
    d[16] = 432481;  d[17] = 958121;  d[18] = 495390;  d[19] = 1000516;
    d[20] = 629142;  d[21] = 629094;  d[22] = 630774;  d[23] = 616041;
    d[24] = 615492;  d[25] = 992399;
    return d[ascii - 65];
}

bool fontPixel(int ascii, int px, int py) {
    int bits = fontData(ascii);
    int row = (4 - py) * 4 + (3 - px);
    return ((bits >> row) & 1) == 1;
}

// 5x5 emote bitmaps (25 bits packed into int)
// Row 0 (top) is bits 24-20, row 4 (bottom) is bits 4-0
int emoteData(int etype) {
    if (etype == 1) return 11533764; // heart:    .#.#. ##### ##### .###. ..#..
    if (etype == 2) return 4685252;  // star:     ..#.. .###. ##### .###. ..#..
    if (etype == 3) return 32575775; // Z:        ##### ...#. ..#.. .#... #####
    if (etype == 4) return 4329476;  // !:        ..#.. ..#.. ..#.. ..... ..#..
    if (etype == 5) return 6427392;  // note:     ..##. ..#.. ..#.. ##... .....
    if (etype == 6) return 15243268; // ?:        .###. #...# ..##. ..... ..#..
    return 0;
}

bool emotePixel(int etype, int px, int py) {
    int bits = emoteData(etype);
    int idx = (4 - py) * 5 + (4 - px);
    return ((bits >> idx) & 1) == 1;
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
        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iPrevAlpha));
        col += (iPaletteSize > 0 ? iPaletteFg : vec3(0.5)) * edge * mix(0.05, 0.15, focus_amt);
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

        float sw = 32.0 * scale;
        float sh = 32.0 * scale;

        vec2 local = fc - vec2(bx - sw * 0.5, by);
        if (facing < 0.0) local.x = sw - local.x;

        if (local.x >= 0.0 && local.x < sw && local.y >= 0.0 && local.y < sh) {
            float lu = local.x / sw;
            float lv = 1.0 - local.y / sh;

            vec2 tex_uv = vec2(mix(u0, u1, lu), mix(v0, v1, lv));
            vec4 texel = texture(iSprite, tex_uv);

            if (texel.a > 0.1) {
                // Recolor to palette
                float lum = dot(texel.rgb, vec3(0.299, 0.587, 0.114));
                if (iPaletteSize > 5) {
                    vec3 dark = iPalette[0];
                    vec3 mid = iPalette[5];
                    vec3 light = iPaletteFg;
                    col = lum < 0.5
                        ? mix(dark, mid, lum * 2.0)
                        : mix(mid, light, (lum - 0.5) * 2.0);
                } else {
                    col = texel.rgb;
                }
            }
        }

        // Shadow
        float sy = fc.y - by;
        float sx = abs(fc.x - bx);
        if (sy < 0.0 && sy > -4.0 && sx < sw * 0.35) {
            col = mix(col, vec3(0.0), smoothstep(-4.0, 0.0, sy) * 0.15 * smoothstep(sw * 0.35, 0.0, sx));
        }

        // --- Speech bubble ---
        if (iParticleCount > 2) {
            float text_len = iParticles[2].x;
            float timer = iParticles[2].y;
            float duration = iParticles[2].z;

            if (text_len > 0.0 && timer > 0.0) {
                float font_scale = 2.0;
                float char_w = 4.0 * font_scale;
                float char_h = 5.0 * font_scale;
                float spacing = 1.0 * font_scale;
                float pad = 4.0 * font_scale;
                int num_chars = int(text_len);

                float bubble_w = float(num_chars) * (char_w + spacing) - spacing + pad * 2.0;
                float bubble_h = char_h + pad * 2.0;
                float tail_h = 6.0;

                // Bubble positioned above buddy
                vec2 bubble_center = vec2(bx, by + sh + tail_h + bubble_h * 0.5 + 4.0);

                // Fade in/out
                float alpha = smoothstep(0.0, 0.3, timer) * smoothstep(0.0, 0.5, duration - (duration - timer));
                alpha *= smoothstep(0.0, 0.3, timer); // fade out at end

                // Bubble background (rounded rect)
                float bd = sdBox(fc, bubble_center, vec2(bubble_w * 0.5, bubble_h * 0.5));
                float bubble_shape = 1.0 - smoothstep(-1.0, 1.0, bd - 4.0);

                // Tail triangle
                vec2 tail_top = vec2(bx, bubble_center.y - bubble_h * 0.5);
                vec2 tail_bot = vec2(bx, by + sh + 4.0);
                float tail_dist = length(fc - mix(tail_bot, tail_top, clamp((fc.y - tail_bot.y) / (tail_top.y - tail_bot.y + 0.1), 0.0, 1.0)));
                float tail_width = mix(2.0, 6.0, clamp((fc.y - tail_bot.y) / (tail_top.y - tail_bot.y + 0.1), 0.0, 1.0));
                float tail_shape = 1.0 - smoothstep(0.0, tail_width, tail_dist);

                float full_shape = max(bubble_shape, tail_shape);

                vec3 bubble_bg = (iPaletteSize > 0) ? iPalette[0] : vec3(0.15);
                vec3 text_col = (iPaletteSize > 5) ? iPalette[5] : vec3(0.8);

                col = mix(col, bubble_bg, full_shape * alpha * 0.9);

                // Render text
                vec2 text_origin = vec2(
                    bubble_center.x - bubble_w * 0.5 + pad,
                    bubble_center.y - char_h * 0.5
                );

                for (int ci = 0; ci < num_chars && ci < 20; ci++) {
                    // Read char from packed uniforms
                    int slot = 3 + ci / 4;
                    int sub = ci - (ci / 4) * 4;
                    float char_code;
                    if (sub == 0) char_code = iParticles[slot].x;
                    else if (sub == 1) char_code = iParticles[slot].y;
                    else if (sub == 2) char_code = iParticles[slot].z;
                    else char_code = iParticles[slot].w;

                    int ascii = int(char_code);

                    vec2 char_pos = text_origin + vec2(float(ci) * (char_w + spacing), 0.0);
                    vec2 lp = (fc - char_pos) / font_scale;

                    if (lp.x >= 0.0 && lp.x < 4.0 && lp.y >= 0.0 && lp.y < 5.0) {
                        int px = int(lp.x);
                        int py = 4 - int(lp.y); // flip Y for screen coords
                        if (fontPixel(ascii, px, py)) {
                            col = mix(col, text_col, alpha);
                        }
                    }
                }
            }
        }
    }

    // --- Emote particles (slots 9-14) ---
    for (int ei = 9; ei < min(iParticleCount, 15); ei++) {
        float etype = iParticles[ei].x;
        float ex = iParticles[ei].y;
        float ey = iParticles[ei].z;
        float alpha = iParticles[ei].w;

        if (etype < 0.5 || alpha < 0.01) continue;

        float emote_scale = 2.0;
        float ew = 5.0 * emote_scale;
        float eh = 5.0 * emote_scale;

        vec2 lp = (fc - vec2(ex - ew * 0.5, ey)) / emote_scale;
        if (lp.x >= 0.0 && lp.x < 5.0 && lp.y >= 0.0 && lp.y < 5.0) {
            int px = int(lp.x);
            int py = 4 - int(lp.y);
            if (emotePixel(int(etype), px, py)) {
                // Each emote type uses a different palette color
                int ci = 1 + int(mod(etype, 6.0));
                vec3 emote_col = (iPaletteSize > ci) ? iPalette[ci] : vec3(0.9);
                col = mix(col, emote_col, alpha);
            }
        }
    }

    col *= 1.0 - 0.2 * length(uv - 0.5);
    fragColor = vec4(col, 1.0);
}
