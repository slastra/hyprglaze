//! Orbs: matte spheres set half way through a plane, seen from low and
//! close, the way a studio render of them would be.
//!
//! Every sphere has its center on the plane, so what shows is a dome, and
//! no two touch. That makes the scene a packing of discs on the plane:
//! the field below keeps them apart, and the shader traces each pixel's
//! ray against the domes and the plane and lights what it hits.
//!
//! The light is one large soft lamp behind the focused window, low over
//! the plane, so it rakes across the domes and they throw long soft
//! shadows over the plane and each other. When focus moves, that lamp
//! goes down as another comes up behind the new window. A dim cool light
//! from the whole sky fills the shadows, and lit surfaces throw a little
//! of their light back onto their neighbors.
//!
//! The field slides slowly toward the eye, as if the camera were pulling
//! back over it. A dome shrinks to nothing past the near edge of the view
//! and grows again past the far one, both out of sight. The cursor pushes
//! domes aside. In music each dome swells a little with its own band, and
//! a loud passage quickens the slide.

const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");
const lamps_mod = @import("lamps.zig");
const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

const WindowRect = shader_mod.ShaderProgram.WindowRect;
const Lamps = lamps_mod.Lamps;
const max_lamps = lamps_mod.max_lamps;

/// The most domes in the field, and the most the shader is given (ORBS
/// there).
pub const max_orbs = 64;
pub const max_sent = 48;

/// A lamp's own radius: a large one, so shadows are soft from the start.
/// The shader is told it.
const lamp_r = 0.22;
/// How many of its own radii off a dome stops hiding any of the sky from
/// a point. Must match REACH in the shader.
const sky_reach = 5.5;
/// How soft an outline is for each part in a hundred it is out of focus,
/// in screen heights. Must match SHALLOW in the shader.
const shallow = 0.013;

/// Radii at size 1, in screen heights at the middle of the view.
const r_small = 0.10;
const r_large = 0.40;
/// The least bare plane between two domes.
const gap = 0.02;
/// How far inside the near and far edges of the field a dome grows from
/// nothing, or shrinks to it.
const fade = 0.22;
/// How fast the field slides at speed 1, in screen heights a second.
const slide = 0.011;
/// How much a dome swells at the top of its band.
const swell = 0.07;

