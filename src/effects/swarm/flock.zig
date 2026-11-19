//! A murmuration: thousands of starlings in a shallow slab of air, watched
//! from the side. Screen x and y are the slab's width and height; z is
//! depth, toward the viewer. Everything here is CPU and GL-free.
//!
//! The flocking is topological (Ballerini et al. 2008): a bird steers by
//! its seven nearest neighbors however far away they are, not by everyone
//! inside a radius. That is what lets a real flock stretch, thin and split
//! without falling apart. Around it sit the pieces of Hildenbrandt, Carere
//! and Hemelrijk's StarDisplay model (2010): a cruise speed each bird holds,
//! a home range it turns back into, a preference for level flight, and a
//! roll that follows how hard it is turning.
//!
//! Seen from the side, a level bird is a sliver and a banked one shows its
//! wings. A wave of agitation (Procaccini et al. 2011) passes from neighbor
//! to neighbor and each bird it reaches rolls, so the wave crosses the
//! flock as a band of flashing wings.

const std = @import("std");
const clock = @import("../clock.zig");

pub const max_birds = 8192;
/// Neighbors a bird steers by.
pub const k_nbr = 7;

const max_sites = 33; // 32 windows and the ground
const max_slots = 512;
const hash_buckets = 8192;
/// Seconds after rolling with a wave before a bird will join another.
const refractory: f32 = 0.9;
/// Address of the ground, the roost when no window is up.
const ground_addr: u64 = 1;

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32, address: u64 = 0 };

pub const State = enum(u8) {
    flying,
    /// Coming down onto its perch.
    landing,
    /// Sitting on a window's top edge, in view.
    perched,
    /// Roosting out of sight behind its window: an edge holds only so many.
    hidden,
};

pub const Bird = struct {
    p: [3]f32 = .{ 0, 0, 0 },
    v: [3]f32 = .{ 0, 0, 0 },
    roll: f32 = 0,
    /// Wingbeat phase and rate (rad, rad/s).
    flap: f32 = 0,
    flap_rate: f32 = 50,
    state: State = .flying,
    nbr: [k_nbr]u16 = @splat(0),
    nbr_n: u8 = 0,
    /// Packed cell of the neighbor grid, set each frame.
    key: u32 = 0,

    // The agitation wave. `since` is seconds since this bird last rolled
    // with it, `amp` how strong the wave was when it arrived, and `fuse`
    // the reaction time still to run before it joins in (-1: not primed).
    amp: f32 = 0,
    since: f32 = 100,
    fuse: f32 = -1,

    // Roosting: the site and place along its edge this bird makes for,
    // the slot it holds once perched, and the wait before it lifts off
    // (-1: staying put).
    site: u8 = 0,
    /// The site's generation when this bird chose it: a slot in the table
    /// can pass to another window.
    site_gen: u16 = 0,
    perch_u: f32 = 0,
    slot: i16 = -1,
    leave_in: f32 = -1,
    /// Landing, and over the edge: on its final drop to the perch.
    final: bool = false,
};

/// A bird as the neighbor grid holds it.
const Entry = struct { p: [3]f32, key: u32, idx: u16 };

/// A top edge birds roost on.
const Site = struct {
    used: bool = false,
    live: bool = false,
    gen: u16 = 0,
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    taken: [max_slots]bool = @splat(false),
};

/// One bird as drawn, in screen px: where it is, half its body, and its
/// wing axis and wing normal (already scaled to the span), from which the
/// vertex shader beats the wings.
pub const Instance = extern struct {
    x: f32,
    y: f32,
    bx: f32,
    by: f32,
    ax: f32 = 0,
    ay: f32 = 0,
    nx: f32 = 0,
    ny: f32 = 0,
    alpha: f32,
    /// 0 nearest the viewer, 1 farthest.
    far: f32,
    /// How much wing it is showing to the wave, 0..1.
    flash: f32,
    size: f32,
    /// Screen velocity, px/s: the flock steps slower than the display and
    /// the vertex shader carries each bird between steps.
    vx: f32 = 0,
    vy: f32 = 0,
    /// Wingbeat phase and rate (rad, rad/s). A rate of 0 folds the wings.
    flap: f32 = 0,
    flap_rate: f32 = 0,
};

pub const Inputs = struct {
    dt: f32,
    windows: []const Rect,
    cursor: [2]f32,
    /// Low end of the music, 0..1. The flock quickens with it. (Speed is
    /// the safe thing to tune: pulling harder, or packing closer, balls a
    /// flock of seven-neighbor birds up into separate clumps.)
    bass: f32 = 0,
    /// Strength of a kick landing this frame, 0 for none.
    kick: f32 = 0,
    /// The flock should be down on its roost.
    roost: bool = false,
};

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn sdBox(px: f32, py: f32, r: Rect) f32 {
    const qx = @abs(px - (r.x + r.w * 0.5)) - r.w * 0.5;
    const qy = @abs(py - (r.y + r.h * 0.5)) - r.h * 0.5;
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0);
}

fn cellHash(key: u32) u32 {
    var h = key *% 0x9E3779B1;
    h ^= h >> 15;
    h *%= 0x85EBCA6B;
    h ^= h >> 13;
    return h & (hash_buckets - 1);
}

/// 0..1, fixed for a slot on a site.
fn slotNoise(site: u8, slot: i16) f32 {
    var h = @as(u32, site) *% 0x9E3779B1 +% @as(u32, @intCast(slot)) *% 0x85EBCA6B;
    h ^= h >> 15;
    h *%= 0x2c1b3c6d;
    h ^= h >> 12;
    return @as(f32, @floatFromInt(h & 0xffff)) / 65536.0;
}

