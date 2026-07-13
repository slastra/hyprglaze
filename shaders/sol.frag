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
uniform float iSolBands[6];
uniform float iSolOnsets[6];
uniform float iSolBeat;
uniform float iSolDownbeat;
uniform float iSolIntensity;
uniform vec4 iSolGesture;      // cursor velocity px/s, decaying gesture energy
uniform vec4 iSolWindowMotion; // focused-window velocity px/s, motion impulse

out vec4 fragColor;

const float TAU = 6.28318530718;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float valueNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
               mix(hash21(i + vec2(0.0, 1.0)), hash21(i + 1.0), f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0;
    mat2 turn = mat2(0.80, -0.60, 0.60, 0.80);
    v += valueNoise(p) * 0.500; p = turn * p * 2.03 + 8.3;
    v += valueNoise(p) * 0.250; p = turn * p * 2.01 + 3.7;
    v += valueNoise(p) * 0.125; p = turn * p * 2.04 + 7.1;
    v += valueNoise(p) * 0.063;
    return v;
}

float boxSdf(vec2 p, vec4 w) {
    vec2 q = abs(p - (w.xy + w.zw * 0.5)) - w.zw * 0.5;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

vec3 palette(int i, vec3 fallback) {
    return iPaletteSize > i ? iPalette[i] : fallback;
}

vec3 vivid(vec3 c, float amount) {
    float luma = dot(c, vec3(0.299, 0.587, 0.114));
    return max(vec3(0.0), mix(vec3(luma), c, amount));
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    float px = min(iResolution.x, iResolution.y);
    vec2 uv = (fc - iResolution.xy * 0.5) / px;
    vec2 mouse = (iMouse.xy - iResolution.xy * 0.5) / px;

    float sub = iSolBands[0];
    float bass = iSolBands[1];
    float body = 0.5 * (iSolBands[2] + iSolBands[3]);
    float air = 0.5 * (iSolBands[4] + iSolBands[5]);
    float kick = iSolOnsets[0] + iSolOnsets[1];
    float snap = pow(max(0.0, 1.0 - iSolBeat * 4.0), 4.0);
    float down = pow(max(0.0, 1.0 - iSolDownbeat * 2.4), 5.0);
    float energy = clamp(sub * 0.35 + bass * 0.45 + body * 0.25, 0.0, 1.6);
    vec2 gestureV = iSolGesture.xy / px;
    float gesture = iSolGesture.z;
    vec2 gestureDir = gestureV / max(length(gestureV), 0.001);
    vec2 windowV = iSolWindowMotion.xy / px;
    float windowMotion = iSolWindowMotion.z;

    // The pointer is a conductor, not the subject: it bends the entire field.
    vec2 toMouse = uv - mouse;
    float mouseR = length(toMouse);
    vec2 mouseTangent = vec2(-toMouse.y, toMouse.x) / max(mouseR, 0.025);
    vec2 q = uv + mouseTangent * exp(-mouseR * 5.5) * (0.045 + air * 0.035);
    q += normalize(toMouse + vec2(0.0001)) * exp(-mouseR * 10.0) * kick * 0.025;

    // Quick gestures comb the field in their direction and leave a broad
    // luminous wake behind the pointer. This is momentum, not raw position.
    float behind = max(0.0, -dot(toMouse, gestureDir));
    float across = abs(dot(toMouse, vec2(-gestureDir.y, gestureDir.x)));
    float gestureWake = exp(-across * 15.0) * exp(-behind * 2.8) *
                        step(dot(toMouse, gestureDir), 0.02) * gesture;
    q += gestureDir * gestureWake * 0.055;
    q += vec2(-windowV.y, windowV.x) * windowMotion * 0.025;

    // Window bodies curve nearby field lines. Focused windows carry much more
    // mass; transitions transfer that mass smoothly from one body to another.
    float rims = 0.0;
    float silhouettes = 0.0;
    float focusWake = 0.0;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 w = iWindows[i];
        vec2 center = (w.xy + w.zw * 0.5 - iResolution.xy * 0.5) / px;
        vec2 d = q - center;
        float r = length(d);
        float focus = 0.0;
        if (i == iFocusedIndex) focus = smoothstep(0.0, 1.0, iTransition);
        if (i == iPrevIndex) focus = max(focus, 1.0 - smoothstep(0.0, 1.0, iTransition));
        float mass = 0.0025 + focus * 0.010;
        q += vec2(-d.y, d.x) * mass / (0.018 + r * r) * (0.65 + energy * 0.35);

        float edge = boxSdf(fc, w);
        rims += exp(-abs(edge) * (0.050 - focus * 0.012)) * (0.10 + focus * 0.55);
        silhouettes = max(silhouettes, smoothstep(18.0, -12.0, edge) * (0.035 + focus * 0.055));
        focusWake += focus * exp(-r * 3.8) * (0.5 + 0.5 * cos(atan(d.y, d.x) * 3.0 - iTime));
    }

    // A broad diagonal flow keeps the canvas composed rather than radial.
    float t = iTime * (0.075 + body * 0.025);
    q += vec2(fbm(q * 2.2 + vec2(t, -t)) - 0.5,
              fbm(q * 2.1 + vec2(-t, t + 9.0)) - 0.5) * (0.10 + body * 0.035);
    q.x += q.y * 0.22;

    // Interference between three moving phase fields forms luminous magnetic
    // ribbons. Narrow line extraction gives them an etched, fibrous quality.
    float n1 = fbm(q * 4.2 + vec2(t * 2.0, -t));
    float n2 = fbm(q * 7.5 - vec2(t, t * 1.4));
    float phaseA = q.x * (7.0 + bass * 1.8) + q.y * 2.4 + n1 * 5.0 - iTime * 0.22;
    float phaseB = q.y * (8.5 + air * 3.0) - q.x * 1.8 + n2 * 4.0 + iTime * 0.17;
    float a = abs(sin(phaseA));
    float b = abs(sin(phaseB));
    float ribbons = pow(1.0 - min(a, b), 8.0);
    float hair = pow(1.0 - abs(sin(phaseA * 2.03 + n2 * 2.0)), 18.0);
    float crossing = pow(1.0 - a, 10.0) * pow(1.0 - b, 6.0);

    // Each beat launches an expanding, distorted pressure ring from the cursor.
    float ringPhase = fract(iSolBeat + mouseR * 1.7);
    float shock = exp(-pow((ringPhase - 0.52) * 18.0, 2.0));
    shock *= (snap * 0.9 + kick * 0.65) * exp(-mouseR * 0.65);

    // Moving a window sends a second, slower compression wave through the
    // entire loom. Its direction is encoded as an asymmetric traveling fold.
    float windowWaveCoord = dot(uv, normalize(windowV + vec2(0.001))) * 1.7;
    float windowWave = exp(-pow(fract(windowWaveCoord - iTime * 0.42) - 0.5, 2.0) * 90.0);
    windowWave *= windowMotion;

    vec3 bg = iPaletteSize > 0 ? iPaletteBg : vec3(0.010, 0.008, 0.025);
    vec3 cold = vivid(mix(palette(4, vec3(0.20, 0.35, 0.95)),
                          palette(5, vec3(0.55, 0.25, 0.95)), 0.52), 1.65);
    vec3 warm = vivid(mix(palette(1, vec3(1.00, 0.27, 0.08)),
                          palette(3, vec3(1.00, 0.76, 0.18)), 0.42), 1.55);
    vec3 white = mix(iPaletteSize > 0 ? iPaletteFg : vec3(1.0), vec3(1.0), 0.45);

    float vignette = 1.0 - smoothstep(0.22, 0.92, length(uv));
    vec3 col = bg * (0.72 + vignette * 0.22);
    col += cold * (ribbons * (0.16 + body * 0.30) + focusWake * 0.060);
    col += warm * (hair * (0.13 + air * 0.38) + crossing * (0.34 + energy * 0.48));
    col += white * crossing * (0.06 + kick * 0.36);
    // Soft colored bloom beneath the hairline filaments preserves depth while
    // the hot crossings stay crisp.
    col += cold * pow(1.0 - min(a, b), 3.0) * (0.025 + body * 0.035);
    col += mix(cold, warm, 0.5 + 0.5 * sin(iTime * 0.2)) * shock * 0.42 * iSolIntensity;
    col += mix(cold, white, 0.35) * windowWave * (0.10 + energy * 0.12);

    // Gesture wake splits into a subtle spectral edge. It reads like light
    // being physically dragged across the glass rather than a cursor trail.
    col += warm * gestureWake * (0.16 + kick * 0.24);
    col += cold * exp(-across * 28.0) * exp(-behind * 4.0) * gesture * 0.22;
    col += white * exp(-across * 75.0) * exp(-behind * 7.0) * gesture * 0.16;

    // Window edges become energized cuts through the field, with a brief white
    // downbeat glint. Their interiors remain only subtly heavier than the field.
    col = mix(col, bg * 0.70, silhouettes);
    col += warm * rims * (0.30 + energy * 0.20);
    col += white * rims * down * 0.24;

    // A restrained cursor singularity: dark pinprick, chromatic accretion ring.
    float cursorRing = exp(-pow((mouseR - 0.021) * 120.0, 2.0));
    col += mix(cold, warm, air) * cursorRing * (0.42 + air * 0.4);
    col *= 1.0 - exp(-mouseR * 95.0) * 0.62;

    // Sparse motes only reveal themselves in active regions and on treble.
    vec2 moteCell = floor((uv + 0.7) * 95.0);
    vec2 motePos = (moteCell + vec2(hash21(moteCell), hash21(moteCell + 19.1))) / 95.0 - 0.7;
    float mote = exp(-length(uv - motePos) * 1200.0) * step(0.994, hash21(moteCell + 4.2));
    col += mix(cold, white, 0.55) * mote * (0.04 + air * 1.0 + iSolOnsets[5] * 1.5);

    col *= 0.88 + 0.12 * vignette;
    col += (hash21(fc + floor(iTime * 30.0)) - 0.5) * 0.006;
    fragColor = vec4(col, 1.0);
}