fn smooth(x: f32) f32 {
    const t = std.math.clamp(x, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// The eye. It looks down at the middle of the plane (the origin; the
/// plane is y = 0, +z is away) from low and close. One unit is the
/// screen's height at the point it looks at.
pub const Camera = struct {
    eye: [3]f32,
    right: [3]f32,
    up: [3]f32,
    /// Forward, times the focal length in screen heights.
    fwd: [3]f32,
    width: f32,
    height: f32,

    /// How far below level it looks.
    const pitch = std.math.degreesToRadians(36.0);
    /// Wide enough that the near domes loom and the far ones fall away.
    const fov = std.math.degreesToRadians(34.0);

    pub fn init(width: f32, height: f32) Camera {
        const focal = 0.5 / @tan(0.5 * fov);
        const s = @sin(pitch);
        const co = @cos(pitch);
        return .{
            .eye = .{ 0, s * focal, -co * focal },
            .right = .{ 1, 0, 0 },
            .up = .{ 0, co, s },
            .fwd = .{ 0, -s * focal, co * focal },
            .width = width,
            .height = height,
        };
    }

    /// The ray through a pixel, not normalized.
    pub fn ray(self: Camera, px: [2]f32) [3]f32 {
        const u = (px[0] - 0.5 * self.width) / self.height;
        const v = (px[1] - 0.5 * self.height) / self.height;
        var d: [3]f32 = undefined;
        for (&d, self.fwd, self.right, self.up) |*out, f, r, up| out.* = f + r * u + up * v;
        return d;
    }

    /// Where a pixel's ray meets the plane: x and z.
    pub fn ground(self: Camera, px: [2]f32) [2]f32 {
        const d = self.ray(px);
        const t = -self.eye[1] / @min(d[1], -1e-3);
        return .{ self.eye[0] + d[0] * t, self.eye[2] + d[2] * t };
    }

    /// The pixel a point is seen at.
    pub fn pixel(self: Camera, p: [3]f32) [2]f32 {
        const rel = [3]f32{ p[0] - self.eye[0], p[1] - self.eye[1], p[2] - self.eye[2] };
        const focal = @sqrt(self.fwd[1] * self.fwd[1] + self.fwd[2] * self.fwd[2]);
        const depth = (rel[1] * self.fwd[1] + rel[2] * self.fwd[2]) / focal;
        const u = rel[0] / depth * focal;
        const v = (rel[1] * self.up[1] + rel[2] * self.up[2]) / depth * focal;
        return .{ u * self.height + 0.5 * self.width, v * self.height + 0.5 * self.height };
    }

    /// How far a point is from the eye.
    pub fn range(self: Camera, p: [3]f32) f32 {
        const rel = [3]f32{ p[0] - self.eye[0], p[1] - self.eye[1], p[2] - self.eye[2] };
        return @sqrt(rel[0] * rel[0] + rel[1] * rel[1] + rel[2] * rel[2]);
    }
};

pub const Orb = struct {
    /// x and z on the plane.
    pos: [2]f32 = .{ 0, 0 },
    /// Its radius full grown and at rest.
    r: f32 = 0,
    /// The band of the music it swells to, and how much of it it hears.
    band: u8 = 0,
    level: f32 = 0,
    seed: f32 = 0,
};

/// The discs the domes stand on.
pub const Field = struct {
    orbs: [max_orbs]Orb = @splat(.{}),
    n: usize = 0,
    /// The field's edges. It wraps in z and is walled in x.
    half_x: f32,
    z0: f32,
    z1: f32,
    size: f32,
    speed: f32,
    /// How loud the music is, slowly.
    energy: f32 = 0,
    prng: std.Random.DefaultPrng,

    pub fn init(camera: Camera, size: f32, speed: f32, seed: u64) Field {
        const top = camera.ground(.{ camera.width, camera.height });
        const bottom = camera.ground(.{ 0.5 * camera.width, 0 });
        const largest = r_large * size * (1.0 + swell);
        // A dome past the near edge of the view still stands up into
        // it, by more the lower the ray it stands under. Past the far
        // edge only its crown shows, small, dim and out of focus, so
        // there it is let grow in view.
        const low = camera.ray(.{ 0.5 * camera.width, 0 });
        const sine = -low[1] / @sqrt(low[1] * low[1] + low[2] * low[2]);
        var self = Field{
            .half_x = top[0] + largest + 0.1,
            .z0 = bottom[1] - largest / (0.95 * sine) - fade - 0.05,
            .z1 = top[1] + largest * 1.2 + fade + 0.05,
            .size = size,
            .speed = speed,
            .prng = std.Random.DefaultPrng.init(seed),
        };
        const r = self.prng.random();

        // The largest are placed first, each wherever it fits, so the
        // small ones fill what is left between them.
        var radii: [max_orbs]f32 = undefined;
        for (&radii) |*radius| radius.* = self.pick();
        std.mem.sort(f32, &radii, {}, std.sort.desc(f32));
        for (radii) |radius| {
            var tries: usize = 0;
            while (tries < 400) : (tries += 1) {
                // Later tries settle for a smaller dome.
                const fit = if (tries < 200) radius else @max(r_small * size, radius * 0.6);
                const pos = [2]f32{
                    (r.float(f32) * 2.0 - 1.0) * (self.half_x - fit),
                    self.z0 + r.float(f32) * (self.z1 - self.z0),
                };
                if (!self.fits(pos, fit, max_orbs)) continue;
                self.orbs[self.n] = .{
                    .pos = pos,
                    .r = fit,
                    .band = @intCast(r.uintLessThan(u8, 6)),
                    .seed = r.float(f32),
                };
                self.n += 1;
                break;
            }
        }
        return self;
    }

    /// A radius for a new dome: any size, the large ones a little rarer.
    fn pick(self: *Field) f32 {
        const u = self.prng.random().float(f32);
        return (r_small + (r_large - r_small) * std.math.pow(f32, u, 1.25)) * self.size;
    }

    /// How far apart two points are in z, the short way round.
    fn across(self: *const Field, dz: f32) f32 {
        const span = self.z1 - self.z0;
        return dz - span * @round(dz / span);
    }

    fn fits(self: *const Field, pos: [2]f32, radius: f32, skip: usize) bool {
        for (self.orbs[0..self.n], 0..) |other, j| {
            if (j == skip) continue;
            const dx = pos[0] - other.pos[0];
            const dz = self.across(pos[1] - other.pos[1]);
            const least = (radius + other.r) * (1.0 + swell) + gap;
            if (dx * dx + dz * dz < least * least) return false;
        }
        return true;
    }

    /// The radius a dome stands at, swollen by the music, before the
    /// edges of the field take it down.
    fn girth(orb: Orb) f32 {
        return orb.r * (1.0 + swell * orb.level);
    }

    /// The radius a dome shows.
    pub fn shown(self: *const Field, i: usize) f32 {
        const orb = self.orbs[i];
        const inside = @min(orb.pos[1] - self.z0, self.z1 - orb.pos[1]);
        return girth(orb) * smooth(inside / fade);
    }

    /// `cursor` is where the cursor's ray meets the plane.
    pub fn step(self: *Field, dt_in: f32, bands: *const [6]f32, cursor: [2]f32) void {
        const dt = std.math.clamp(dt_in, 0.0, 0.05);
        var loud: f32 = 0;
        for (bands) |b| loud += b / 6.0;
        self.energy += (std.math.clamp(loud * 1.6, 0.0, 1.0) - self.energy) * @min(1.0, 0.5 * dt);

        const by = slide * self.speed * (1.0 + 0.6 * self.energy) * dt;
        for (self.orbs[0..self.n], 0..) |*orb, i| {
            // Each follows its band at its own slow pace.
            const heard = std.math.clamp(bands[orb.band] * 1.4, 0.0, 1.0);
            orb.level += (heard - orb.level) * @min(1.0, (0.7 + 1.6 * orb.seed) * dt);

            orb.pos[1] -= by;
            if (orb.pos[1] < self.z0) {
                // Past the near edge it is nothing, and comes round to
                // the far edge as another dome.
                orb.pos[1] += self.z1 - self.z0;
                const r = self.prng.random();
                var radius = self.pick();
                var tries: usize = 0;
                while (tries < 8 and !self.fits(orb.pos, radius, i)) : (tries += 1) radius = @max(r_small * self.size, radius * 0.8);
                orb.r = radius;
                orb.band = @intCast(r.uintLessThan(u8, 6));
                orb.seed = r.float(f32);
            }
        }

        // The cursor is a small post the domes slide round.
        const post = 0.05;
        const ease = @min(1.0, 5.0 * dt);
        for (self.orbs[0..self.n]) |*orb| {
            const dx = orb.pos[0] - cursor[0];
            const dz = orb.pos[1] - cursor[1];
            const d = @sqrt(dx * dx + dz * dz);
            const least = girth(orb.*) + post;
            if (d >= least or d < 1e-5) continue;
            const push = (least - d) * ease / d;
            orb.pos[0] += dx * push;
            orb.pos[1] += dz * push;
        }

        // Domes that have come to overlap, by one being pushed or
        // swelling, part again, the smaller giving more way.
        for (0..3) |_| {
            for (0..self.n) |i| {
                for (i + 1..self.n) |j| {
                    const a = &self.orbs[i];
                    const b = &self.orbs[j];
                    const dx = a.pos[0] - b.pos[0];
                    const dz = self.across(a.pos[1] - b.pos[1]);
                    const least = girth(a.*) + girth(b.*) + gap;
                    const d2 = dx * dx + dz * dz;
                    if (d2 >= least * least or d2 < 1e-10) continue;
                    const d = @sqrt(d2);
                    const over = (least - d) * 0.5 / d;
                    const wa = b.r * b.r / (a.r * a.r + b.r * b.r);
                    a.pos[0] += dx * over * wa;
                    a.pos[1] += dz * over * wa;
                    b.pos[0] -= dx * over * (1.0 - wa);
                    b.pos[1] -= dz * over * (1.0 - wa);
                }
            }
            for (self.orbs[0..self.n]) |*orb| {
                const wall = self.half_x - girth(orb.*);
                orb.pos[0] = std.math.clamp(orb.pos[0], -wall, wall);
                if (orb.pos[1] >= self.z1) orb.pos[1] -= self.z1 - self.z0;
                if (orb.pos[1] < self.z0) orb.pos[1] += self.z1 - self.z0;
            }
        }
    }

    /// How high a lamp over `at` must hang to clear the domes, with a
    /// little to spare. Nothing, away from them all.
    pub fn clear(self: *const Field, at: [2]f32) f32 {
        var high: f32 = 0;
        for (self.orbs[0..self.n], 0..) |orb, i| {
            const reach = self.shown(i) + 0.12;
            const dx = orb.pos[0] - at[0];
            const dz = orb.pos[1] - at[1];
            const under = reach * reach - dx * dx - dz * dz;
            if (under > 0) high = @max(high, @sqrt(under) + 0.05);
        }
        return high;
    }

    /// The domes for the shader, nearest the eye first: x, z, radius,
    /// seed. Returns how many. Those that neither show, nor stand near
    /// enough to what shows to shade it, nor throw a shadow into view
    /// from any of `lamps` (x, height, z, strength), are left out: the
    /// shader's work is in proportion to the count.
    pub fn pack(self: *const Field, camera: Camera, lamps: []const [4]f32, out: *[max_sent][4]f32) usize {
        const view = [4][2]f32{
            camera.ground(.{ 0, 0 }),
            camera.ground(.{ camera.width, 0 }),
            camera.ground(.{ camera.width, camera.height }),
            camera.ground(.{ 0, camera.height }),
        };
        var near: [max_sent]f32 = undefined;
        var count: usize = 0;
        for (self.orbs[0..self.n], 0..) |orb, i| {
            const radius = self.shown(i);
            if (radius < 1e-3) continue;
            if (!matters(view, orb.pos, radius, lamps)) continue;
            const d = camera.range(.{ orb.pos[0], 0, orb.pos[1] }) - radius;
            // Put in place among those already taken. Should more
            // matter than the shader takes, the farthest go without.
            if (count == max_sent) {
                if (near[count - 1] <= d) continue;
                count -= 1;
            }
            var k = count;
            while (k > 0 and near[k - 1] > d) : (k -= 1) {
                near[k] = near[k - 1];
                out[k] = out[k - 1];
            }
            near[k] = d;
            out[k] = .{ orb.pos[0], orb.pos[1], radius, orb.seed };
            count += 1;
        }
        for (out[count..]) |*rest| rest.* = .{ 0, 0, 0, 0 };
        return count;
    }
};

/// How far outside the part of the plane in view a point is (negative
/// inside). Past a corner it reads a little short, which only errs
/// toward keeping a dome.
fn outside(view: [4][2]f32, p: [2]f32) f32 {
    var most: f32 = -1e9;
    for (view, 0..) |a, i| {
        const b = view[(i + 1) % 4];
        const ex = b[0] - a[0];
        const ez = b[1] - a[1];
        // The corners run counter-clockwise seen from above with +z up
        // the page, so outside is to the right of each edge.
        most = @max(most, ((p[0] - a[0]) * ez - (p[1] - a[1]) * ex) / @sqrt(ex * ex + ez * ez));
    }
    return most;
}

/// How far past a dome its shadow from a lamp can be seen on the plane,
/// given how far off along the plane the lamp is and how high.
fn shadowLength(radius: f32, d: f32, high: f32) f32 {
    // The soft edge of the shadow runs on past where the lamp is wholly
    // hidden.
    const tall = radius + lamp_r;
    return if (high > tall * 1.05) @min(6.0, d * tall / (high - tall) + 0.1) else 6.0;
}

/// How far to either side of the line from the lamp through a dome its
/// shadow reaches, `along` past the dome: it fans out from the lamp, and
/// its edge softens as it goes.
fn shadowWidth(radius: f32, d: f32, along: f32) f32 {
    const soft = @min(lamp_r, lamp_r * (along + radius) / @max(d, 0.3));
    // And a little over, for a lamp that moves between one making of
    // the shader's lists and the next.
    return (radius + soft) * (1.0 + along / @max(d, 0.05)) + 0.05;
}

fn matters(view: [4][2]f32, pos: [2]f32, radius: f32, lamps: []const [4]f32) bool {
    // In view (a dome past the edge still stands up into it), or near
    // enough to hide some of the sky from what is.
    if (outside(view, pos) < 3.2 * radius + 0.05) return true;
    for (lamps) |lamp| {
        if (lamp[3] <= 0) continue;
        const dx = pos[0] - lamp[0];
        const dz = pos[1] - lamp[2];
        const d = @max(@sqrt(dx * dx + dz * dz), 1e-3);
        const len = shadowLength(radius, d, lamp[1]);
        var along: f32 = 0;
        while (along <= len) : (along += 0.5 * radius) {
            const q = [2]f32{ pos[0] + dx / d * along, pos[1] + dz / d * along };
            if (outside(view, q) < shadowWidth(radius, d, along) + 0.3 * radius) return true;
        }
    }
    return false;
}

/// Entries a screen tile and a bin of the plane can hold. Must match
/// TILE_SLOTS and BIN_SLOTS in the shader. Each list is stored as its
/// length, then its entries: a loop the shader runs to a length it reads
/// stops there, where one with a fixed bound and a way out is unrolled
/// by the driver to the full bound at every pixel.
pub const tile_slots = 16;
pub const bin_slots = 32;
const tile_stride = tile_slots + 1;
const bin_stride = bin_slots + 1;

/// What lets the shader pass over most domes at each pixel: for every
/// tile of the screen, the domes that can show in it, nearest first; and
/// for every bin of the plane, the domes that can shade a point over it,
/// by hiding some of its sky or by standing between it and a lamp.
pub const Index = struct {
    allocator: std.mem.Allocator,
    /// A tile's side in px, and how many across and up.
    tile: f32,
    tw: usize,
    th: usize,
    tiles: []u8,
    /// A bin's side, how many across and along, and the corner they
    /// start from (x, z).
    bin: f32,
    bw: usize,
    bh: usize,
    origin: [2]f32,
    bins: []u8,
    /// Which domes each bin has already.
    bin_has: []u64,
    /// The most a bin was asked to hold in the last build.
    fullest: usize = 0,

    pub fn init(allocator: std.mem.Allocator, camera: Camera, field: *const Field) !Index {
        const tile = std.math.clamp(@round(camera.height / 24.0), 24.0, 160.0);
        const tw: usize = @intFromFloat(@ceil(camera.width / tile));
        const th: usize = @intFromFloat(@ceil(camera.height / tile));
        const bin = 0.3;
        const bw: usize = @intFromFloat(@ceil(2.0 * field.half_x / bin));
        const bh: usize = @intFromFloat(@ceil((field.z1 - field.z0) / bin));
        const tiles = try allocator.alloc(u8, tw * th * tile_stride);
        errdefer allocator.free(tiles);
        const bins = try allocator.alloc(u8, bw * bh * bin_stride);
        errdefer allocator.free(bins);
        const bin_has = try allocator.alloc(u64, bw * bh);
        @memset(tiles, 0);
        @memset(bins, 0);
        return .{
            .allocator = allocator,
            .tile = tile,
            .tw = tw,
            .th = th,
            .tiles = tiles,
            .bin = bin,
            .bw = bw,
            .bh = bh,
            .origin = .{ -field.half_x, field.z0 },
            .bins = bins,
            .bin_has = bin_has,
        };
    }

    pub fn deinit(self: *Index) void {
        self.allocator.free(self.tiles);
        self.allocator.free(self.bins);
        self.allocator.free(self.bin_has);
    }

    /// `sent` is what the shader is given, nearest first; `lamps` are x,
    /// height, z, strength; `focus` is the distance in focus and `blur`
    /// how shallow the focus is.
    pub fn build(self: *Index, camera: Camera, sent: []const [4]f32, lamps: []const [4]f32, focus: f32, blur: f32) void {
        @memset(self.tiles, 0);
        @memset(self.bins, 0);
        @memset(self.bin_has, 0);
        self.fullest = 0;

        const focal = @sqrt(camera.fwd[1] * camera.fwd[1] + camera.fwd[2] * camera.fwd[2]);
        for (sent, 0..) |orb, j| {
            const center = [3]f32{ orb[0], 0, orb[1] };
            const radius = orb[2];
            const rel = [3]f32{ center[0] - camera.eye[0], -camera.eye[1], center[2] - camera.eye[2] };
            const depth = (rel[1] * camera.fwd[1] + rel[2] * camera.fwd[2]) / focal;
            if (depth - radius < 0.05) {
                // All but at the eye: it could be anywhere.
                for (0..self.tw * self.th) |at| self.intoTile(at, @intCast(j));
                continue;
            }
            // Its outline is soft by `w` px, as the shader reckons px
            // at its distance: the ball with that much added is what
            // can show. No point of that ball is drawn farther from
            // where its center is drawn than `reach`.
            const px = camera.pixel(center);
            const u = (px[0] - 0.5 * camera.width) / camera.height;
            const v = (px[1] - 0.5 * camera.height) / camera.height;
            const off = @sqrt(u * u + v * v) / focal;
            const range = camera.range(center);
            const span = focal * camera.height;
            const nearest = @max(range - radius - 0.1, 0.05);
            const farthest = range + radius + 0.1;
            const w = @max(0.75, shallow * blur * camera.height * @max(@abs(farthest - focus), @abs(nearest - focus)) / nearest);
            const ball = radius + (w + 1.0) * farthest / span;
            if (depth - ball < 0.05) {
                for (0..self.tw * self.th) |at| self.intoTile(at, @intCast(j));
                continue;
            }
            const reach = span * ball / (depth - ball) * (1.0 + off) + 1.0;
            const x0 = self.tileAt(px[0] - reach, self.tw) orelse 0;
            const x1 = self.tileAt(px[0] + reach, self.tw) orelse self.tw - 1;
            const y0 = self.tileAt(px[1] - reach, self.th) orelse 0;
            const y1 = self.tileAt(px[1] + reach, self.th) orelse self.th - 1;
            if (px[0] + reach < 0 or px[1] + reach < 0 or px[0] - reach > camera.width or px[1] - reach > camera.height) continue;
            var ty = y0;
            while (ty <= y1) : (ty += 1) {
                var tx = x0;
                while (tx <= x1) : (tx += 1) {
                    const lx = @as(f32, @floatFromInt(tx)) * self.tile;
                    const ly = @as(f32, @floatFromInt(ty)) * self.tile;
                    const dx = px[0] - std.math.clamp(px[0], lx, lx + self.tile);
                    const dy = px[1] - std.math.clamp(px[1], ly, ly + self.tile);
                    if (dx * dx + dy * dy <= reach * reach) self.intoTile(ty * self.tw + tx, @intCast(j));
                }
            }
        }

        // What hides sky goes in first, so that should a bin ever fill,
        // it is a far-off shadow that is lost.
        for (sent, 0..) |orb, j| self.mark(.{ orb[0], orb[1] }, sky_reach * orb[2], @intCast(j));
        for (lamps) |lamp| {
            if (lamp[3] <= 0) continue;
            for (sent, 0..) |orb, j| {
                const radius = orb[2];
                const dx = orb[0] - lamp[0];
                const dz = orb[1] - lamp[2];
                const d = @max(@sqrt(dx * dx + dz * dz), 1e-3);
                const len = shadowLength(radius, d, lamp[1]);
                // Discs half their own width apart, a little over
                // size, cover the whole of the shadow between them. Past
                // the edge of the bins there is nothing to mark.
                const span = @as(f32, @floatFromInt(self.bw + self.bh)) * self.bin;
                var along: f32 = 0;
                while (along <= @min(len, span)) {
                    const wide = shadowWidth(radius, d, along);
                    const q = [2]f32{ orb[0] + dx / d * along, orb[1] + dz / d * along };
                    self.mark(q, wide * 1.2, @intCast(j));
                    along += 0.5 * wide;
                }
            }
        }
    }

    fn tileAt(self: *const Index, px: f32, count: usize) ?usize {
        if (px < 0) return null;
        const at: usize = @intFromFloat(px / self.tile);
        return if (at >= count) null else at;
    }

    fn intoTile(self: *Index, at: usize, j: u8) void {
        const list = self.tiles[at * tile_stride ..][0..tile_stride];
        // Full: those behind go without. They are in order, nearest
        // first.
        if (list[0] >= tile_slots) return;
        list[0] += 1;
        list[list[0]] = j;
    }

    /// Every bin any part of which is within `reach` of `at` takes `j`.
    fn mark(self: *Index, at: [2]f32, reach: f32, j: u8) void {
        const fx0 = (at[0] - reach - self.origin[0]) / self.bin;
        const fx1 = (at[0] + reach - self.origin[0]) / self.bin;
        const fz0 = (at[1] - reach - self.origin[1]) / self.bin;
        const fz1 = (at[1] + reach - self.origin[1]) / self.bin;
        const w: f32 = @floatFromInt(self.bw);
        const h: f32 = @floatFromInt(self.bh);
        if (fx1 < 0 or fz1 < 0 or fx0 >= w or fz0 >= h) return;
        const x0: usize = @intFromFloat(@max(fx0, 0));
        const x1: usize = @intFromFloat(@min(fx1, w - 1));
        const z0: usize = @intFromFloat(@max(fz0, 0));
        const z1: usize = @intFromFloat(@min(fz1, h - 1));
        const bit = @as(u64, 1) << @intCast(j);
        var bz = z0;
        while (bz <= z1) : (bz += 1) {
            var bx = x0;
            while (bx <= x1) : (bx += 1) {
                const k = bz * self.bw + bx;
                if (self.bin_has[k] & bit != 0) continue;
                const lx = self.origin[0] + @as(f32, @floatFromInt(bx)) * self.bin;
                const lz = self.origin[1] + @as(f32, @floatFromInt(bz)) * self.bin;
                const dx = at[0] - std.math.clamp(at[0], lx, lx + self.bin);
                const dz = at[1] - std.math.clamp(at[1], lz, lz + self.bin);
                if (dx * dx + dz * dz > reach * reach) continue;
                self.bin_has[k] |= bit;
                self.fullest = @max(self.fullest, @popCount(self.bin_has[k]));
                const list = self.bins[k * bin_stride ..][0..bin_stride];
                if (list[0] >= bin_slots) continue;
                list[0] += 1;
                list[list[0]] = j;
            }
        }
    }

    /// The domes that can show at a pixel.
    pub fn tileList(self: *const Index, px: [2]f32) []const u8 {
        const tx = @min(self.tw - 1, @as(usize, @intFromFloat(@max(px[0], 0) / self.tile)));
        const ty = @min(self.th - 1, @as(usize, @intFromFloat(@max(px[1], 0) / self.tile)));
        const at = ty * self.tw + tx;
        return self.tiles[at * tile_stride + 1 ..][0..self.tiles[at * tile_stride]];
    }

    /// The domes that can shade a point over `at` on the plane.
    pub fn binList(self: *const Index, at: [2]f32) []const u8 {
        const bx = @min(self.bw - 1, @as(usize, @intFromFloat(@max((at[0] - self.origin[0]) / self.bin, 0))));
        const bz = @min(self.bh - 1, @as(usize, @intFromFloat(@max((at[1] - self.origin[1]) / self.bin, 0))));
        const k = bz * self.bw + bx;
        return self.bins[k * bin_stride + 1 ..][0..self.bins[k * bin_stride]];
    }
};

/// Where the light comes from.
const Light = enum {
    /// Behind the focused window; off to the right when there is none.
    focus,
    /// Carried by the cursor.
    cursor,
    /// Off to the right.
    fixed,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    camera: Camera,
    field: Field,
    light: Light,
    lamps: Lamps = .{},
    /// For each lamp: the lowest it hangs, how far its light carries,
    /// and how far along the plane from it things are lit at full
    /// strength.
    hang: [max_lamps][3]f32 = @splat(.{ 1.0, 2.3, 2.6 }),
    /// How high each hangs now: it rides up over a dome that passes
    /// under it.
    high: [max_lamps]f32 = @splat(1.0),
    /// Where the cursor's lamp has got to.
    carried: ?[2]f32 = null,
    /// Palette slots of the lamp's color and the sky's.
    key: f32,
    fill: f32,
    /// How shallow the focus is (0 = everything sharp).
    blur: f32,
    /// How much film grain lies over the picture (0 = none).
    grain: f32,
    frame: u32 = 0,
    index: Index,
    /// The tiles' lists and the bins'.
    tex: [2]c.GLuint = .{ 0, 0 },
    /// Time not yet given to the field, whether it has moved since the
    /// shader's lists were last made, and the domes those lists are of.
    owed: f32 = 0,
    stale: bool = true,
    sent: [max_sent][4]f32 = @splat(.{ 0, 0, 0, 0 }),
    count: usize = 0,

    u: Uniforms(.{
        .orb = "iOrb[0]",
        .count = "iOrbCount",
        .eye = "iOrbEye",
        .right = "iOrbRight",
        .up = "iOrbUp",
        .fwd = "iOrbFwd",
        .lamp = "iOrbLamp[0]",
        .lamp_how = "iOrbLampHow[0]",
        .look = "iOrbLook",
        .clock = "iOrbClock",
        .tiles = "iOrbTiles",
        .bins = "iOrbBins",
        .grid = "iOrbGrid",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const camera = Camera.init(@max(width, 64.0), @max(height, 64.0));
        const field = Field.init(
            camera,
            std.math.clamp(params.getFloat("size", 1.0), 0.7, 1.4),
            std.math.clamp(params.getFloat("speed", 1.0), 0.0, 6.0),
            0x0b5,
        );
        var music = try spectral.Analyzer.init(allocator, params);
        errdefer music.deinit(allocator);
        return .{
            .allocator = allocator,
            .music = music,
            .camera = camera,
            .field = field,
            .index = try Index.init(allocator, camera, &field),
            .light = std.meta.stringToEnum(Light, params.getString("light", null) orelse "focus") orelse .focus,
            .key = @floatFromInt(std.math.clamp(params.getInt("key", 5), -1, 15)),
            .fill = @floatFromInt(std.math.clamp(params.getInt("fill", 4), -1, 15)),
            .blur = std.math.clamp(params.getFloat("blur", 1.0), 0.0, 3.0),
            .grain = std.math.clamp(params.getFloat("grain", 1.0), 0.0, 3.0),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        _ = self.music.update(dt);
        // The field moves slowly enough that seventy steps a second show
        // it as smoothly as more would, so on a fast display it sits out
        // every other frame, and the lists the shader looks things up in
        // are made half as often. The lamps move every frame.
        self.owed += dt;
        if (self.owed >= 1.0 / 70.0) {
            self.field.step(self.owed, &self.music.bands.bands, self.camera.ground(state.cursor));
            self.owed = 0;
            self.stale = true;
        }
        self.frame +%= 1;

        const cam = self.camera;
        // With nothing focused the lamp stands well off to the right, a
        // little toward the eye, so its light comes in low across the
        // whole view.
        const home = cam.pixel(.{ 2.5, 0, -0.7 });
        const home_hang = [3]f32{ 1.0, 2.3, 2.6 };
        var id: u64 = lamps_mod.home_id;
        var pos = home;
        var hang = home_hang;
        switch (self.light) {
            .fixed => {},
            .cursor => {
                const goal = [2]f32{
                    std.math.clamp(state.cursor[0], 0.0, cam.width),
                    std.math.clamp(state.cursor[1], 0.0, cam.height),
                };
                const at = self.carried orelse goal;
                const ease = @min(1.0, 3.5 * dt);
                pos = .{ at[0] + (goal[0] - at[0]) * ease, at[1] + (goal[1] - at[1]) * ease };
                self.carried = pos;
                hang = .{ 0.3, 1.2, 0.8 };
                id = lamps_mod.cursor_id;
            },
            .focus => if (state.focused_address > lamps_mod.cursor_id) {
                for (state.windows) |w| {
                    if (w.address != state.focused_address or w.w < 1.0 or w.h < 1.0) continue;
                    id = w.address;
                    pos = .{ w.x + w.w * 0.5, w.y + w.h * 0.5 };
                    hang = hangFor(cam, w);
                    break;
                }
            },
        }
        self.lamps.step(dt, id, pos, state.windows);
        for (self.lamps.lamps, &self.hang, &self.high) |lamp, *h, *high| {
            if (lamp.id == id) {
                h.* = hang;
            } else for (state.windows) |w| {
                if (w.address == lamp.id and w.w >= 1.0 and w.h >= 1.0) h.* = hangFor(cam, w);
            }
            // Up at once, so it is never inside a dome, and down at
            // leisure.
            const least = @max(h[0], self.field.clear(cam.ground(lamp.pos)));
            high.* = if (lamp.glow <= 0) least else @max(least, high.* - 0.5 * dt);
        }
    }

    /// A lamp behind a large window hangs higher and carries farther,
    /// so what shows round the window is lit at much the same angle
    /// whatever the window's size.
    fn hangFor(cam: Camera, w: WindowRect) [3]f32 {
        const half = 0.5 * @sqrt(w.w * w.h) / cam.height;
        return .{ 0.3 + 0.4 * half, 1.7 + 1.3 * half, 1.4 * half + 0.35 };
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        const cam = self.camera;
        // The lamps that are lit, first.
        var lamps: [max_lamps][4]f32 = @splat(.{ 0, 1, 0, 0 });
        var how: [max_lamps][3]f32 = @splat(.{ 1, lamp_r, 1 });
        var lit: usize = 0;
        for (self.lamps.lamps, self.hang, self.high) |lamp, hang, high| {
            if (lamp.id == 0 or lamp.strength() <= 0) continue;
            const at = cam.ground(lamp.pos);
            lamps[lit] = .{ at[0], high, at[1], lamp.strength() };
            // How far it carries, its own radius, and what its falloff
            // is scaled by to be one at its full-strength distance.
            const full2 = high * high + hang[2] * hang[2];
            how[lit] = .{ hang[1], lamp_r, 1.0 + full2 / (hang[1] * hang[1]) };
            lit += 1;
        }
        // The lens is focused nearer than the middle of the view.
        const focus = 0.9 * cam.range(.{ 0, 0, 0 });
        const index = &self.index;
        const fresh = self.stale or self.tex[0] == 0;
        if (fresh) {
            self.count = self.field.pack(cam, lamps[0..lit], &self.sent);
            index.build(cam, self.sent[0..self.count], lamps[0..lit], focus, self.blur);
            self.stale = false;
        }
        const count = self.count;

        const tiles_w: c.GLsizei = @intCast(index.tw * tile_stride);
        const tiles_h: c.GLsizei = @intCast(index.th);
        const bins_w: c.GLsizei = @intCast(index.bw * bin_stride);
        const bins_h: c.GLsizei = @intCast(index.bh);
        if (self.tex[0] == 0) {
            c.glGenTextures(2, &self.tex);
            for (self.tex, [2][2]c.GLsizei{ .{ tiles_w, tiles_h }, .{ bins_w, bins_h } }) |tex, size| {
                c.glBindTexture(c.GL_TEXTURE_2D, tex);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
                c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8UI, size[0], size[1], 0, c.GL_RED_INTEGER, c.GL_UNSIGNED_BYTE, null);
            }
        }
        // Rows of single bytes, of any length.
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glActiveTexture(c.GL_TEXTURE1);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[1]);
        if (fresh) c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, bins_w, bins_h, c.GL_RED_INTEGER, c.GL_UNSIGNED_BYTE, index.bins.ptr);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[0]);
        if (fresh) c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, tiles_w, tiles_h, c.GL_RED_INTEGER, c.GL_UNSIGNED_BYTE, index.tiles.ptr);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);

        self.u.use(prog.program);
        self.u.int(.tiles, 0);
        self.u.int(.bins, 1);
        self.u.f4(.grid, index.tile, index.bin, index.origin[0], index.origin[1]);
        self.u.f4v(.orb, max_sent, &self.sent[0]);
        self.u.f2(.count, @floatFromInt(count), @floatFromInt(lit));
        self.u.f3(.eye, cam.eye[0], cam.eye[1], cam.eye[2]);
        self.u.f3(.right, cam.right[0], cam.right[1], cam.right[2]);
        self.u.f3(.up, cam.up[0], cam.up[1], cam.up[2]);
        self.u.f3(.fwd, cam.fwd[0], cam.fwd[1], cam.fwd[2]);
        self.u.f4v(.lamp, max_lamps, &lamps[0]);
        self.u.f3v(.lamp_how, max_lamps, &how[0]);
        // The far edge of the view is lost in the dark.
        const far = cam.range(blk: {
            const at = cam.ground(.{ 0.5 * cam.width, cam.height });
            break :blk .{ at[0], 0, at[1] };
        });
        self.u.f4(.look, self.key, self.fill, focus, self.blur);
        self.u.f4(.clock, @floatFromInt(self.frame % 1024), self.field.energy, far, self.grain);
    }

    pub fn deinit(self: *Context) void {
        if (self.tex[0] != 0) c.glDeleteTextures(2, &self.tex);
        self.index.deinit();
        self.music.deinit(self.allocator);
    }
};