pub const Flock = struct {
    allocator: std.mem.Allocator,
    birds: []Bird,
    w: f32,
    h: f32,
    /// Pixel scale against a 1440-line screen.
    s: f32,
    /// Cruise speed, px/s.
    cruise: f32,
    /// Half the slab's depth.
    depth: f32,
    rng: std.Random.DefaultPrng,
    /// State of the per-bird noise (xorshift): thousands of draws a step,
    /// none of which need to be good.
    noise: u32 = 0x9E3779B9,
    now: f64 = 0,
    frame: u32 = 0,

    // Neighbor grid: birds counting-sorted by hashed cell, each entry a
    // copy of what a search needs so a scan never leaves the array.
    order: []Entry,
    starts: []u32,
    cell: f32,

    // Distance to the nearest window on a coarse grid, rebuilt when the
    // windows change. Birds only need its value and slope.
    sdf: []f32,
    sdf_cell: f32,
    sdf_w: usize,
    sdf_h: usize,
    field_wins: [32]Rect = undefined,
    field_n: usize = std.math.maxInt(usize),
    /// How much the windows count as obstacles, 0..1. On a desktop that is
    /// nearly all window (a tiled workspace) there is no sky left to steer
    /// into, and the flock flies behind the windows instead of being
    /// squeezed into the gaps between them.
    solid: f32 = 1,

    sites: [max_sites]Site = @splat(.{}),
    roosting: bool = false,
    roost_t: f32 = 0,
    /// Center of the range the flock wheels in.
    home: [2]f32,
    /// Set for the frame the cursor flushed the roost.
    alarm: bool = false,

    /// Birds in the air (flying or landing), on an edge, and out of sight.
    aloft: usize = 0,
    perched: usize = 0,
    hidden: usize = 0,

    pub fn init(allocator: std.mem.Allocator, count: usize, w: f32, h: f32, speed: f32) !Flock {
        const n = @min(count, max_birds);
        const s = std.math.clamp(h / 1440.0, 0.5, 2.5);
        const birds = try allocator.alloc(Bird, n);
        errdefer allocator.free(birds);
        const order = try allocator.alloc(Entry, n);
        errdefer allocator.free(order);
        const starts = try allocator.alloc(u32, hash_buckets + 1);
        errdefer allocator.free(starts);
        const sdf_cell = 32.0 * s;
        const sdf_w: usize = @as(usize, @intFromFloat(@ceil(@max(w, 1.0) / sdf_cell))) + 2;
        const sdf_h: usize = @as(usize, @intFromFloat(@ceil(@max(h, 1.0) / sdf_cell))) + 2;
        const sdf = try allocator.alloc(f32, sdf_w * sdf_h);
        errdefer allocator.free(sdf);

        var self = Flock{
            .allocator = allocator,
            .birds = birds,
            .w = w,
            .h = h,
            .s = s,
            .cruise = speed * s,
            .depth = h * 0.24,
            .rng = std.Random.DefaultPrng.init(0x5EED_B12D),
            .order = order,
            .starts = starts,
            .cell = 30.0 * s,
            .sdf = sdf,
            .sdf_cell = sdf_cell,
            .sdf_w = sdf_w,
            .sdf_h = sdf_h,
            .home = .{ w * 0.5, h * 0.5 },
        };

        // One loose cloud with a shared heading, so the flock starts whole
        // instead of condensing out of a mist.
        const r = self.rng.random();
        const heading = r.float(f32) * std.math.tau;
        const spread = 0.16 * h;
        for (birds) |*b| {
            b.* = .{};
            const a = r.float(f32) * std.math.tau;
            const rad = @sqrt(r.float(f32)) * spread;
            b.p = .{
                w * 0.5 + @cos(a) * rad * 1.6,
                h * 0.5 + @sin(a) * rad,
                (r.float(f32) * 2.0 - 1.0) * self.depth * 0.5,
            };
            const jitter = heading + (r.float(f32) - 0.5) * 0.6;
            b.v = .{ @cos(jitter) * self.cruise, (r.float(f32) - 0.5) * 0.2 * self.cruise, @sin(jitter) * self.cruise };
            b.flap = r.float(f32) * std.math.tau;
            b.flap_rate = std.math.tau * (6.5 + r.float(f32) * 3.0);
        }
        self.aloft = n;
        return self;
    }

    pub fn deinit(self: *Flock) void {
        self.allocator.free(self.birds);
        self.allocator.free(self.order);
        self.allocator.free(self.starts);
        self.allocator.free(self.sdf);
    }

    // ---- windows ----

    fn slotPitch(self: *const Flock) f32 {
        return 8.0 * self.s;
    }

    fn slotCount(self: *const Flock, site: *const Site) usize {
        return @min(max_slots, @as(usize, @intFromFloat(@max(site.rect.w, 0.0) / self.slotPitch())));
    }

    /// Where a bird sits (or makes for) on its site's top edge.
    fn perchPoint(self: *const Flock, b: *const Bird) [2]f32 {
        const site = &self.sites[b.site];
        const top = site.rect.y + site.rect.h;
        if (b.slot >= 0) {
            // Birds on a wire are never evenly spaced.
            const shuffle = (slotNoise(b.site, b.slot) - 0.5) * 0.7;
            return .{ site.rect.x + (@as(f32, @floatFromInt(b.slot)) + 0.5 + shuffle) * self.slotPitch(), top };
        }
        return .{ site.rect.x + b.perch_u * site.rect.w, top };
    }

    /// A cheap random number in 0..1.
    fn rand(self: *Flock) f32 {
        var x = self.noise;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.noise = x;
        return @as(f32, @floatFromInt(x >> 8)) * (1.0 / 16777216.0);
    }

    /// Put a bird that was on or bound for a perch back in the air.
    fn launch(self: *Flock, b: *Bird) void {
        const r = self.rng.random();
        if (b.state == .perched and b.slot >= 0) self.sites[b.site].taken[@intCast(b.slot)] = false;
        if (b.state != .landing) {
            b.p[1] += 5.0 * self.s;
            b.p[2] = (r.float(f32) * 2.0 - 1.0) * self.depth * 0.3;
            const dir = [3]f32{ r.float(f32) * 1.2 - 0.6, 1.0, r.float(f32) - 0.5 };
            const len = @sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
            const sp = self.cruise * (0.9 + r.float(f32) * 0.3) / len;
            b.v = .{ dir[0] * sp, dir[1] * sp, dir[2] * sp };
        }
        b.state = .flying;
        b.final = false;
        b.slot = -1;
        b.leave_in = -1;
        b.nbr_n = 0;
    }

    /// The bird's site is still the one it chose.
    fn holds(self: *const Flock, b: *const Bird) bool {
        const site = &self.sites[b.site];
        return site.used and site.gen == b.site_gen;
    }

    /// A site for a bird to roost on, wider edges taking more birds.
    fn pickSite(self: *Flock, b: *Bird) void {
        const r = self.rng.random();
        var total: f32 = 0;
        for (&self.sites) |*site| {
            if (site.used) total += site.rect.w;
        }
        if (total <= 0) return;
        var pick = r.float(f32) * total;
        for (&self.sites, 0..) |*site, i| {
            if (!site.used) continue;
            b.site = @intCast(i);
            b.site_gen = site.gen;
            pick -= site.rect.w;
            if (pick <= 0) break;
        }
        b.perch_u = 0.02 + r.float(f32) * 0.96;
    }

    /// Match the roost sites to this frame's windows. A bird whose window
    /// is gone, or whose slot a resize took away, goes back up.
    fn syncSites(self: *Flock, windows: []const Rect) void {
        for (&self.sites) |*site| site.live = false;

        var any = false;
        for (windows) |win| {
            if (win.w < 60.0 * self.s or win.h < 30.0 * self.s or win.address == 0) continue;
            any = true;
            for (&self.sites) |*site| {
                if (site.used and site.rect.address == win.address) {
                    site.rect = win;
                    site.live = true;
                    break;
                }
            }
        }
        const ground = Rect{ .x = 0, .y = -40, .w = self.w, .h = 40, .address = ground_addr };
        if (!any) {
            for (&self.sites) |*site| {
                if (site.used and site.rect.address == ground_addr) site.live = true;
            }
        }

        // Retire the sites that went, before their slots can be reused.
        var retired = false;
        for (&self.sites) |*site| {
            if (site.used and !site.live) {
                site.used = false;
                site.taken = @splat(false);
                retired = true;
            }
        }

        const add = struct {
            fn add(flock: *Flock, win: Rect) void {
                for (&flock.sites) |*site| {
                    if (site.used and site.rect.address == win.address) return;
                }
                for (&flock.sites) |*site| {
                    if (site.used) continue;
                    site.* = .{ .used = true, .live = true, .rect = win, .gen = site.gen +% 1 };
                    return;
                }
            }
        }.add;
        if (any) {
            for (windows) |win| {
                if (win.w < 60.0 * self.s or win.h < 30.0 * self.s or win.address == 0) continue;
                add(self, win);
            }
        } else add(self, ground);

        for (self.birds) |*b| {
            if (b.state == .flying) {
                // Still to come down: make for a site that exists.
                if (self.roosting and retired and !self.holds(b)) self.pickSite(b);
                continue;
            }
            const site = &self.sites[b.site];
            const gone = !self.holds(b);
            const squeezed = b.state == .perched and @as(usize, @intCast(b.slot)) >= self.slotCount(site);
            if (gone or squeezed) {
                if (gone) b.slot = -1; // its slot went with the site
                self.launch(b);
                if (self.roosting) self.pickSite(b);
            }
        }
    }

    fn rebuildField(self: *Flock, windows: []const Rect) void {
        const n = @min(windows.len, self.field_wins.len);
        var same = n == self.field_n;
        if (same) {
            for (windows[0..n], self.field_wins[0..n]) |a, b| {
                if (a.x != b.x or a.y != b.y or a.w != b.w or a.h != b.h) {
                    same = false;
                    break;
                }
            }
        }
        if (same) return;
        self.field_n = n;
        @memcpy(self.field_wins[0..n], windows[0..n]);
        var open: f32 = 0;
        var cells: f32 = 0;

        for (0..self.sdf_h) |gy| {
            const y = @as(f32, @floatFromInt(gy)) * self.sdf_cell;
            for (0..self.sdf_w) |gx| {
                const x = @as(f32, @floatFromInt(gx)) * self.sdf_cell;
                var d: f32 = 1e6;
                for (windows[0..n]) |win| d = @min(d, sdBox(x, y, win));
                self.sdf[gy * self.sdf_w + gx] = d;
                if (x <= self.w and y <= self.h) {
                    cells += 1;
                    if (d > self.sdf_cell) open += 1;
                }
            }
        }
        self.solid = smoothstep(0.12, 0.35, open / @max(cells, 1.0));
    }

    /// Distance to the nearest window at a point, and which way is out.
    pub fn windowField(self: *const Flock, x: f32, y: f32) struct { d: f32, gx: f32, gy: f32 } {
        const fx = std.math.clamp(x / self.sdf_cell, 0.0, @as(f32, @floatFromInt(self.sdf_w - 2)));
        const fy = std.math.clamp(y / self.sdf_cell, 0.0, @as(f32, @floatFromInt(self.sdf_h - 2)));
        const ix: usize = @intFromFloat(fx);
        const iy: usize = @intFromFloat(fy);
        const tx = fx - @as(f32, @floatFromInt(ix));
        const ty = fy - @as(f32, @floatFromInt(iy));
        const s00 = self.sdf[iy * self.sdf_w + ix];
        const s10 = self.sdf[iy * self.sdf_w + ix + 1];
        const s01 = self.sdf[(iy + 1) * self.sdf_w + ix];
        const s11 = self.sdf[(iy + 1) * self.sdf_w + ix + 1];
        const lo = s00 + (s10 - s00) * tx;
        const hi = s01 + (s11 - s01) * tx;
        return .{
            .d = lo + (hi - lo) * ty,
            .gx = ((s10 - s00) * (1.0 - ty) + (s11 - s01) * ty) / self.sdf_cell,
            .gy = ((s01 - s00) * (1.0 - tx) + (s11 - s10) * tx) / self.sdf_cell,
        };
    }

    // ---- neighbors ----

    fn cellKey(self: *const Flock, p: [3]f32) u32 {
        const inv = 1.0 / self.cell;
        const cx: u32 = @intFromFloat(std.math.clamp(p[0] * inv + 64.0, 0.0, 2047.0));
        const cy: u32 = @intFromFloat(std.math.clamp(p[1] * inv + 64.0, 0.0, 2047.0));
        const cz: u32 = @intFromFloat(std.math.clamp(p[2] * inv + 256.0, 0.0, 1023.0));
        return cx | (cy << 11) | (cz << 22);
    }

    fn buildGrid(self: *Flock) void {
        // Hot: thousands of birds a step. The indices here are the flock's
        // own and the floats are clamped before they are cast.
        @setRuntimeSafety(false);
        @memset(self.starts, 0);
        for (self.birds) |*b| {
            if (b.state != .flying and b.state != .landing) continue;
            b.key = self.cellKey(b.p);
            self.starts[cellHash(b.key) + 1] += 1;
        }
        for (1..self.starts.len) |i| self.starts[i] += self.starts[i - 1];
        // `starts[k]` is now where bucket k begins; fill, advancing a
        // cursor per bucket, then shift the cursors back.
        for (self.birds, 0..) |*b, i| {
            if (b.state != .flying and b.state != .landing) continue;
            const k = cellHash(b.key);
            self.order[self.starts[k]] = .{ .p = b.p, .key = b.key, .idx = @intCast(i) };
            self.starts[k] += 1;
        }
        var k: usize = hash_buckets;
        while (k > 0) : (k -= 1) self.starts[k] = self.starts[k - 1];
        self.starts[0] = 0;
    }

    /// The (up to) seven nearest birds to bird `i`, looking in its own cell
    /// and the seven that share the corner it is nearest: a block of eight
    /// that reaches at least half a cell from the bird every way.
    fn findNeighbors(self: *Flock, i: usize) void {
        // Hot: thousands of birds a step. The indices here are the flock's
        // own and the floats are clamped before they are cast.
        @setRuntimeSafety(false);
        const b = &self.birds[i];
        var best_d: [k_nbr]f32 = @splat(std.math.floatMax(f32));
        var best_i: [k_nbr]u16 = undefined;
        var found: u8 = 0;

        const inv = 1.0 / self.cell;
        const cx: i32 = @intCast(b.key & 2047);
        const cy: i32 = @intCast((b.key >> 11) & 2047);
        const cz: i32 = @intCast(b.key >> 22);
        // Which half of its cell the bird is in, each way.
        const fx = b.p[0] * inv + 64.0;
        const fy = b.p[1] * inv + 64.0;
        const fz = b.p[2] * inv + 256.0;
        const sx: i32 = if (fx - @floor(fx) < 0.5) -1 else 1;
        const sy: i32 = if (fy - @floor(fy) < 0.5) -1 else 1;
        const sz: i32 = if (fz - @floor(fz) < 0.5) -1 else 1;

        for (0..8) |corner| {
            const qx = cx + (if (corner & 1 != 0) sx else 0);
            const qy = cy + (if (corner & 2 != 0) sy else 0);
            const qz = cz + (if (corner & 4 != 0) sz else 0);
            if (qx < 0 or qy < 0 or qz < 0 or qx > 2047 or qy > 2047 or qz > 1023) continue;
            const key = @as(u32, @intCast(qx)) | (@as(u32, @intCast(qy)) << 11) | (@as(u32, @intCast(qz)) << 22);
            const bucket = cellHash(key);
            for (self.order[self.starts[bucket]..self.starts[bucket + 1]]) |*o| {
                // Two cells can share a bucket; take each once.
                if (o.key != key or o.idx == i) continue;
                const ex = o.p[0] - b.p[0];
                const ey = o.p[1] - b.p[1];
                const ez = o.p[2] - b.p[2];
                const d = ex * ex + ey * ey + ez * ez;
                if (d >= best_d[k_nbr - 1]) continue;
                var slot: usize = k_nbr - 1;
                while (slot > 0 and best_d[slot - 1] > d) : (slot -= 1) {
                    best_d[slot] = best_d[slot - 1];
                    best_i[slot] = best_i[slot - 1];
                }
                best_d[slot] = d;
                best_i[slot] = o.idx;
                if (found < k_nbr) found += 1;
            }
        }
        b.nbr = best_i;
        b.nbr_n = found;
    }

    // ---- the frame ----

    pub fn update(self: *Flock, in: Inputs) void {
        // Hot: thousands of birds a step. The indices here are the flock's
        // own and the floats are clamped before they are cast.
        @setRuntimeSafety(false);
        const dt = std.math.clamp(in.dt, 0.0, 0.05);
        if (self.birds.len == 0) return;
        self.now += dt;
        self.frame +%= 1;
        self.alarm = false;
        const r = self.rng.random();
        const s = self.s;

        self.syncSites(in.windows);
        self.rebuildField(in.windows);

        // The falcon is the cursor, when it is out over open sky.
        const falcon = self.windowField(in.cursor[0], in.cursor[1]).d > 0;

        // ---- roost: coming down, and going up ----
        if (in.roost and !self.roosting) {
            self.roosting = true;
            self.roost_t = 0;
            for (self.birds) |*b| self.pickSite(b);
        }
        var lift: ?[2]f32 = null;
        if (self.roosting) {
            self.roost_t += dt;
            if (!in.roost) {
                lift = .{ r.float(f32) * self.w, r.float(f32) * self.h };
            } else if (falcon) {
                // The falcon over the roost puts the whole flock up.
                const reach = 150.0 * s;
                for (self.birds) |*b| {
                    if (b.state != .perched) continue;
                    const ex = b.p[0] - in.cursor[0];
                    const ey = b.p[1] - in.cursor[1];
                    if (ex * ex + ey * ey < reach * reach) {
                        lift = in.cursor;
                        self.alarm = true;
                        break;
                    }
                }
            }
        }
        if (lift) |origin| {
            // The alarm spreads out from where it was raised.
            self.roosting = false;
            for (self.birds) |*b| {
                switch (b.state) {
                    .flying => {},
                    .landing => self.launch(b),
                    .perched, .hidden => {
                        const ex = b.p[0] - origin[0];
                        const ey = b.p[1] - origin[1];
                        b.leave_in = @sqrt(ex * ex + ey * ey) / (1400.0 * s) + r.float(f32) * 0.35;
                    },
                }
            }
        }

        // ---- home: the range the flock wheels in ----
        // It wanders the screen slowly, and settles over the widest roost
        // when it is time to come down.
        var home = [2]f32{
            self.w * (0.5 + 0.22 * @sin(clock.phase(self.now, std.math.tau / 41.0)) + 0.06 * @sin(clock.phase(self.now, std.math.tau / 13.7))),
            self.h * (0.5 + 0.20 * @sin(clock.phase(self.now, std.math.tau / 29.0) + 1.3) + 0.08 * @sin(clock.phase(self.now, std.math.tau / 11.3))),
        };
        if (self.roosting) {
            var widest: f32 = 0;
            for (&self.sites) |*site| {
                if (!site.used or site.rect.w <= widest) continue;
                widest = site.rect.w;
                home = .{
                    site.rect.x + site.rect.w * 0.5,
                    @min(site.rect.y + site.rect.h + self.h * 0.16, self.h * 0.86),
                };
            }
        }
        const ease = @min(1.0, 0.6 * dt);
        self.home[0] += (home[0] - self.home[0]) * ease;
        self.home[1] += (home[1] - self.home[1]) * ease;
        if (!self.roosting) {
            // Home keeps clear of the windows, or the flock would spend
            // its time pressed against one.
            const clear = 240.0 * s;
            const f = self.windowField(self.home[0], self.home[1]);
            if (f.d < clear) {
                const step = @min(clear - f.d, 400.0 * s * dt) * self.solid;
                self.home[0] = std.math.clamp(self.home[0] + f.gx * step, 0.1 * self.w, 0.9 * self.w);
                self.home[1] = std.math.clamp(self.home[1] + f.gy * step, 0.15 * self.h, 0.85 * self.h);
            }
        }

        // ---- neighbors: an eighth of the flock looks around each step ----
        // Who a bird's nearest seven are changes slowly next to how often
        // it steers by them.
        self.buildGrid();
        for (self.birds, 0..) |*b, i| {
            if (b.state != .flying and b.state != .landing) continue;
            if ((i +% self.frame) % 8 == 0 or (b.nbr_n == 0 and (i +% self.frame) % 2 == 0)) self.findNeighbors(i);
        }

        // ---- a kick starts a wave at one edge of the flock ----
        if (in.kick > 0) {
            const a = r.float(f32) * std.math.tau;
            const ax = @cos(a);
            const ay = @sin(a);
            var far: f32 = -std.math.floatMax(f32);
            for (self.birds) |*b| {
                if (b.state == .flying) far = @max(far, b.p[0] * ax + b.p[1] * ay);
            }
            const band = 26.0 * s;
            for (self.birds) |*b| {
                if (b.state != .flying or b.fuse >= 0) continue;
                if (b.p[0] * ax + b.p[1] * ay > far - band) {
                    b.amp = std.math.clamp(0.7 + 0.3 * in.kick, 0.0, 1.0);
                    b.fuse = r.float(f32) * 0.03;
                }
            }
        }

        // ---- birds ----
        const cruise = self.cruise * (1.0 + 0.3 * in.bass);
        const sep_r = 21.0 * s;
        const pull: f32 = 15.0;
        const margin = 75.0 * s;
        const flee_r = 210.0 * s;
        const range_x = self.w * 0.30;
        const range_y = self.h * 0.30;
        const land_ramp = smoothstep(0.0, 8.0, self.roost_t);

        self.aloft = 0;
        self.perched = 0;
        self.hidden = 0;

        for (self.birds) |*b| {
            if (b.state == .perched or b.state == .hidden) {
                // Riding the window, wherever it goes.
                const at = self.perchPoint(b);
                b.p = .{ at[0], at[1] + (if (b.state == .perched) 2.5 * s else -8.0 * s), 0 };
                b.v = .{ 0, 0, 0 };
                b.roll = 0;
                if (b.leave_in >= 0) {
                    b.leave_in -= dt;
                    if (b.leave_in < 0) self.launch(b);
                }
                if (b.state == .perched) self.perched += 1;
                if (b.state == .hidden) self.hidden += 1;
                if (b.state != .flying) continue;
            }
            self.aloft += 1;

            const speed = @sqrt(b.v[0] * b.v[0] + b.v[1] * b.v[1] + b.v[2] * b.v[2]);
            const inv_speed = 1.0 / @max(speed, 1e-3);
            const hx = b.v[0] * inv_speed;
            const hy = b.v[1] * inv_speed;
            const hz = b.v[2] * inv_speed;

            var ax: f32 = 0;
            var ay: f32 = 0;
            var az: f32 = 0;

            // Birds crowd in as they come down: spacing gives way near the
            // perch, or they would hold each other off it.
            const landing = b.state == .landing;
            var room: f32 = 1.0;
            if (landing) {
                const at = self.perchPoint(b);
                const ex = at[0] - b.p[0];
                const ey = at[1] - b.p[1];
                room = smoothstep(20.0 * s, 140.0 * s, @sqrt(ex * ex + ey * ey));
            }

            // ---- the seven ----
            var cx: f32 = 0;
            var cy: f32 = 0;
            var cz: f32 = 0;
            var mx: f32 = 0;
            var my: f32 = 0;
            var mz: f32 = 0;
            var seen: f32 = 0;
            var wave_amp: f32 = 0;
            for (b.nbr[0..b.nbr_n]) |j| {
                const o = &self.birds[j];
                if (o.state != .flying and o.state != .landing) continue;
                const ex = o.p[0] - b.p[0];
                const ey = o.p[1] - b.p[1];
                const ez = o.p[2] - b.p[2];
                const d2 = ex * ex + ey * ey + ez * ez;
                if (d2 < sep_r * sep_r) {
                    const d = @sqrt(d2) + 1e-3;
                    const push = (1.0 - d / sep_r) * 5.0 * self.cruise * room / d;
                    ax -= ex * push;
                    ay -= ey * push;
                    az -= ez * push;
                }
                cx += ex;
                cy += ey;
                cz += ez;
                mx += o.v[0];
                my += o.v[1];
                mz += o.v[2];
                seen += 1;
                if (o.since < 0.1) wave_amp = @max(wave_amp, o.amp);
            }

            if (seen > 0) {
                const inv = 1.0 / seen;
                // Landing birds keep their spacing but stop following.
                const follow: f32 = if (landing) 0.25 else 1.0;
                ax += cx * inv * pull * follow;
                ay += cy * inv * pull * follow;
                az += cz * inv * pull * follow;
                ax += (mx * inv - b.v[0]) * 3.2 * follow;
                ay += (my * inv - b.v[1]) * 3.2 * follow;
                az += (mz * inv - b.v[2]) * 3.2 * follow;
            }

            if (landing) {
                // Down onto the perch. A bird below the edge first climbs
                // round the nearer side of its window to a point above
                // the corner, and only then drops in.
                const at = self.perchPoint(b);
                const rect = self.sites[b.site].rect;
                var tx = at[0];
                var ty = at[1] + 3.0 * s;
                if (b.p[1] > at[1] + 30.0 * s) b.final = true;
                if (!b.final) {
                    const left = b.p[0] - rect.x < rect.x + rect.w - b.p[0];
                    tx = if (left) rect.x - 130.0 * s else rect.x + rect.w + 130.0 * s;
                    ty = at[1] + 120.0 * s;
                }
                tx -= b.p[0];
                ty -= b.p[1];
                const tz = -b.p[2];
                const dist = @sqrt(tx * tx + ty * ty + tz * tz) + 1e-3;
                if (b.final and dist < 7.0 * s) {
                    self.settle(b);
                    continue;
                }
                const want = @min(self.cruise, dist * 2.4 + 30.0 * s) / dist;
                // The last drop is flown tight; the way round is not.
                const grip: f32 = if (b.final) 4.0 else 1.8;
                ax += (tx * want - b.v[0]) * grip;
                ay += (ty * want - b.v[1]) * grip;
                az += (tz * want - b.v[2]) * grip;
            } else {
                // Hold the cruise speed.
                const hold = (cruise - speed) * 3.0;
                ax += hx * hold;
                ay += hy * hold;
                az += hz * hold;

                // Turn back into the home range, a soft ellipsoid of air.
                // A bird flying straight out of it is turned hardest, so
                // the flock wheels rather than bounces.
                const ox = (b.p[0] - self.home[0]) / range_x;
                const oy = (b.p[1] - self.home[1]) / range_y;
                const oz = b.p[2] / self.depth;
                const out = @sqrt(ox * ox + oy * oy + oz * oz);
                if (out > 0.6) {
                    var nx = ox / range_x;
                    var ny = oy / range_y;
                    var nz = oz / self.depth;
                    const nl = @sqrt(nx * nx + ny * ny + nz * nz) + 1e-6;
                    nx /= nl;
                    ny /= nl;
                    nz /= nl;
                    const away = hx * nx + hy * ny + hz * nz;
                    const turn = smoothstep(0.6, 1.5, out) * (0.5 + 0.5 * away) * 4.0 * self.cruise;
                    ax -= nx * turn;
                    ay -= ny * turn;
                    az -= nz * turn;
                }
                // Starlings would rather fly level.
                ay -= b.v[1] * 0.8;

                // Time to come down: birds near their perch peel off first,
                // a trickle that becomes a pour.
                if (self.roosting and self.holds(b)) {
                    const at = self.perchPoint(b);
                    const near = 1.0 - smoothstep(self.w * 0.2, self.w * 0.55, @abs(b.p[0] - at[0]));
                    var rate = (0.2 + 1.6 * near) * land_ramp;
                    if (self.roost_t > 24.0) rate += 3.0;
                    if (self.rand() < rate * dt) {
                        b.state = .landing;
                        b.final = false;
                    }
                }
            }

            // Keep to the sky: off the screen's floor and ceiling. Not a
            // landing bird, whose perch may be right against either: it
            // goes where its approach takes it, off the screen if need be.
            const floor = 0.03 * self.h;
            if (!landing) {
                if (b.p[1] < floor) ay += (floor - b.p[1]) * 30.0;
                if (b.p[1] > self.h - floor) ay -= (b.p[1] - (self.h - floor)) * 30.0;
            }

            // ---- windows: steer by where it is about to be ----
            if (!b.final) {
                const f = self.windowField(b.p[0] + b.v[0] * 0.22, b.p[1] + b.v[1] * 0.22);
                if (f.d < margin) {
                    const k = @min(1.0 - f.d / margin, 1.6);
                    const push = k * k * 8.0 * self.cruise * self.solid;
                    ax += f.gx * push;
                    ay += f.gy * push;
                }
            }

            // ---- the falcon ----
            var fear: f32 = 0;
            if (falcon) {
                const ex = b.p[0] - in.cursor[0];
                const ey = b.p[1] - in.cursor[1];
                const d = @sqrt(ex * ex + ey * ey) + 1e-3;
                if (d < flee_r) {
                    fear = 1.0 - d / flee_r;
                    const push = fear * 16.0 * self.cruise / d;
                    ax += ex * push;
                    ay += ey * push;
                    if (fear > 0.25 and b.fuse < 0 and b.since > refractory) {
                        b.amp = 1.0;
                        b.fuse = self.rand() * 0.04;
                    }
                }
            }

            // ---- the wave ----
            // A neighbor that has just rolled primes this bird; it follows
            // after its reaction time, a little weaker, and then cannot be
            // set off again for a while. So the wave runs out through the
            // flock once and dies.
            b.since += dt;
            if (b.fuse >= 0) {
                b.fuse -= dt;
                if (b.fuse < 0) b.since = 0;
            } else if (wave_amp * 0.965 > 0.2 and b.since > refractory) {
                b.amp = wave_amp * 0.965;
                b.fuse = 0.03 + self.rand() * 0.02;
            }
            const flash: f32 = if (b.since < 0.3) @sin(std.math.pi * b.since / 0.3) * b.amp else 0;

            // A little restlessness.
            const fidget = 0.3 * self.cruise;
            ax += (self.rand() - 0.5) * fidget;
            ay += (self.rand() - 0.5) * fidget;
            az += (self.rand() - 0.5) * fidget;

            // ---- roll: a bird banks into its turn ----
            const hl = @sqrt(hx * hx + hz * hz);
            var lat: f32 = 0;
            if (hl > 1e-3) lat = (ax * -hz + az * hx) / hl;
            // atan(t), near enough: the bank angle of a coordinated turn.
            const t = lat / (2.2 * self.cruise);
            var want_roll = t / (1.0 + 0.28 * t * t);
            want_roll += flash * 1.2 * (if (b.roll < 0) @as(f32, -1.0) else 1.0);
            want_roll = std.math.clamp(want_roll, -1.35, 1.35);
            b.roll += (want_roll - b.roll) * @min(1.0, 7.0 * dt);
            b.flap += b.flap_rate * dt;
            if (b.flap > std.math.tau) b.flap -= std.math.tau;

            // ---- move ----
            b.v[0] += ax * dt;
            b.v[1] += ay * dt;
            b.v[2] += az * dt;
            const sp = @sqrt(b.v[0] * b.v[0] + b.v[1] * b.v[1] + b.v[2] * b.v[2]);
            const lo: f32 = if (landing) 0.0 else 0.65 * cruise;
            const hi = cruise * (1.45 + 0.9 * fear);
            const clamped = std.math.clamp(sp, lo, hi);
            if (sp > 1e-3 and clamped != sp) {
                const k = clamped / sp;
                b.v[0] *= k;
                b.v[1] *= k;
                b.v[2] *= k;
            }
            b.p[0] += b.v[0] * dt;
            b.p[1] += b.v[1] * dt;
            b.p[2] = std.math.clamp(b.p[2] + b.v[2] * dt, -1.6 * self.depth, 1.6 * self.depth);
        }
    }

    /// A landing bird reaches the edge: it takes the nearest free slot, or
    /// if the edge is full there, drops in behind the window.
    fn settle(self: *Flock, b: *Bird) void {
        const site = &self.sites[b.site];
        const slots = self.slotCount(site);
        b.state = .hidden;
        b.slot = -1;
        b.fuse = -1;
        if (slots > 0) {
            const want: i32 = @intFromFloat(b.perch_u * @as(f32, @floatFromInt(slots)));
            var off: i32 = 0;
            while (off <= 8) : (off += 1) {
                inline for (.{ 1, -1 }) |sign| {
                    const q = want + off * sign;
                    if (b.state == .hidden and q >= 0 and q < slots and !site.taken[@intCast(q)]) {
                        site.taken[@intCast(q)] = true;
                        b.slot = @intCast(q);
                        b.state = .perched;
                    }
                }
            }
        }
        self.aloft -|= 1;
        if (b.state == .perched) self.perched += 1 else self.hidden += 1;
    }

    /// The birds in view, as drawn, as of the last update. Returns how many
    /// were written.
    pub fn instances(self: *const Flock, out: []Instance) usize {
        // Hot: thousands of birds a step. The indices here are the flock's
        // own and the floats are clamped before they are cast.
        @setRuntimeSafety(false);
        var n: usize = 0;
        const s = self.s;
        for (self.birds) |*b| {
            if (n >= out.len) break;
            switch (b.state) {
                .hidden => continue,
                .perched => {
                    // Wings folded: an upright little body on the edge, no
                    // two quite the same height or lean.
                    const tall = 0.8 + 0.45 * slotNoise(b.site +% 7, b.slot);
                    const lean = (slotNoise(b.site +% 19, b.slot) - 0.5) * 1.1;
                    out[n] = .{
                        .x = b.p[0],
                        .y = b.p[1] + 2.4 * s * (tall - 1.0),
                        .bx = lean * s,
                        .by = 2.4 * s * tall,
                        .alpha = 0.95,
                        .far = 0.2,
                        .flash = 0,
                        .size = s * 1.15,
                    };
                    n += 1;
                    continue;
                },
                .flying, .landing => {},
            }
            const speed = @sqrt(b.v[0] * b.v[0] + b.v[1] * b.v[1] + b.v[2] * b.v[2]);
            if (speed < 1e-3) continue;
            const hx = b.v[0] / speed;
            const hy = b.v[1] / speed;
            const hz = b.v[2] / speed;

            // Nearer birds are larger and stronger.
            const zn = std.math.clamp(b.p[2] / self.depth, -1.0, 1.0);
            const size = s * (1.0 + 0.3 * zn);

            // The wing axis, level and square to the heading, and the
            // bird's own up. Only their screen parts are needed.
            const hl = @sqrt(hx * hx + hz * hz);
            var wx: f32 = 0;
            var wz: f32 = 1;
            if (hl > 1e-3) {
                wx = -hz / hl;
                wz = hx / hl;
            }
            const ux = -wz * hy;
            const uy = wz * hx - wx * hz;
            const cr = @cos(b.roll);
            const sr = @sin(b.roll);
            // Rolled: wing axis and wing normal.
            const ax = cr * wx + sr * ux;
            const ay = sr * uy;
            const nx = -sr * wx + cr * ux;
            const ny = cr * uy;

            const flash: f32 = if (b.since < 0.3) @sin(std.math.pi * b.since / 0.3) * b.amp else 0;
            // Rolled right over, a bird shows the whole spread of its wings.
            const span = 5.0 * size * (1.0 + 0.7 * flash);
            out[n] = .{
                .x = b.p[0],
                .y = b.p[1],
                .bx = hx * 3.4 * size,
                .by = hy * 3.4 * size,
                .ax = ax * span,
                .ay = ay * span,
                .nx = nx * span,
                .ny = ny * span,
                .alpha = std.math.clamp(0.7 + 0.25 * zn + 0.5 * flash, 0.0, 1.0),
                .far = 0.5 - 0.5 * zn,
                .flash = flash,
                .size = size,
                .vx = b.v[0],
                .vy = b.v[1],
                .flap = b.flap,
                .flap_rate = b.flap_rate,
            };
            n += 1;
        }
        return n;
    }
};

