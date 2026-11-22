const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");
const palette_mod = @import("../core/palette.zig");
const lamps_mod = @import("lamps.zig");

const Uniforms = @import("uniforms.zig").Uniforms;
const WindowRect = shader_mod.ShaderProgram.WindowRect;

const c = @import("c");

// A board of small square lamps on a strict grid, nearly all of them dim.
// The lamps sit on a pond of light: where the pond stands high the lamps
// over it wake, each when the light passes its own mark, most of them
// white and the rest in the theme's colors, the keenest with a halo. A
// lamp wakes at once and fades slowly, so whatever crosses the board has
// a crisp front and a soft tail. Nothing spills from one lamp's cell
// into the next: the board between the lamps stays the background.
//
// The light under a lamp is the sum of these.
//
//   - The swell: a few long, slow waves crossing the screen at different
//     headings, so broad bands of light drift over the board and never
//     quite repeat. A plain sum of sines.
//   - The ripples: a wave equation on the lamp grid, one cell a lamp,
//
//         v' = c^2 lap(u) - k v,    u' = v
//
//     and what the desktop does is laid on it. A cursor that moves leaves
//     a wake, and one at rest adds nothing. A window edge that moves
//     pushes the pond up ahead of it and leaves it low behind, so a
//     dragged window throws a bow wave and one that opens sends a ring
//     out. Focus landing on a window sends a soft ring out from its
//     frame.
//   - The cursor's own light: while it moves it lights the lamps round
//     it, which fade behind it as a tail.
//   - The focused window's: the lamps along its frame stand in a little
//     light, which goes down as the next window's comes up when focus
//     moves (lamps.zig).
//
// Music lays nothing on the pond. Each color has a band of the spectrum
// to itself, low to high as a rainbow runs: red, yellow, green, cyan,
// blue, magenta. While music plays a colored lamp wakes to its band, all
// over the board when the band is loud and hardly at all when it is
// quiet, so the colors on the board are the spectrum. White lamps keep to
// the pond. Each beat pushes the swell forward a little, so the bands of
// light march to it, and each wave of the swell stands taller while its
// own band is loud.
//
// Past each edge of the screen the pond runs on a little way and drains
// faster the farther out, so ripples leave the screen and do not come
// back. A pond with nothing moving on it is not stepped at all.
//
// The lamps are kept here, four bytes each, and handed to the shader as
// a small texture of what each one shows (shaders/darkwave.frag).

/// Rows of lamps up the screen at size 1.
const rows_at_one = 60.0;
/// A lamp's side as a part of the pitch.
const lamp_side = 0.3;
/// Cells of pond past each edge of the screen.
const margin = 12;
/// Cells a ripple crosses in a second.
const ripple_speed = 15.0;
/// The pond's steps: this long each, and at most so many a frame.
const step_s = 1.0 / 60.0;
const max_steps = 4;
/// How fast a ripple dies on the screen, and at the far edge of the
/// margin, per second.
const drain_open = 0.6;
const drain_edge = 10.0;
/// Below this everywhere, the pond is still.
const still = 1.5e-3;
/// Steps of the pond between looks at whether it is still.
const look_every = 15;
/// Anything that dies away is put to rest once it is this small. Left
/// to itself it would shrink for ever into numbers too small to be worth
/// anything and many times slower to reckon with.
const rest = 1e-5;

/// How wide a thing laid on the pond is, in cells. Wide enough that the
/// ripples it makes are several cells long, which the grid carries well.
const drop_radius = 1.5;
/// Level laid per cell the cursor travels.
const wake = 0.25;
/// Level laid along a window edge per cell it moves, and the most cells
/// one frame may count (a window that jumps is not a tidal wave).
const bow = 0.35;
const most_shift = 2.0;
/// The ring sent out from a window that takes focus.
const focus_ring = 0.45;
/// How long the push a beat gives the swell lasts, seconds, and how much
/// faster than its own pace the swell runs at the top of one.
const surge_s = 0.22;
const surge_push = 2.6;
/// How much taller a wave of the swell stands with its band full on.
const swell_lift = 0.7;
/// The two bands each wave of the swell listens to: the longest to the
/// lowest.
const swell_bands = [n_swells][2]u8{ .{ 0, 1 }, .{ 2, 2 }, .{ 3, 3 }, .{ 4, 5 } };

/// The waves of the swell.
const n_swells = 4;
/// Seconds a lamp takes to wake, and to fade: each lamp is of one of
/// these kinds.
const wake_s = 0.04;
const fade_s = [4]f32{ 0.3, 0.45, 0.65, 0.95 };
/// A lamp woken all at once glints: for a moment it is full on and
/// white with a small halo, whatever it then settles to. How much it
/// must be woken by in one step to count, and the seconds a glint lasts.
const glint_from = 0.45;
const glint_s = 0.13;
/// The light the cursor throws while it moves, how far it carries in
/// cells, the speed in cells a second it is full at, and the seconds it
/// takes to go out once the cursor stops.
const torch = 1.0;
const torch_radius = 2.0;
const torch_full = 14.0;
const torch_out_s = 0.45;
/// The light along the focused window's frame, and how many cells out
/// from the frame it carries.
const rim = 0.45;
const rim_reach = 2.2;
/// The band each of the six colors (red, green, yellow, blue, magenta,
/// cyan) listens to, so that low to high runs as a rainbow does.
const band_of = [6]u8{ 0, 2, 1, 4, 5, 3 };
/// How often the lamps are worked out, at most, a second. They change
/// slowly enough that more would not show.
const lamp_hz = 30.0;
/// Seconds for all the lamps to change their marks and colors, one by
/// one, each at its own moment.
const turn_s = 44.0;

/// Windows remembered at once.
const max_known = 64;

const tau = 2.0 * std.math.pi;

/// Where the lamps are: a whole number of pixels apart, each a whole
/// number of pixels across and lying on whole pixels, so every lamp is
/// the same crisp square.
pub const Grid = struct {
    pitch: f32,
    side: f32,
    /// The corner of lamp (0, 0)'s cell, px. At or below zero: the board
    /// is centered and its overhang split between the two edges.
    origin: [2]f32,
    cols: usize,
    rows: usize,

    pub fn init(width: f32, height: f32, size: f32) Grid {
        const pitch = @max(6.0, @round(height / rows_at_one * size));
        // A lamp is centered in its cell, so it lies on whole pixels only
        // if it is even when the pitch is and odd when the pitch is.
        const want = pitch * lamp_side;
        var side = @round(want);
        if (@mod(side, 2.0) != @mod(pitch, 2.0)) side += if (want >= side) 1.0 else -1.0;
        const cols = @ceil(width / pitch);
        const rows = @ceil(height / pitch);
        return .{
            .pitch = pitch,
            .side = @max(2.0, side),
            .origin = .{ -@floor((cols * pitch - width) * 0.5), -@floor((rows * pitch - height) * 0.5) },
            .cols = @intFromFloat(cols),
            .rows = @intFromFloat(rows),
        };
    }

    /// A point on screen (px) in cells: lamp (i, j) is centered at
    /// (i + 0.5, j + 0.5).
    pub fn cell(self: Grid, px: [2]f32) [2]f32 {
        return .{ (px[0] - self.origin[0]) / self.pitch, (px[1] - self.origin[1]) / self.pitch };
    }
};

