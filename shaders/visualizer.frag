#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;

// [0..31] = left channel (128 samples, 4 per vec4)
// [32..63] = right channel (128 samples, 4 per vec4)
uniform vec4 iParticles[300];
uniform int iParticleCount;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

float rawSample(int base, int i) {
    i = clamp(i, 0, 127);
    int slot = base + i / 4;
    int sub = i - (i / 4) * 4;
    if (sub == 0) return iParticles[slot].x;
    if (sub == 1) return iParticles[slot].y;
    if (sub == 2) return iParticles[slot].z;
    return iParticles[slot].w;
}

// Catmull-Rom cubic interpolation for smooth waveform
float getSample(int channel, float x) {
    float fi = x * 127.0;
    int i1 = int(fi);
    float t = fract(fi);

    int base = channel * 32;
    float p0 = rawSample(base, i1 - 1);
    float p1 = rawSample(base, i1);
    float p2 = rawSample(base, i1 + 1);
    float p3 = rawSample(base, i1 + 2);

    // Catmull-Rom spline
    float t2 = t * t;
    float t3 = t2 * t;
    return 0.5 * (
        (2.0 * p1) +
        (-p0 + p2) * t +
        (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2 +
        (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
    );
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02);
    vec3 col = bg;
    vec3 wave_col = (iPaletteSize > 5) ? iPalette[5] : vec3(0.5, 0.8, 1.0);

    // Bass energy from first ~10 samples of both channels
    float bass = 0.0;
    for (int i = 0; i < 10; i++) {
        bass += abs(rawSample(0, i)) + abs(rawSample(32, i));
    }
    bass /= 20.0;

    // Bass flash — tint the background
    float flash = bass * bass * 4.0; // squared for punch
    col += wave_col * flash * 0.08;

    // Color by amplitude — quiet=base color, loud=shifts through palette
    // Uses chromatic indices 1-6
    float left = getSample(0, uv.x);
    float right = getSample(1, uv.x);

    float left_amp = abs(left);
    float right_amp = abs(right);

    // Map amplitude to palette position (0=quiet, 5=loud)
    float left_ci = clamp(left_amp * 15.0, 0.0, 5.0);
    float right_ci = clamp(right_amp * 15.0, 0.0, 5.0);

    int lci0 = 1 + int(left_ci);
    int lci1 = min(lci0 + 1, 6);
    float lt = fract(left_ci);
    vec3 left_col = (iPaletteSize > lci1)
        ? mix(iPalette[lci0], iPalette[lci1], lt)
        : wave_col;

    int rci0 = 1 + int(right_ci);
    int rci1 = min(rci0 + 1, 6);
    float rt = fract(right_ci);
    vec3 right_col = (iPaletteSize > rci1)
        ? mix(iPalette[rci0], iPalette[rci1], rt)
        : wave_col;

    // Left channel - upper half (center = 0.7)
    float left_y = 0.7 + left * 0.2;
    float left_dist = abs(uv.y - left_y);
    float left_line = 1.0 - smoothstep(0.0, 0.002, left_dist);
    float left_glow = 1.0 - smoothstep(0.0, 0.02 + left_amp * 0.03, left_dist);
    col = mix(col, left_col, left_glow * 0.3);
    col = mix(col, left_col, left_line);

    // Right channel - lower half (center = 0.3)
    float right_y = 0.3 + right * 0.2;
    float right_dist = abs(uv.y - right_y);
    float right_line = 1.0 - smoothstep(0.0, 0.002, right_dist);
    float right_glow = 1.0 - smoothstep(0.0, 0.02 + right_amp * 0.03, right_dist);
    col = mix(col, right_col, right_glow * 0.3);
    col = mix(col, right_col, right_line);

    fragColor = vec4(col, 1.0);
}
