#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;

// Palette uniforms
uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

// Sample palette as a 1D ramp: t in [0,1] maps across all colors
vec3 samplePalette(float t) {
    if (iPaletteSize <= 0) return vec3(t);
    float idx = t * float(iPaletteSize - 1);
    int i0 = int(floor(idx));
    int i1 = min(i0 + 1, iPaletteSize - 1);
    float frac = idx - float(i0);
    return mix(iPalette[i0], iPalette[i1], frac);
}

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    vec2 mouse = iMouse.xy / iResolution.xy;

    // Distance from cursor
    float d = distance(uv, mouse);

    // Animated index into palette
    float pulse = 0.5 + 0.5 * sin(iTime * 2.0);

    if (iPaletteSize > 0) {
        // Palette mode: radial gradient samples the color ramp
        float t = 1.0 - smoothstep(0.0, 0.4, d);
        float shifted = fract(t * 0.8 + iTime * 0.1);
        vec3 col = mix(iPaletteBg, samplePalette(shifted), t);

        // Ring highlight near cursor
        float ring = smoothstep(0.12, 0.10, d) - smoothstep(0.10, 0.08, d);
        col += iPaletteFg * ring * 0.5;

        // Subtle vignette
        col *= 1.0 - 0.3 * length(uv - 0.5);

        fragColor = vec4(col, 1.0);
    } else {
        // Fallback: original hardcoded colors
        float ring = smoothstep(0.15 + 0.05 * pulse, 0.0, d);
        vec3 bg = mix(vec3(0.02, 0.02, 0.06), vec3(0.05, 0.03, 0.1), uv.y);
        vec3 glow = mix(vec3(0.2, 0.5, 1.0), vec3(1.0, 0.3, 0.6), pulse);
        vec3 col = bg + glow * ring * 0.8;
        col *= 1.0 - 0.4 * length(uv - 0.5);
        fragColor = vec4(col, 1.0);
    }
}
