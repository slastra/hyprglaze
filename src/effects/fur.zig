const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

// A short combed pile the desktop sits on. The strands are shader-side —
// a follicle grid marched shell by shell from the tips down to the skin —
// and everything that touches the coat comes from state the daemon
// already tracks: the cursor combs a parting through it, windows crush it
// flat where they sit and shove it aside at their edges, and the focused
// window keeps its own edge standing.
//
// This context owns the drift clock. It creeps on its own so the coat
// always has a slow current running through it, and quickens with energy.
// Accumulated here rather than derived from iTime so a tempo change never
// snaps the grain.
pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},

    flow: f64 = 0,

    /// Follicle spacing and pile length, both in pixels. Spacing is the
    /// knob that matters for texture: very fine strands shimmer as they
    /// move and turn to noise behind text, so the default stays on the
    /// coarse side of what still reads as hair rather than as quills.
    /// Length is how far a strand reaches across the screen as it lies over.
    cell: f32,
    length: f32,
    brightness: f32,

    u: Uniforms(.{
        .flow = "iFurFlow",
        .bass = "iFurBass",
        .beat = "iFurBeat",
        .cell = "iFurCell",
        .len = "iFurLength",
        .bright = "iFurBright",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        const music = try spectral.Analyzer.init(allocator, params);
        return .{
            .allocator = allocator,
            .music = music,
            .cell = std.math.clamp(params.getFloat("spacing", 15.0), 4.0, 60.0),
            .length = std.math.clamp(params.getFloat("length", 30.0), 2.0, 200.0),
            .brightness = std.math.clamp(params.getFloat("brightness", 1.0), 0.0, 3.0),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        _ = self.music.update(dt);
        self.flow += dt * (0.25 + self.music.bands.energy_ema * 0.65);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        self.u.use(prog.program);
        self.u.f1(.flow, @floatCast(self.flow));
        self.u.f1(.bass, self.music.bass());
        self.u.f1(.beat, self.music.onset.beat);
        self.u.f1(.cell, self.cell);
        self.u.f1(.len, self.length);
        self.u.f1(.bright, self.brightness);
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
    }
};
