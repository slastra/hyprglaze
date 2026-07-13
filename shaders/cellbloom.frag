#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iTime;
uniform vec4 iMouse;
uniform vec4 iWindow;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Music (all zero / iBloomFlow steady in silence → the classic look).
uniform float iBloomFlow;     // CPU drift clock, quickens with energy
uniform float iBloomBands[6]; // smoothed AGC'd bands, low to high
uniform float iBloomBass;     // smoothed low end
uniform float iBloomBeat;     // kick envelope, ~200ms decay

out vec4 fragColor;

float sdRoundBox(vec2 p, vec2 center, vec2 half_size, float radius) {
    vec2 d = abs(p - center) - half_size + radius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

void main() {
    vec2 fc = gl_FragCoord.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.1, 0.09, 0.14);
    vec3 accent = (iPaletteSize > 5) ? iPalette[5] : vec3(0.77, 0.65, 0.91);

    vec3 pal[6];
    pal[0] = (iPaletteSize > 1) ? iPalette[1] : vec3(0.9, 0.4, 0.6);
    pal[1] = (iPaletteSize > 2) ? iPalette[2] : vec3(0.6, 0.8, 0.8);
    pal[2] = (iPaletteSize > 3) ? iPalette[3] : vec3(0.9, 0.7, 0.5);
    pal[3] = (iPaletteSize > 4) ? iPalette[4] : vec3(0.2, 0.4, 0.6);
    pal[4] = (iPaletteSize > 5) ? iPalette[5] : vec3(0.7, 0.6, 0.9);
    pal[5] = (iPaletteSize > 6) ? iPalette[6] : vec3(0.9, 0.7, 0.7);

    // Focus expansion: focused window claims more Voronoi territory
    float focus_expand = (1.0 - iTransition) * 80.0 + 15.0; // 95px → 15px

    vec3 col = bg;

    // --- Voronoi with focus interaction ---
    // Every cell owner carries a spectral band; the winning cell's band
    // level drives its fill below (the dancefloor).
    float d1 = 1e9, d2 = 1e9;
    vec3 c1 = bg, c2 = bg;
    float nearest_focus_amt = 0.0;
    float cell_pulse = 0.0;

    for (int i = 0; i < iWindowCount && i < 32; i++) {
        vec4 win = iWindows[i];
        if (win.z < 1.0 || win.w < 1.0) continue;

        float d = sdRoundBox(fc, win.xy + win.zw * 0.5, win.zw * 0.5, 12.0);

        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, 1.0 - smoothstep(0.0, 1.0, iTransition));

        // Focused window pulls cells toward it, scaled by focus strength.
        d -= focus_expand * focus_amt;

        int ci = int(mod(float(i), 6.0));
        vec3 tint = mix(pal[ci], accent, focus_amt);

        if (d < d1) {
            d2 = d1; c2 = c1;
            d1 = d;  c1 = tint;
            nearest_focus_amt = focus_amt;
            cell_pulse = iBloomBands[ci];
        } else if (d < d2) {
            d2 = d;  c2 = tint;
        }
    }

    // Cursor control point
    float cursor_d = distance(fc, iMouse.xy);
    if (cursor_d < d1) {
        d2 = d1; c2 = c1;
        d1 = cursor_d; c1 = accent * 0.4;
        nearest_focus_amt = 0.0;
        cell_pulse = 0.0;
    } else if (cursor_d < d2) {
        d2 = cursor_d; c2 = accent * 0.4;
    }

    // Drifting ambient points. The clock comes from the CPU and quickens
    // with music energy (accumulated, so rate changes never snap phase);
    // bass heaves the wander amplitude so cells surge on the low end.
    float t = iBloomFlow;
    float wander = 0.1 * (1.0 + min(iBloomBass, 1.2) * 0.6);
    for (int i = 0; i < 24; i++) {
        float fi = float(i);
        float px = fract(fi * 0.381966) + wander * sin(t * (0.5 + fi * 0.11));
        float py = fract(fi * 0.618034) + wander * cos(t * (0.4 + fi * 0.13));
        vec2 dp = iResolution.xy * vec2(clamp(px, 0.02, 0.98), clamp(py, 0.02, 0.98));
        float d = distance(fc, dp);
        int ci = int(mod(fi + 3.0, 6.0));
        vec3 tint = pal[ci] * 0.3;
        if (d < d1) {
            d2 = d1; c2 = c1;
            d1 = d;  c1 = tint;
            nearest_focus_amt = 0.0;
            cell_pulse = iBloomBands[int(mod(fi, 6.0))];
        } else if (d < d2) {
            d2 = d;  c2 = tint;
        }
    }

    // --- Cell fill: the dancefloor ---
    // Resting fill is the classic whisper; a cell whose band is playing
    // floods with its own tint, hard.
    float fill = exp(-max(d1, 0.0) / 120.0);
    float lit = mix(0.03, 0.06, nearest_focus_amt) + min(cell_pulse, 1.2) * 0.30;
    col = mix(col, c1, fill * min(lit, 0.42));

    // --- Sharp cell edge lines ---
    // Kicks flash the whole lattice: brighter and momentarily wider.
    float edge_dist = d2 - d1;
    vec3 edge_color = mix(c1, c2, 0.5);

    float line = 1.0 - smoothstep(0.0, 3.0 + iBloomBeat * 4.0, edge_dist);
    col = mix(col, edge_color, min(line * (0.6 + iBloomBeat * 0.4), 0.95));

    // --- Cursor proximity boost ---
    float cursor_dist = distance(fc, iMouse.xy);
    float proximity = exp(-cursor_dist / 150.0);
    col = mix(col, edge_color, line * proximity * 0.3);

    fragColor = vec4(col, 1.0);
}
