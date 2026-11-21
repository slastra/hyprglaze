#version 300 es
precision highp float;
precision highp sampler2D;

// A culture of cells on a plate of food (src/effects/cellbloom.zig). Each
// cell is a clear ball lit by a lamp, cut back where it overlaps a
// neighbor along the straight wall the two circles share, so a colony is
// drawn as pressed-together bubbles: round on its open side, flat where
// cells meet. Nothing is quite regular: outlines wobble, nuclei float off
// center, grains drift inside the cells and motes in the medium. It is
// all seen down a microscope, with dust on its glass and a little grain.
uniform vec3 iResolution;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

const int LAMPS = 3;
// Specks of dust on the microscope's glass.
const int DUST = 14;

uniform sampler2D iCellBins; // SLOTS texels a bin: center px, radius px, index; radius 0 ends the list
uniform sampler2D iCellInfo; // a column a cell. Row 0: how slack it is, band level, mate or -1, how far
                             // the wall to its mate has closed. Row 1: vitality, how stirred up
                             // (waiting to divide, or dividing), seed, the mids it hears. Row 2: where
                             // its nucleus floats, px from its center; nothing; the treble it hears
uniform sampler2D iCellFood; // the plate, 1 = untouched
uniform vec3 iCellGrid;      // bin size px, bins across, bins up (a border of one round the screen)
uniform vec4 iCellLook;      // line scale, unused, overall level, px past its rim a cell is searched for
uniform vec2 iCellPlate;     // px the food texture spans
uniform float iCellColor;    // the palette slot the cells are colored from (-1 = foreground)
uniform vec3 iCellClock;     // the slow wobble's angle (under a turn), frame number, px a lamp's light carries
uniform vec4 iCellLamp[LAMPS]; // px x, y, height over the plate, strength 0 to 1
uniform float iCellLens;       // how much of the microscope shows: dust and grain (0 = none)
uniform vec4 iCellDust[DUST];  // px x, y, radius, and how far out of focus (0 crisp to 1)
uniform vec2 iCellDustHow[DUST]; // how much it darkens, how bright the ring round it

out vec4 fragColor;

const float TAU = 6.2831853;

// Where the dim room is brightest: up, left, and well overhead.
const vec3 ROOM = vec3(-0.40, 0.49, 0.775);
// A lamp's radius, in its own heights over the plate.
const float LAMP = 0.22;

const int SLOTS = 8;
// The most cells that can reach one pixel.
const int NEAR = 12;
// Grains adrift in each cell.
const int GRAINS = 5;

// A lamp as seen along a ray: 1 looking straight into it, a soft edge,
// and a faint glare round it. Its radius is never less than a few pixels'
// worth of the picture it makes on a ball of radius `r`, so a far-off
// ball still shows a point of light.
float lampSeen(vec3 lamp, vec3 from, vec3 ray, float r) {
    vec3 w = lamp - from;
    float along = dot(w, ray);
    if (along <= 0.0) return 0.0;
    float miss = length(w - ray * along);
    float size = max(LAMP * lamp.z, along * 3.2 * iCellLook.x / r);
    // A ray that only just clears the horizon sees it less and less.
    float clear = smoothstep(0.0, 2.0 * size, along);
    return clear * ((1.0 - smoothstep(0.55 * size, 1.25 * size, miss)) + 0.30 * exp(-miss * miss / (7.0 * size * size)));
}

// How far the outline stands out from its circle at angle `th`, in
// radii: a few slow standing waves that swell and fade out of step, so
// the shape breathes without turning. `ph` is the clock, and every rate
// is a whole number of it, so it wraps without a jump.
float wobble(float th, float seed, float ph) {
    float a = seed * TAU;
    return 0.020 * sin(2.0 * th + 3.0 * a) * sin(ph + 5.0 * a)
         + 0.017 * sin(3.0 * th + 7.0 * a) * sin(2.0 * ph + 11.0 * a)
         + 0.013 * sin(5.0 * th + 13.0 * a) * sin(3.0 * ph + 17.0 * a)
         + 0.012 * cos(2.0 * th + 19.0 * a) * cos(2.0 * ph + 23.0 * a);
}

uint mixBits(uint h) {
    h ^= h >> 15; h *= 0x2c1b3c6du;
    h ^= h >> 12; h *= 0x297a2d39u;
    h ^= h >> 15;
    return h;
}

float dither(ivec2 p) {
    return float(mixBits(uint(p.x) * 0x8da6b343u + uint(p.y) * 0xd8163841u) >> 8) / 16777216.0;
}

