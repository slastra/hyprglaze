#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;

uniform vec4 iParticles[300];
uniform int iParticleCount;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

vec3 samplePalette(float t) {
    if (iPaletteSize <= 0) return vec3(0.6);
    float idx = t * float(iPaletteSize - 1);
    int i0 = int(floor(idx));
    int i1 = min(i0 + 1, iPaletteSize - 1);
    return mix(iPalette[i0], iPalette[i1], idx - float(i0));
}

void main() {
    vec2 fragCoord = gl_FragCoord.xy;
    vec2 uv = fragCoord / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02);
    vec3 col = bg;

    // Particles — clean dots with soft falloff
    for (int i = 0; i < iParticleCount && i < 300; i++) {
        vec4 pd = iParticles[i];
        vec2 delta = fragCoord - pd.xy;

        // Early-out: skip if clearly outside particle radius
        float r = pd.z;
        if (abs(delta.x) > r + 1.0 || abs(delta.y) > r + 1.0) continue;

        float dist = length(delta);
        float dot = 1.0 - smoothstep(r - 0.5, r + 0.5, dist);

        if (dot > 0.001) {
            vec3 pcol = samplePalette(pd.w);
            col = mix(col, pcol, dot * 0.85);
        }
    }

    fragColor = vec4(col, 1.0);
}
