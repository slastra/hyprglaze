const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

// A skein of thin lines across the screen. A ribbon is a couple of dozen
// lines strung evenly between two curves, its edges: where the edges
// stand apart the lines fan out into nested lobes, and where they cross
// every line passes through the one point. Two ribbons lie over each
// other, and where they overlap their lines make a fine moire.
//
// An edge is the sum of three things.
//
//   - Its waves: a few long sines of different lengths travelling along
//     it at different slow paces, some one way and some the other, so
//     the crossings slide along the ribbon and the lobes between them
//     swell and sink and it never quite repeats.
//   - Its string: the edge is also a string under tension,
//
//         v' = c^2 u_xx - k v - s u + n v_xx,    u' = v
//
//     (a weak spring back to its place, so that what a pluck leaves
//     behind does not linger, and a smoothing of anything only a few
//     points long)
//     which the cursor plucks. Moving up or down through a ribbon the
//     cursor carries the lines it is among along with it, and what it
//     lets go of runs off both ways along the ribbon as a pulse. Moving
//     along the ribbon, or at rest, it does nothing.
//   - The line they are laid along, straight across the middle of the
//     screen. The skein keeps to it whatever the windows do. (It used to
//     bend to pass behind the focused window. Every focus change,
//     workspace switch and window animation then swung the whole ribbon,
//     which on a busy desktop read as a fault.)
//
// In music it dances. Each wave listens to one band and stands taller
// as that band sounds, sinking back as it fades, so the big lobes swell
// with the bass and the smaller ones with the middle and the top. A wave
// follows its band as a weight on a spring follows a hand, never starting
// or stopping at once, the low bands' heavily and the top bands' lightly:
// the bass heaves and the top flickers. And the top bands run fine, fast
// ripples along the edges, as a string shivers. Nothing moves along the
// ribbon to the beat: the waves keep their own slow pace, a little
// quicker in a loud passage.
//
// The edges are worked out here at a few hundred points across the
// screen and handed to the shader as a texture, with their slopes; the
// shader finds, for each pixel, the lines of each ribbon nearest it
// (shaders/skein.frag). It draws them only where there is room to see
// them: in the narrow gaps between tiled windows a few thin lines
// crossing read as flickering hatch marks, so there they fade to nothing.
// Lengths are px, up from the bottom of the screen.

/// Points across the screen an edge is worked out at. Must match SAMPLES
/// in the shader.
pub const samples = 768;
/// Ribbons. Must match RIBBONS in the shader.
pub const n_ribbons = 2;
/// Waves in an edge.
const n_waves = 3;
/// Points of string past each end of the screen, where pulses die.
const pad = 64;
const cells = samples + 2 * pad;

/// How far the waves stand off the path at size 1, in screen heights.
const reach = 0.21;
/// Screen widths a pulse runs along a string in a second.
const string_speed = 0.42;
/// How fast a pulse dies on the screen, and at the far end of the pad,
/// per second.
const drain_open = 1.1;
const drain_edge = 16.0;
/// How hard a string is drawn back to its place, per second squared.
/// Weak: a pulse runs off long before it tells, and what is left behind
/// sways back over a second or two.
const spring = 2.0;
/// A string is carried on in steps of one fixed length, this many a
/// second, however the frames fall: in each a pulse crosses two thirds of
/// a point's spacing. The steps must not vary. Cut each frame into its own
/// number of steps and frames of uneven length pump a wave a few points
/// long until it fills the screen, which is what a desktop of tiled
/// windows did.
const string_hz = 480.0;
/// Most steps one frame may take; a longer stall drops its backlog.
const most_steps = 24;
/// How fast a wave only a few points long is smoothed away, in points
/// squared a second. A pulse from a pluck is some forty points long and
/// hardly feels it; anything near the grid's own scale is gone in a few
/// hundredths of a second.
const smoothing = 12.0;
/// Steps of a string between looks at whether it is still, and what
/// counts as still, px. Anything that dies away is put to rest below
/// `rest`: left to itself it would shrink for ever into numbers many
/// times slower to reckon with.
const look_every = 24;
const still = 0.05;
const rest = 1e-4;

/// How much of the cursor's way up or down a string under it goes with
/// it, how wide the pluck is in screen widths, how far outside a ribbon
/// the cursor still catches it and the most a string may be pulled, in
/// screen heights.
const drag = 0.55;
const pluck_width = 0.022;
const catch_margin = 0.025;
const most_pull = 0.13;

/// How quickly a wave follows each band, low to high: the pull of the
/// spring it follows on, per second, as the band rises and as it falls.
/// It gets most of the way to a new level in about three divided by this
/// many seconds. Every band lets go slowly: a wave that dropped as fast
/// as the top bands flicker would thrash.
const band_pull = [6]f32{ 9.0, 10.0, 14.0, 16.0, 20.0, 22.0 };
const band_ease = [6]f32{ 3.5, 3.5, 4.0, 4.0, 4.5, 4.5 };
/// How much taller an edge's three waves stand with their bands full
/// on: the long one least, being the tallest to begin with.
const wave_lift = [n_waves]f32{ 0.6, 0.85, 0.9 };
/// How much faster they all travel in a loud passage.
const loud_haste = 0.5;
/// The ripples the top bands run along the edges: how high with the
/// band full on, in screen heights.
const ripple_height = 0.017;

