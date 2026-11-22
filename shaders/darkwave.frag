#version 300 es
precision highp float;

// A board of small square lamps on a strict grid (src/effects/darkwave.zig).
// Which lamps are awake, in what color and how brightly is worked out
// there and handed over as a small texture with a texel for each lamp.
// Here each pixel only finds its lamp and draws it. Nothing of one lamp
// reaches into the next one's cell.
uniform vec3 iResolution;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

uniform sampler2D iWaveLamps;  // a lamp's color, and in alpha how bright it is (lower half) and its halo (upper half)
uniform vec4 iWaveGrid;        // pitch px, a lamp's side px, the corner of lamp (0, 0)'s cell px
uniform float iWaveLook;       // how strong the halos are

out vec4 fragColor;

void main() {
    float pitch = iWaveGrid.x;
    vec2 g = (gl_FragCoord.xy - iWaveGrid.zw) / pitch;
    ivec2 id = ivec2(floor(g));
    // From the lamp's middle, px.
    vec2 local = (g - vec2(id) - 0.5) * pitch;

    vec4 shown = texelFetch(iWaveLamps, id, 0);
    vec3 hue = shown.rgb;
    float both = shown.a * 255.0 / 127.0;
    float bright = min(both, 1.0);
    float hot = max(both - 1.0, 0.0);

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.094, 0.094, 0.133);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    vec3 lamp = mix(bg, mix(hue, fg, 0.3 * hot), bright);

    // A square with its corners taken off. Awake it is a pixel larger
    // all round, which is still whole pixels.
    float half_side = 0.5 * iWaveGrid.y + smoothstep(0.35, 0.95, bright);
    float corner = 0.2 * iWaveGrid.y;
    float d = length(max(abs(local) - (half_side - corner), 0.0)) - corner;
    float cover = clamp(0.5 - d, 0.0, 1.0);

    // Close round a lamp with a halo, that. It is nothing by the time it
    // reaches the edge of the lamp's own cell.
    float r = length(local) / pitch;
    float fade = clamp(1.0 - 4.0 * r * r, 0.0, 1.0);
    float halo = hot * iWaveLook * 0.6 * exp(-r * r / (2.0 * 0.17 * 0.17)) * fade * fade;

    fragColor = vec4(mix(bg + hue * halo, lamp, cover), 1.0);
}