/// The ripples.
pub const Pond = struct {
    allocator: std.mem.Allocator,
    /// Cells across and up, margins and all.
    w: usize,
    h: usize,
    u: []f32,
    v: []f32,
    /// How fast each cell drains.
    drain: []f32,
    owed: f32 = 0,
    ticks: u32 = 0,
    /// Whether anything is moving on it.
    awake: bool = false,

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !Pond {
        const w = cols + 2 * margin;
        const h = rows + 2 * margin;
        const u = try allocator.alloc(f32, w * h);
        errdefer allocator.free(u);
        const v = try allocator.alloc(f32, w * h);
        errdefer allocator.free(v);
        const drain = try allocator.alloc(f32, w * h);
        @memset(u, 0);
        @memset(v, 0);
        for (0..h) |y| {
            for (0..w) |x| {
                // How far out into the margin, 0 at the screen's edge
                // and 1 at the pond's.
                const near = @min(@min(x, w - 1 - x), @min(y, h - 1 - y));
                const out = 1.0 - @min(1.0, @as(f32, @floatFromInt(near)) / @as(f32, margin));
                drain[y * w + x] = drain_open + (drain_edge - drain_open) * out * out;
            }
        }
        return .{ .allocator = allocator, .w = w, .h = h, .u = u, .v = v, .drain = drain };
    }

    pub fn deinit(self: *Pond) void {
        self.allocator.free(self.u);
        self.allocator.free(self.v);
        self.allocator.free(self.drain);
    }

    /// The level under lamp (x, y).
    pub fn at(self: *const Pond, x: usize, y: usize) f32 {
        return self.u[(y + margin) * self.w + x + margin];
    }

    /// Raise the pond round a point (in cells, as `Grid.cell` gives it)
    /// by `amount` at the point itself.
    pub fn drop(self: *Pond, where: [2]f32, amount: f32) void {
        if (amount == 0) return;
        // In the pond's own cells, whose middles are at whole numbers.
        const px = where[0] + margin - 0.5;
        const py = where[1] + margin - 0.5;
        const reach = 3.0 * drop_radius;
        if (px < -reach or py < -reach or px > @as(f32, @floatFromInt(self.w)) + reach or py > @as(f32, @floatFromInt(self.h)) + reach) return;
        const x0: usize = @intFromFloat(std.math.clamp(@floor(px - reach), 1.0, @as(f32, @floatFromInt(self.w - 2))));
        const x1: usize = @intFromFloat(std.math.clamp(@ceil(px + reach), 1.0, @as(f32, @floatFromInt(self.w - 2))));
        const y0: usize = @intFromFloat(std.math.clamp(@floor(py - reach), 1.0, @as(f32, @floatFromInt(self.h - 2))));
        const y1: usize = @intFromFloat(std.math.clamp(@ceil(py + reach), 1.0, @as(f32, @floatFromInt(self.h - 2))));
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) - px;
                const dy = @as(f32, @floatFromInt(y)) - py;
                self.u[y * self.w + x] += amount * @exp(-(dx * dx + dy * dy) / (2.0 * drop_radius * drop_radius));
            }
        }
        self.awake = true;
    }

    /// Raise it along a line by `amount` at the line itself.
    pub fn line(self: *Pond, from: [2]f32, to: [2]f32, amount: f32) void {
        if (amount == 0) return;
        const dx = to[0] - from[0];
        const dy = to[1] - from[1];
        const len = @sqrt(dx * dx + dy * dy);
        const spacing = 0.75;
        const n: usize = @intFromFloat(@ceil(len / spacing));
        if (n == 0) return self.drop(from, amount);
        // A row of drops this far apart adds up to a ridge of this
        // height.
        const gap = len / @as(f32, @floatFromInt(n));
        const each = amount * gap / (drop_radius * @sqrt(tau));
        for (0..n) |i| {
            const t = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(n));
            self.drop(.{ from[0] + dx * t, from[1] + dy * t }, each);
        }
    }

    /// Carry it `dt` on. False when it is still, and was not touched.
    pub fn step(self: *Pond, dt: f32) bool {
        if (!self.awake) {
            self.owed = 0;
            return false;
        }
        self.owed += std.math.clamp(dt, 0.0, 0.1);
        var steps: usize = 0;
        var most: f32 = 0;
        var looked = false;
        const c2 = ripple_speed * ripple_speed;
        const w = self.w;
        while (self.owed >= step_s and steps < max_steps) : (steps += 1) {
            self.owed -= step_s;
            for (1..self.h - 1) |y| {
                const row = y * w;
                const mid = self.u[row..][0..w];
                const below = self.u[row - w ..][1 .. w - 1];
                const above = self.u[row + w ..][1 .. w - 1];
                const vel = self.v[row..][1 .. w - 1];
                const drain = self.drain[row..][1 .. w - 1];
                for (mid[1 .. w - 1], mid[0 .. w - 2], mid[2..w], below, above, vel, drain) |m, l, r, b, a, *v, d| {
                    v.* += (c2 * (l + r + b + a - 4.0 * m) - d * v.*) * step_s;
                }
            }
            for (self.u, self.v) |*u, v| u.* += v * step_s;
            // Now and then, a look at how much is still moving, and
            // what has all but died away is put to rest. Not every
            // step: it is the slowest part of one.
            self.ticks +%= 1;
            if (self.ticks % look_every != 0) continue;
            looked = true;
            for (self.u, self.v) |*u, *v| {
                if (@abs(v.*) < rest) v.* = 0;
                if (@abs(u.*) < rest) u.* = 0;
                most = @max(most, @max(@abs(u.*), @abs(v.*) / ripple_speed));
            }
        }
        // A stall drops its backlog.
        if (self.owed >= step_s) self.owed = 0;
        if (looked and most < still) {
            @memset(self.u, 0);
            @memset(self.v, 0);
            self.awake = false;
        }
        return true;
    }
};

/// What the desktop lays on the pond: the cursor's wake, the waves
/// windows push, and the ring where focus lands.
pub const Desk = struct {
    const Known = struct { address: u64, rect: WindowRect, seen: bool = true };

    known: [max_known]Known = undefined,
    n: usize = 0,
    cursor: ?[2]f32 = null,
    focused: u64 = 0,
    switches: u32 = 0,
    started: bool = false,
    /// How brightly the cursor shines: up with its speed, and out soon
    /// after it stops.
    torch: f32 = 0,

    pub fn update(self: *Desk, pond: *Pond, grid: Grid, state: effects.FrameState) void {
        // The cursor's wake, as much per cell however fast it goes. A
        // jump across the screen is not a stroke.
        const now = grid.cell(state.cursor);
        const dt = std.math.clamp(state.dt, 1e-4, 0.05);
        var speed: f32 = 0;
        if (self.cursor) |last| {
            const dx = now[0] - last[0];
            const dy = now[1] - last[1];
            const moved = @sqrt(dx * dx + dy * dy);
            if (moved > 0.02 and moved < 30.0) {
                pond.line(last, now, wake);
                speed = moved / dt;
            }
        }
        self.cursor = now;
        const goal = std.math.clamp(speed / torch_full, 0.0, 1.0);
        self.torch += (goal - self.torch) * (1.0 - @exp(-dt / (if (goal > self.torch) @as(f32, 0.08) else torch_out_s)));
        if (goal == 0 and self.torch < rest) self.torch = 0;

        // A workspace switch slides every window across the screen, and
        // none of that is a window moving. While it does, and on the
        // first frame of all, windows are only noted.
        const settled = self.started and state.workspace_slide >= 1.0 and state.workspace_switches == self.switches;
        self.switches = state.workspace_switches;
        self.started = true;

        for (self.known[0..self.n]) |*k| k.seen = false;
        for (state.windows) |win| {
            if (win.w < 1.0 or win.h < 1.0) continue;
            var found: ?*Known = null;
            for (self.known[0..self.n]) |*k| {
                if (k.address == win.address) found = k;
            }
            if (found) |k| {
                if (settled) push(pond, grid, k.rect, win);
                k.rect = win;
                k.seen = true;
            } else {
                // A window not seen before grew from its middle.
                if (settled) push(pond, grid, .{ .x = win.x + win.w * 0.5, .y = win.y + win.h * 0.5, .w = 0, .h = 0 }, win);
                if (self.n < max_known) {
                    self.known[self.n] = .{ .address = win.address, .rect = win };
                    self.n += 1;
                }
            }
        }
        // One that closed shrank to its middle. One merely not here (it
        // is on another workspace) is kept as it was.
        for (state.closed_windows) |address| {
            var i: usize = 0;
            while (i < self.n) : (i += 1) {
                if (self.known[i].address != address) continue;
                const r = self.known[i].rect;
                if (settled) push(pond, grid, r, .{ .x = r.x + r.w * 0.5, .y = r.y + r.h * 0.5, .w = 0, .h = 0 });
                self.known[i] = self.known[self.n - 1];
                self.n -= 1;
                break;
            }
        }
        // With no room left, those not on screen make way.
        if (self.n == max_known) {
            var kept: usize = 0;
            for (self.known[0..self.n]) |k| {
                if (!k.seen) continue;
                self.known[kept] = k;
                kept += 1;
            }
            self.n = kept;
        }

        // Focus landing on a window sends a ring out from its frame.
        if (state.focused_address != self.focused) {
            self.focused = state.focused_address;
            if (settled) for (state.windows) |win| {
                if (win.address != state.focused_address or win.w < 1.0 or win.h < 1.0) continue;
                const a = grid.cell(.{ win.x, win.y });
                const b = grid.cell(.{ win.x + win.w, win.y + win.h });
                pond.line(.{ a[0], a[1] }, .{ b[0], a[1] }, focus_ring);
                pond.line(.{ a[0], b[1] }, .{ b[0], b[1] }, focus_ring);
                pond.line(.{ a[0], a[1] }, .{ a[0], b[1] }, focus_ring);
                pond.line(.{ b[0], a[1] }, .{ b[0], b[1] }, focus_ring);
                break;
            };
        }
    }

    /// A window went from `was` to `is`: each edge raises the pond by how
    /// far it moved outward, and lowers it by how far it moved inward.
    fn push(pond: *Pond, grid: Grid, was: WindowRect, is: WindowRect) void {
        const a0 = grid.cell(.{ was.x, was.y });
        const b0 = grid.cell(.{ was.x + was.w, was.y + was.h });
        const a = grid.cell(.{ is.x, is.y });
        const b = grid.cell(.{ is.x + is.w, is.y + is.h });
        const left = std.math.clamp(a0[0] - a[0], -most_shift, most_shift);
        const right = std.math.clamp(b[0] - b0[0], -most_shift, most_shift);
        const bottom = std.math.clamp(a0[1] - a[1], -most_shift, most_shift);
        const top = std.math.clamp(b[1] - b0[1], -most_shift, most_shift);
        const least = 0.004;
        if (@abs(left) > least) pond.line(.{ a[0], a[1] }, .{ a[0], b[1] }, bow * left);
        if (@abs(right) > least) pond.line(.{ b[0], a[1] }, .{ b[0], b[1] }, bow * right);
        if (@abs(bottom) > least) pond.line(.{ a[0], a[1] }, .{ b[0], a[1] }, bow * bottom);
        if (@abs(top) > least) pond.line(.{ a[0], b[1] }, .{ b[0], b[1] }, bow * top);
    }
};

