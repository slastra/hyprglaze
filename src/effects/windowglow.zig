const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

// The glow itself is shader-side; this context only lets the focused
// window's halo breathe with the music — a slow energy swell plus a
// whisper of bass. Both uniforms are zero in silence (or with
// music = false), which collapses the shader to the classic look.
pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    /// Film-grain amplitude (config: grain, 0 disables).
    grain: f32,
    /// Grain reseed clock: ~10fps at rest, treble drives it toward 24fps.
    /// Accumulated here so the rate change never stutters the sequence.
    grain_clock: f64 = 0,

    u: Uniforms(.{
        .energy = "iGlowEnergy",
        .bass = "iGlowBass",
        .grain = "iGlowGrain",
        .grain_t = "iGlowGrainT",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        const music = try spectral.Analyzer.init(allocator, params);
        return .{
            .allocator = allocator,
            .music = music,
            .grain = std.math.clamp(params.getFloat("grain", 0.5), 0.0, 2.0),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        _ = self.music.update(dt);
        const treble = self.music.treble();
        self.grain_clock += dt * (10.0 + @min(treble, 1.0) * 14.0);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        self.u.use(prog.program);
        self.u.f1(.energy, self.music.bands.energy_ema);
        self.u.f1(.bass, self.music.bass());
        self.u.f1(.grain, self.grain);
        self.u.f1(.grain_t, @floatCast(self.grain_clock));
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
    }
};