const tau = 2.0 * std.math.pi;

/// One wave of an edge.
const Wave = struct {
    /// Its length in screen widths, the seconds it takes to pass a point
    /// (negative: it travels to the left), its height as a part of the
    /// edge's reach, and the band of the music it listens to.
    length: f32,
    period: f32,
    amp: f32,
    band: u8,
    phase: f32 = 0,
};

/// A fine ripple along an edge, as high as its band is loud.
const Ripple = struct {
    /// Its length in screen widths, the seconds it takes to pass a point
    /// (negative: it travels to the left), and its band.
    length: f32,
    period: f32,
    band: u8,
    phase: f32 = 0,
};

/// Each edge's ripple.
const shivers = [n_ribbons][2]Ripple{
    .{ .{ .length = 0.083, .period = 1.1, .band = 4 }, .{ .length = 0.061, .period = -0.8, .band = 5 } },
    .{ .{ .length = 0.071, .period = -0.95, .band = 5 }, .{ .length = 0.104, .period = 1.3, .band = 3 } },
};

/// The waves of each ribbon's two edges. The heights of an edge's waves
/// add up to one.
const cast = [n_ribbons][2][n_waves]Wave{
    .{
        .{
            .{ .length = 0.62, .period = 31, .amp = 0.50, .band = 0 },
            .{ .length = 1.35, .period = -43, .amp = 0.30, .band = 2 },
            .{ .length = 0.29, .period = 17, .amp = 0.20, .band = 4 },
        },
        .{
            .{ .length = 0.47, .period = -27, .amp = 0.50, .band = 1 },
            .{ .length = 0.95, .period = 37, .amp = 0.30, .band = 3 },
            .{ .length = 0.24, .period = -13, .amp = 0.20, .band = 5 },
        },
    },
    .{
        .{
            .{ .length = 0.54, .period = -29, .amp = 0.50, .band = 1 },
            .{ .length = 1.10, .period = 39, .amp = 0.28, .band = 3 },
            .{ .length = 0.26, .period = -15, .amp = 0.22, .band = 5 },
        },
        .{
            .{ .length = 0.71, .period = 33, .amp = 0.50, .band = 0 },
            .{ .length = 0.37, .period = -21, .amp = 0.30, .band = 2 },
            .{ .length = 0.21, .period = 12, .amp = 0.20, .band = 4 },
        },
    },
};

/// A string under tension, damped, with its ends run on past the screen
/// into a stretch where everything dies.
pub const String = struct {
    u: [cells]f32 = @splat(0),
    v: [cells]f32 = @splat(0),
    /// Time not yet carried on.
    owed: f32 = 0,
    ticks: u32 = 0,
    /// Whether anything is moving on it.
    awake: bool = false,

    /// How fast each point drains.
    const drain: [cells]f32 = blk: {
        @setEvalBranchQuota(10000);
        var d: [cells]f32 = undefined;
        for (&d, 0..) |*x, i| {
            const near = @min(i, cells - 1 - i);
            const out = 1.0 - @min(1.0, @as(f32, @floatFromInt(near)) / @as(f32, pad));
            x.* = drain_open + (drain_edge - drain_open) * out * out;
        }
        break :blk d;
    };

    /// How far it stands off its place at point `i` of the screen.
    pub fn at(self: *const String, i: usize) f32 {
        return self.u[i + pad];
    }

    /// Pull it by `amount` at point `where` of the screen (which need
    /// not be a whole one), and less to either side over `width` points.
    pub fn pluck(self: *String, where: f32, amount: f32, width: f32) void {
        if (amount == 0) return;
        const center = where + pad;
        const lo: usize = @intFromFloat(std.math.clamp(@floor(center - 3.0 * width), 1.0, cells - 2.0));
        const hi: usize = @intFromFloat(std.math.clamp(@ceil(center + 3.0 * width), 1.0, cells - 2.0));
        for (lo..hi + 1) |i| {
            const d = (@as(f32, @floatFromInt(i)) - center) / width;
            self.u[i] += amount * @exp(-0.5 * d * d);
        }
        self.awake = true;
    }

    /// Carry it `dt` on. False when it is still, and was not touched.
    pub fn step(self: *String, dt_in: f32) bool {
        if (!self.awake) {
            self.owed = 0;
            return false;
        }
        // Points a pulse crosses in a second, and in a step.
        const speed = string_speed * @as(f32, samples - 1);
        const h = 1.0 / string_hz;
        comptime std.debug.assert(string_speed * @as(f32, samples - 1) / string_hz < 0.75);
        comptime std.debug.assert(4.0 * smoothing / string_hz < 0.5);
        const c2 = speed * speed;
        self.owed += std.math.clamp(dt_in, 0.0, 0.05);
        var looked = false;
        var most: f32 = 0;
        var steps: usize = 0;
        while (self.owed >= h and steps < most_steps) : (steps += 1) {
            self.owed -= h;
            // What pulls on each point: the string's tension, the drag,
            // the weak spring back to its place, and the smoothing of
            // anything sharp, which works on how fast the points move.
            var pull: [cells]f32 = undefined;
            pull[0] = 0;
            pull[cells - 1] = 0;
            for (pull[1 .. cells - 1], self.u[1 .. cells - 1], self.u[0 .. cells - 2], self.u[2..cells], self.v[1 .. cells - 1], self.v[0 .. cells - 2], self.v[2..cells], drain[1 .. cells - 1]) |*a, m, l, r, v, vl, vr, d| {
                a.* = c2 * (l + r - 2.0 * m) - d * v - spring * m + smoothing * (vl + vr - 2.0 * v);
            }
            for (&self.v, pull) |*v, a| v.* += a * h;
            for (&self.u, self.v) |*u, v| u.* += v * h;
            self.ticks +%= 1;
            if (self.ticks % look_every != 0) continue;
            looked = true;
            most = 0;
            for (&self.u, &self.v) |*u, *v| {
                if (@abs(u.*) < rest) u.* = 0;
                if (@abs(v.*) < rest) v.* = 0;
                most = @max(most, @max(@abs(u.*), @abs(v.*) / speed));
            }
        }
        // A stall drops its backlog.
        if (self.owed >= h) self.owed = 0;
        if (looked and most < still) {
            self.u = @splat(0);
            self.v = @splat(0);
            self.awake = false;
        }
        return true;
    }
};

