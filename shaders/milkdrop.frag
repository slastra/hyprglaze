#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform sampler2D iSprite;

// Declared so the shader program resolves palette uniform locations
// (milkdrop context reads these via glGetUniformfv for its internal shaders)
uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

out vec4 fragColor;

void main() {
    vec2 uv = gl_FragCoord.xy / iResolution.xy;
    fragColor = texture(iSprite, uv);
}
