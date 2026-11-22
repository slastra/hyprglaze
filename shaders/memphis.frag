#version 300 es
precision highp float;
precision highp usampler2D;

// A Memphis print in two flat colors (src/effects/memphis.zig): discs,
// triangles, squares, zigzag strokes and fields of halftone dots. A pixel
// starts as paper and flips between paper and ink once for every shape it
// is inside, so wherever two shapes overlap the color turns over. So that
// a pixel need not look at every shape, each tile of the screen lists the
// shapes that can show in it.
// Lengths are screen heights, from the bottom left corner.
uniform vec3 iResolution;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

const int SHAPES = 80;
// How far outside its radius a shape may still draw, as a part of it.
const float SLACK = 0.2;
// The loose dots between the shapes: their lattice's pitch.
const float SPRINKLE_PITCH = 0.085;
const int TILE_STRIDE = 16;

uniform vec4 iShape[SHAPES];     // x, y, radius, kind with the seed as its fraction
uniform vec4 iShapeHow[SHAPES];  // how it is turned, two numbers of its kind's, how loud its band is
uniform vec2 iShapeCount;        // how many shapes, how loud the music is
uniform usampler2D iShapeTiles;  // TILE_STRIDE texels a tile: how many shapes, then indices into iShape
uniform float iShapeTile;        // a tile's side px
uniform vec2 iSprinkle;          // how far the loose dots have slid
uniform vec4 iMemphisLook;       // palette slots of ink and paper, ink mixed into the paper, size

out vec4 fragColor;

uint mixBits(uint h) {
    h ^= h >> 15; h *= 0x2c1b3c6du;
    h ^= h >> 12; h *= 0x297a2d39u;
    h ^= h >> 15;
    return h;
}

// Four numbers in 0..1 for a lattice cell.
vec4 rand4(ivec2 id, uint salt) {
    uint a = mixBits(uint(id.x) * 0x8da6b343u + uint(id.y) * 0xd8163841u + salt * 0x9e3779b9u);
    uint b = mixBits(a ^ 0x7f4a7c15u);
    return vec4(float(a & 0xffffu), float(a >> 16), float(b & 0xffffu), float(b >> 16)) / 65535.0;
}

// One for the `i`th part of a shape.
float rand1(float seed, int i) {
    return float(mixBits(uint(seed * 65535.0) * 0x9e3779b9u + uint(i) * 0x85ebca6bu + 0x1234567u) >> 8) / 16777216.0;
}

// `q` as seen by something turned by `a`.
vec2 turned(vec2 q, float a) {
    float c = cos(a), s = sin(a);
    return vec2(c * q.x + s * q.y, -s * q.x + c * q.y);
}

// How much of a pixel is inside an outline it is `d` from.
float inside(float d) {
    return clamp(0.5 - d * iResolution.y, 0.0, 1.0);
}

// The same for a dot `len` from its middle. A dot smaller than a pixel
// fades out rather than holding on as one gray pixel.
float dotInside(float len, float rad) {
    float px = rad * iResolution.y;
    return clamp(0.5 - (len - rad) * iResolution.y, 0.0, 1.0) * clamp(2.0 * px * px, 0.0, 1.0);
}

// How far outside the edge from `u` to `v` of a shape whose corners run
// counter-clockwise.
float beyond(vec2 q, vec2 u, vec2 v) {
    vec2 e = normalize(v - u);
    return dot(q - u, vec2(e.y, -e.x));
}

// A triangle with its corners on the circle: one at the top, the other
// two each moved round a way from where an even triangle has them.
float triangle(vec2 q, float r, float a, float b) {
    vec2 p0 = vec2(0.0, r);
    vec2 p1 = r * vec2(cos(3.6652 + a), sin(3.6652 + a));
    vec2 p2 = r * vec2(cos(5.7596 + b), sin(5.7596 + b));
    return max(max(beyond(q, p0, p1), beyond(q, p1, p2)), beyond(q, p2, p0));
}

// The `i`th corner of a zigzag of `n` strokes: across the shape from left
// to right, alternately low and high, the inner high ones moved aside so
// the strokes are long and short by turns.
vec2 corner(int i, int n, float reach, float pace, float amp, float lean, float seed) {
    bool odd = (i & 1) == 1;
    float x = -reach + float(i) * pace + ((odd && i < n) ? lean : 0.0);
    float y = (odd ? amp : -amp) * (0.75 + 0.25 * rand1(seed, i));
    return vec2(x, y);
}

// A zigzag stroke of even thickness with square ends and pointed
// corners. Each stroke is a rectangle, and each corner the lozenge where
// the two strokes' bands cross, which fills in the point.
float zigzag(vec2 q, float r, float strokes, float thick, float seed, float level) {
    int n = int(strokes);
    float reach = 0.7 * r;
    float pace = 2.0 * reach / strokes;
    float amp = min(0.5 * r, 1.1 * pace) * (0.7 + 0.3 * rand1(seed, 9)) * (1.0 + 0.2 * level);
    float lean = (rand1(seed, 8) - 0.5) * 1.2 * pace;
    float half_w = 0.5 * thick;
    float d = 1e9;
    float last = 0.0;
    vec2 a = corner(0, n, reach, pace, amp, lean, seed);
    for (int i = 0; i < 4; i++) {
        if (i >= n) break;
        vec2 b = corner(i + 1, n, reach, pace, amp, lean, seed);
        vec2 e = b - a;
        float len = length(e);
        vec2 t = e / len;
        vec2 w = q - a;
        float off = abs(t.x * w.y - t.y * w.x);
        d = min(d, max(off - half_w, abs(dot(w, t) - 0.5 * len) - 0.5 * len));
        if (i > 0) d = min(d, max(off, last) - half_w);
        last = off;
        a = b;
    }
    return d;
}

