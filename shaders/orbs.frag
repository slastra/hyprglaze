#version 300 es
precision highp float;
precision highp usampler2D;

// Matte spheres set half way through a plane (src/effects/orbs.zig), seen
// from low and close. Each pixel's ray is traced
// against the domes and the plane, and what it hits is lit by one large
// soft lamp low over the plane, a dim cool sky, and the light its
// neighbors throw back. Domes away from the plane of focus have soft
// outlines. So that a pixel need not look at every dome, each tile of the
// screen lists the domes that can show in it, and each bin of the plane
// the domes that can shade a point over it.
uniform vec3 iResolution;

uniform vec3 iPalette[16];
uniform int iPaletteSize;
uniform vec3 iPaletteBg;
uniform vec3 iPaletteFg;

const int ORBS = 48;
const int LAMPS = 3;

uniform vec4 iOrb[ORBS];         // x and z on the plane, radius, seed; nearest the eye first
uniform vec2 iOrbCount;           // how many domes, how many lamps (lit ones come first)
uniform vec3 iOrbEye;
uniform vec3 iOrbRight;
uniform vec3 iOrbUp;
uniform vec3 iOrbFwd;            // forward, times the focal length in screen heights
uniform vec4 iOrbLamp[LAMPS];    // where it hangs, strength 0 to 1
uniform vec3 iOrbLampHow[LAMPS]; // how far its light carries, its radius, its gain
uniform vec4 iOrbLook;           // palette slots of the lamp and the sky, distance in focus, how shallow the focus
uniform vec4 iOrbClock;          // frame number, how loud the music is, how far off the far edge of the view is, how much grain

uniform usampler2D iOrbTiles;    // TILE_SLOTS + 1 texels a tile: how many, then indices into iOrb, nearest first
uniform usampler2D iOrbBins;     // BIN_SLOTS + 1 texels a bin, likewise
uniform vec4 iOrbGrid;           // a tile's side px, a bin's side, the bins' corner x and z

out vec4 fragColor;

const int TILE_SLOTS = 16;
const int BIN_SLOTS = 32;
// How many of its own radii off a dome stops hiding any sky.
const float REACH = 5.5;
// How soft an outline is for how far out of focus, in screen heights.
const float SHALLOW = 0.013;

// Where the sky is brightest: up, to the left, a little toward the eye.
const vec3 SKY = vec3(-0.48, 0.80, -0.36);
// How much of the light that falls on it a surface throws back.
const float ALBEDO = 0.7;

uint mixBits(uint h) {
    h ^= h >> 15; h *= 0x2c1b3c6du;
    h ^= h >> 12; h *= 0x297a2d39u;
    h ^= h >> 15;
    return h;
}

float dither(ivec2 p, uint salt) {
    return float(mixBits(uint(p.x) * 0x8da6b343u + uint(p.y) * 0xd8163841u + salt) >> 8) / 16777216.0;
}

// What a dome at `d` from a point (the square of how far is `l2`, its
// radius `r`; it hides `hid` of the point's sky, and `near` is one over
// how far it is when it hides any) does to one lamp's light there: how
// much of the lamp it leaves in sight, and how much of the lamp's light
// it throws back. Most domes in a list do neither to a given point, and
// those cost no more than a dot product.
vec2 domeAndLamp(vec3 d, float l2, float r, float hid, float near, vec3 toward, float dist, float power, float size) {
    float along = dot(d, toward);
    // What it hides it also lights, by what the lamp lays on the side
    // of it that faces the point.
    float back = hid * power * clamp(0.3 - 0.7 * along * near, 0.0, 1.0);
    // Its shadow: how far the way to the lamp clears it, against how
    // wide the lamp looks from there.
    float seen = 1.0;
    if (along > 0.0) {
        float soft = max(min(along, dist) * size / dist, 1e-4);
        float aside2 = l2 - along * along;
        float reach = r + soft;
        if (aside2 < reach * reach) seen = smoothstep(-soft, soft, sqrt(max(aside2, 0.0)) - r);
    }
    return vec2(seen, back);
}

