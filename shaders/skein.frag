#version 300 es
precision highp float;

// A skein of thin lines across the screen (src/effects/skein.zig). A
// ribbon is so many lines strung evenly between two curves, its edges,
// which are worked out on the CPU at a few hundred points across the
// screen and handed over as a texture, with their slopes. A pixel finds
// the lines of each ribbon nearest it and how far from them it is.
uniform vec3 iResolution;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

const int SAMPLES = 768;
const int RIBBONS = 2;

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

vec3 slot(float s, vec3 otherwise) {
    int i = int(s);
    return (iPaletteSize == 0 || s < 0.0 || i >= iPaletteSize) ? otherwise : iPalette[i];
}

void main() {
    vec2 p = gl_FragCoord.xy;
    float cover = max(ribbon(0, iSkeinLook.x, p), ribbon(1, iSkeinLook.y, p));

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.118, 0.118, 0.180);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    // One color at the left running into another at the right.
    float along = smoothstep(0.08, 0.92, p.x / iResolution.x);
    vec3 ink = mix(slot(iSkeinInk.x, vec3(0.85, 0.70, 0.95)), slot(iSkeinInk.y, vec3(0.55, 0.78, 0.98)), along);
    ink = mix(ink, fg, iSkeinInk.z);
    fragColor = vec4(mix(bg, ink, cover), 1.0);
}