// ---- tests ----

const testing = std.testing;

fn testFlock(count: usize) !Flock {
    return Flock.init(testing.allocator, count, 2560, 1440, 300);
}

test "the window field is the distance to the nearest window" {
    var flock = try testFlock(8);
    defer flock.deinit();
    const wins = [_]Rect{.{ .x = 1000, .y = 500, .w = 400, .h = 300, .address = 9 }};
    flock.rebuildField(&wins);

    const out = flock.windowField(800, 650);
    try testing.expectApproxEqAbs(@as(f32, 200), out.d, 2.0);
    try testing.expect(out.gx < -0.9); // out is to the left
    const in = flock.windowField(1200, 650);
    try testing.expect(in.d < 0);
    const above = flock.windowField(1200, 900);
    try testing.expectApproxEqAbs(@as(f32, 100), above.d, 2.0);
    try testing.expect(above.gy > 0.9);
}

test "the grid finds the same nearest neighbors as a full search" {
    var flock = try testFlock(600);
    defer flock.deinit();
    // Pack them close, so there are neighbors within reach to check.
    for (flock.birds) |*b| {
        b.p[0] = 1000 + (b.p[0] - 1280) * 0.25;
        b.p[1] = 700 + (b.p[1] - 720) * 0.25;
        b.p[2] *= 0.25;
    }
    flock.buildGrid();
    // The eight cells searched reach half a cell from the bird every way,
    // so every bird nearer than that must be found, nearest first.
    const reach = flock.cell * 0.5;
    var checked: usize = 0;
    for ([_]usize{ 0, 17, 311, 599 }) |i| {
        flock.findNeighbors(i);
        const b = &flock.birds[i];

        var dists: [600]f32 = undefined;
        var m: usize = 0;
        for (flock.birds, 0..) |*o, j| {
            if (j == i) continue;
            const ex = o.p[0] - b.p[0];
            const ey = o.p[1] - b.p[1];
            const ez = o.p[2] - b.p[2];
            const d = ex * ex + ey * ey + ez * ez;
            if (d < reach * reach) {
                dists[m] = d;
                m += 1;
            }
        }
        std.mem.sort(f32, dists[0..m], {}, std.sort.asc(f32));
        const want = @min(m, k_nbr);
        try testing.expect(b.nbr_n >= want);
        for (b.nbr[0..want], 0..) |j, rank| {
            const o = &flock.birds[j];
            const ex = o.p[0] - b.p[0];
            const ey = o.p[1] - b.p[1];
            const ez = o.p[2] - b.p[2];
            try testing.expectApproxEqAbs(dists[rank], ex * ex + ey * ey + ez * ez, 1e-2);
        }
        checked += want;
    }
    try testing.expect(checked >= 8);
}

