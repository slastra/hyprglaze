#version 300 es
precision highp float;

uniform vec3 iResolution;
uniform float iVoltTime;
uniform vec4 iWindows[32];
uniform int iWindowCount;
uniform float iTransition;
uniform int iFocusedIndex;
uniform int iPrevIndex;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

// Arc geometry from voltaic.zig. Every channel is a polyline of short
// segments in chunks of eight. Row c of iSegTex is chunk c: texels 0-7 are
// the segments (x1, y1, x2, y2), texels 8-15 their (brightness, core
// half-width px, cool, -), cool running from 0, live, to 1, an ember.
// iChunkBox[c] is the chunk's bounds padded by the glow's reach, so one
// test skips all eight segments.
uniform highp sampler2D iSegTex;
uniform vec4 iChunkBox[256];
uniform int iChunkCount;
uniform float iPx;         // pixel scale against a 1440-line screen
uniform float iBeat;
uniform float iBass;
uniform float iTreble;
uniform float iFlash;

// Must match glow_reach in voltaic.zig.
const float REACH = 170.0;

out vec4 fragColor;

// ---------- noise ----------

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// ---------- palette ----------

// Push a palette color's chroma without moving its hue: theme accents are
// often pastel, and a pastel glow over a dark bench reads as gray.
vec3 vivid(vec3 c, float k) {
    float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return clamp(mix(vec3(l), c, k), 0.0, 1.0);
}

// Electric blue from the theme's bright blue.
vec3 glowColor() {
    if (iPaletteSize > 12) return vivid(iPalette[12], 1.7);
    return vec3(0.30, 0.55, 1.0);
}

vec3 coreColor() {
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    return mix(fg, vec3(1.0), 0.6);
}

// Afterglow ember: the theme's purple (ANSI magenta — Rosé Pine's iris, etc).
// Deepen it slightly so it stays readably purple when added over the dark bench
// rather than washing toward pastel.
vec3 emberColor() {
    vec3 p = (iPaletteSize > 13) ? iPalette[13]
           : (iPaletteSize > 5)  ? iPalette[5]
           : vec3(0.66, 0.20, 1.0);
    // Pull toward a saturated violet to counter pastel palette purples.
    return mix(p, vec3(0.60, 0.16, 0.95), 0.45);
}

// ---------- focus rim ----------