// The light at a point `p` with normal `n`: from the lamps, from the
// sky, and thrown back by what is round it. `self` is the dome the point
// is on, or -1 on the plane.
vec3 lightAt(vec3 p, vec3 n, int self) {
    int lamps = int(iOrbCount.y);
    vec3 toward[LAMPS];
    float dist[LAMPS];
    float power[LAMPS];
    float shade[LAMPS];
    for (int k = 0; k < LAMPS; k++) {
        vec3 l = iOrbLamp[k].xyz - p;
        float d = length(l);
        toward[k] = l / d;
        dist[k] = d;
        float carry = iOrbLampHow[k].x;
        power[k] = iOrbLamp[k].w * iOrbLampHow[k].z / (1.0 + d * d / (carry * carry));
        shade[k] = 1.0;
    }

    float open = 1.0;
    float back = 0.0;
    ivec2 size = textureSize(iOrbBins, 0);
    ivec2 bin = clamp(ivec2(floor((p.xz - iOrbGrid.zw) / iOrbGrid.y)), ivec2(0), ivec2(size.x / (BIN_SLOTS + 1) - 1, size.y - 1));
    int first = bin.x * (BIN_SLOTS + 1);
    // Every loop here runs to a length that is read, never to a fixed
    // one: the driver unrolls a fixed bound in full at every pixel.
    int count = int(texelFetch(iOrbBins, ivec2(first, bin.y), 0).r);
    for (int e = 1; e <= count; e++) {
        int j = int(texelFetch(iOrbBins, ivec2(first + e, bin.y), 0).r);
        if (j == self) continue;
        vec4 o = iOrb[j];
        vec3 d = vec3(o.x - p.x, -p.y, o.y - p.z);
        float r = o.z;
        float l2 = dot(d, d);

        // How much of the sky it hides: a sphere's share of what the
        // point sees, less when the point's own horizon cuts it, and
        // fading to nothing a few radii off.
        float hid = 0.0;
        float near = 0.0;
        if (l2 < REACH * REACH * r * r) {
            float h2 = l2 / (r * r);
            near = inversesqrt(l2);
            float nl = dot(n, d) * near;
            float nh = nl / (near * r);
            float part = clamp(0.5 * (nh + 1.0) / h2, 0.0, 1.0);
            hid = min((nh >= 1.0) ? nl / h2 : part * sqrt(part), 1.0);
            hid *= 1.0 - smoothstep(0.6 * REACH * REACH, REACH * REACH, h2);
            open *= 1.0 - hid;
        }

        // Nearly always there is the one lamp.
        vec2 both = domeAndLamp(d, l2, r, hid, near, toward[0], dist[0], power[0], iOrbLampHow[0].y);
        shade[0] *= both.x;
        back += both.y;
        for (int k = 1; k < lamps; k++) {
            both = domeAndLamp(d, l2, r, hid, near, toward[k], dist[k], power[k], iOrbLampHow[k].y);
            shade[k] *= both.x;
            back += both.y;
        }
    }

    float key = 0.0;
    for (int k = 0; k < lamps; k++) {
        // A large lamp wraps a little past where a point of light would
        // stop, and its edge on a dome is never a line.
        float x = clamp((dot(n, toward[k]) + 0.22) / 1.22, 0.0, 1.0);
        float face = x * x * (1.7 - 0.7 * x);
        key += power[k] * shade[k] * face;
        if (self >= 0) {
            // A dome's lower flanks look at the plane, which is lit on
            // the side toward the lamp and in the dome's own shadow on
            // the other.
            vec2 out2 = n.xz / max(length(n.xz), 1e-4);
            vec2 to2 = toward[k].xz / max(length(toward[k].xz), 1e-4);
            float lit = smoothstep(-0.3, 0.7, dot(out2, to2));
            back += (0.5 - 0.5 * n.y) * power[k] * shade[k] * max(toward[k].y, 0.0) * lit;
        }
    }
    // The plane hides the lower half of the sky from a dome's flanks.
    if (self >= 0) open *= 0.5 + 0.5 * n.y;

    float sky = open * (0.55 + 0.45 * dot(n, SKY));
    return vec3(key, sky, ALBEDO * back);
}

// `far` is how far off the point is, from 0 at the plane of focus to 1
// at the far edge of the view: distance takes the light out of things.
vec3 paint(vec3 light, float rim, float far, vec3 bg, vec3 keyc, vec3 skyc) {
    float haze = 1.0 - 0.62 * smoothstep(0.0, 1.0, far);
    light.xz *= haze * haze;
    light.y *= haze;
    float sky = light.y;
    // Lamp light, with what is thrown back counted in, and rolled off
    // so the brightest faces never clip.
    float lit = 1.0 - exp(-1.9 * (light.x + 0.75 * light.z));
    vec3 col = mix(bg, skyc, 0.02 + 0.30 * sky + 0.08 * rim * sky);
    col = mix(col, keyc, 0.96 * lit);
    return col;
}

