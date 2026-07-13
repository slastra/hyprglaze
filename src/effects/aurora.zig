const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const spectral = @import("spectral.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// The curtains are shader-side; this context paces them (a CPU flow
// clock, so music-driven speed never snaps phase) and lets them breathe:
// energy lengthens the rays, and each curtain layer rides a band group
// (front = lows, mid = mids, back = highs). All zero in silence — or
// with music = false — collapsing to the calm night.
pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    an: spectral.Bands = .{},
    flow: f32 = 0,

    cached_program: c.GLuint = 0,
    loc_flow: c.GLint = -1,
    loc_energy: c.GLint = -1,
    loc_layers: c.GLint = -1,

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
        self.flow += dt * (0.15 + self.an.energy_ema * 0.25);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_flow = c.glGetUniformLocation(prog.program, "iAuroraFlow");
            self.loc_energy = c.glGetUniformLocation(prog.program, "iAuroraEnergy");
            self.loc_layers = c.glGetUniformLocation(prog.program, "iAuroraLayers[0]");
        }
        if (self.loc_flow >= 0) c.glUniform1f(self.loc_flow, self.flow);
        if (self.loc_energy >= 0) c.glUniform1f(self.loc_energy, self.an.energy_ema);
        if (self.loc_layers >= 0) {
            const layers = [3]f32{
                (self.an.smooth[0] + self.an.smooth[1]) * 0.5,
                (self.an.smooth[2] + self.an.smooth[3]) * 0.5,
                (self.an.smooth[4] + self.an.smooth[5]) * 0.5,
            };
            c.glUniform1fv(self.loc_layers, 3, &layers[0]);
        }
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| {
            audio.stop();
            self.allocator.destroy(audio);
        }
    }
};