/// What the music does to the board.
pub const Tune = struct {
    /// The push the last beats gave the swell, dying away.
    surge: f32 = 0,
    /// Each band's level, followed quickly and followed slowly. A lamp
    /// goes by something between the two.
    quick: [6]f32 = @splat(0),
    slow: [6]f32 = @splat(0),

    pub fn step(self: *Tune, dt: f32, bands: *const [6]f32, beat: bool) void {
        if (beat) self.surge = @min(1.5, self.surge + 1.0);
        self.surge *= @exp(-dt / surge_s);
        if (self.surge < rest) self.surge = 0;
        for (&self.quick, &self.slow, bands) |*q, *s, b| {
            const heard = std.math.clamp(b, 0.0, 1.0);
            q.* += (heard - q.*) * @min(1.0, 9.0 * dt);
            s.* += (heard - s.*) * @min(1.0, 1.1 * dt);
            if (heard == 0 and q.* < rest) q.* = 0;
            if (heard == 0 and s.* < rest) s.* = 0;
        }
    }

    /// How many times its own pace the swell runs at now.
    pub fn haste(self: *const Tune) f32 {
        return 1.0 + surge_push * self.surge;
    }

    /// How many times its own height wave `i` of the swell stands at.
    pub fn lift(self: *const Tune, i: usize) f32 {
        const b = swell_bands[i];
        return 1.0 + swell_lift * 0.5 * (self.slow[b[0]] + self.slow[b[1]]);
    }

    pub fn loud(self: *const Tune) f32 {
        var sum: f32 = 0;
        for (self.slow) |x| sum += x / 6.0;
        return sum;
    }
};

/// One wave of the swell: how its phase changes per cell across and up,
/// its pace, its height, and where it has got to.
const Swell = struct {
    k: [2]f32,
    pace: f32,
    amp: f32,
    phase: f32,
};

/// The edges are known when it is compiled, so the division is done
/// then: this runs for every lamp.
inline fn smoothstep(comptime e0: f32, comptime e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) * (1.0 / (e1 - e0)), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn mixBits(x: u32) u32 {
    var h = x;
    h ^= h >> 15;
    h *%= 0x2c1b3c6d;
    h ^= h >> 12;
    h *%= 0x297a2d39;
    h ^= h >> 15;
    return h;
}

/// Four numbers in 0..1 for lamp `i` and a salt.
fn rand4(i: u32, salt: u32) [4]f32 {
    const a = mixBits(i *% 0x8da6b343 +% salt *% 0x9e3779b9 +% 0x51ed270b);
    const b = mixBits(a ^ 0x7f4a7c15);
    const unit = 1.0 / 65535.0;
    return .{
        @as(f32, @floatFromInt(a & 0xffff)) * unit,
        @as(f32, @floatFromInt(a >> 16)) * unit,
        @as(f32, @floatFromInt(b & 0xffff)) * unit,
        @as(f32, @floatFromInt(b >> 16)) * unit,
    };
}

pub const Lamp = struct {
    /// When in the board's turn it changes its mark and color. Its own
    /// for good.
    own: f32,
    /// How far behind its band it follows (0 close, 1 far), and which
    /// kind of fade it has. Its own for good.
    lag: f32,
    fade: u2,
    /// For this turn: how keen it is, its palette slot (0 = white), the
    /// band it listens to, and whether it has a halo.
    keen: f32 = 0,
    slot: u8 = 0,
    band: u8 = 0,
    halo: bool = false,
    /// The turn those are of.
    rolled: u32 = std.math.maxInt(u32),
    /// How awake it is: 0 asleep, 1 full on, past 1 and a lamp with a
    /// halo shows it.
    level: f32 = 0,
    /// The light it stands in, as it shows it: up at once and down
    /// slowly, like the lamp itself.
    lit: f32 = 0,
    /// What is left of its glint.
    glint: f32 = 0,
};

/// What the board is lit by this step.
pub const Scene = struct {
    swells: []const Swell,
    /// How many times its own height each wave stands at.
    lifts: [n_swells]f32 = @splat(1),
    pond: *const Pond,
    tune: *const Tune,
    /// Turns the board has made, and how far through this one it is.
    turns: u32 = 0,
    turn: f32 = 0,
    /// The share of lamps that are colored.
    color: f32 = 0.45,
    palette: ?*const palette_mod.Palette = null,
};