void main() {
    vec2 fc = gl_FragCoord.xy;
    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.04, 0.04, 0.06);
    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    int ks = int(iOrbLook.x);
    int fs = int(iOrbLook.y);
    vec3 keyc = (iPaletteSize == 0 || ks < 0 || ks >= iPaletteSize) ? fg : mix(iPalette[ks], fg, 0.55);
    vec3 skyc = (iPaletteSize == 0 || fs < 0 || fs >= iPaletteSize) ? mix(bg, fg, 0.5) : iPalette[fs];

    vec2 uv = (fc - 0.5 * iResolution.xy) / iResolution.y;
    vec3 rd = normalize(iOrbFwd + iOrbRight * uv.x + iOrbUp * uv.y);
    vec3 ro = iOrbEye;
    // Pixels a unit spans at a unit's distance.
    float span = length(iOrbFwd) * iResolution.y;
    float focus = iOrbLook.z;
    float shallow = SHALLOW * iOrbLook.w * iResolution.y;

    vec3 acc = vec3(0.0);
    float cover = 0.0;
    ivec2 tile = ivec2(fc / iOrbGrid.x);
    int first = tile.x * (TILE_SLOTS + 1);
    int count = int(texelFetch(iOrbTiles, ivec2(first, tile.y), 0).r);
    for (int e = 1; e <= count; e++) {
        int i = int(texelFetch(iOrbTiles, ivec2(first + e, tile.y), 0).r);
        vec4 o = iOrb[i];
        vec3 c = vec3(o.x, 0.0, o.y);
        float r = o.z;
        vec3 oc = c - ro;
        float along = dot(oc, rd);
        // Behind the eye.
        if (along <= 0.0) continue;
        vec3 off = rd * along - oc;
        float miss = length(off);
        float scale = span / along;
        // Out of focus, its outline is soft.
        float w = max(0.75, shallow * abs(along - focus) / along);
        float edge = (r - miss) * scale;
        if (edge <= -w) continue;

        // Where the ray meets it. A ray that only passes close by, in
        // the soft outline, is given the point on the rim.
        float m = min(miss, r);
        vec3 inward = off * (m / max(miss, 1e-6));
        vec3 n = (inward - rd * sqrt(r * r - m * m)) / r;
        vec3 p = c + n * r;
        // Below the plane it is hidden.
        float a = smoothstep(-w, w, edge) * smoothstep(-w, w, p.y * scale);
        if (a <= 0.002) continue;
        n.y = max(n.y, 0.0);
        n = normalize(n);
        p = c + n * r;

        float rim = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
        float far = (length(p - ro) - focus) / (iOrbClock.z - focus);
        vec3 col = paint(lightAt(p, n, i), rim, far, bg, keyc, skyc);
        acc += (1.0 - cover) * a * col;
        cover += (1.0 - cover) * a;
        if (cover > 0.995) break;
    }
    if (cover <= 0.995) {
        float t = -ro.y / min(rd.y, -1e-4);
        vec3 p = ro + rd * t;
        float far = (t - focus) / (iOrbClock.z - focus);
        vec3 col = paint(lightAt(p, vec3(0.0, 1.0, 0.0), -1), 0.0, far, bg, keyc, skyc);
        acc += (1.0 - cover) * col;
    }

    // The picture falls off a little toward its edges.
    vec2 q = fc / iResolution.xy - 0.5;
    acc = mix(acc, bg, clamp(0.7 * dot(q, q) + 0.9 * q.y * q.y, 0.0, 0.7));

    // Film grain: fine, with coarser clumps in it, a little even in the
    // dark and more where there is light, changing a few dozen times a
    // second.
    ivec2 ip = ivec2(fc);
    int tick = int(iOrbClock.x) / 4;
    float lum = dot(acc, vec3(0.30, 0.59, 0.11));
    float grain = 0.65 * (dither(ip + ivec2(tick * 37, tick * 59), 0u) - 0.5)
                + 0.35 * (dither(ivec2(fc * 0.5) + ivec2(tick * 17, tick * 83), 0u) - 0.5);
    acc += grain * iOrbClock.w * (0.035 + 0.08 * lum);

    // Under it, the still noise that keeps smooth dark gradients from
    // banding in eight bits.
    vec3 noise = vec3(dither(ip, 0u), dither(ip, 0x9e3779b9u), dither(ip, 0x7f4a7c15u)) - 0.5;
    fragColor = vec4(acc + noise / 255.0, 1.0);
}
