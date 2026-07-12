#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Music (all zero in silence or with music = false, which makes every
// modulation below collapse to exactly the classic fluid look).
uniform float iFluidBands[6];
uniform float iFluidEnergy;

out vec4 fragColor;

float sdRoundBox(vec2 p, vec2 center, vec2 half_size, float radius) {
    vec2 d = abs(p - center) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void main() {
    vec2 fc = gl_FragCoord.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.1, 0.09, 0.14);
    vec3 muted = (iPaletteSize > 8) ? iPalette[8] : vec3(0.43, 0.42, 0.53);
    vec3 accent = (iPaletteSize > 5) ? iPalette[5] : vec3(0.77, 0.65, 0.91);

    vec3 pal[6];
    pal[0] = (iPaletteSize > 1) ? iPalette[1] : vec3(0.9, 0.4, 0.6);
    pal[1] = (iPaletteSize > 2) ? iPalette[2] : vec3(0.6, 0.8, 0.8);
    pal[2] = (iPaletteSize > 3) ? iPalette[3] : vec3(0.9, 0.7, 0.5);
    pal[3] = (iPaletteSize > 4) ? iPalette[4] : vec3(0.2, 0.4, 0.6);
    pal[4] = (iPaletteSize > 5) ? iPalette[5] : vec3(0.7, 0.6, 0.9);
    pal[5] = (iPaletteSize > 6) ? iPalette[6] : vec3(0.9, 0.7, 0.7);

    float t = iTime * 0.3;

    // --- Metaball field ---
    // Each source contributes r²/(d²+r²) to the field
    // Where sources overlap, field values add → blobs merge
    float field = 0.0;
    vec3 field_color = bg;
    float color_weight = 0.0;
    float r = 250.0; // blob radius

    // Window blobs (SDF-based distance)
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0 || win.w < 1.0) continue;

        float raw_d = sdRoundBox(fc, win.xy + win.zw * 0.5, win.zw * 0.5, 12.0);
        float d = sqrt(raw_d * raw_d + 20.0); // smooth kink at boundary

        float contribution = (r * r) / (d * d + r * r);
        field += contribution;

        int ci = int(mod(float(i), 6.0));
        vec3 tint = pal[ci];
        field_color += tint * contribution;
        color_weight += contribution;
    }

    // Cursor blob
    float cd = distance(fc, iMouse.xy);
    float cr = 120.0;
    float cursor_contrib = (cr * cr) / (cd * cd + cr * cr);
    field += cursor_contrib;
    field_color += muted * cursor_contrib;
    color_weight += cursor_contrib;

    // Drifting ambient blobs — one per spectral band, low to high. A
    // playing band inflates its blob and weighs it heavier in the field
    // (bass swells fuse into neighboring contours; hats flutter the small
    // ones). Amplitude-only modulation: silence renders identically.
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float be = min(iFluidBands[i], 1.2);
        float px = 0.5 + 0.35 * sin(t * (0.3 + fi * 0.07) + fi * 1.5);
        float py = 0.5 + 0.35 * cos(t * (0.2 + fi * 0.09) + fi * 2.1);
        vec2 dp = iResolution.xy * vec2(px, py);
        float dd = distance(fc, dp);
        float dr = (100.0 + 30.0 * sin(t + fi)) * (1.0 + be * 0.7);
        float contrib = (dr * dr) / (dd * dd + dr * dr);
        field += contrib * (0.4 + be * 0.45);

        int ci = int(mod(fi + 2.0, 6.0));
        field_color += pal[ci] * (0.3 + be * 0.4) * contrib;
        color_weight += contrib * (0.3 + be * 0.4);
    }

    // Normalize color
    if (color_weight > 0.001) {
        field_color /= color_weight;
    }

    vec3 col = bg;

    // --- Isocontour lines with screen-space anti-aliasing ---
    // Loud passages densify the topography (more iso levels between the
    // same field extremes); the slow energy envelope keeps it a breath,
    // not a flicker. Silence: exactly 6, the classic look.
    float contours = 6.0 + iFluidEnergy * 7.0;
    float f_scaled = field * contours;

    // Distance to the nearest integer of f_scaled (= nearest isocontour).
    // Triangle-wave trick avoids the fract() discontinuity that caused
    // stairstepping when the two-sided smoothstep straddled the wrap.
    float dist = abs(fract(f_scaled + 0.5) - 0.5);
    float fw = fwidth(f_scaled);
    float line = 1.0 - smoothstep(0.0, max(fw * 2.0, 0.005), dist);

    // Fade lines with distance from sources
    float intensity = smoothstep(0.1, 0.5, field);

    // Thin colored lines on a surface-color background
    col = mix(col, field_color, line * intensity);


    fragColor = vec4(col, 1.0);
}