vec3 hash3(ivec2 p) {
    uint h = mixBits(uint(p.x) * 0x8da6b343u + uint(p.y) * 0xd8163841u);
    uint g = mixBits(h + 0x9e3779b9u);
    return vec3(float(h >> 8), float(g >> 8), float((h ^ (g << 7)) >> 8)) / 16777216.0;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.04, 0.04, 0.06);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    int slot = int(iCellColor);
    vec3 tint = (iPaletteSize == 0 || slot < 0 || slot >= iPaletteSize) ? fg : iPalette[slot];
    float px = iCellLook.x;
    float reach = iCellLook.w;
    float ph = iCellClock.x;
    float carry = iCellClock.z * iCellClock.z;

    // The plate: eaten ground is a shade darker than fresh, and the
    // lamps lay a pool of light on it.
    float food = texture(iCellFood, fc / iCellPlate).r;
    vec3 col = bg * (0.74 + 0.26 * smoothstep(0.1, 0.9, food));
    float pool = 0.0;
    for (int i = 0; i < LAMPS; i++) {
        vec2 d = iCellLamp[i].xy - fc;
        pool += iCellLamp[i].w * carry / (carry + dot(d, d));
    }
    pool = min(pool, 1.0);
    col = mix(col, fg, 0.03 * pool);
    float bright = mix(0.68, 1.0, pool);

    // Motes adrift in the medium, one to a tile or none, each wandering
    // a slow loop inside its own tile. One in five is out of focus.
    {
        float tile = 150.0 * px;
        vec2 g = fc / tile;
        vec3 h = hash3(ivec2(floor(g)));
        if (h.z < 0.7) {
            vec2 at = 0.3 + 0.4 * h.xy + 0.17 * vec2(sin(ph + TAU * h.y), cos(2.0 * ph + TAU * h.x));
            float blur = step(0.8, fract(h.z * 13.0));
            float size = mix(1.0 + 1.2 * h.x, 4.0 + 3.0 * h.y, blur) * px;
            float mote = 1.0 - smoothstep(0.4 * size, size, length((fract(g) - at) * tile));
            col = mix(col, fg, min(mote * mix(0.08 + 0.12 * h.y, 0.03, blur) * (0.3 + 0.7 * pool), 0.8));
        }
    }

    // Every cell close enough to matter here is in the 3x3 bins round
    // this pixel's own.
    ivec2 dims = ivec2(iCellGrid.yz);
    ivec2 home = ivec2(floor(fc / iCellGrid.x)) + 1;
    vec4 near[NEAR];
    int n = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            ivec2 q = home + ivec2(dx, dy);
            if (q.x < 0 || q.y < 0 || q.x >= dims.x || q.y >= dims.y) continue;
            for (int k = 0; k < SLOTS; k++) {
                vec4 s = texelFetch(iCellBins, ivec2(q.x * SLOTS + k, q.y), 0);
                if (s.z <= 0.0) break;
                vec2 v = fc - s.xy;
                float far = s.z + reach;
                if (dot(v, v) < far * far && n < NEAR) {
                    near[n] = s;
                    n++;
                }
            }
        }
    }

    if (n > 0) {
        // The owner is the cell with the least power here: where two
        // discs overlap, that hands each the part on its own side of the
        // line through the two points where the circles cross.
        int o = 0;
        float least = 1e12;
        for (int i = 0; i < n; i++) {
            vec2 v = fc - near[i].xy;
            float pw = dot(v, v) - near[i].z * near[i].z;
            if (pw < least) { least = pw; o = i; }
        }
        vec4 me = near[o];
        vec4 a0 = texelFetch(iCellInfo, ivec2(int(me.w), 0), 0);
        vec4 a1 = texelFetch(iCellInfo, ivec2(int(me.w), 1), 0);
        vec4 a2 = texelFetch(iCellInfo, ivec2(int(me.w), 2), 0);
        vec2 vo = fc - me.xy;
        float d_o = length(vo);
        float slack = a0.x;
        float level = clamp(a0.y, 0.0, 1.2);
        float vital = a1.x;
        float seed = a1.z;
        // What it hears besides its own band: the mids and the treble.
        // All three reach it slowly, so they sway it and never blink it.
        float mid = clamp(a1.w, 0.0, 1.2);
        float treble = clamp(a2.w, 0.0, 1.2);

        // Its outline is not quite its circle: it wobbles, more the
        // slacker the cell; a starving one crumples further, and the
        // mids slacken it a little. A dividing cell is taut, so its two
        // halves are true circles.
        float loose = slack * min(1.0 + 0.7 * (1.0 - vital) + 0.35 * mid, 1.7);
        float ball = me.z * (1.0 + wobble(atan(vo.y, vo.x + 1e-6), seed, ph) * loose);

        // Distance in to the cell's border. The cell is its outline cut
        // back along each wall, with every corner rounded: the shape a
        // disc of radius `corner` sweeps out rolling round the inside of
        // the cut one. So a packed cell keeps round shoulders, and the
        // plate shows in the gaps where three cells meet. A wall is the
        // radical axis of the two circles, which only cuts into this
        // cell once they overlap or its outline bulges across, so a
        // neighbor that is merely close changes nothing.
        float corner = 0.28 * me.z;
        float inside = ball - d_o;
        // How far past each border, drawn in by `corner`, this point is,
        // and which way that border faces.
        float past[NEAR];
        vec2 face[NEAR];
        int m = 0;
        if (inside < corner) {
            past[0] = corner - inside;
            face[0] = -vo / max(d_o, 1e-3);
            m = 1;
        }
        for (int i = 0; i < n; i++) {
            if (i == o) continue;
            vec4 c = near[i];
            vec2 between = c.xy - me.xy;
            float sep = max(length(between), 1e-3);
            if (sep >= 1.2 * (c.z + me.z)) continue;
            vec2 vj = fc - c.xy;
            float wall = (dot(-between, vj + vo) - (c.z - me.z) * (c.z + me.z)) / (2.0 * sep);
            // The wall between the two halves of a dividing cell is the
            // last thing to form: until then they are one body.
            if (abs(c.w - a0.z) < 0.5) wall += (1.0 - a0.w) * (corner + 12.0 * px);
            inside = min(inside, wall);
            if (wall < corner) {
                past[m] = corner - wall;
                face[m] = -between / sep;
                m++;
            }
        }
        if (m > 0) {
            // Distance to the drawn-in shape: to its nearest border, or
            // to the corner two borders make, whichever is further.
            float off = 0.0;
            for (int i = 0; i < m; i++) {
                off = max(off, past[i]);
                for (int j = 0; j < i; j++) {
                    float cs = dot(face[i], face[j]);
                    if (past[j] > cs * past[i] && past[i] > cs * past[j]) {
                        float both = sqrt(max(past[i] * past[i] + past[j] * past[j] - 2.0 * cs * past[i] * past[j], 0.0)
                                          / max(1.0 - cs * cs, 1e-3));
                        // Two walls that face each other leave no room
                        // for a corner; a cell that thin is drawn as cut.
                        off = max(off, mix(max(past[i], past[j]), both, smoothstep(-0.6, -0.1, cs)));
                    }
                }
            }
            inside = corner - off;
        }

        // Neighbors stand a little apart: each is drawn back from the
        // wall, and the plate shows between them.
        float edge = inside - 2.2 * px;
        float cover = smoothstep(-1.0, 1.0, edge);

        // The cell is a ball of clear gel whose outline is its own,
        // resting on the plate. A wall cuts the ball without changing
        // its curve, as the film between two pressed bubbles does, and
        // the two halves of a dividing cell are two balls coming apart.
        vec2 lean = vo / max(ball, 1.0);
        float l2 = dot(lean, lean);
        if (l2 > 1.0) { lean *= inversesqrt(l2); l2 = 1.0; }
        vec3 N = vec3(lean, sqrt(1.0 - l2));
        // The points of its upper and under surfaces seen here, and
        // where a sight line straight down is sent by each: mirrored off
        // the top, and through to the inside of the far wall, which
        // sends it the other way.
        vec3 here = vec3(fc, ball * (1.0 + N.z));
        vec3 under = vec3(fc, ball * (1.0 - N.z));
        vec3 up_ray = vec3(2.0 * N.z * lean, 2.0 * N.z * N.z - 1.0);
        vec3 back_ray = vec3(-up_ray.xy, up_ray.z);

        // Its nucleus: a smaller, denser ball floating a little off the
        // middle, swelling with the band the cell listens to.
        float core_r = (0.28 + 0.04 * level) * me.z;
        vec2 vn = vo - a2.xy;
        float core = core_r - length(vn);
        vec2 cl = vn / max(core_r, 1.0);
        vec3 CN = vec3(cl, sqrt(max(1.0 - dot(cl, cl), 0.0)));

        // What each lamp does. During a change of focus there are two:
        // one fading out as the other fades in.
        float wrap = 0.0, lens = 0.0, toward = 0.0, seen = 0.0, echo = 0.0, sheen = 0.0;
        float spill = 0.0, shadow = 0.0, core_wrap = 0.0, core_glint = 0.0;
        for (int i = 0; i < LAMPS; i++) {
            float s = iCellLamp[i].w;
            if (s < 0.004) continue;
            vec3 lp = iCellLamp[i].xyz;
            vec2 lamp = lp.xy - fc;
            vec3 L = normalize(lp - here);
            // Which side of the ball this is: 1 facing the lamp, -1 the
            // far side. Fades out right under it, where there is no side.
            float side = dot(lean, lamp) / max(length(lamp), ball);
            float far_side = max(-side, 0.0);
            toward += s * side;
            // Cloudy enough to take a little light on the lamp's side.
            wrap += s * clamp((dot(N, L) + 0.3) / 1.3, 0.0, 1.0);
            // A clear ball is a lens: the light that enters on the
            // lamp's side gathers into a crescent inside the far rim,
            // and under a lamp straight overhead into a spot beneath
            // the middle. Some of it spills on the plate behind.
            lens += s * (far_side * far_side * smoothstep(0.25, 0.95, sqrt(l2))
                         + 0.35 * (1.0 - length(L.xy)) * N.z * N.z * N.z * N.z);
            spill += s * far_side * far_side * length(L.xy);
            // The lamp's picture in the top surface is the highlight:
            // round face on, squeezed into an arc toward the rim, large
            // on a ball near the lamp and a point on a far one. A second,
            // dimmer one, upside down, sits across the middle from it.
            seen += s * lampSeen(lp, here, up_ray, ball);
            echo += s * lampSeen(lp, under, back_ray, ball);
            sheen += s * pow(max(dot(up_ray, L), 0.0), 14.0);
            // The nucleus is lit the same way, and throws a shadow.
            vec2 away = -lamp / max(length(lamp), ball);
            shadow += s * (1.0 - smoothstep(0.4 * core_r, 1.7 * core_r, length(vn - away * 0.55 * core_r)));
            core_wrap += s * clamp((dot(CN, L) + 0.2) / 1.2, 0.0, 1.0);
            core_glint += s * pow(max(dot(CN, normalize(L + vec3(0.0, 0.0, 1.0))), 0.0), 30.0);
        }

        // Its substance, lit by its band and brighter while it divides:
        // nearly clear.
        float glass = (0.14 + 0.12 * level + 0.10 * a1.y + 0.04 * iCellLook.z) * (0.3 + 0.7 * vital);
        // Seen at a glancing angle a clear surface mirrors more than it
        // passes (Schlick's fit to Fresnel), so the ball brightens at
        // its rim.
        float mirror = 0.04 + 0.96 * pow(1.0 - N.z, 5.0);
        float lit = glass * (0.30 + 1.10 * wrap) * bright + 0.34 * mirror * (0.3 + 0.7 * vital);
        vec3 body = mix(bg, tint, min(lit, 0.9));
        body = mix(body, tint, min(0.85 * lens * bright * vital, 0.85));

        // Grains adrift in the gel, each swinging about its own place.
        // They thin out as a cell tautens to divide.
        float well_in = smoothstep(0.0, 0.10 * me.z, edge);
        float grains = 0.0;
        for (int k = 0; k < GRAINS; k++) {
            float h1 = fract(seed * 91.7 + float(k) * 0.618034);
            float h2 = fract(seed * 47.3 + float(k) * 0.381966);
            float ang = TAU * h1 + 0.7 * sin(ph + TAU * h2);
            float rad = (0.42 + 0.34 * h2 + 0.05 * sin(2.0 * ph + TAU * h1)) * me.z;
            float size = (0.030 + 0.028 * h1) * me.z;
            float g = 1.0 - smoothstep(0.55 * size, size, length(vo - rad * vec2(cos(ang), sin(ang))));
            grains = max(grains, g * (0.5 + 0.5 * h2));
        }
        // The treble brightens them a little.
        vec3 grain_col = mix(bg, tint, min((glass + 0.16 + 0.22 * treble) * (0.5 + 0.8 * wrap) * bright, 0.95));
        body = mix(body, grain_col, min(0.6 + 0.15 * treble, 0.9) * grains * slack * vital * well_in);

        // The nucleus and its shadow, kept clear of the walls. It is a
        // faint thing: a soft-edged thickening of the gel, a little
        // denser than what is round it, with only a breath of shadow,
        // and in the theme's neutral foreground, not the cell's color.
        body *= 1.0 - 0.16 * min(shadow, 1.0) * well_in;
        float core_lit = (glass + 0.09 + 0.08 * level) * (0.45 + 0.95 * core_wrap) * bright;
        vec3 nucleus = mix(bg, fg, min(core_lit, 0.9));
        nucleus = mix(nucleus, fg, min(0.10 * core_glint * bright * vital, 0.9));
        body = mix(body, nucleus, 0.75 * smoothstep(-0.45 * core_r, 0.40 * core_r, core) * well_in);

        // The membrane: the film seen more and more edge on toward the
        // border, so it thickens into a soft band there and is clear
        // further in. Brighter toward the lamp.
        float skin = exp(-max(edge, 0.0) / (0.045 * me.z + 1.2 * px));
        vec3 membrane = mix(tint, fg, 0.15);
        body = mix(body, membrane, 0.46 * skin * (0.4 + 0.6 * vital) * (0.75 + 0.25 * toward) * (0.6 + 0.4 * bright));

        // Reflections. A film mirrors less face on than at a glance, but
        // a lamp is far brighter than anything round it, so its picture
        // shows everywhere; a broad soft sheen lies round it.
        float shine = seen * (0.55 + 0.45 * mirror) + 0.16 * sheen * (0.3 + 0.7 * mirror);
        body = mix(body, mix(tint, fg, 0.85), min(shine * bright * (0.4 + 0.6 * vital), 0.95));
        body = mix(body, mix(tint, fg, 0.5), min(0.34 * echo * bright * vital, 0.9));
        // The room beyond the lamps is dim but not black: a faint, wide
        // patch of it shows in every ball, up and to the left, so one far
        // from any lamp is still a ball.
        float room = max(dot(up_ray, ROOM), 0.0);
        room *= room; room *= room;
        body = mix(body, mix(tint, fg, 0.3), 0.20 * room * room * (0.4 + 0.6 * vital));

        // Outside the membrane: its soft outer edge, and on the far side
        // the light the ball has gathered, spilled on the plate.
        float out_d = max(-edge, 0.0);
        float glow = exp(-out_d / (3.4 * px)) * 0.13 * vital * (0.6 + 0.3 * level);
        float spilt = spill * exp(-out_d / (0.075 * me.z + 2.0 * px)) * (1.0 - smoothstep(0.6 * reach, reach, out_d));
        col = mix(col, tint, min(glow + 0.45 * spilt * bright * vital, 0.9) * (1.0 - cover));
        col = mix(col, body, cover);
    }

    // The view down the microscope. Dust on its glass is far out of
    // focus: each speck is a soft disc that dims what is under it and
    // scatters a haze of light, brightest in a ring at its edge, and it
    // stays put while the culture moves beneath.
    float lens = iCellLens;
    float dim = 0.0, ring = 0.0;
    for (int i = 0; i < DUST; i++) {
        vec4 d = iCellDust[i];
        float t = length(fc - d.xy) / d.z;
        if (t > 1.8) continue;
        float soft = 0.25 + 0.5 * d.w;
        float disc = 1.0 - smoothstep(1.0 - soft, 1.0, t);
        dim = max(dim, disc * iCellDustHow[i].x);
        float off = (t - 1.0) / (0.10 + 0.25 * soft);
        ring += (exp(-off * off) + 0.45 * disc) * iCellDustHow[i].y;
    }
    col *= 1.0 - lens * dim;
    col += fg * lens * min(ring, 0.25) * (0.55 + 0.45 * pool);

    vec2 uv = fc / iResolution.xy;
    col *= 1.0 - 0.22 * length(uv - 0.5);

    // Grain: fine, with coarser clumps in it, a little even in the dark
    // and more where there is light, changing a few dozen times a second.
    // Under it, the still dither that keeps dark gradients from banding.
    int tick = int(iCellClock.y) / 4;
    float lum = dot(col, vec3(0.30, 0.59, 0.11));
    float grain = 0.65 * (dither(ivec2(fc) + ivec2(tick * 37, tick * 59)) - 0.5)
                + 0.35 * (dither(ivec2(fc * 0.5) + ivec2(tick * 17, tick * 83)) - 0.5);
    col += grain * lens * (0.045 + 0.16 * lum);
    col += (dither(ivec2(fc)) - 0.5) / 255.0;
    fragColor = vec4(col, 1.0);
}