/// The edges of every ribbon as the shader takes them: at each point
/// the first edge's height, the second's, and the slope of each.
pub const Edges = [n_ribbons][samples][4]f32;

pub const Skein = struct {
    width: f32,
    height: f32,
    /// How far the waves stand off the middle of the screen.
    reach: f32,
    waves: [n_ribbons][2][n_waves]Wave = cast,
    ripples: [n_ribbons][2]Ripple = shivers,
    strings: [n_ribbons][2]String = @splat(@splat(.{})),
    edges: Edges = undefined,
    /// Where the cursor was, px.
    cursor: ?[2]f32 = null,

    pub fn init(width: f32, height: f32, size: f32, seed: u64) Skein {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        var self = Skein{
            .width = width,
            .height = height,
            .reach = reach * size * height,
        };
        for (&self.waves) |*ribbon| {
            for (ribbon) |*edge| {
                for (edge) |*wave| wave.phase = r.float(f32) * tau;
            }
        }
        self.compose(@splat(0));
        return self;
    }

    /// The px across the screen point `i` is at.
    pub fn x(self: *const Skein, i: usize) f32 {
        return self.width * @as(f32, @floatFromInt(i)) / @as(f32, samples - 1);
    }

    /// The point of the screen px `at` is nearest.
    fn point(self: *const Skein, at: f32) f32 {
        return std.math.clamp(at / self.width, 0.0, 1.0) * @as(f32, samples - 1);
    }

    /// Carry everything `dt` on. `heard` is how loud each band of the
    /// music is (0 to 1), `haste` how many times their own pace the
    /// waves travel at (less than nothing: backward).
    pub fn step(self: *Skein, dt_in: f32, cursor: [2]f32, heard: [6]f32, haste: f32) void {
        const dt = std.math.clamp(dt_in, 0.0, 0.05);
        for (&self.waves) |*ribbon| {
            for (ribbon) |*edge| {
                for (edge) |*wave| wave.phase = @mod(wave.phase + tau * dt * haste / wave.period, tau);
            }
        }
        for (&self.ripples) |*ribbon| {
            for (ribbon) |*ripple| ripple.phase = @mod(ripple.phase + tau * dt / ripple.period, tau);
        }
        self.strum(cursor);
        for (&self.strings) |*ribbon| {
            for (ribbon) |*string| _ = string.step(dt);
        }
        self.compose(heard);
    }

    /// The cursor, moving up or down through a ribbon, carries the
    /// strings it is among along with it.
    fn strum(self: *Skein, cursor: [2]f32) void {
        const last = self.cursor orelse {
            self.cursor = cursor;
            return;
        };
        self.cursor = cursor;
        // A jump across the screen is not a stroke.
        const most = most_pull * self.height;
        if (@abs(cursor[0] - last[0]) > 0.2 * self.width) return;
        const rise = std.math.clamp(cursor[1] - last[1], -most, most);
        if (@abs(rise) < 0.05 or cursor[0] < 0 or cursor[0] > self.width) return;
        const at = self.point(cursor[0]);
        const i: usize = @intFromFloat(@round(at));
        const margin = catch_margin * self.height;
        const width = pluck_width * @as(f32, samples - 1);
        for (&self.strings, self.edges) |*strings, edges| {
            const a = edges[i][0];
            const b = edges[i][1];
            const lo = @min(a, b) - margin;
            const hi = @max(a, b) + margin;
            // It must have been in the ribbon somewhere on its way.
            if (@max(cursor[1], last[1]) < lo or @min(cursor[1], last[1]) > hi) continue;
            // Where between the two edges it is: the nearer edge goes
            // with it more.
            const span = b - a;
            const t = if (@abs(span) < 1.0) 0.5 else std.math.clamp((cursor[1] - a) / span, 0.0, 1.0);
            for (strings, [2]f32{ 1.25 - t, 0.25 + t }) |*string, share| {
                // The farther it is pulled already, the less it gives.
                const pulled = string.at(i);
                const give = 1.0 - @min(1.0, @abs(pulled) / most);
                const against = if (pulled * rise > 0) give else 1.0;
                string.pluck(at, drag * rise * @min(1.0, share) * against, width);
            }
        }
    }

    /// `height` times sin(k x - phase) added to `to` along the points,
    /// each from the last by one turn of a fixed angle.
    fn addSine(to: *[samples]f32, length: f32, phase: f32, height: f32) void {
        // A thousandth of a pixel is nothing.
        if (@abs(height) < 1e-3) return;
        const turn = tau / (length * @as(f32, samples - 1));
        const cs = @cos(turn);
        const sn = @sin(turn);
        var s = @sin(-phase);
        var co = @cos(-phase);
        for (to) |*out| {
            out.* += height * s;
            const next = s * cs + co * sn;
            co = co * cs - s * sn;
            s = next;
        }
    }

    /// Work out every edge at every point, and its slope.
    fn compose(self: *Skein, heard: [6]f32) void {
        const dx = self.width / @as(f32, samples - 1);
        for (&self.edges, self.waves, self.ripples, &self.strings) |*edges, ribbon, ripples, *strings| {
            for (ribbon, ripples, strings, 0..) |edge, ripple, *string, which| {
                // The waves as they are in silence, as parts of the
                // edge's reach, and what the music adds to them with the
                // ripple, in px.
                var shape: [samples]f32 = @splat(0);
                var more: [samples]f32 = @splat(0);
                for (edge, wave_lift) |wave, lift| {
                    addSine(&shape, wave.length, wave.phase, wave.amp);
                    addSine(&more, wave.length, wave.phase, self.reach * wave.amp * lift * heard[wave.band]);
                }
                addSine(&more, ripple.length, ripple.phase, ripple_height * self.height * heard[ripple.band]);
                for (edges, shape, more, 0..) |*out, sh, m, i| {
                    out[which] = 0.5 * self.height + self.reach * sh + m + string.at(i);
                }
            }
            // The slopes, from the points to either side.
            for (0..samples) |i| {
                const before = if (i == 0) 0 else i - 1;
                const after = if (i == samples - 1) i else i + 1;
                const span = dx * @as(f32, @floatFromInt(after - before));
                edges[i][2] = (edges[after][0] - edges[before][0]) / span;
                edges[i][3] = (edges[after][1] - edges[before][1]) / span;
            }
        }
    }
};

