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

float getSample(int channel, float x) {
    float fi = x * 127.0;
    int i0 = int(fi);
    int i1 = min(i0 + 1, 127);
    float t = fract(fi);

    int base = channel * 32; // left=0, right=32

    int slot0 = base + i0 / 4;
    int sub0 = i0 - (i0 / 4) * 4;
    float v0;
    if (sub0 == 0) v0 = iParticles[slot0].x;
    else if (sub0 == 1) v0 = iParticles[slot0].y;
    else if (sub0 == 2) v0 = iParticles[slot0].z;
    else v0 = iParticles[slot0].w;

    int slot1 = base + i1 / 4;
    int sub1 = i1 - (i1 / 4) * 4;
    float v1;
    if (sub1 == 0) v1 = iParticles[slot1].x;
    else if (sub1 == 1) v1 = iParticles[slot1].y;
    else if (sub1 == 2) v1 = iParticles[slot1].z;
    else v1 = iParticles[slot1].w;

    return mix(v0, v1, t);
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02);
    vec3 col = bg;
    vec3 wave_col = (iPaletteSize > 5) ? iPalette[5] : vec3(0.5, 0.8, 1.0);

    // Left channel - upper half (center = 0.7)
    float left = getSample(0, uv.x);
    float left_y = 0.7 + left * 0.2;
    float left_dist = abs(uv.y - left_y);
    float left_line = 1.0 - smoothstep(0.0, 0.002, left_dist);
    float left_glow = 1.0 - smoothstep(0.0, 0.015, left_dist);
    col = mix(col, wave_col, left_glow * 0.3);
    col = mix(col, wave_col, left_line);

    // Right channel - lower half (center = 0.3)
    float right = getSample(1, uv.x);
    float right_y = 0.3 + right * 0.2;
    float right_dist = abs(uv.y - right_y);
    float right_line = 1.0 - smoothstep(0.0, 0.002, right_dist);
    float right_glow = 1.0 - smoothstep(0.0, 0.015, right_dist);
    col = mix(col, wave_col, right_glow * 0.3);
    col = mix(col, wave_col, right_line);

    fragColor = vec4(col, 1.0);
}