const quiet: [6]f32 = @splat(0);
const nowhere = [2]f32{ -1e6, -1e6 };

fn clearance(field: *const Field) f32 {
    var least: f32 = 1e9;
    for (0..field.n) |i| {
        for (i + 1..field.n) |j| {
            const a = field.orbs[i];
            const b = field.orbs[j];
            const dx = a.pos[0] - b.pos[0];
            const dz = field.across(a.pos[1] - b.pos[1]);
            least = @min(least, @sqrt(dx * dx + dz * dz) - Field.girth(a) - Field.girth(b));
        }
    }
    return least;
}

test "the eye sees the plane across the whole screen, and a point on it comes back to its pixel" {
    const cam = Camera.init(3840, 2160);
    const corners = [_][2]f32{ .{ 0, 0 }, .{ 3840, 0 }, .{ 0, 2160 }, .{ 3840, 2160 }, .{ 1234, 567 } };
    for (corners) |px| {
        const at = cam.ground(px);
        try std.testing.expect(@abs(at[0]) < 3.0 and @abs(at[1]) < 3.0);
        const back = cam.pixel(.{ at[0], 0, at[1] });
        try std.testing.expectApproxEqAbs(px[0], back[0], 0.05);
        try std.testing.expectApproxEqAbs(px[1], back[1], 0.05);
    }
    // The middle of the screen looks at the origin, farther up the
    // screen is farther away, and a unit there is a screen height.
    try std.testing.expectApproxEqAbs(@as(f32, 0), cam.ground(.{ 1920, 1080 })[1], 1e-4);
    try std.testing.expect(cam.ground(.{ 1920, 2160 })[1] > cam.ground(.{ 1920, 0 })[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 1920 + 2160), cam.pixel(.{ 1, 0, 0 })[0], 0.05);
}

