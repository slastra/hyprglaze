const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const spectral = @import("spectral.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// The glow itself is shader-side; this context only lets the focused
// window's halo breathe with the music — a slow energy swell plus a
// whisper of bass. Both uniforms are zero in silence (or with
// music = false), which collapses the shader to the classic look.
pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    an: spectral.Bands = .{},

    cached_program: c.GLuint = 0,
    loc_energy: c.GLint = -1,
    loc_bass: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        var audio: ?*audio_mod.AudioCapture = null;
        if (params.getBool("music", true)) {
            const cap = try allocator.create(audio_mod.AudioCapture);
            cap.* = audio_mod.AudioCapture.init(params.getString("sink", null));
            cap.start();
            audio = cap;
        }
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
            self.loc_energy = c.glGetUniformLocation(prog.program, "iGlowEnergy");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iGlowBass");
        }
        if (self.loc_energy >= 0) c.glUniform1f(self.loc_energy, self.an.energy_ema);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, (self.an.smooth[0] + self.an.smooth[1]) * 0.5);
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| {
            audio.stop();
            self.allocator.destroy(audio);
        }
    }
};
