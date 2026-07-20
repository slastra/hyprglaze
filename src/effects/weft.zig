const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// Weft: windows shining through a diffraction weave. Three stripe
// lattices interfere into large drifting moiré fringes, visible only
// where window halos light the grating — born from the happy accident
// of a broken hash making interference bands in windowglow's film
// grain, kept deliberate here.
//
// The music IS woven into the interference: the audio waveform itself —
// smoothed ~50ms so it keeps its shape without frame jitter, peak-
// normalized so volume doesn't change depth — threads through the
// fringes as a phase displacement sampled along each thread's length.
// Every fringe is an oscilloscope trace in the weave: a kick is a sharp
// hump rippling through, a pad a slow braid; silence is clean, still
// threads (bit-identical to no music). Nothing else responds — no
// bands, no envelopes, no beat detector. Halo reach, drift, grain
// cadence, and detune are constants.
pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,

    /// Lattice phase drift (slow, constant).
    drift: f32 = 0,
    /// Grain reseed clock (fixed film cadence).
    grain_clock: f32 = 0,
    /// Mono waveform, EMA-smoothed per sample (~50ms memory).
    wave_s: [128]f32 = [_]f32{0} ** 128,
    /// Peak-normalized copy shipped to the shader.
    wave_n: [128]f32 = [_]f32{0} ** 128,
    /// Slow AGC peak (~3s decay).
    wave_peak: f32 = 0,

    // Params.
    scale: f32,
    reach: f32,
    grain: f32,

    cached_program: c.GLuint = 0,
    loc_drift: c.GLint = -1,
    loc_grain_t: c.GLint = -1,
    loc_wave: c.GLint = -1,
    loc_scale: c.GLint = -1,
    loc_reach: c.GLint = -1,
    loc_grain: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        var audio: ?*audio_mod.AudioCapture = null;
        if (params.getBool("music", true)) audio = try audio_mod.spawn(allocator, params);
        return .{
            .allocator = allocator,
            .audio = audio,
            .scale = std.math.clamp(params.getFloat("scale", 26.0), 8.0, 120.0),
            .reach = std.math.clamp(params.getFloat("reach", 1.0), 0.3, 3.0),
            .grain = std.math.clamp(params.getFloat("grain", 1.0), 0.0, 2.0),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        if (self.audio) |audio| {
            const wave = audio.getWaveform();
            var peak_new: f32 = 0;
            const a = @min(1.0, 18.0 * dt); // ~55ms shape memory
            for (0..128) |i| {
                const s = (wave[i] + wave[128 + i]) * 0.5;
                self.wave_s[i] += (s - self.wave_s[i]) * a;
                peak_new = @max(peak_new, @abs(self.wave_s[i]));
            }
            self.wave_peak = @max(self.wave_peak * @exp(-dt / 3.0), peak_new);
            const inv: f32 = if (self.wave_peak > 0.01) 1.0 / self.wave_peak else 0.0;
            for (0..128) |i| {
                self.wave_n[i] = std.math.clamp(self.wave_s[i] * inv, -1.0, 1.0);
            }
        }
        self.grain_clock += dt * 10.0;
        self.drift += dt * 0.06;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_drift = c.glGetUniformLocation(prog.program, "iWeftDrift");
            self.loc_grain_t = c.glGetUniformLocation(prog.program, "iWeftGrainT");
            self.loc_wave = c.glGetUniformLocation(prog.program, "iWeftWave[0]");
            self.loc_scale = c.glGetUniformLocation(prog.program, "iWeftScale");
            self.loc_reach = c.glGetUniformLocation(prog.program, "iWeftReach");
            self.loc_grain = c.glGetUniformLocation(prog.program, "iWeftGrain");
        }
        if (self.loc_drift >= 0) c.glUniform1f(self.loc_drift, self.drift);
        if (self.loc_grain_t >= 0) c.glUniform1f(self.loc_grain_t, self.grain_clock);
        if (self.loc_wave >= 0) c.glUniform1fv(self.loc_wave, 128, &self.wave_n[0]);
        if (self.loc_scale >= 0) c.glUniform1f(self.loc_scale, self.scale);
        if (self.loc_reach >= 0) c.glUniform1f(self.loc_reach, self.reach);
        if (self.loc_grain >= 0) c.glUniform1f(self.loc_grain, self.grain);
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| audio_mod.shutdown(audio, self.allocator);
    }
};