test "the field is well filled, with domes of every size, and no two touch however long it runs" {
    const cam = Camera.init(3840, 2160);
    var field = Field.init(cam, 1.0, 1.0, 7);
    try std.testing.expect(field.n >= 40);
    var covered: f32 = 0;
    var small: usize = 0;
    var large: usize = 0;
    for (field.orbs[0..field.n]) |orb| {
        covered += std.math.pi * orb.r * orb.r;
        if (orb.r < 0.18) small += 1;
        if (orb.r > 0.3) large += 1;
    }
    try std.testing.expect(covered / (2.0 * field.half_x * (field.z1 - field.z0)) > 0.4);
    try std.testing.expect(small >= 4 and large >= 4);
    try std.testing.expect(clearance(&field) >= gap - 1e-4);

    // Ten minutes, in which every dome comes round at least once, with
    // the cursor wandering through them.
    var least: f32 = 1e9;
    for (0..36000) |i| {
        const t: f32 = @floatFromInt(i);
        const cursor = [2]f32{ 0.8 * @sin(t * 0.004), 0.1 + 0.5 * @sin(t * 0.0031) };
        field.step(1.0 / 60.0, &quiet, cursor);
        if (i % 20 == 0) least = @min(least, clearance(&field));
        for (field.orbs[0..field.n]) |orb| {
            try std.testing.expect(@abs(orb.pos[0]) <= field.half_x);
            try std.testing.expect(orb.pos[1] >= field.z0 and orb.pos[1] <= field.z1);
        }
    }
    try std.testing.expect(least > -0.02);
}

