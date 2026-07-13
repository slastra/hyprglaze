const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const spectral = @import("spectral.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// The Voronoi lattice is shader-side; this context turns it into a
// dancefloor. Every cell is assigned a spectral band and its fill lights
// with it, bass heaves the drift geometry, energy quickens the drift
// clock (accumulated here so the rate change never snaps phase), and
// kicks flash the lattice edges. All zero in silence — or music = false,
// which skips capture — collapsing to the classic quiet patchwork.
pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    an: spectral.Bands = .{},
    onset: spectral.Onset = .{},
    /// Music-paced drift clock (replaces the shader's iTime * 0.15).
    flow: f32 = 0,

    cached_program: c.GLuint = 0,
    loc_flow: c.GLint = -1,
    loc_bands: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_beat: c.GLint = -1,

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
            self.onset.update(&mags, dt, self.an.bands[0]);
        }
        self.flow += dt * (0.15 + self.an.energy_ema * 0.45);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_flow = c.glGetUniformLocation(prog.program, "iBloomFlow");
            self.loc_bands = c.glGetUniformLocation(prog.program, "iBloomBands[0]");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iBloomBass");
            self.loc_beat = c.glGetUniformLocation(prog.program, "iBloomBeat");
        }
        if (self.loc_flow >= 0) c.glUniform1f(self.loc_flow, self.flow);
        if (self.loc_bands >= 0) c.glUniform1fv(self.loc_bands, 6, &self.an.smooth[0]);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, (self.an.smooth[0] + self.an.smooth[1]) * 0.5);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.onset.beat);
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| {
            audio.stop();
            self.allocator.destroy(audio);
        }
    }
};