/// The lamps.
pub const Board = struct {
    allocator: std.mem.Allocator,
    cols: usize,
    rows: usize,
    lamps: []Lamp,
    /// Light laid on each lamp besides the pond's, for the coming step.
    extra: []f32,
    /// What each lamp shows, four bytes a lamp: its color, then how
    /// bright it is (the lower half of the byte's range) and how strong
    /// its halo (the upper).
    shown: []u8,
    /// Working room: each wave's sine and cosine along the columns and
    /// along the rows.
    across: [][n_swells][2]f32,
    up: [][n_swells][2]f32,

    pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !Board {
        const n = cols * rows;
        const lamps = try allocator.alloc(Lamp, n);
        errdefer allocator.free(lamps);
        const extra = try allocator.alloc(f32, n);
        errdefer allocator.free(extra);
        const shown = try allocator.alloc(u8, n * 4);
        errdefer allocator.free(shown);
        const across = try allocator.alloc([n_swells][2]f32, cols);
        errdefer allocator.free(across);
        const up = try allocator.alloc([n_swells][2]f32, rows);
        for (lamps, 0..) |*lamp, i| {
            const h = rand4(@intCast(i), 0);
            lamp.* = .{ .own = h[0], .lag = h[2] * h[2], .fade = @intFromFloat(@min(3.0, h[3] * 4.0)) };
        }
        @memset(extra, 0);
        @memset(shown, 0);
        return .{ .allocator = allocator, .cols = cols, .rows = rows, .lamps = lamps, .extra = extra, .shown = shown, .across = across, .up = up };
    }

    pub fn deinit(self: *Board) void {
        self.allocator.free(self.lamps);
        self.allocator.free(self.extra);
        self.allocator.free(self.shown);
        self.allocator.free(self.across);
        self.allocator.free(self.up);
    }

    pub fn at(self: *const Board, x: usize, y: usize) *Lamp {
        return &self.lamps[y * self.cols + x];
    }

    /// Light round a point (in cells), `amount` at the point itself,
    /// for the coming step.
    pub fn shine(self: *Board, where: [2]f32, amount: f32, radius: f32) void {
        if (amount <= 0.002) return;
        const reach = 2.6 * radius;
        const box = self.cellsIn(.{ where[0] - reach, where[1] - reach }, .{ where[0] + reach, where[1] + reach }) orelse return;
        var y = box[1];
        while (y <= box[3]) : (y += 1) {
            var x = box[0];
            while (x <= box[2]) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - where[0];
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - where[1];
                self.extra[y * self.cols + x] += amount * @exp(-(dx * dx + dy * dy) / (2.0 * radius * radius));
            }
        }
    }

    /// Light along the frame of a rect (corners in cells), `amount` on
    /// the frame and falling to nothing `reach` cells outside it.
    pub fn frame(self: *Board, a: [2]f32, b: [2]f32, amount: f32, reach: f32) void {
        if (amount <= 0.002) return;
        const box = self.cellsIn(.{ a[0] - reach, a[1] - reach }, .{ b[0] + reach, b[1] + reach }) orelse return;
        var y = box[1];
        while (y <= box[3]) : (y += 1) {
            var x = box[0];
            while (x <= box[2]) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                // How far outside the rect.
                const ox = @max(@max(a[0] - px, px - b[0]), 0.0);
                const oy = @max(@max(a[1] - py, py - b[1]), 0.0);
                const out = @sqrt(ox * ox + oy * oy);
                // Lamps under the window are not seen, and take none.
                if (out <= 0 or out >= reach) continue;
                const t = 1.0 - out / reach;
                self.extra[y * self.cols + x] += amount * t * t * (3.0 - 2.0 * t);
            }
        }
    }

    /// The lamps whose cells a box touches: first and last column, first
    /// and last row.
    fn cellsIn(self: *const Board, lo: [2]f32, hi: [2]f32) ?[4]usize {
        const w: f32 = @floatFromInt(self.cols);
        const h: f32 = @floatFromInt(self.rows);
        if (hi[0] < 0 or hi[1] < 0 or lo[0] >= w or lo[1] >= h) return null;
        return .{
            @intFromFloat(std.math.clamp(@floor(lo[0]), 0.0, w - 1.0)),
            @intFromFloat(std.math.clamp(@floor(lo[1]), 0.0, h - 1.0)),
            @intFromFloat(std.math.clamp(@floor(hi[0]), 0.0, w - 1.0)),
            @intFromFloat(std.math.clamp(@floor(hi[1]), 0.0, h - 1.0)),
        };
    }

    /// A lamp's mark, color and band for turn `k`.
    fn roll(lamp: *Lamp, i: usize, k: u32, share: f32) void {
        const h = rand4(@intCast(i), k +% 1);
        const n: u8 = @intFromFloat(@min(11.0, h[2] * 12.0));
        lamp.keen = h[0] * @sqrt(h[0]);
        lamp.slot = if (h[1] < share) 1 + n % 6 + (if (n >= 6) @as(u8, 8) else 0) else 0;
        lamp.band = band_of[n % 6];
        lamp.halo = h[3] > 0.9;
        lamp.rolled = k;
    }

    /// Carry the lamps `dt` on under `scene` and what was laid on them
    /// since the last step, and make the picture of them.
    pub fn step(self: *Board, dt: f32, scene: Scene) void {
        const cols = self.cols;
        // Each wave is sin(kx x + ky y - phase): its sine and cosine
        // along the columns and along the rows, then two products a
        // lamp.
        for (self.across, 0..) |*wave, x| {
            wave.* = @splat(.{ 0, 0 });
            for (scene.swells, scene.lifts[0..scene.swells.len], 0..) |s, lift, w| {
                const a = s.k[0] * (@as(f32, @floatFromInt(x)) + 0.5) - s.phase;
                wave[w] = .{ s.amp * lift * @sin(a), s.amp * lift * @cos(a) };
            }
        }
        for (self.up, 0..) |*wave, y| {
            wave.* = @splat(.{ 0, 1 });
            for (scene.swells, 0..) |s, w| {
                const b = s.k[1] * (@as(f32, @floatFromInt(y)) + 0.5);
                wave[w] = .{ @sin(b), @cos(b) };
            }
        }

        var colors: [16][3]f32 = @splat(.{ 0.9, 0.9, 0.9 });
        var white = [3]f32{ 0.9, 0.9, 0.9 };
        var known: usize = 0;
        if (scene.palette) |pal| {
            white = .{ pal.foreground.r, pal.foreground.g, pal.foreground.b };
            known = @min(16, pal.color_count);
            for (colors[0..known], pal.colors[0..known]) |*out, col| out.* = .{ col.r, col.g, col.b };
        }

        const music = smoothstep(0.02, 0.12, scene.tune.loud());
        const waking = 1.0 - @exp(-dt / wake_s);
        var fading: [fade_s.len]f32 = undefined;
        for (&fading, fade_s) |*f, secs| f.* = 1.0 - @exp(-dt / secs);
        const glinting = @exp(-dt / glint_s);

        const pond = scene.pond;
        for (self.up, 0..) |r, y| {
            const first = y * cols;
            const ripples = pond.u[(y + margin) * pond.w + margin ..][0..cols];
            const row_shown = self.shown[first * 4 ..][0 .. cols * 4];
            for (self.lamps[first..][0..cols], self.extra[first..][0..cols], ripples, self.across, 0..) |*lamp, more, ripple, cw, x| {
                const i = first + x;
                var swell: f32 = 0;
                inline for (0..n_swells) |w| swell += cw[w][0] * r[w][1] + cw[w][1] * r[w][0];
                // A ripple shows wherever it runs, its crests lighting
                // dark water and its troughs dimming lit.
                const light = std.math.clamp(smoothstep(-0.55, 0.7, swell) + 1.6 * ripple + more, 0.0, 1.25);

                // Its mark and color hold for one turn of the board.
                // Each lamp turns at its own moment. Coming up to it
                // the lamp grows dull and its color drains to white,
                // and after it they come back, so nothing is seen to
                // change.
                const through = scene.turn + lamp.own;
                const whole = @floor(through);
                const part = through - whole;
                const k = scene.turns +% @as(u32, @intFromFloat(whole));
                if (lamp.rolled != k) roll(lamp, i, k, scene.color);
                const open = smoothstep(0.0, 0.18, part) * smoothstep(1.0, 0.82, part);
                const keen = lamp.keen * open;

                // What it wakes to. A white lamp, and every lamp in
                // silence, wakes to the light. While music plays a
                // colored one wakes to its band: all over the board
                // when the band is loud, thickest where the light is,
                // and hardly at all when the band is quiet.
                var slot = lamp.slot;
                if (slot > 8 and known < 15) slot -= 8;
                if (known < 7) slot = 0;
                var seen = light;
                if (slot != 0 and music > 0) {
                    const tune = scene.tune;
                    const heard = tune.quick[lamp.band] + (tune.slow[lamp.band] - tune.quick[lamp.band]) * lamp.lag;
                    seen += (@min(light * (0.35 + heard) + 0.55 * heard, 1.4) - light) * music;
                }
                // It wakes as that passes its mark, the keenest first:
                // at once, and fades at its leisure.
                const mark = 1.7 - 1.6 * keen;
                const goal = std.math.clamp((1.3 * seen - mark) / 0.5, 0.0, 2.0) * @min(1.0, 6.0 * open);
                // The slow swell brings a lamp up by degrees; a ripple's
                // crest, the cursor or a beat strikes it.
                lamp.glint = if (lamp.glint < 1e-3) 0.0 else lamp.glint * glinting;
                if (goal - lamp.level > glint_from and lamp.glint < 0.25) lamp.glint = 1;
                lamp.level += (goal - lamp.level) * (if (goal > lamp.level) waking else fading[lamp.fade]);
                if (@abs(goal - lamp.level) < 1e-4) lamp.level = goal;

                // Asleep it is a faint square, a little less faint
                // where the light is.
                lamp.lit += (light - lamp.lit) * (if (light > lamp.lit) waking else fading[lamp.fade]);
                if (@abs(light - lamp.lit) < 1e-4) lamp.lit = light;
                const dim = 0.07 + 0.2 * lamp.lit;
                const awake = @min(lamp.level, 1.0);
                const steady = dim + (1.0 - dim) * awake;
                const bright = steady + (1.0 - steady) * lamp.glint;
                const hot = @max(if (lamp.halo) std.math.clamp((lamp.level - 1.0) / 0.6, 0.0, 1.0) else 0.0, 0.7 * lamp.glint);
                var hue = white;
                if (slot != 0) {
                    const tinted = @min(1.0, 3.0 * open);
                    inline for (0..3) |ch| hue[ch] += (colors[slot][ch] - white[ch]) * tinted;
                }
                const out = row_shown[x * 4 ..][0..4];
                inline for (0..3) |ch| out[ch] = @intFromFloat(std.math.clamp(hue[ch], 0.0, 1.0) * 255.0 + 0.5);
                out[3] = @intFromFloat((bright + hot) * 127.0 + 0.5);
            }
        }
        @memset(self.extra, 0);
    }

};

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    grid: Grid,
    pond: Pond,
    board: Board,
    desk: Desk = .{},
    /// The light behind the focused window's frame, and each lamp's
    /// frame in cells.
    focus: lamps_mod.Lamps = .{},
    swells: [n_swells]Swell,
    speed: f32,
    /// The share of lamps that are colored, and how strong the halos
    /// are.
    color: f32,
    glow: f32,
    /// How far through its turn the board is, and how many turns it has
    /// made.
    turn: f32 = 0,
    turns: u32 = 0,
    tune: Tune = .{},
    /// Time the lamps have not been carried on yet.
    owed: f32 = 1,
    tex: c.GLuint = 0,
    /// Whether the lamps have changed since the shader last had them.
    stale: bool = true,

    u: Uniforms(.{
        .lamps = "iWaveLamps",
        .grid = "iWaveGrid",
        .look = "iWaveLook",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const grid = Grid.init(@max(width, 64.0), @max(height, 64.0), std.math.clamp(params.getFloat("size", 1.0), 0.5, 3.0));
        var music = try spectral.Analyzer.init(allocator, params);
        errdefer music.deinit(allocator);
        var prng = std.Random.DefaultPrng.init(0xda2c);
        const r = prng.random();

        // Long waves and shorter ones, the long ones running up to the
        // right and the rest fanned to either side of that. Lengths are
        // in screen heights, so the picture is the same at any lamp
        // size.
        const rows: f32 = @floatFromInt(grid.rows);
        const lengths = [n_swells]f32{ 1.55, 1.0, 0.64, 0.43 };
        const headings = [n_swells]f32{ 0.62, 1.15, 0.05, 1.75 };
        const periods = [n_swells]f32{ 26.0, 19.0, 13.5, 9.5 };
        const amps = [n_swells]f32{ 0.5, 0.27, 0.15, 0.08 };
        var swells: [n_swells]Swell = undefined;
        for (&swells, lengths, headings, periods, amps) |*s, len, heading, period, amp| {
            const k = tau / (len * rows);
            s.* = .{
                .k = .{ k * @cos(heading), k * @sin(heading) },
                .pace = tau / period,
                .amp = amp,
                .phase = r.float(f32) * tau,
            };
        }
        var pond = try Pond.init(allocator, grid.cols, grid.rows);
        errdefer pond.deinit();
        return .{
            .allocator = allocator,
            .music = music,
            .grid = grid,
            .pond = pond,
            .board = try Board.init(allocator, grid.cols, grid.rows),
            .swells = swells,
            .speed = std.math.clamp(params.getFloat("speed", 1.0), 0.0, 6.0),
            .color = std.math.clamp(params.getFloat("color", 0.45), 0.0, 1.0),
            .glow = std.math.clamp(params.getFloat("glow", 1.0), 0.0, 3.0),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        const beat = self.music.update(dt);
        self.tune.step(dt, &self.music.bands.bands, beat);

        const by = self.speed * dt;
        for (&self.swells) |*s| s.phase = @mod(s.phase + s.pace * by * self.tune.haste(), tau);
        self.turn += by / turn_s;
        if (self.turn >= 1.0) {
            self.turn -= 1.0;
            self.turns = (self.turns + 1) % 4096;
        }

        self.desk.update(&self.pond, self.grid, state);
        _ = self.pond.step(dt);

        // The light behind the focused window's frame.
        var id: u64 = lamps_mod.home_id;
        if (state.focused_address > lamps_mod.cursor_id) {
            for (state.windows) |w| {
                if (w.address == state.focused_address and w.w >= 1.0 and w.h >= 1.0) id = w.address;
            }
        }
        self.focus.step(dt, id, .{ 0, 0 }, state.windows);

        self.owed += dt;
        if (self.owed < 1.0 / lamp_hz) return;
        const grid = self.grid;
        const board = &self.board;
        if (self.desk.cursor) |at| board.shine(at, torch * self.desk.torch, torch_radius);
        for (self.focus.lamps) |lamp| {
            if (lamp.id <= lamps_mod.cursor_id or lamp.strength() <= 0) continue;
            for (state.windows) |w| {
                if (w.address != lamp.id or w.w < 1.0 or w.h < 1.0) continue;
                board.frame(grid.cell(.{ w.x, w.y }), grid.cell(.{ w.x + w.w, w.y + w.h }), rim * lamp.strength(), rim_reach);
                break;
            }
        }
        var lifts: [n_swells]f32 = undefined;
        for (&lifts, 0..) |*lift, i| lift.* = self.tune.lift(i);
        board.step(@min(self.owed, 0.1), .{
            .swells = &self.swells,
            .lifts = lifts,
            .pond = &self.pond,
            .tune = &self.tune,
            .turns = self.turns,
            .turn = self.turn,
            .color = self.color,
            .palette = state.palette,
        });
        self.owed = 0;
        self.stale = true;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        const board = &self.board;
        const tex_w: c.GLsizei = @intCast(board.cols);
        const tex_h: c.GLsizei = @intCast(board.rows);
        c.glActiveTexture(c.GL_TEXTURE0);
        const new = self.tex == 0;
        if (new) {
            c.glGenTextures(1, &self.tex);
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, tex_w, tex_h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        }
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        if (new or self.stale) c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, tex_w, tex_h, c.GL_RGBA, c.GL_UNSIGNED_BYTE, board.shown.ptr);
        self.stale = false;

        const grid = self.grid;
        self.u.use(prog.program);
        self.u.int(.lamps, 0);
        self.u.f4(.grid, grid.pitch, grid.side, grid.origin[0], grid.origin[1]);
        self.u.f1(.look, self.glow);
    }

    pub fn deinit(self: *Context) void {
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
        self.board.deinit();
        self.pond.deinit();
        self.music.deinit(self.allocator);
    }
};