test "a dome is nothing where it comes round: near the eye it shrinks out of sight, far off only its crown shows as it grows" {
    const cam = Camera.init(3840, 2160);
    var field = Field.init(cam, 1.0, 1.0, 7);
    field.n = 1;
    const orb = &field.orbs[0];
    orb.r = r_large;
    orb.pos = .{ 0, field.z0 + 1e-4 };
    try std.testing.expect(field.shown(0) < 1e-3);
    orb.pos = .{ 0, field.z1 - 1e-4 };
    try std.testing.expect(field.shown(0) < 1e-3);

    var z = field.z0;
    while (z < field.z1) : (z += 0.01) {
        orb.pos = .{ 0, z };
        const radius = field.shown(0);
        if (radius >= r_large - 1e-4) continue;
        if (z > 0) {
            // Far off, where it meets the plane is past the top of the
            // screen.
            try std.testing.expect(cam.pixel(.{ 0, 0, z - radius })[1] > cam.height);
            continue;
        }
        // Near the eye, every point of the half circle of it that the
        // eye looks along is below the screen.
        var a: f32 = 0;
        while (a < std.math.pi) : (a += 0.05) {
            const p = [3]f32{ 0, radius * @sin(a), z + radius * @cos(a) };
            try std.testing.expect(cam.pixel(p)[1] < 0);
        }
    }
}

