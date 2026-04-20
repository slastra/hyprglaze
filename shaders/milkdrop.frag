#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform sampler2D iSprite;

out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    fragColor = texture(iSprite, uv);
}