fn frame(cursor: [2]f32, windows: []const WindowRect) effects.FrameState {
    return .{
        .dt = 1.0 / 120.0,
        .time = 0,
        .cursor = cursor,
        .focused_win = .{},
        .windows = windows,
    };
}

test "every lamp is the same whole-pixel square, and the board covers the screen from its middle" {
    const screens = [_][3]f32{ .{ 3840, 2160, 1.0 }, .{ 2560, 1440, 1.0 }, .{ 1920, 1080, 0.7 }, .{ 3440, 1440, 1.3 }, .{ 1366, 768, 1.0 }, .{ 1080, 1920, 2.0 } };
    for (screens) |s| {
        const grid = Grid.init(s[0], s[1], s[2]);
        try std.testing.expectEqual(grid.pitch, @round(grid.pitch));
        try std.testing.expectEqual(grid.side, @round(grid.side));
        try std.testing.expectEqual(@mod(grid.pitch, 2.0), @mod(grid.side, 2.0));
        try std.testing.expect(grid.side >= 0.22 * grid.pitch and grid.side <= 0.4 * grid.pitch);
        for (grid.origin, [2]f32{ s[0], s[1] }, [2]usize{ grid.cols, grid.rows }) |origin, size, count| {
            const span = @as(f32, @floatFromInt(count)) * grid.pitch;
            try std.testing.expectEqual(origin, @round(origin));
            try std.testing.expect(origin <= 0 and origin + span >= size);
            // As much hangs off one edge as the other, to a pixel.
            try std.testing.expect(@abs(-origin - (origin + span - size)) <= 1.0);
        }
    }
    const grid = Grid.init(3840, 2160, 1.0);
    try std.testing.expectEqual(@as(usize, 60), grid.rows);
    const middle = grid.cell(.{ 1920, 1080 });
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(grid.cols)) * 0.5, middle[0], 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 30), middle[1], 0.02);
}