test "the cursor pushes a dome aside, and in music a dome swells and its neighbors make room" {
    const cam = Camera.init(3840, 2160);
    var field = Field.init(cam, 1.0, 0.0, 7);
    // The dome nearest the middle of the view.
    var mid: usize = 0;
    for (field.orbs[0..field.n], 0..) |orb, i| {
        const best = field.orbs[mid];
        if (orb.pos[0] * orb.pos[0] + orb.pos[1] * orb.pos[1] < best.pos[0] * best.pos[0] + best.pos[1] * best.pos[1]) mid = i;
    }
    const was = field.orbs[mid].pos;
    const cursor = [2]f32{ was[0] + 0.02, was[1] };
    for (0..600) |_| field.step(1.0 / 60.0, &quiet, cursor);
    const now = field.orbs[mid].pos;
    const d = @sqrt((now[0] - cursor[0]) * (now[0] - cursor[0]) + (now[1] - cursor[1]) * (now[1] - cursor[1]));
    try std.testing.expect(d >= field.orbs[mid].r);
    try std.testing.expect(clearance(&field) > -0.01);

    const loud: [6]f32 = @splat(0.8);
    const before = field.shown(mid);
    for (0..600) |_| field.step(1.0 / 60.0, &loud, nowhere);
    try std.testing.expect(field.shown(mid) > before * 1.03);
    try std.testing.expect(clearance(&field) > -0.01);
}