/// What the music does.
pub const Tune = struct {
    /// Each band's level as the waves follow it, and how fast that is
    /// changing.
    heard: [6]f32 = @splat(0),
    moving: [6]f32 = @splat(0),
    /// How loud it is over all, followed slowly.
    loud: f32 = 0,

    pub fn step(self: *Tune, dt_in: f32, bands: *const [6]f32) void {
        // In steps short enough for the stiffest spring.
        const n: usize = @intFromFloat(@max(1.0, @ceil(dt_in / 0.006)));
        const dt = dt_in / @as(f32, @floatFromInt(n));
        var sum: f32 = 0;
        for (bands) |b| sum += std.math.clamp(b, 0.0, 1.0) / 6.0;
        for (0..n) |_| {
            for (&self.heard, &self.moving, bands, band_pull, band_ease) |*h, *v, b, up, down| {
                // A weight on a spring with just enough drag never to
                // swing: it sets off slowly, and arrives slowly. The
                // spring is slacker going down.
                const now = std.math.clamp(b, 0.0, 1.0);
                const pull = if (now > h.*) up else down;
                v.* += (pull * pull * (now - h.*) - 2.0 * pull * v.*) * dt;
                h.* += v.* * dt;
                // Carried past either end by its own way, it stops
                // there.
                if (h.* < 0 or h.* > 1) {
                    h.* = std.math.clamp(h.*, 0.0, 1.0);
                    v.* = 0;
                }
            }
        }
        for (&self.heard, &self.moving, bands) |*h, *v, b| {
            // Anything that is not a number (a capture that hiccups)
            // would never leave: put it down. So is anything that has
            // all but died away, whether or not the band itself has
            // quite reached nothing: followed down it becomes a number
            // many times slower to reckon with, and the waves are
            // worked out from it at every point of every edge.
            if (!std.math.isFinite(h.*) or !std.math.isFinite(v.*) or (b < rest and @abs(h.*) < rest and @abs(v.*) < rest)) {
                h.* = 0;
                v.* = 0;
            }
        }
        self.loud += (@min(1.0, 1.6 * sum) - self.loud) * @min(1.0, 0.8 * dt_in);
        if (!std.math.isFinite(self.loud) or (sum == 0 and self.loud < rest)) self.loud = 0;
    }

    /// How many times their own pace the waves travel at: a little
    /// faster when it is loud.
    pub fn haste(self: *const Tune) f32 {
        return 1.0 + loud_haste * self.loud;
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    skein: Skein,
    tune: Tune = .{},
    speed: f32,
    /// Lines in each ribbon, and their width in px.
    lines: [n_ribbons]f32,
    line_width: f32,
    /// Palette slots of the colors at the left and the right, and how
    /// far both are paled toward the foreground.
    from: f32,
    to: f32,
    pale: f32,
    tex: c.GLuint = 0,

    u: Uniforms(.{
        .edges = "iSkeinEdges",
        .look = "iSkeinLook",
        .ink = "iSkeinInk",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const w = @max(width, 64.0);
        const h = @max(height, 64.0);
        var music = try spectral.Analyzer.init(allocator, params);
        errdefer music.deinit(allocator);
        const lines = std.math.clamp(params.getFloat("lines", 1.0), 0.3, 2.5);
        return .{
            .allocator = allocator,
            .music = music,
            .skein = Skein.init(w, h, std.math.clamp(params.getFloat("size", 1.0), 0.4, 1.8), 0x5ce1),
            .speed = std.math.clamp(params.getFloat("speed", 1.0), 0.0, 6.0),
            .lines = .{ @max(2.0, @round(28.0 * lines)), @max(2.0, @round(20.0 * lines)) },
            // An eighth of a percent of the screen's height: under three
            // px on a 4K screen, and never under a pixel and a half.
            .line_width = @max(1.5, 0.0013 * h * std.math.clamp(params.getFloat("width", 1.0), 0.3, 4.0)),
            .from = @floatFromInt(std.math.clamp(params.getInt("from", 5), -1, 15)),
            .to = @floatFromInt(std.math.clamp(params.getInt("to", 4), -1, 15)),
            .pale = std.math.clamp(params.getFloat("pale", 0.25), 0.0, 1.0),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        _ = self.music.update(dt);
        self.tune.step(dt, &self.music.bands.bands);

        self.skein.step(dt, state.cursor, self.tune.heard, self.speed * self.tune.haste());
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glActiveTexture(c.GL_TEXTURE0);
        if (self.tex == 0) {
            c.glGenTextures(1, &self.tex);
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
            // Whole floats, which cannot be told to blend between
            // texels everywhere: the shader does that itself.
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA32F, samples, n_ribbons, 0, c.GL_RGBA, c.GL_FLOAT, null);
        }
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, samples, n_ribbons, c.GL_RGBA, c.GL_FLOAT, &self.skein.edges);

        self.u.use(prog.program);
        self.u.int(.edges, 0);
        self.u.f3(.look, self.lines[0], self.lines[1], self.line_width);
        self.u.f3(.ink, self.from, self.to, self.pale);
    }

    pub fn deinit(self: *Context) void {
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
        self.music.deinit(self.allocator);
    }
};

const flat: [6]f32 = @splat(0);
const nowhere = [2]f32{ -1e6, -1e6 };

test "the edges stay within their reach of the path, cross each other, and their slopes are those of the edges" {
    var skein = Skein.init(3840, 2160, 1.0, 3);
    const most = reach * 2160.0 + 1.0;
    var crossings: usize = 0;
    var widest_gap: f32 = 0;
    for (0..40) |_| {
        for (0..300) |_| skein.step(0.02, nowhere, flat, 1.0);
        for (skein.edges) |edges| {
            for (edges, 0..) |e, i| {
                try std.testing.expect(@abs(e[0] - 1080.0) <= most and @abs(e[1] - 1080.0) <= most);
                widest_gap = @max(widest_gap, @abs(e[1] - e[0]));
                if (i == 0) continue;
                const was = edges[i - 1];
                if ((was[1] - was[0]) * (e[1] - e[0]) < 0) crossings += 1;
                // The slope carries one point on to the next, near
                // enough.
                if (i < samples - 1) {
                    const dx = skein.x(i + 1) - skein.x(i);
                    try std.testing.expectApproxEqAbs(edges[i + 1][0], e[0] + e[2] * dx, 0.5);
                    try std.testing.expectApproxEqAbs(edges[i + 1][1], e[1] + e[3] * dx, 0.5);
                }
            }
        }
    }
    // A few crossings a ribbon at any moment, and lobes worth the name.
    try std.testing.expect(crossings >= 40 * n_ribbons * 2 and crossings <= 40 * n_ribbons * 13);
    try std.testing.expect(widest_gap > 0.25 * 2160.0);
}

test "a pluck runs off both ways at the string's speed, dies past the ends, and leaves the string at rest" {
    var string = String{};
    try std.testing.expect(!string.step(1.0 / 120.0));
    const middle = 0.5 * @as(f32, samples - 1);
    string.pluck(middle, 100.0, 12.0);
    try std.testing.expectApproxEqAbs(@as(f32, 100), string.at(samples / 2), 1.0);
    // Half a second on: two pulses of half the height, each as far from
    // the middle as the speed says.
    for (0..60) |_| try std.testing.expect(string.step(1.0 / 120.0));
    var peak: [2]usize = .{ 0, samples - 1 };
    for (0..samples / 2) |i| {
        if (string.at(i) > string.at(peak[0])) peak[0] = i;
    }
    for (samples / 2..samples) |i| {
        if (string.at(i) > string.at(peak[1])) peak[1] = i;
    }
    const run = 0.5 * string_speed * @as(f32, samples - 1);
    try std.testing.expectApproxEqAbs(middle - run, @as(f32, @floatFromInt(peak[0])), 6.0);
    try std.testing.expectApproxEqAbs(middle + run, @as(f32, @floatFromInt(peak[1])), 6.0);
    try std.testing.expect(string.at(peak[0]) > 20.0 and string.at(peak[0]) < 50.0);
    try std.testing.expect(@abs(string.at(samples / 2)) < 6.0);
    // They leave the screen, what is left sways back, and nothing comes
    // in again: a few seconds after the pluck the screen is all but
    // flat, and then the string is put to rest.
    var steps: usize = 0;
    while (string.step(1.0 / 120.0)) : (steps += 1) {
        if (steps >= 480) {
            for (0..samples) |i| try std.testing.expect(@abs(string.at(i)) < 3.0);
        }
    }
    try std.testing.expect(steps < 120 * 20);
    for (string.u, string.v) |u, v| {
        try std.testing.expectEqual(@as(f32, 0), u);
        try std.testing.expectEqual(@as(f32, 0), v);
    }
}

test "a string stays bounded at any frame rate, and nothing on it is ever too small to be worth reckoning" {
    var string = String{};
    var prng = std.Random.DefaultPrng.init(4);
    const r = prng.random();
    const smallest = std.math.floatMin(f32);
    for (0..6000) |i| {
        if (i < 3000 and i % 9 == 0) string.pluck(r.float(f32) * samples, 60.0 * (r.float(f32) - 0.5), 14.0);
        _ = string.step(0.002 + 0.04 * r.float(f32));
        for (string.u, string.v) |u, v| {
            try std.testing.expect(@abs(u) < 600.0);
            if (i % 50 == 0) try std.testing.expect((u == 0 or @abs(u) >= smallest) and (v == 0 or @abs(v) >= smallest));
        }
    }
    try std.testing.expect(!string.awake);
}

test "the cursor plucks a ribbon by moving up or down through it, and not by moving along it or past it" {
    var skein = Skein.init(3840, 2160, 1.0, 3);
    const awake = struct {
        fn any(s: *const Skein) bool {
            for (s.strings) |ribbon| {
                for (ribbon) |string| {
                    if (string.awake) return true;
                }
            }
            return false;
        }
    }.any;
    // Along the middle of the screen, through every ribbon: nothing.
    for (0..60) |i| skein.step(1.0 / 120.0, .{ 600 + 30 * @as(f32, @floatFromInt(i)), 1080 }, flat, 0.0);
    try std.testing.expect(!awake(&skein));
    // Up and down well above them all: nothing.
    for (0..60) |i| skein.step(1.0 / 120.0, .{ 1000, 2000 + 2 * @as(f32, @floatFromInt(i)) }, flat, 0.0);
    try std.testing.expect(!awake(&skein));
    // A jump from there into the middle of one: nothing.
    skein.step(1.0 / 120.0, .{ 3000, 1080 }, flat, 0.0);
    try std.testing.expect(!awake(&skein));

    // Up through the first ribbon where it stands widest.
    var at: usize = 0;
    for (skein.edges[0], 0..) |e, i| {
        if (@abs(e[1] - e[0]) > @abs(skein.edges[0][at][1] - skein.edges[0][at][0])) at = i;
    }
    const px = skein.x(at);
    const lo = @min(skein.edges[0][at][0], skein.edges[0][at][1]);
    skein.cursor = null;
    skein.step(1.0 / 120.0, .{ px, lo - 300 }, flat, 0.0);
    try std.testing.expect(!awake(&skein));
    const before = skein.edges[0][at];
    for (0..30) |i| skein.step(1.0 / 120.0, .{ px, lo - 60 + 6 * @as(f32, @floatFromInt(i)) }, flat, 0.0);
    try std.testing.expect(awake(&skein));
    // The lower edge, which it went through, has gone up with it, by a
    // good part of the way and no more than it may be pulled.
    const pulled = @max(skein.edges[0][at][0] - before[0], skein.edges[0][at][1] - before[1]);
    try std.testing.expect(pulled > 15.0 and pulled <= most_pull * 2160.0 + 1.0);
    // Let go, it all runs off and the edges are back where they were.
    for (0..120 * 30) |_| {
        skein.step(1.0 / 120.0, .{ px, lo + 120 }, flat, 0.0);
        if (!awake(&skein)) break;
    }
    try std.testing.expect(!awake(&skein));
    try std.testing.expectApproxEqAbs(before[0], skein.edges[0][at][0], 0.01);
    try std.testing.expectApproxEqAbs(before[1], skein.edges[0][at][1], 0.01);
}

test "a wave follows its band without a start or a stop, the low bands slowly and the top ones fast, and a ripple is as high as its band is loud" {
    var tune = Tune{};
    var bands: [6]f32 = @splat(0);
    bands[0] = 1;
    bands[5] = 1;
    // Both bands full on at once. Neither wave has gone anywhere in the
    // first frame; a tenth of a second on the top one is most of the way
    // and the bass a quarter of it; half a second on both are there.
    tune.step(1.0 / 120.0, &bands);
    try std.testing.expect(tune.heard[0] < 0.01 and tune.heard[5] < 0.08);
    var last = tune.heard;
    var fastest = [2]f32{ 0, 0 };
    for (1..60) |n| {
        tune.step(1.0 / 120.0, &bands);
        for ([2]usize{ 0, 5 }, &fastest) |b, *f| {
            // Always upward, and never past.
            try std.testing.expect(tune.heard[b] >= last[b] and tune.heard[b] <= 1.0);
            f.* = @max(f.*, tune.heard[b] - last[b]);
        }
        last = tune.heard;
        if (n == 11) {
            try std.testing.expect(tune.heard[0] > 0.15 and tune.heard[0] < 0.4);
            try std.testing.expect(tune.heard[5] > 0.55);
        }
    }
    try std.testing.expect(tune.heard[0] > 0.9 and tune.heard[5] > 0.99);
    // The bass never moved by more than a twentieth of its way in a
    // frame.
    try std.testing.expect(fastest[0] < 0.05);
    try std.testing.expectEqual(@as(f32, 0), tune.heard[3]);

    // Silence: down as smoothly and more slowly, the top band as slowly
    // as the bass, and to nothing.
    bands = @splat(0);
    tune.step(1.0 / 120.0, &bands);
    try std.testing.expect(last[0] - tune.heard[0] < 0.01);
    for (0..23) |_| tune.step(1.0 / 120.0, &bands);
    try std.testing.expect(tune.heard[5] > 0.6 and tune.heard[0] > 0.6);
    for (0..1800) |_| tune.step(1.0 / 120.0, &bands);
    for (tune.heard, tune.moving) |h, v| {
        try std.testing.expectEqual(@as(f32, 0), h);
        try std.testing.expectEqual(@as(f32, 0), v);
    }
    try std.testing.expectEqual(@as(f32, 0), tune.loud);

    // At any frame rate, and with the bands thrown about, it stays
    // between nothing and all.
    var prng = std.Random.DefaultPrng.init(8);
    const r = prng.random();
    for (0..4000) |_| {
        for (&bands) |*b| b.* = if (r.float(f32) < 0.3) r.float(f32) else b.*;
        tune.step(0.002 + 0.048 * r.float(f32), &bands);
        for (tune.heard) |h| try std.testing.expect(h >= 0 and h <= 1);
    }

    // The same skein in silence and with one band full on: the edges
    // that listen to it stand farther off the path, by no more than
    // their waves may be lifted.
    var hush = Skein.init(3840, 2160, 1.0, 3);
    var sung = Skein.init(3840, 2160, 1.0, 3);
    var heard: [6]f32 = @splat(0);
    heard[0] = 1;
    hush.step(0.01, nowhere, flat, 0.0);
    sung.step(0.01, nowhere, heard, 0.0);
    var most = [2]f32{ 0, 0 };
    for (hush.edges[0], sung.edges[0]) |h, s| {
        most[0] = @max(most[0], @abs(h[0] - 1080.0));
        most[1] = @max(most[1], @abs(s[0] - 1080.0));
        try std.testing.expect(@abs(s[0] - 1080.0) <= (1.0 + wave_lift[n_waves - 1]) * hush.reach + 1.0);
    }
    try std.testing.expect(most[1] > 1.15 * most[0]);

    // A top band and nothing else, on a skein with its waves laid
    // flat: the edge with a ripple for that band stands off the path
    // by the ripple's height and no more, and the others not at all.
    heard = @splat(0);
    heard[5] = 1;
    var bare = Skein.init(3840, 2160, 1.0, 3);
    for (&bare.waves) |*ribbon| {
        for (ribbon) |*edge| {
            for (edge) |*wave| wave.amp = 0;
        }
    }
    bare.step(0.01, nowhere, heard, 0.0);
    for (bare.edges, shivers) |edges, ripples| {
        for (ripples, 0..) |ripple, which| {
            var high: f32 = 0;
            for (edges) |e| high = @max(high, @abs(e[which] - 1080.0));
            const want: f32 = if (ripple.band == 5) ripple_height * 2160.0 else 0.0;
            try std.testing.expectApproxEqAbs(want, high, 0.02 * ripple_height * 2160.0);
        }
    }
}

test "with every band of the music full on, no line stands farther off the middle than under half the screen" {
    var skein = Skein.init(3840, 2160, 1.0, 3);
    const full: [6]f32 = @splat(1);
    var widest_lobe: f32 = 0;
    for (0..2000) |_| {
        skein.step(1.0 / 120.0, nowhere, full, 3.0);
        for (skein.edges) |edges| {
            for (edges) |e| widest_lobe = @max(widest_lobe, @max(@abs(e[0] - 1080.0), @abs(e[1] - 1080.0)));
        }
    }
    try std.testing.expect(widest_lobe > 0.25 * 2160.0 and widest_lobe < 0.42 * 2160.0);
}

test "the skein keeps to the middle of the screen whatever the windows do" {
    // It is given no windows to go by: nothing in its step takes one.
    const takes = @typeInfo(@TypeOf(Skein.step)).@"fn".param_types;
    try std.testing.expectEqual(@as(usize, 5), takes.len);
    var skein = Skein.init(3840, 2160, 1.0, 3);
    var sum: f64 = 0;
    var n: f64 = 0;
    for (0..40) |_| {
        for (0..300) |_| skein.step(0.02, nowhere, flat, 1.0);
        for (skein.edges) |edges| {
            for (edges) |e| {
                sum += e[0] + e[1];
                n += 2;
            }
        }
    }
    // Over time the edges lie as much above the middle as below it.
    try std.testing.expectApproxEqAbs(@as(f64, 1080), sum / n, 25.0);
}

test "two minutes of a wild cursor, loud music and uneven frames leave the skein on the screen" {
    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    var skein = Skein.init(3840, 2160, 1.0, 3);
    var tune = Tune{};
    var bands: [6]f32 = @splat(0);
    var cursor = [2]f32{ 1900, 1000 };
    var vel = [2]f32{ 0, 0 };
    for (0..120 * 120) |_| {
        // Mostly steady frames, now and then a long stall.
        const dt: f32 = if (r.float(f32) < 0.02) 0.3 * r.float(f32) else 1.0 / 120.0 + 0.004 * r.float(f32);
        for (&bands) |*b| {
            if (r.float(f32) < 0.2) b.* = r.float(f32);
        }
        tune.step(@min(dt, 0.05), &bands);
        // The cursor wanders fast and wraps round the screen, which is
        // a jump.
        for (0..2) |k| {
            vel[k] += (r.float(f32) - 0.5) * 900.0;
            vel[k] *= 0.9;
            cursor[k] += vel[k] * dt * 8.0;
        }
        cursor[0] = @mod(cursor[0], 3840.0);
        cursor[1] = @mod(cursor[1], 2160.0);
        skein.step(dt, cursor, tune.heard, tune.haste());
        // No edge farther from the middle of the screen than two thirds
        // of its height, and no string pulled farther than it may be.
        for (skein.edges) |edges| {
            for (edges) |e| {
                try std.testing.expect(@abs(e[0] - 1080.0) < 0.67 * 2160.0 and @abs(e[1] - 1080.0) < 0.67 * 2160.0);
                try std.testing.expect(@abs(e[2]) < 50.0 and @abs(e[3]) < 50.0);
            }
        }
        for (skein.strings) |ribbon| {
            for (ribbon) |string| {
                for (string.u) |u| try std.testing.expect(@abs(u) < 1.2 * most_pull * 2160.0);
            }
        }
    }
}

test "a band that is not a number for a moment does not stay with the skein" {
    var tune = Tune{};
    var bands: [6]f32 = @splat(0.5);
    for (0..60) |_| tune.step(1.0 / 120.0, &bands);
    bands[2] = std.math.nan(f32);
    bands[4] = std.math.inf(f32);
    tune.step(1.0 / 120.0, &bands);
    bands = @splat(0.5);
    for (0..240) |_| tune.step(1.0 / 120.0, &bands);
    for (tune.heard) |h| try std.testing.expect(h > 0.4 and h < 0.6);
    try std.testing.expect(std.math.isFinite(tune.loud));
}

test "a band that never quite reaches silence still leaves the skein at rest" {
    var tune = Tune{};
    var bands: [6]f32 = @splat(0.8);
    for (0..240) |_| tune.step(1.0 / 120.0, &bands);
    // Silence as an analyser gives it: ever smaller, never nothing.
    for (0..120 * 60) |n| {
        for (&bands) |*b| b.* *= 0.96;
        tune.step(1.0 / 120.0, &bands);
        if (n > 120 * 20) {
            for (tune.heard, tune.moving) |h, v| {
                try std.testing.expectEqual(@as(f32, 0), h);
                try std.testing.expectEqual(@as(f32, 0), v);
            }
        }
    }
}

test "frames of uneven length never pump a string: plucked, it dies away however the time is cut up" {
    const cases = [_]struct { a: f32, b: f32, random: bool }{
        .{ .a = 0.00833, .b = 0.00833, .random = false },
        .{ .a = 0.0040, .b = 0.0127, .random = false },
        .{ .a = 0.0070, .b = 0.0097, .random = false },
        .{ .a = 0.0060, .b = 0.0107, .random = false },
        .{ .a = 0.0020, .b = 0.0147, .random = false },
        .{ .a = 0.0005, .b = 0.0330, .random = false },
        .{ .a = 0.0065, .b = 0.0085, .random = true },
        .{ .a = 0.0020, .b = 0.0150, .random = true },
        .{ .a = 0.0001, .b = 0.1000, .random = true },
    };
    for (cases) |case| {
        var prng = std.Random.DefaultPrng.init(5);
        const r = prng.random();
        var string = String{};
        string.pluck(380, 60.0, 16.9);
        var t: f32 = 0;
        var n: usize = 0;
        var kink: f32 = 0;
        var high: f32 = 0;
        while (t < 30.0) : (n += 1) {
            const dt = if (case.random) case.a + (case.b - case.a) * r.float(f32) else if (n % 2 == 0) case.a else case.b;
            t += dt;
            // Kept awake with a whisper, as a hand resting on the mouse
            // keeps it.
            if (n % 40 == 0) string.pluck(100 + 500 * r.float(f32), 0.5 * (r.float(f32) - 0.5), 16.9);
            _ = string.step(dt);
            // Never rough, even while the pluck is still on it: no point
            // out of line with its neighbors by a pixel.
            for (1..cells - 1) |i| {
                kink = @max(kink, @abs(string.u[i - 1] - 2.0 * string.u[i] + string.u[i + 1]));
                if (t > 12.0) high = @max(high, @abs(string.u[i]));
            }
        }
        try std.testing.expect(kink < 1.0);
        // And once the pluck has run off, nothing left but the whispers.
        try std.testing.expect(high < 2.0);
    }
}