test "a drop spreads as a ring at the pond's speed" {
    var pond = try Pond.init(std.testing.allocator, 107, 60);
    defer pond.deinit();
    pond.drop(.{ 53.5, 30.5 }, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pond.at(53, 30), 1e-3);
    for (0..120) |_| _ = pond.step(1.0 / 120.0);
    // After a second the crest along the row through the drop is one
    // second's travel out.
    var crest: usize = 0;
    var high: f32 = 0;
    for (54..107) |x| {
        if (pond.at(x, 30) > high) {
            high = pond.at(x, 30);
            crest = x;
        }
    }
    try std.testing.expect(high > 0.03);
    try std.testing.expectApproxEqAbs(ripple_speed, @as(f32, @floatFromInt(crest - 53)), 2.5);
    // And it is a ring: as high the same way up as across.
    try std.testing.expectApproxEqAbs(high, pond.at(53, 30 + (crest - 53)), 0.15 * high);
}

test "ripples run off the screen and do not come back, and a still pond is not stepped" {
    var pond = try Pond.init(std.testing.allocator, 107, 60);
    defer pond.deinit();
    try std.testing.expect(!pond.step(1.0 / 120.0));
    // Hard by the left edge: what heads left is gone in a second or
    // so, and would be back at the drop by then if the edge threw it
    // back.
    pond.drop(.{ 4.0, 30.5 }, 1.0);
    var worst: f32 = 0;
    for (0..3 * 120) |i| {
        try std.testing.expect(pond.step(1.0 / 120.0));
        if (i < 150) continue;
        for (0..12) |x| worst = @max(worst, @abs(pond.at(x, 30)));
    }
    try std.testing.expect(worst < 0.03);
    var steps: usize = 0;
    while (pond.step(1.0 / 120.0)) steps += 1;
    try std.testing.expect(steps < 40 * 120);
    for (pond.u) |u| try std.testing.expectEqual(@as(f32, 0), u);
}

test "the pond stays bounded however long things are laid on it" {
    var pond = try Pond.init(std.testing.allocator, 107, 60);
    defer pond.deinit();
    var prng = std.Random.DefaultPrng.init(9);
    const r = prng.random();
    for (0..120 * 60) |i| {
        if (i % 7 == 0) pond.drop(.{ r.float(f32) * 107.0, r.float(f32) * 60.0 }, 1.0);
        // Frames of every length.
        _ = pond.step(0.004 + 0.03 * r.float(f32));
    }
    for (pond.u) |u| try std.testing.expect(@abs(u) < 6.0);
}

test "the cursor leaves a wake where it moves, and none where it rests" {
    const grid = Grid.init(3840, 2160, 1.0);
    var pond = try Pond.init(std.testing.allocator, grid.cols, grid.rows);
    defer pond.deinit();
    var desk = Desk{};
    for (0..30) |_| desk.update(&pond, grid, frame(.{ 1000, 1000 }, &.{}));
    try std.testing.expect(!pond.awake);
    // A stroke to the right, slowly and then fast: as much is laid per
    // cell either way.
    desk.update(&pond, grid, frame(.{ 1000 + 36 * 4, 1000 }, &.{}));
    const slow = pond.at(@intFromFloat(grid.cell(.{ 1072, 1000 })[0]), @intFromFloat(grid.cell(.{ 1072, 1000 })[1]));
    desk.update(&pond, grid, frame(.{ 1000 + 36 * 24, 1000 }, &.{}));
    const fast = pond.at(@intFromFloat(grid.cell(.{ 1500, 1000 })[0]), @intFromFloat(grid.cell(.{ 1500, 1000 })[1]));
    try std.testing.expect(slow > 0.5 * wake and slow < 1.3 * wake);
    try std.testing.expectApproxEqAbs(slow, fast, 0.25 * wake);
    // A jump across the screen lays nothing.
    const before = pond.at(80, 10);
    desk.update(&pond, grid, frame(.{ 3000, 300 }, &.{}));
    try std.testing.expectEqual(before, pond.at(80, 10));
}

test "a window that moves raises the pond ahead of it and lowers it behind" {
    const grid = Grid.init(3840, 2160, 1.0);
    var pond = try Pond.init(std.testing.allocator, grid.cols, grid.rows);
    defer pond.deinit();
    var desk = Desk{};
    var win = WindowRect{ .x = 1080, .y = 720, .w = 720, .h = 720, .address = 0xa0 };
    // First sight of everything is only noted.
    desk.update(&pond, grid, frame(.{ 0, 0 }, &.{win}));
    try std.testing.expect(!pond.awake);
    win.x += 36;
    desk.update(&pond, grid, frame(.{ 0, 0 }, &.{win}));
    const row: usize = 30;
    const ahead = pond.at(@intFromFloat(grid.cell(.{ win.x + win.w, 0 })[0]), row);
    const behind = pond.at(@intFromFloat(grid.cell(.{ win.x, 0 })[0]), row);
    try std.testing.expect(ahead > 0.5 * bow);
    try std.testing.expect(behind < -0.5 * bow);
    // The edges it slid along did nothing.
    try std.testing.expectApproxEqAbs(@as(f32, 0), pond.at(40, @intFromFloat(grid.cell(.{ 0, win.y + win.h })[1] + 3)), 0.02);
}

test "a window that opens sends a ring out, and a workspace switch makes no splash" {
    const grid = Grid.init(3840, 2160, 1.0);
    var pond = try Pond.init(std.testing.allocator, grid.cols, grid.rows);
    defer pond.deinit();
    var desk = Desk{};
    const a = WindowRect{ .x = 400, .y = 400, .w = 800, .h = 600, .address = 0xa0 };
    const b = WindowRect{ .x = 2000, .y = 900, .w = 900, .h = 700, .address = 0xb0 };
    desk.update(&pond, grid, frame(.{ 0, 0 }, &.{a}));
    try std.testing.expect(!pond.awake);

    // Another workspace: one window gone, another there, everything
    // sliding.
    var state = frame(.{ 0, 0 }, &.{b});
    state.workspace_switches = 1;
    state.workspace_slide = 0.2;
    desk.update(&pond, grid, state);
    state.workspace_slide = 1.0;
    desk.update(&pond, grid, state);
    // And back.
    state = frame(.{ 0, 0 }, &.{a});
    state.workspace_switches = 2;
    desk.update(&pond, grid, state);
    state.workspace_switches = 2;
    desk.update(&pond, grid, state);
    try std.testing.expect(!pond.awake);

    // A window opening here and now does.
    const opened = WindowRect{ .x = 2200, .y = 300, .w = 600, .h = 400, .address = 0xc0 };
    state = frame(.{ 0, 0 }, &.{ a, opened });
    state.workspace_switches = 2;
    desk.update(&pond, grid, state);
    try std.testing.expect(pond.awake);
    const edge = grid.cell(.{ opened.x + opened.w, opened.y + 200 });
    try std.testing.expect(pond.at(@intFromFloat(edge[0]), @intFromFloat(edge[1])) > 0.3 * bow);
    // And focus landing on a window sends a ring out from its frame.
    while (pond.step(0.01)) {}
    state.focused_address = a.address;
    desk.update(&pond, grid, state);
    const frame_at = grid.cell(.{ a.x, a.y + 300 });
    try std.testing.expect(pond.at(@intFromFloat(frame_at[0]), @intFromFloat(frame_at[1])) > 0.5 * focus_ring);
}

