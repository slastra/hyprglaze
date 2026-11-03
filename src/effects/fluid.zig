const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

// The metaball topography is entirely shader-side; this context only
// feeds it music. The six drifting ambient blobs map one-to-one onto the
// six spectral bands: a playing band inflates its blob and weighs it
// heavier in the field, and overall energy densifies the contour lines.
// Every shader modulation is a (1 + band * k) amplitude term, so with no
// music (or music = false) the render is exactly the classic fluid look.
pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},

    u: Uniforms(.{
        .bands = "iFluidBands[0]",
        .energy = "iFluidEnergy",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        const music = try spectral.Analyzer.init(allocator, params);
        return .{ .allocator = allocator, .music = music };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        _ = self.music.update(dt);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        self.u.use(prog.program);
        self.u.f1v(.bands, 6, &self.music.bands.smooth[0]);
        self.u.f1(.energy, self.music.bands.energy_ema);
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
    }
};