test "the shader is given every dome that shows or shadows what shows, and not the rest" {
    const cam = Camera.init(3840, 2160);
    var field = Field.init(cam, 1.0, 1.0, 7);
    const lamps = [_][4]f32{.{ 2.5, 1.0, -0.7, 1 }};
    var out: [max_sent][4]f32 = undefined;
    const count = field.pack(cam, &lamps, &out);
    try std.testing.expect(count < field.n);
    try std.testing.expect(count >= 12);

    // Every dome any of whose crown or rim falls on the screen is there.
    for (field.orbs[0..field.n], 0..) |orb, i| {
        const radius = field.shown(i);
        var seen = false;
        var a: f32 = 0;
        while (a < std.math.tau) : (a += 0.1) {
            var b: f32 = 0;
            while (b < 0.5 * std.math.pi) : (b += 0.1) {
                const px = cam.pixel(.{
                    orb.pos[0] + radius * @cos(a) * @cos(b),
                    radius * @sin(b),
                    orb.pos[1] + radius * @sin(a) * @cos(b),
                });
                if (px[0] >= 0 and px[0] <= cam.width and px[1] >= 0 and px[1] <= cam.height) seen = true;
            }
        }
        if (!seen) continue;
        var sent = false;
        for (out[0..count]) |o| {
            if (o[0] == orb.pos[0] and o[1] == orb.pos[1]) sent = true;
        }
        try std.testing.expect(sent);
    }
    // And they come nearest the eye first.
    for (out[0 .. count - 1], out[1..count]) |a, b| {
        try std.testing.expect(cam.range(.{ a[0], 0, a[1] }) - a[2] <= cam.range(.{ b[0], 0, b[1] }) - b[2] + 1e-5);
    }

    // A dome well off to the side, away from the lamp, is left out. One
    // between a low lamp and the view is kept for its shadow, and left
    // out when the lamp is high and its shadow falls short.
    field.n = 1;
    field.orbs[0] = .{ .pos = .{ -1.9, 0.9 }, .r = 0.12 };
    field.half_x = 3;
    try std.testing.expectEqual(@as(usize, 0), field.pack(cam, &lamps, &out));
    field.orbs[0].pos = .{ 1.75, -0.45 };
    try std.testing.expect(outside(.{ cam.ground(.{ 0, 0 }), cam.ground(.{ 3840, 0 }), cam.ground(.{ 3840, 2160 }), cam.ground(.{ 0, 2160 }) }, field.orbs[0].pos) > 3.2 * 0.12 + 0.05);
    const high = [_][4]f32{.{ 2.5, 3.0, -0.7, 1 }};
    try std.testing.expectEqual(@as(usize, 0), field.pack(cam, &high, &out));
    const low = [_][4]f32{.{ 2.5, 0.2, -0.7, 1 }};
    try std.testing.expectEqual(@as(usize, 1), field.pack(cam, &low, &out));
}