test "the flock holds together and keeps off the windows" {
    var flock = try testFlock(800);
    defer flock.deinit();
    const wins = [_]Rect{.{ .x = 900, .y = 400, .w = 700, .h = 500, .address = 3 }};
    for (0..900) |_| flock.update(.{ .dt = 1.0 / 60.0, .windows = &wins, .cursor = .{ -500, -500 } });

    var deep: usize = 0;
    for (flock.birds) |b| {
        try testing.expect(std.math.isFinite(b.p[0]) and std.math.isFinite(b.p[1]) and std.math.isFinite(b.p[2]));
        try testing.expect(b.p[1] > -50 and b.p[1] < 1490);
        // Well inside the window, not just clipping its edge.
        if (sdBox(b.p[0], b.p[1], wins[0]) < -60) deep += 1;
    }
    try testing.expect(deep * 50 < flock.birds.len);
    try testing.expectEqual(flock.birds.len, flock.aloft);
}

test "roosting fills the edge, hides the rest, and a closed window puts them up" {
    var flock = try testFlock(400);
    defer flock.deinit();
    const wins = [_]Rect{.{ .x = 800, .y = 300, .w = 480, .h = 400, .address = 5 }};
    for (0..60 * 50) |_| flock.update(.{ .dt = 1.0 / 60.0, .windows = &wins, .cursor = .{ -500, -500 }, .roost = true });

    // A 480 px edge holds 60 birds at 8 px; nobody shares a slot.
    try testing.expectEqual(@as(usize, 0), flock.aloft);
    try testing.expectEqual(@as(usize, 60), flock.perched);
    try testing.expectEqual(@as(usize, 340), flock.hidden);
    var taken: usize = 0;
    for (flock.sites[0].taken) |t| taken += @intFromBool(t);
    try testing.expectEqual(@as(usize, 60), taken);

    // The window closes: everyone is flying again, bound for the ground.
    flock.update(.{ .dt = 1.0 / 60.0, .windows = &.{}, .cursor = .{ -500, -500 }, .roost = true });
    try testing.expectEqual(flock.birds.len, flock.aloft);
    for (flock.birds) |*b| try testing.expect(flock.holds(b));

    // And the roost ending lifts the ones that had landed on it.
    for (0..60 * 50) |_| flock.update(.{ .dt = 1.0 / 60.0, .windows = &.{}, .cursor = .{ -500, -500 }, .roost = true });
    try testing.expectEqual(@as(usize, 0), flock.aloft);
    for (0..60 * 3) |_| flock.update(.{ .dt = 1.0 / 60.0, .windows = &.{}, .cursor = .{ -500, -500 } });
    try testing.expectEqual(flock.birds.len, flock.aloft);
}

