#version 300 es
precision highp float;

// A skein of thin lines across the screen (src/effects/skein.zig). A
// ribbon is so many lines strung evenly between two curves, its edges,
// which are worked out on the CPU at a few hundred points across the
// screen and handed over as a texture, with their slopes. A pixel finds
// the lines of each ribbon nearest it and how far from them it is.
//
// The skein is drawn only where there is room to see it. Through the
// narrow gaps between tiled windows, or between a window and the edge of
// the screen, a few thin lines crossing show as flickering hatch marks;
// there the lines fade to nothing and the gap is plain background.
uniform vec3 iResolution;

uniform vec4 iWindows[32];   // each window on screen: x, y, w, h px, up from the bottom left
uniform int iWindowCount;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

const int SAMPLES = 768;
const int RIBBONS = 2;
// A gap this narrow, as a part of the screen's height, shows none of the
// skein, and one this wide shows all of it.
const float NARROW = 0.012;
const float WIDE = 0.075;

uniform sampler2D iSkeinEdges;  // a row a ribbon: the first edge's height px, the second's, the slope of each
uniform vec3 iSkeinLook;        // lines in the first ribbon, in the second, a line's width px
uniform vec3 iSkeinInk;         // palette slots of the color at the left and at the right, how far both are paled

out vec4 fragColor;

// How much of the pixel the lines of ribbon `r` cover.
float ribbon(int r, float lines, vec2 p) {
    // The edges here, between the two points to either side.
    float fx = clamp(p.x / iResolution.x, 0.0, 1.0) * float(SAMPLES - 1);
    int i = min(int(fx), SAMPLES - 2);
    vec4 e = mix(texelFetch(iSkeinEdges, ivec2(i, r), 0), texelFetch(iSkeinEdges, ivec2(i + 1, r), 0), fx - float(i));

    // Line k of n + 1 is the part k / n of the way from the first edge
    // to the second. The one nearest this pixel, and the one to either
    // side of it: where the lines crowd together more than that are
    // within reach, and the three already cover the pixel.
    float span = e.y - e.x;
    float n = lines - 1.0;
    float safe = abs(span) < 1e-3 ? 1e-3 : span;
    float nearest = clamp(floor((p.y - e.x) / safe * n + 0.5), 0.0, n);
    // Where the lines crowd they are drawn finer, so they stay lines
    // until they are a pixel apart, and only then run together.
    float here = e.z + nearest / n * (e.w - e.z);
    float apart = abs(span) / n * inversesqrt(1.0 + here * here);
    float width = clamp(0.62 * apart, 1.0, iSkeinLook.z);
    float cover = 0.0;
    for (int j = -1; j <= 1; j++) {
        float k = nearest + float(j);
        if (k < 0.0 || k > n) continue;
        float t = k / n;
        float slope = e.z + t * (e.w - e.z);
        // Straight up to the line, turned into the shortest way to it.
        float d = abs(p.y - (e.x + t * span)) * inversesqrt(1.0 + slope * slope);
        cover += clamp(0.5 * width + 0.5 - d, 0.0, 1.0);
    }
    return min(cover, 1.0);
}

// How much room there is to see the skein at `p`: nothing in a gap
// narrower than NARROW, all in one wider than WIDE. The gap is how far it
// is across the open space the pixel is in, from the window or screen
// edge on one side to the one on the other, the lesser of across and up.
float room(vec2 p) {
    float left = 0.0, right = iResolution.x;
    float below = 0.0, above = iResolution.y;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 w = iWindows[i];
        if (w.z < 1.0 || w.w < 1.0) continue;
        vec2 lo = w.xy, hi = w.xy + w.zw;
        bool in_x = p.x > lo.x && p.x < hi.x;
        bool in_y = p.y > lo.y && p.y < hi.y;
        // Under a window it is not seen at all.
        if (in_x && in_y) return 0.0;
        if (in_y) {
            if (hi.x <= p.x) left = max(left, hi.x);
            else right = min(right, lo.x);
        }
        if (in_x) {
            if (hi.y <= p.y) below = max(below, hi.y);
            else above = min(above, lo.y);
        }
    }
    float gap = min(right - left, above - below) / iResolution.y;
    return smoothstep(NARROW, WIDE, gap);
}

vec3 slot(float s, vec3 otherwise) {
    int i = int(s);
    return (iPaletteSize == 0 || s < 0.0 || i >= iPaletteSize) ? otherwise : iPalette[i];
}

void main() {
    vec2 p = gl_FragCoord.xy;
    float seen = room(p);
    float cover = seen > 0.0 ? seen * max(ribbon(0, iSkeinLook.x, p), ribbon(1, iSkeinLook.y, p)) : 0.0;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.118, 0.118, 0.180);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    // One color at the left running into another at the right.
    float along = smoothstep(0.08, 0.92, p.x / iResolution.x);
    vec3 ink = mix(slot(iSkeinInk.x, vec3(0.85, 0.70, 0.95)), slot(iSkeinInk.y, vec3(0.55, 0.78, 0.98)), along);
    ink = mix(ink, fg, iSkeinInk.z);
    fragColor = vec4(mix(bg, ink, cover), 1.0);
}