test "a lamp rides up over a dome that passes under it" {
    const cam = Camera.init(3840, 2160);
    var field = Field.init(cam, 1.0, 1.0, 7);
    field.n = 1;
    field.orbs[0] = .{ .pos = .{ 0, 0 }, .r = 0.4 };
    try std.testing.expect(field.clear(.{ 0, 0 }) > 0.4);
    try std.testing.expect(field.clear(.{ 0.3, 0 }) > @sqrt(0.4 * 0.4 - 0.3 * 0.3));
    try std.testing.expectEqual(@as(f32, 0), field.clear(.{ 0.6, 0 }));
}

fn has(list: []const u8, j: usize) bool {
    for (list) |e| {
        if (e == j) return true;
    }
    return false;
}

test "the lists the shader looks up leave out no dome that shows at a pixel or shades a point" {
    const cam = Camera.init(3840, 2160);
    var field = Field.init(cam, 1.0, 1.0, 7);
    var index = try Index.init(std.testing.allocator, cam, &field);
    defer index.deinit();
    const focus = 0.9 * cam.range(.{ 0, 0, 0 });
    const blur = 1.0;
    // A lamp off to the side, and a low one in the middle of the view,
    // as behind a small window: long shadows every way.
    const lamps = [_][4]f32{ .{ 2.5, 1.0, -0.7, 0.5 }, .{ 0.1, 0.62, 0.2, 0.5 } };
    var prng = std.Random.DefaultPrng.init(3);
    const r = prng.random();
    var out: [max_sent][4]f32 = undefined;
    var shorter: usize = 0;
    var checked: usize = 0;

    for (0..40) |round| {
        for (0..600) |_| field.step(1.0 / 60.0, &quiet, nowhere);
        const count = field.pack(cam, &lamps, &out);
        const sent = out[0..count];
        index.build(cam, sent, &lamps, focus, blur);
        try std.testing.expect(index.fullest <= bin_slots);

        for (0..400) |_| {
            // A pixel, and the ray through it.
            const px = [2]f32{ r.float(f32) * cam.width, r.float(f32) * cam.height };
            var rd = cam.ray(px);
            const len = @sqrt(rd[0] * rd[0] + rd[1] * rd[1] + rd[2] * rd[2]);
            for (&rd) |*x| x.* /= len;
            const span = @sqrt(cam.fwd[1] * cam.fwd[1] + cam.fwd[2] * cam.fwd[2]) * cam.height;
            const list = index.tileList(px);
            try std.testing.expect(list.len <= tile_slots);
            shorter += list.len;
            checked += 1;

            // What the ray comes to first: a dome, or the plane.
            var p = blk: {
                const t = -cam.eye[1] / rd[1];
                break :blk [3]f32{ cam.eye[0] + rd[0] * t, 0, cam.eye[2] + rd[2] * t };
            };
            var best: f32 = 1e9;
            for (sent, 0..) |orb, j| {
                const oc = [3]f32{ orb[0] - cam.eye[0], -cam.eye[1], orb[1] - cam.eye[2] };
                const along = oc[0] * rd[0] + oc[1] * rd[1] + oc[2] * rd[2];
                const miss2 = oc[0] * oc[0] + oc[1] * oc[1] + oc[2] * oc[2] - along * along;
                const miss = @sqrt(@max(miss2, 0));
                // Behind the eye.
                if (along <= 0) continue;
                const w = @max(0.75, shallow * blur * cam.height * @abs(along - focus) / along);
                // As the shader has it: drawn wherever the ray passes
                // within the soft outline. The tile's list must not be
                // full, or the dome must be in it.
                if ((orb[2] - miss) * span / along > -w and list.len < tile_slots) try std.testing.expect(has(list, j));
                if (miss >= orb[2]) continue;
                const t = along - @sqrt(orb[2] * orb[2] - miss2);
                const hit = [3]f32{ cam.eye[0] + rd[0] * t, cam.eye[1] + rd[1] * t, cam.eye[2] + rd[2] * t };
                if (hit[1] < 0 or t >= best) continue;
                best = t;
                p = hit;
            }

            // Every dome that hides sky from that point, or stands in
            // the way of a lamp, is in the list of the bin it is over.
            const near = index.binList(.{ p[0], p[2] });
            for (sent, 0..) |orb, j| {
                const d = [3]f32{ orb[0] - p[0], -p[1], orb[1] - p[2] };
                const l2 = d[0] * d[0] + d[1] * d[1] + d[2] * d[2];
                var shades = l2 < sky_reach * sky_reach * orb[2] * orb[2];
                for (lamps) |lamp| {
                    var to = [3]f32{ lamp[0] - p[0], lamp[1] - p[1], lamp[2] - p[2] };
                    const dist = @sqrt(to[0] * to[0] + to[1] * to[1] + to[2] * to[2]);
                    for (&to) |*x| x.* /= dist;
                    const along = d[0] * to[0] + d[1] * to[1] + d[2] * to[2];
                    if (along <= 0) continue;
                    const clear = @sqrt(@max(l2 - along * along, 0)) - orb[2];
                    if (clear < @min(along, dist) * lamp_r / dist) shades = true;
                }
                // The dome the point is on shades itself by its own
                // shape, not through the list.
                if (shades and l2 > orb[2] * orb[2] * 1.0001) try std.testing.expect(has(near, j));
            }
        }
        _ = round;
    }
    // And the lists are worth having: a few domes a tile, of dozens.
    try std.testing.expect(shorter / checked < 10);
}