// A field of halftone dots on a lattice. `which`: 0 a round field whose
// dots grow across it toward `grow`, 1 a square one likewise, 2 a round
// one whose dots grow toward its middle, 3 a square one of even dots.
float halftone(vec2 q, float r, float pitch, float which, float grow, float seed, float level) {
    float lat = seed < 0.5 ? 0.7854 : (seed < 0.75 ? 0.0 : 0.5236);
    vec2 cell = floor(turned(q, lat) / pitch + 0.5);
    vec2 c = turned(cell * pitch, -lat);
    bool square = which == 1.0 || which == 3.0;
    float out_by = square ? max(abs(c.x), abs(c.y)) / (0.72 * r) : length(c) / r;
    if (out_by > 1.0) return 0.0;
    float t = 0.72;
    if (which < 1.5) t = 0.5 + dot(c, vec2(cos(grow), sin(grow))) / (1.7 * r);
    else if (which < 2.5) t = 1.0 - length(c) / r;
    float rad = pitch * 0.43 * pow(clamp(t, 0.0, 1.0), 1.25) * (1.0 + 0.25 * level);
    return dotInside(length(q - c), min(rad, 0.47 * pitch));
}

// A loose scatter of dots of all sizes, dwindling toward its rim.
float scatter(vec2 q, float r, float pitch, float most, float seed, float level) {
    ivec2 id = ivec2(floor(q / pitch));
    vec4 h = rand4(id, uint(seed * 65535.0));
    if (h.x > 0.62) return 0.0;
    vec2 c = (vec2(id) + 0.5 + (h.yz - 0.5) * 0.3) * pitch;
    float fall = clamp((1.0 - length(c) / r) * 3.0, 0.0, 1.0);
    float rad = pitch * most * (0.4 + 0.6 * h.w) * fall * (1.0 + 0.25 * level);
    return dotInside(length(q - c), rad);
}

// The loose dots that lie between the shapes everywhere.
float sprinkle(vec2 p, float size, float loud) {
    vec2 g = (p + iSprinkle) / SPRINKLE_PITCH;
    ivec2 id = ivec2(floor(g));
    vec4 h = rand4(id & 63, 0x51u);
    if (h.x > 0.26) return 0.0;
    vec2 c = (vec2(id) + 0.5 + (h.yz - 0.5) * 0.5) * SPRINKLE_PITCH - iSprinkle;
    float rad = size * (0.0025 + 0.0085 * h.w * h.w * h.w) * (1.0 + 0.2 * loud);
    return dotInside(length(p - c), rad);
}

vec3 slot(float s, vec3 otherwise) {
    int i = int(s);
    return (iPaletteSize == 0 || s < 0.0 || i >= iPaletteSize) ? otherwise : iPalette[i];
}

void main() {
    vec2 p = gl_FragCoord.xy / iResolution.y;
    float px = 1.0 / iResolution.y;

    float v = sprinkle(p, iMemphisLook.w, iShapeCount.y);
    // The loop runs to a length read from the texture: one with a fixed
    // bound and a break gets unrolled to the full bound at every pixel.
    ivec2 tile = ivec2(gl_FragCoord.xy / iShapeTile);
    int first = tile.x * TILE_STRIDE;
    int n = int(texelFetch(iShapeTiles, ivec2(first, tile.y), 0).r);
    for (int e = 1; e <= n; e++) {
        int i = int(texelFetch(iShapeTiles, ivec2(first + e, tile.y), 0).r);
        vec4 s = iShape[i];
        vec2 q = p - s.xy;
        float r = s.z;
        float reach = r * (1.0 + SLACK) + px;
        if (dot(q, q) > reach * reach) continue;
        vec4 how = iShapeHow[i];
        int kind = int(s.w);
        float seed = fract(s.w) / 0.999;
        float c;
        if (kind == 0) c = inside(length(q) - r);
        else if (kind == 1) c = inside(triangle(turned(q, how.x), r, how.y, how.z));
        else if (kind == 2) {
            vec2 t = abs(turned(q, how.x));
            c = inside(max(t.x, t.y) - 0.7071 * r);
        }
        else if (kind == 3) c = inside(zigzag(turned(q, how.x), r, how.y, how.z, seed, how.w));
        else if (kind == 4) c = halftone(q, r, how.y, how.z, how.x, seed, how.w);
        else c = scatter(turned(q, how.x), r, how.y, how.z, seed, how.w);
        // Inside one more shape: the color turns over.
        v = v + c - 2.0 * v * c;
    }

    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.04, 0.04, 0.06);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    vec3 ink = slot(iMemphisLook.x, fg);
    vec3 paper = mix(slot(iMemphisLook.y, bg), ink, iMemphisLook.z);
    fragColor = vec4(mix(paper, ink, v), 1.0);
}
