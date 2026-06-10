#version 300 es
precision highp float;

// The swarm effect renders itself in a low-resolution compute pass (one
// fragment per pixel-block, see src/effects/swarm/context.zig) — this pass
// just nearest-upscales that canvas to the screen. The NEAREST filter on
// iCanvas is what keeps the blocks razor sharp.
uniform vec3 iResolution;
uniform sampler2D iCanvas;

out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    fragColor = vec4(texture(iCanvas, uv).rgb, 1.0);
}