test "a beat pushes the swell on and the push dies away, and a band held loud raises its wave slowly" {
    var tune = Tune{};
    const quiet: [6]f32 = @splat(0);
    try std.testing.expectEqual(@as(f32, 1), tune.haste());
    tune.step(1.0 / 120.0, &quiet, true);
    try std.testing.expect(tune.haste() > 1.0 + 0.8 * surge_push);
    // How far ahead of its own pace one beat carries the swell: a
    // fraction of a second's drift, not a jump.
    var ahead: f32 = (tune.haste() - 1.0) / 120.0;
    for (0..240) |_| {
        tune.step(1.0 / 120.0, &quiet, false);
        ahead += (tune.haste() - 1.0) / 120.0;
    }
    try std.testing.expectApproxEqAbs(surge_push * surge_s, ahead, 0.05);
    try std.testing.expect(tune.haste() < 1.001);
    // Beats come as fast as they like and the push stays bounded.
    for (0..600) |i| tune.step(1.0 / 120.0, &quiet, i % 6 == 0);
    try std.testing.expect(tune.haste() <= 1.0 + 1.5 * surge_push);

    // Bass held full on: lamps that follow quickly have it in a quarter
    // second, the slow ones and the long wave not for a second or more.
    var bass: [6]f32 = @splat(0);
    bass[0] = 1;
    bass[1] = 1;
    tune = .{};
    for (0..30) |_| tune.step(1.0 / 120.0, &bass, false);
    try std.testing.expect(tune.quick[0] > 0.85);
    try std.testing.expect(tune.slow[0] < 0.3);
    try std.testing.expect(tune.lift(0) < 1.0 + 0.3 * swell_lift);
    for (0..480) |_| tune.step(1.0 / 120.0, &bass, false);
    try std.testing.expectApproxEqAbs(1.0 + swell_lift, tune.lift(0), 0.02);
    // The other waves, with other bands, stand as they did.
    try std.testing.expectEqual(@as(f32, 1), tune.lift(1));
    try std.testing.expectEqual(@as(f32, 1), tune.lift(3));
}

const still_tune = Tune{};

/// A swell that is low everywhere and stays so.
const trough = [1]Swell{.{ .k = .{ 0, 0 }, .pace = 0, .amp = 1, .phase = 0.25 * tau }};

/// A board in the dark, to try single things on.
fn bare(pond: *const Pond, tune: *const Tune) Scene {
    return .{ .swells = &trough, .pond = pond, .tune = tune };
}

test "a lamp wakes at once and fades slowly, and the picture says so" {
    var pond = try Pond.init(std.testing.allocator, 40, 30);
    defer pond.deinit();
    var board = try Board.init(std.testing.allocator, 40, 30);
    defer board.deinit();
    const scene = bare(&pond, &still_tune);
    const dt = 1.0 / 70.0;
    // The middle of a turn, so every lamp is as keen as it gets.
    var mid = scene;
    mid.turn = 0.5;

    // Nothing lit: every lamp asleep and faint.
    for (0..20) |_| board.step(dt, mid);
    for (board.lamps) |lamp| try std.testing.expectEqual(@as(f32, 0), lamp.level);
    for (0..board.lamps.len) |i| {
        try std.testing.expect(board.shown[i * 4 + 3] > 0 and board.shown[i * 4 + 3] < 20);
    }

    // A strong light on one spot for a tenth of a second.
    for (0..7) |_| {
        board.shine(.{ 20.5, 15.5 }, 1.25, 3.0);
        board.step(dt, mid);
    }
    var woke: usize = 0;
    var keenest: usize = 0;
    for (13..18) |y| {
        for (18..23) |x| {
            const lamp = board.at(x, y);
            if (lamp.level > 0.5) woke += 1;
            if (lamp.level > board.lamps[keenest].level) keenest = y * 40 + x;
        }
    }
    try std.testing.expect(woke >= 3);
    try std.testing.expect(board.shown[keenest * 4 + 3] >= 127);
    // Far from it nothing woke.
    try std.testing.expectEqual(@as(f32, 0), board.at(3, 3).level);

    // The light gone: a quarter second on the lamp still shows, and
    // four seconds on it is asleep again.
    const full = board.lamps[keenest].level;
    for (0..17) |_| board.step(dt, mid);
    const after = board.lamps[keenest].level;
    try std.testing.expect(after < 0.9 * full and after > 0.15 * @min(full, 1.0));
    for (0..280) |_| board.step(dt, mid);
    try std.testing.expect(board.lamps[keenest].level < 0.02);
}

test "in music a color's lamps wake to its own band and to no other, and white lamps to none" {
    var pond = try Pond.init(std.testing.allocator, 60, 40);
    defer pond.deinit();
    var board = try Board.init(std.testing.allocator, 60, 40);
    defer board.deinit();
    var pal = palette_mod.Palette{ .color_count = 16 };
    for (&pal.colors, 0..) |*col, i| col.* = .{ .r = @as(f32, @floatFromInt(i)) / 16.0, .g = 0.5, .b = 0.5 };

    // Bass and nothing else, held.
    var tune = Tune{};
    var bands: [6]f32 = @splat(0);
    bands[1] = 1;
    for (0..600) |_| tune.step(1.0 / 120.0, &bands, false);
    var scene = bare(&pond, &tune);
    scene.palette = &pal;
    scene.turn = 0.5;
    for (0..40) |_| board.step(1.0 / 70.0, scene);

    // Yellow (slot 3) and its bright twin (11) listen to bass.
    var awake: [17]usize = @splat(0);
    var of: [17]usize = @splat(0);
    for (board.lamps) |lamp| {
        of[lamp.slot] += 1;
        if (lamp.level > 0.3) awake[lamp.slot] += 1;
    }
    for (1..7) |slot| {
        const both = awake[slot] + awake[slot + 8];
        const all = of[slot] + of[slot + 8];
        try std.testing.expect(all > 100);
        if (slot == 3) {
            try std.testing.expect(both * 10 > all);
        } else {
            try std.testing.expectEqual(@as(usize, 0), both);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), awake[0]);
    try std.testing.expect(of[0] > 800);

    // In silence the same lamps under the same dark pond all sleep.
    var hush = bare(&pond, &still_tune);
    hush.palette = &pal;
    hush.turn = 0.5;
    for (0..400) |_| board.step(1.0 / 70.0, hush);
    for (board.lamps) |lamp| try std.testing.expect(lamp.level < 0.02);
}

test "a lamp's color never jumps, though every lamp changes its color each turn of the board" {
    var pond = try Pond.init(std.testing.allocator, 50, 30);
    defer pond.deinit();
    var board = try Board.init(std.testing.allocator, 50, 30);
    defer board.deinit();
    var pal = palette_mod.Palette{ .color_count = 16 };
    for (&pal.colors, 0..) |*col, i| col.* = .{ .r = @as(f32, @floatFromInt(i % 4)) / 3.0, .g = @as(f32, @floatFromInt(i / 4)) / 3.0, .b = 0.2 };
    var loud = Tune{};
    const full: [6]f32 = @splat(1);
    for (0..600) |_| loud.step(1.0 / 120.0, &full, false);
    var scene = bare(&pond, &loud);
    scene.palette = &pal;
    const was = try std.testing.allocator.alloc([3]u8, board.lamps.len);
    defer std.testing.allocator.free(was);
    const slots = try std.testing.allocator.alloc(u8, board.lamps.len);
    defer std.testing.allocator.free(slots);
    // Two turns of the board, every band of the music full on, under a
    // light strong enough to wake every lamp that can be woken.
    const dt = 1.0 / 70.0;
    var changed: usize = 0;
    for (0..2 * 70 * @as(usize, @intFromFloat(turn_s))) |n| {
        scene.turn += dt / turn_s;
        if (scene.turn >= 1.0) {
            scene.turn -= 1.0;
            scene.turns += 1;
        }
        @memset(board.extra, 1.1);
        board.step(dt, scene);
        for (board.lamps, slots, was, 0..) |lamp, *slot, *rgb, i| {
            const now = board.shown[i * 4 ..][0..3].*;
            if (n > 0) {
                if (lamp.slot != slot.*) changed += 1;
                for (now, rgb.*) |x, y| try std.testing.expect(@abs(@as(i32, x) - @as(i32, y)) <= 8);
            }
            slot.* = lamp.slot;
            rgb.* = now;
        }
    }
    try std.testing.expect(changed > board.lamps.len / 2);
}

