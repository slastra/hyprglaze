#version 300 es
precision highp float;

// The murmuration is drawn bird by bird into its own layer (see
// src/effects/swarm/context.zig). This pass lays that layer over the sky.
uniform vec3 iResolution;
uniform sampler2D iFlock;   // premultiplied ink

uniform vec3 iPaletteBg;
uniform int iPaletteSize;

out vec4 fragColor;

// Integer hash for the dither: a fract-multiply hash lines up into
// streaks on a pixel lattice.
float dither(ivec2 p) {
    uint h = uint(p.x) * 0x8da6b343u + uint(p.y) * 0xd8163841u;
    h ^= h >> 15; h *= 0x2c1b3c6du;
    h ^= h >> 12; h *= 0x297a2d39u;
    h ^= h >> 15;
    return float(h >> 8) / 16777216.0;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    // The theme's background as dusk: a touch lighter toward the horizon.
    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.03, 0.035, 0.05);
    float vig = 1.0 - 0.30 * length(uv - 0.5);
    vec3 col = bg * (0.92 * vig) + (bg + 0.02) * 0.10 * (1.0 - uv.y);

    // A static half-step of dither, added: the gradient is too shallow
    // for 8 bits and would band into rings.
    col += (dither(ivec2(fc)) - 0.5) / 255.0;

    vec4 ink = texelFetch(iFlock, ivec2(fc), 0);
    col = col * (1.0 - ink.a) + ink.rgb;

    fragColor = vec4(col, 1.0);
}
