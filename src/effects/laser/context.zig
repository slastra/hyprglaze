const std = @import("std");
const clock = @import("../clock.zig");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const effects = @import("../../effects.zig");
const spectral = @import("../spectral.zig");
const trace = @import("trace.zig");

const Uniforms = @import("../uniforms.zig").Uniforms;

const c = @import("c");

pub const max_beams = 2;
/// Legs per beam. At the default falloff a beam fades out in ~18.
pub const max_legs = 32;
/// Must match the array sizes in shaders/laser.frag.
pub const max_segments = max_beams * max_legs;
/// Kick pulses in flight down the low beam at once.
pub const max_pulses = 4;
/// How long a kick pulse travels before it has faded out, seconds.
const pulse_life: f32 = 1.6;

const Beam = struct {
    origin: [2]f32,
    /// Theme palette index (0-based).
    color: i32,
    /// Last usable aim, kept while the cursor sits on the emitter.
    dir: [2]f32,
    segs: [max_legs]trace.Segment = undefined,
    count: usize = 0,
};

/// Lasers fired from screen corners toward the cursor, reflecting off
/// windows and the screen's edges and dimming by `falloff` at each bounce
/// (see trace.zig). The second beam fires from the opposite corner in
/// another theme colour. Retraced every frame from the live window rects.
///
/// With music, each beam resonates with its own end of the spectrum: the
/// first (red) with the lows, the second (blue) with the highs. A beam
/// swells with its band's energy and a wave of brightness travels out
/// along it through every bounce, long and slow on the low beam, fine and
/// fast on the high one; bass kicks fire pulses down the low beam.
pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    /// Strength of the music response; 0 = none.
    react: f32,
    /// Travelling-wave phase per beam, accumulated so a change in energy
    /// changes the wave's speed rather than jumping its position.
    phase: [max_beams]f32 = .{ 0, 0 },
    /// Kick pulse ages in seconds; >= pulse_life is idle.
    pulses: [max_pulses]f32 = @splat(pulse_life),
    next_pulse: usize = 0,

    width: f32,
    height: f32,
    falloff: f32,
    min_intensity: f32,
    beam_width: f32,
    smoke: f32,
    speckle: f32,
    /// Speckle pattern seed, re-rolled only when a beam's aim moves.
    seed: f32 = 0,
    beams: [max_beams]Beam,
    beam_count: usize,
    now: f64 = 0,

    u: Uniforms(.{
        .seg = "iLaserSeg[0]",
        .int = "iLaserLeg[0]",
        .count = "iLaserCount",
        .split = "iLaserSplit",
        .width = "iLaserWidth",
        .color = "iLaserColor",
        .color2 = "iLaserColor2",
        .time = "iLaserTime",
        .smoke = "iLaserSmoke",
        .speckle = "iLaserSpeckle",
        .seed = "iLaserSeed",
        .band = "iLaserBand",
        .phase = "iLaserPhase",
        .pulse = "iLaserPulse",
        .react = "iLaserReact",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const music = try spectral.Analyzer.init(allocator, params);
        // GL space is y-up: "bottom" is y = 0.
        const corner = params.getString("corner", "bottom-left") orelse "bottom-left";
        const inset: f32 = 2.0;
        const left = !std.mem.endsWith(u8, corner, "right");
        const bottom = !std.mem.startsWith(u8, corner, "top");
        const first: [2]f32 = .{ if (left) inset else width - inset, if (bottom) inset else height - inset };
        // The opposite corner: mirror both axes.
        const second: [2]f32 = .{ width - first[0], height - first[1] };
        const centre: [2]f32 = .{ width * 0.5, height * 0.5 };
        return .{
            .allocator = allocator,
            .music = music,
            .react = std.math.clamp(params.getFloat("react", 1.0), 0.0, 3.0),
            .width = width,
            .height = height,
            .falloff = std.math.clamp(params.getFloat("falloff", 0.82), 0.05, 0.99),
            .min_intensity = 0.03,
            .beam_width = @max(params.getFloat("width", 1.6), 0.3),
            .smoke = std.math.clamp(params.getFloat("smoke", 0.6), 0.0, 2.0),
            .speckle = std.math.clamp(params.getFloat("speckle", 0.6), 0.0, 1.0),
            .beam_count = @intCast(std.math.clamp(params.getInt("beams", 2), 1, max_beams)),
            .beams = .{
                // Theme slots, 1-16 (the color_NN numbers): 2 is the red,
                // 5 the blue.
                .{ .origin = first, .color = themeSlot(params.getInt("color", 2)), .dir = .{ centre[0] - first[0], centre[1] - first[1] } },
                .{ .origin = second, .color = themeSlot(params.getInt("color2", 5)), .dir = .{ centre[0] - second[0], centre[1] - second[1] } },
            },
        };
    }

    /// Smoothed energy in each beam's band, scaled by `react`: the lows
    /// (bands 0-1) for the first beam, the highs (4-5) for the second.
    fn bandEnergy(self: *const Context) [2]f32 {
        return .{
            self.music.bass() * self.react,
            self.music.treble() * self.react,
        };
    }

    fn themeSlot(slot: i64) i32 {
        return @intCast(std.math.clamp(slot, 1, 16) - 1);
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.1);
        self.now += dt;

        // A kick launches a pulse from the low beam's emitter.
        if (self.music.update(@min(dt, 0.05))) {
            self.pulses[self.next_pulse] = 0;
            self.next_pulse = (self.next_pulse + 1) % max_pulses;
        }
        for (&self.pulses) |*age| age.* = @min(age.* + dt, pulse_life);
        // The waves run faster as their band gets louder: slow undulation
        // on the lows, quick ripple on the highs.
        const e = self.bandEnergy();
        self.phase[0] = @mod(self.phase[0] + dt * std.math.tau * (0.35 + 0.9 * e[0]), std.math.tau);
        self.phase[1] = @mod(self.phase[1] + dt * std.math.tau * (1.6 + 3.0 * e[1]), std.math.tau);

        var rects: [32]trace.Rect = undefined;
        const n = @min(state.windows.len, rects.len);
        for (state.windows[0..n], 0..) |w, i| rects[i] = .{ .x = w.x, .y = w.y, .w = w.w, .h = w.h };

        var seed: f32 = 0;
        for (self.beams[0..self.beam_count], 0..) |*b, bi| {
            const aim: [2]f32 = .{ state.cursor[0] - b.origin[0], state.cursor[1] - b.origin[1] };
            if (aim[0] * aim[0] + aim[1] * aim[1] > 16.0) b.dir = aim;
            b.count = trace.trace(b.origin, b.dir, self.width, self.height, rects[0..n], self.falloff, self.min_intensity, &b.segs);
            // Speckle decorrelates when the geometry changes: key the
            // pattern to each beam's aim, quantized to ~a grain at range.
            const q = @round(std.math.atan2(b.dir[1], b.dir[0]) / 0.0015);
            seed += q * (if (bi == 0) @as(f32, 0.6180339) else 0.7548776);
        }
        self.seed = @mod(seed, 97.0);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        self.u.use(prog.program);
        // Beams back to back; legs from iLaserSplit on belong to beam 2.
        var seg: [max_segments][4]f32 = undefined;
        // (intensity, light arriving at the leg's start, flare twinkle,
        //  distance along the beam to the leg's start)
        var legs: [max_segments][4]f32 = undefined;
        var total: usize = 0;
        var split: usize = 0;
        for (self.beams[0..self.beam_count], 0..) |b, bi| {
            if (bi == 1) split = total;
            var along: f32 = 0;
            for (b.segs[0..b.count], 0..) |s, j| {
                seg[total] = .{ s.a[0], s.a[1], s.b[0], s.b[1] };
                const arrived = if (j == 0) 1.0 else b.segs[j - 1].intensity;
                const twinkle = 0.85 + 0.15 * @sin(clock.phase(self.now, 9.0) + @as(f32, @floatFromInt(total)) * 2.3);
                legs[total] = .{ s.intensity, arrived, twinkle, along };
                along += @sqrt((s.b[0] - s.a[0]) * (s.b[0] - s.a[0]) + (s.b[1] - s.a[1]) * (s.b[1] - s.a[1]));
                total += 1;
            }
        }
        if (self.beam_count == 1) split = total;
        const n: c_int = @intCast(total);
        self.u.f4v(.seg, n, &seg[0]);
        self.u.f4v(.int, n, &legs[0]);
        self.u.int(.count, n);
        self.u.int(.split, @intCast(split));
        self.u.f1(.width, self.beam_width);
        self.u.int(.color, self.beams[0].color);
        self.u.int(.color2, self.beams[1].color);
        // Effect-local clock keeps shader time small (fire.zig pattern).
        self.u.f1(.time, @floatCast(@mod(self.now, 1000.0)));
        self.u.f1(.smoke, self.smoke);
        self.u.f1(.speckle, self.speckle);
        self.u.f1(.seed, self.seed);
        const e = self.bandEnergy();
        self.u.f2(.band, e[0], e[1]);
        self.u.f2(.phase, self.phase[0], self.phase[1]);
        self.u.f1(.react, if (self.music.audio != null) self.react else 0.0);
        if (self.u.loc(.pulse) >= 0) {
            // Pulse age as a fraction of its life; 1 = idle.
            var ages: [max_pulses]f32 = undefined;
            for (self.pulses, 0..) |age, i| ages[i] = age / pulse_life;
            self.u.f4(.pulse, ages[0], ages[1], ages[2], ages[3]);
        }
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
    }
};