test "the cursor shines while it moves and goes out when it stops, and the focused window's frame is lit outside and not under it" {
    const grid = Grid.init(3840, 2160, 1.0);
    var pond = try Pond.init(std.testing.allocator, grid.cols, grid.rows);
    defer pond.deinit();
    var desk = Desk{};
    for (0..20) |_| desk.update(&pond, grid, frame(.{ 500, 500 }, &.{}));
    try std.testing.expectEqual(@as(f32, 0), desk.torch);
    for (0..40) |i| desk.update(&pond, grid, frame(.{ 500 + 12 * @as(f32, @floatFromInt(i)), 500 }, &.{}));
    try std.testing.expect(desk.torch > 0.9);
    for (0..240) |_| desk.update(&pond, grid, frame(.{ 980, 500 }, &.{}));
    try std.testing.expect(desk.torch < 0.02);

    var board = try Board.init(std.testing.allocator, grid.cols, grid.rows);
    defer board.deinit();
    board.frame(.{ 20.0, 10.0 }, .{ 40.0, 25.0 }, rim, rim_reach);
    // Just outside the frame, on every side.
    try std.testing.expect(board.extra[12 * grid.cols + 19] > 0.6 * rim);
    try std.testing.expect(board.extra[12 * grid.cols + 40] > 0.6 * rim);
    try std.testing.expect(board.extra[9 * grid.cols + 30] > 0.6 * rim);
    try std.testing.expect(board.extra[25 * grid.cols + 30] > 0.6 * rim);
    // Under the window, and well away from it, nothing.
    try std.testing.expectEqual(@as(f32, 0), board.extra[17 * grid.cols + 30]);
    try std.testing.expectEqual(@as(f32, 0), board.extra[12 * grid.cols + 15]);
    for (board.extra) |x| try std.testing.expect(x <= rim);
}

test "a cursor crossing a dark board leaves a tail of lamps that is brightest at its head and fades behind" {
    const grid = Grid.init(3840, 2160, 1.0);
    var pond = try Pond.init(std.testing.allocator, grid.cols, grid.rows);
    defer pond.deinit();
    var board = try Board.init(std.testing.allocator, grid.cols, grid.rows);
    defer board.deinit();
    var desk = Desk{};
    var scene = bare(&pond, &still_tune);
    scene.turn = 0.5;
    // Across the middle of the screen in one second, the lamps worked
    // out every other frame.
    const row: f32 = 1080;
    for (0..120) |n| {
        const x = 600 + 20 * @as(f32, @floatFromInt(n));
        desk.update(&pond, grid, frame(.{ x, row }, &.{}));
        _ = pond.step(1.0 / 120.0);
        if (n % 2 == 1) {
            board.shine(desk.cursor.?, torch * desk.torch, torch_radius);
            board.step(1.0 / 60.0, scene);
        }
    }
    // How awake the lamps within a cell or so of the path are, round
    // three places on it: where the cursor is now, where it was a third
    // of a second ago, and where it set out from.
    const places = [3]f32{ 600 + 20 * 116, 600 + 20 * 80, 600 + 20 * 4 };
    var awake: [3]f32 = @splat(0);
    for (places, &awake) |px, *sum| {
        const at = grid.cell(.{ px, row });
        const cx: usize = @intFromFloat(at[0]);
        const cy: usize = @intFromFloat(at[1]);
        for (cy - 1..cy + 2) |y| {
            for (cx - 2..cx + 3) |x| sum.* += @min(board.at(x, y).level, 1.0) / 15.0;
        }
    }
    try std.testing.expect(awake[0] > 0.3);
    try std.testing.expect(awake[1] > 0.04 and awake[1] < 0.9 * awake[0]);
    try std.testing.expect(awake[2] < 0.5 * awake[1]);
    // Well off the path nothing woke.
    try std.testing.expectEqual(@as(f32, 0), board.at(50, 10).level);
    // Once it has stopped its light goes out, its wake runs off the
    // board, and there is no trace.
    var n: usize = 0;
    var quiet_for: usize = 0;
    while (quiet_for < 360 and n < 120 * 120) : (n += 1) {
        desk.update(&pond, grid, frame(.{ 600 + 20 * 119, row }, &.{}));
        if (!pond.step(1.0 / 120.0)) quiet_for += 1;
        if (n % 2 == 1) {
            board.shine(desk.cursor.?, torch * desk.torch, torch_radius);
            board.step(1.0 / 60.0, scene);
        }
    }
    try std.testing.expect(n < 120 * 60);
    for (board.lamps) |lamp| try std.testing.expect(lamp.level < 0.02);
}

test "a lamp struck awake glints for a moment, and one the light comes up on slowly never does" {
    var pond = try Pond.init(std.testing.allocator, 40, 30);
    defer pond.deinit();
    var board = try Board.init(std.testing.allocator, 40, 30);
    defer board.deinit();
    var scene = bare(&pond, &still_tune);
    scene.turn = 0.5;
    const dt = 1.0 / 45.0;
    board.step(dt, scene);

    // The light comes up over five seconds, as the swell brings it.
    for (0..225) |n| {
        @memset(board.extra, 1.2 * @as(f32, @floatFromInt(n)) / 225.0);
        board.step(dt, scene);
        for (board.lamps) |lamp| try std.testing.expectEqual(@as(f32, 0), lamp.glint);
    }
    var up: usize = 0;
    for (board.lamps) |lamp| {
        if (lamp.level > 0.9) up += 1;
    }
    try std.testing.expect(up > board.lamps.len / 4);

    // Dark again, then the same light all at once.
    for (0..300) |_| board.step(dt, scene);
    @memset(board.extra, 1.2);
    board.step(dt, scene);
    var struck: usize = 0;
    for (board.lamps, 0..) |lamp, i| {
        if (lamp.glint < 1) continue;
        struck += 1;
        // Full on and haloed, whatever it settles to.
        try std.testing.expect(board.shown[i * 4 + 3] > 127 + 60);
    }
    try std.testing.expect(struck > board.lamps.len / 4);
    // Held, the glints are gone inside a second and the lamps stay up.
    for (0..45) |_| {
        @memset(board.extra, 1.2);
        board.step(dt, scene);
    }
    for (board.lamps) |lamp| try std.testing.expect(lamp.glint < 0.01);
}

test "what dies away comes to rest at nothing, not at something too small to see" {
    const smallest = std.math.floatMin(f32);
    var pond = try Pond.init(std.testing.allocator, 60, 40);
    defer pond.deinit();
    var board = try Board.init(std.testing.allocator, 60, 40);
    defer board.deinit();
    var scene = bare(&pond, &still_tune);
    scene.turn = 0.5;
    var tune = Tune{};
    var desk = Desk{};
    const grid = Grid.init(2160, 1440, 1.0);

    // Everything set going at once: a splash, a beat, loud music, a
    // light on every lamp, the cursor on the move.
    pond.drop(.{ 30, 20 }, 1.0);
    const full: [6]f32 = @splat(1);
    tune.step(0.01, &full, true);
    @memset(board.extra, 1.2);
    board.step(1.0 / 45.0, scene);
    desk.update(&pond, grid, frame(.{ 100, 100 }, &.{}));
    desk.update(&pond, grid, frame(.{ 300, 100 }, &.{}));

    // Two minutes of nothing. While the pond still moves, none of it is
    // smaller than the smallest ordinary number.
    const quiet: [6]f32 = @splat(0);
    for (0..120 * 45) |_| {
        tune.step(1.0 / 45.0, &quiet, false);
        desk.update(&pond, grid, frame(.{ 300, 100 }, &.{}));
        _ = pond.step(1.0 / 45.0);
        board.step(1.0 / 45.0, scene);
        for (pond.u, pond.v) |u, v| {
            try std.testing.expect(u == 0 or @abs(u) >= smallest);
            try std.testing.expect(v == 0 or @abs(v) >= smallest);
        }
    }
    try std.testing.expect(!pond.awake);
    try std.testing.expectEqual(@as(f32, 0), tune.surge);
    try std.testing.expectEqual(@as(f32, 0), desk.torch);
    for (tune.quick, tune.slow) |q, s| {
        try std.testing.expectEqual(@as(f32, 0), q);
        try std.testing.expectEqual(@as(f32, 0), s);
    }
    for (board.lamps) |lamp| {
        try std.testing.expectEqual(@as(f32, 0), lamp.level);
        try std.testing.expectEqual(@as(f32, 0), lamp.lit);
        try std.testing.expectEqual(@as(f32, 0), lamp.glint);
    }
}
