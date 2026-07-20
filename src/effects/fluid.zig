const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const spectral = @import("spectral.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// The metaball topography is entirely shader-side; this context only
// feeds it music. The six drifting ambient blobs map one-to-one onto the
// six spectral bands: a playing band inflates its blob and weighs it
// heavier in the field, and overall energy densifies the contour lines.
// Every shader modulation is a (1 + band * k) amplitude term, so with no
// music (or music = false) the render is exactly the classic fluid look.
pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    an: spectral.Bands = .{},

    cached_program: c.GLuint = 0,
    loc_bands: c.GLint = -1,
    loc_energy: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        var audio: ?*audio_mod.AudioCapture = null;
        if (params.getBool("music", true)) audio = try audio_mod.spawn(allocator, params);
        return .{ .allocator = allocator, .audio = audio };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        if (self.audio) |audio| {
            const wave = audio.getWaveform();
            const mags = spectral.magnitudes(&wave);
            self.an.update(&mags, dt);
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_bands = c.glGetUniformLocation(prog.program, "iFluidBands[0]");
            self.loc_energy = c.glGetUniformLocation(prog.program, "iFluidEnergy");
        }
        if (self.loc_bands >= 0) c.glUniform1fv(self.loc_bands, 6, &self.an.smooth[0]);
        if (self.loc_energy >= 0) c.glUniform1f(self.loc_energy, self.an.energy_ema);
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| audio_mod.shutdown(audio, self.allocator);
    }
};