test "a kick's wave runs through the flock once and dies" {
    var flock = try testFlock(1500);
    defer flock.deinit();
    const quiet = Inputs{ .dt = 1.0 / 60.0, .windows = &.{}, .cursor = .{ -500, -500 } };
    for (0..300) |_| flock.update(quiet);

    var kicked = quiet;
    kicked.kick = 1.0;
    flock.update(kicked);

    var reached: usize = 0;
    var peak: usize = 0;
    for (0..60 * 4) |_| {
        flock.update(quiet);
        var rolling: usize = 0;
        for (flock.birds) |b| rolling += @intFromBool(b.since < 0.3);
        peak = @max(peak, rolling);
    }
    for (flock.birds) |b| reached += @intFromBool(b.since < 4.0);
    // It spread well past the birds the kick touched, and nobody is still
    // rolling four seconds on.
    try testing.expect(reached > flock.birds.len / 3);
    try testing.expect(peak > 20);
    for (flock.birds) |b| try testing.expect(b.since >= 0.3 and b.fuse < 0);
}

test "a desktop that is all window stops being an obstacle" {
    var flock = try testFlock(8);
    defer flock.deinit();
    const one = [_]Rect{.{ .x = 1000, .y = 500, .w = 400, .h = 300, .address = 9 }};
    flock.rebuildField(&one);
    try testing.expectEqual(@as(f32, 1), flock.solid);

    // Three tiles with 10 px gaps, as a tiled workspace has.
    const tiled = [_]Rect{
        .{ .x = 10, .y = 10, .w = 1265, .h = 705, .address = 1 },
        .{ .x = 10, .y = 725, .w = 1265, .h = 705, .address = 2 },
        .{ .x = 1285, .y = 10, .w = 1265, .h = 1420, .address = 3 },
    };
    flock.rebuildField(&tiled);
    try testing.expectEqual(@as(f32, 0), flock.solid);
}

test "birds can land on a window right at the top of the screen" {
    var flock = try testFlock(300);
    defer flock.deinit();
    // A tiled layout: the top edges are 30 px under the screen's top and
    // 10 px under the row above, and the windows span the whole width.
    const tiled = [_]Rect{
        .{ .x = 10, .y = 725, .w = 2540, .h = 685, .address = 1 },
        .{ .x = 10, .y = 10, .w = 2540, .h = 705, .address = 2 },
    };
    for (0..60 * 60) |_| flock.update(.{ .dt = 1.0 / 60.0, .windows = &tiled, .cursor = .{ -500, -500 }, .roost = true });
    try testing.expectEqual(@as(usize, 0), flock.aloft);
}