float windowSdf(vec2 p, vec4 win) {
    vec2 cen = win.xy + win.zw * 0.5;
    vec2 q = abs(p - cen) - win.zw * 0.5;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Whisper of steady glow on the focused frame. The crawling arcs (CPU-side
// channels hugging the border) carry the show; this just keeps focus
// readable in the gaps between crawls.
float focusRim(vec2 fc, vec4 win, float focus_amt) {
    if (focus_amt < 0.01 || win.z < 1.0) return 0.0;
    float bd = abs(windowSdf(fc, win));
    if (bd > 70.0) return 0.0;
    return exp(-bd * 0.07) * 0.12 * focus_amt * (0.8 + iTreble * 0.5);
}

// ---------- main ----------

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec2 uv = fc / iResolution.xy;

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.015, 0.018, 0.030);
    vec3 gcol = glowColor();
    vec3 ccol = coreColor();

    // Dark bench, slight vignette, faint ambient hum from the bass.
    float vig = 1.0 - 0.35 * length(uv - 0.5);
    vec3 col = bg * (0.85 * vig + iBass * 0.06);

    // Thunder flash: on big discharges the whole bench floods with light,
    // brightest toward center and tinted by the electric glow — like the
    // room lighting up. Fast CPU-side decay keeps it a snap, not a wash.
    col += (bg * 1.6 + gcol * 0.5) * iFlash * 0.17 * vig;

    // A channel is drawn the way a hot arc photographs:
    //   core:   a thin, crisp, near-white line
    //   sheath: the tight glare hugging it, falling off as inverse square
    //   glow:   the light the channel throws into the air around it
    // Core and sheath are distance fields joined with max(), so joints and
    // crossings never pile up into blobs. The glow is the channel treated
    // as a line light: each segment's inverse-square light integrated along
    // its length (closed form, two atans), summed over segments. A summed
    // integral is smooth across every kink, where a distance field would
    // crease into rays. A window takes it to zero at REACH, so the chunk
    // boxes are never visible as a cutoff.
    float px = max(iPx, 0.1);
    float reach = REACH * px;
    float glow_r = 4.5 * px * (1.0 + iBass * 0.35);

    vec3 light = vec3(0.0);  // glow, sheath, core
    vec2 ember = vec2(0.0);  // afterglow: glow, channel (tinted violet below)
    for (int c = 0; c < iChunkCount && c < 256; c++) {
        vec4 box = iChunkBox[c];
        if (fc.x < box.x || fc.x > box.z || fc.y < box.y || fc.y > box.w) continue;

        for (int k = 0; k < 8; k++) {
            vec4 pr = texelFetch(iSegTex, ivec2(8 + k, c), 0);
            float b = pr.x;
            if (b < 0.004) continue;
            vec4 s = texelFetch(iSegTex, ivec2(k, c), 0);

            vec2 pa = fc - s.xy;
            vec2 ba = s.zw - s.xy;
            float len = length(ba);
            if (len < 1e-3) continue;
            vec2 dir = ba / len;
            float t = dot(pa, dir);                  // along the segment
            float perp = dot(pa, vec2(-dir.y, dir.x));
            float d = length(pa - dir * clamp(t, 0.0, len));
            if (d > reach) continue;

            float hh = sqrt(perp * perp + glow_r * glow_r);
            float win = 1.0 - d * d / (reach * reach);
            // 1 on a long straight channel's axis, glow_r / distance away.
            float g = (atan((len - t) / hh) + atan(t / hh)) * glow_r / (hh * 3.14159265) * win * win;

            // A channel cools from live (0) to ember (1): the ember has no
            // hot core, just the dull channel and its glow.
            float cool = pr.z;
            ember.x += b * cool * g;
            ember.y = max(ember.y, b * cool * exp(-d / (5.0 * px)));

            float w = pr.y;
            float sr = 2.6 * w;
            b *= 1.0 - cool;
            light.x += b * g;
            light.y = max(light.y, b / (1.0 + d * d / (sr * sr)));
            light.z = max(light.z, min(b * 1.8, 1.0) * smoothstep(w + 0.75, w - 0.75, d));
        }
    }

    // Steady rim on the focused window (cross-fading through transitions).
    float rim = 0.0;
    for (int i = 0; i < iWindowCount && i < 32; i++) {
        float focus_amt = 0.0;
        if (i == iFocusedIndex) focus_amt = max(focus_amt, smoothstep(0.0, 1.0, iTransition));
        if (i == iPrevIndex)    focus_amt = max(focus_amt, 1.0 - smoothstep(0.0, 1.0, iTransition));
        rim += focusRim(fc, iWindows[i], focus_amt);
    }

    // Hot to cool, outward: white core, pale sheath, blue glow thinning to
    // the theme's violet where it is faint.
    vec3 ecol = emberColor();
    col += gcol * rim * 0.55;
    // Summed light is compressed, so channels bunched in one gap glow
    // brighter without washing out to white.
    float glow = 1.0 - exp(-light.x * 1.3);
    col += mix(mix(gcol, ecol, 0.6), gcol, smoothstep(0.03, 0.30, glow)) * glow * 0.62;
    col += mix(gcol, ccol, 0.45) * light.y * 0.75;

    // Cooling-ember afterglow: the ionized channel still glows after the arc
    // is out, the recombination glow of a decaying channel. Theme purple,
    // distinct from the live blue arcs.
    col += ecol * ((1.0 - exp(-ember.x * 1.3)) * 0.65 + ember.y * 0.85);

    // The core goes on last and replaces rather than adds, so the line
    // stays crisp however much glow is under it. A faint channel has a
    // cooler core, blue rather than gray.
    vec3 hot = mix(gcol, ccol, smoothstep(0.15, 0.7, light.y));
    col = mix(col, max(col, hot), light.z);

    // Beat: the whole bench flashes faintly, like a capacitor letting go.
    col += gcol * iBeat * 0.045;

    // Fine static grain so the dark field never looks flat.
    col += (hash21(fc + fract(iVoltTime) * 100.0) - 0.5) * 0.012;

    fragColor = vec4(col, 1.0);
}
