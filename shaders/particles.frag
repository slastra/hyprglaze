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

void main() {
    vec2 fc = gl_FragCoord.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02);
    vec3 col = bg;

    for (int i = 0; i < iParticleCount && i < 300; i++) {
        vec4 pd = iParticles[i];
        float r = pd.z;

        if (abs(fc.x - pd.x) > r + 2.0 || abs(fc.y - pd.y) > r + 2.0) continue;

        float dist = length(fc - pd.xy);

        // Decode trail age from w: floor(w/10) = trail step, mod = color
        float trail_step = floor(pd.w / 10.0);
        float color_seed = pd.w - trail_step * 10.0;

        // Opacity decreases with trail age
        float opacity = 1.0 / (1.0 + trail_step * 1.5);

        // Softer edges on trail dots (wider AA for fast-moving trails)
        float aa = 0.5 + trail_step * 0.5;
        float dot = 1.0 - smoothstep(r - aa, r + aa, dist);

        if (dot > 0.001) {
            int ci = 1 + int(mod(color_seed * 5.99, 6.0));
            vec3 pcol = (iPaletteSize > ci) ? iPalette[ci] : vec3(0.6);
            col = mix(col, pcol, dot * opacity * 0.85);
        }
    }

    fragColor = vec4(col, 1.0);
}
