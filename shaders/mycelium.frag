#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;
uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;
uniform float iMycBands[6];
uniform float iMycOnsets[6];
uniform float iMycBeat;
uniform float iMycDownbeat;
uniform vec4 iMycGesture;
uniform vec4 iMycSegments[240];
uniform vec4 iMycMeta[60];
uniform int iMycSegmentCount;

out vec4 fragColor;

float hash11(float p) {
    return fract(sin(p * 127.1) * 43758.5453);
}

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float boxSdf(vec2 p, vec4 w) {
    vec2 q = abs(p - (w.xy + w.zw * .5)) - w.zw * .5;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

vec3 pal(int i, vec3 fallback) {
    return iPaletteSize > i ? iPalette[i] : fallback;
}

vec3 vivid(vec3 c, float s) {
    float l = dot(c, vec3(.299,.587,.114));
    return max(vec3(0), mix(vec3(l), c, s));
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;
    float bass = iMycBands[0] + iMycBands[1];
    float mids = .5 * (iMycBands[2] + iMycBands[3]);
    float treble = .5 * (iMycBands[4] + iMycBands[5]);
    float kick = iMycOnsets[0] + iMycOnsets[1];
    float beat = pow(max(0.0, 1.0 - iMycBeat * 4.0), 4.0);

    vec3 bg = iPaletteSize > 0 ? iPaletteBg : vec3(.006,.002,.017);
    vec3 violet = vivid(mix(pal(5, vec3(.48,.04,.82)), pal(13, vec3(.72,.12,1)), .52), 1.65);
    vec3 amber = vivid(mix(pal(1, vec3(1,.12,.02)), pal(3, vec3(1,.62,.03)), .55), 1.7);
    vec3 hot = mix(amber, iPaletteSize > 0 ? iPaletteFg : vec3(1), .34);

    float purpleHalo = 0.0;
    float amberFiber = 0.0;
    float whiteCore = 0.0;
    float nutrient = 0.0;
    float tips = 0.0;

    for (int i = 0; i < iMycSegmentCount && i < 240; i++) {
        vec4 seg = iMycSegments[i];
        vec2 lo = min(seg.xy, seg.zw) - 55.0;
        vec2 hi = max(seg.xy, seg.zw) + 55.0;
        if (fc.x < lo.x || fc.x > hi.x || fc.y < lo.y || fc.y > hi.y) continue;

        float rawMeta = iMycMeta[i >> 2][i & 3];
        bool terminal = rawMeta < 0.0;
        float generation = terminal ? -rawMeta - .05 : rawMeta;
        vec2 pa = fc - seg.xy;
        vec2 ba = seg.zw - seg.xy;
        float h = clamp(dot(pa, ba) / max(dot(ba, ba), .001), 0.0, 1.0);
        vec2 normal = vec2(-ba.y, ba.x) / max(length(ba), .001);
        float wobble = sin(h * 9.0 + float(i) * 1.71) * 1.35 +
                       sin(h * 21.0 + float(i) * .43) * .48;
        vec2 centerline = seg.xy + ba * h + normal * wobble;
        float d = length(fc - centerline);
        float sideA = abs(dot(fc - centerline, normal) -
                          (3.2 + generation * 2.8) * sin(h * 13.0 + float(i)));
        float sideB = abs(dot(fc - centerline, normal) +
                          (4.0 + generation * 3.5) * sin(h * 17.0 + float(i) * .71));

        // Older trunks are broad; young exploratory hyphae taper to hairlines.
        float taper = mix(2.25, .52, clamp(generation, 0.0, 1.0));
        float irregular = .82 + .18 * sin(h * 31.0 + float(i) * 2.17 + sin(h * 9.0) * 2.0);
        float width = taper * irregular * (1.0 + bass * .12);
        float halo = exp(-d * .085) * mix(.30, .10, generation);
        float fiber = exp(-d * d / max(width * width * 3.0, .1));
        float core = exp(-d * d / max(width * width * .32, .04));
        float satellites = (exp(-sideA * sideA * 1.8) + exp(-sideB * sideB * 2.2)) *
                           smoothstep(.08, .72, generation) *
                           smoothstep(.03, .20, h) * smoothstep(.03, .20, 1.0 - h);

        // Nutrient packets travel from old trunks toward growing tips. Separate
        // phases per branch prevent the organism from flashing in unison.
        float packetPhase = fract(h - iMycBeat - hash11(float(i)) * .72);
        float packet = exp(-pow((packetPhase - .5) * 18.0, 2.0));
        packet *= fiber * (.25 + bass * .34 + beat * .55);

        purpleHalo += halo + satellites * .11;
        amberFiber = max(amberFiber, fiber * (.55 + packet * .55) + satellites * .24);
        whiteCore = max(whiteCore, core * mix(.72, .12, generation));
        nutrient = max(nutrient, packet);

        if (terminal) {
            float td = length(fc - seg.zw);
            float breathe = .78 + .22 * sin(iTime * 1.7 + float(i));
            tips = max(tips, exp(-td * td / (15.0 + treble * 13.0)) * breathe);
        }
    }

    // Windows are slabs of nutrient-rich substrate. The organism doesn't draw
    // a box around them; nearby frame hyphae simply become healthier and hotter.
    float substrate = 0.0;
    float shadow = 0.0;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        float d = boxSdf(fc, iWindows[i]);
        float focus = 0.0;
        if (i == iFocusedIndex) focus = smoothstep(0.0, 1.0, iTransition);
        if (i == iPrevIndex) focus = max(focus, 1.0 - smoothstep(0.0, 1.0, iTransition));
        substrate += exp(-abs(d) * .035) * (.025 + focus * .11);
        shadow = max(shadow, smoothstep(12.0, -16.0, d) * (.018 + focus * .025));
    }

    float soil = .5 + .5 * sin(uv.x * 17.0 + sin(uv.y * 13.0) + iTime * .025);
    vec3 col = bg * (.64 + soil * .035);
    col += violet * min(purpleHalo, 1.6) * (.42 + mids * .14);
    col += amber * amberFiber * (.92 + bass * .24);
    col += hot * whiteCore * (.34 + kick * .24);
    col += hot * nutrient * (.70 + beat * .45);
    col += amber * tips * (1.05 + treble * .55);
    col += violet * tips * .24;
    col += amber * substrate * (.18 + mids * .08);
    col = mix(col, bg * .72, shadow);

    float vignette = 1.0 - smoothstep(.30, .78, length(uv - .5));
    col *= .82 + vignette * .18;
    col += (hash21(fc + floor(iTime * 18.0)) - .5) * .006;
    fragColor = vec4(col, 1.0);
}
