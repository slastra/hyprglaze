const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const spectral = @import("spectral.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// Weft: windows shining through a diffraction weave. Three stripe
// lattices interfere into large drifting moiré fringes, visible only
// where window halos light the grating — born from the happy accident
// of a broken hash making interference bands in windowglow's film
// grain, kept deliberate here.
//
// Music tunes the interferometer, and does nothing else. In silence
// the lattices sit nearly in tune: broad, calm, almost-still fringes.
// Each lattice's wavelength is detuned by its own band group (lows /
// mids / highs, slow envelopes), so the interference pattern IS the
// mix's spectral balance rendered as geometry — bass tightens one
// beat-fringe family, treble another. Kicks pluck the weave: a detune
// impulse across all three that relaxes over ~a second, fringes
// blooming apart and settling back into tune. Halo reach, grain
// cadence, and drift stay constant — the tuning is the whole story.
pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    an: spectral.Bands = .{},
    onset: spectral.Onset = .{},
    beat_prev: f32 = 0,

    /// Lattice phase drift (slow, constant).
    drift: f32 = 0,
    /// Grain reseed clock (fixed film cadence).
    grain_clock: f32 = 0,
    /// Per-lattice detune from band groups, extra-slow EMA (~3/s).
    tune: [3]f32 = [_]f32{0} ** 3,
    /// Kick pluck envelope: detune impulse, relaxing over ~a second.
    pluck: f32 = 0,

    // Params.
    scale: f32,
    reach: f32,
    grain: f32,

    cached_program: c.GLuint = 0,
    loc_drift: c.GLint = -1,
    loc_grain_t: c.GLint = -1,
    loc_tune: c.GLint = -1,
    loc_scale: c.GLint = -1,
    loc_reach: c.GLint = -1,
    loc_grain: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        var audio: ?*audio_mod.AudioCapture = null;
        if (params.getBool("music", true)) {
            const cap = try allocator.create(audio_mod.AudioCapture);
            cap.* = audio_mod.AudioCapture.init(params.getString("sink", null));
            cap.start();
            audio = cap;
        }
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
            const mags = spectral.magnitudes(&wave);
            self.an.update(&mags, dt);
            self.onset.update(&mags, dt, self.an.bands[0]);
            if (self.onset.beat > self.beat_prev) self.pluck = 1.0;
            self.beat_prev = self.onset.beat;
        }
        self.pluck *= @exp(-1.5 * dt);
        if (self.pluck < 0.01) self.pluck = 0;

        // Each lattice detunes with its band group; the pluck detunes all
        // three unevenly so the bloom has shape. Extra-slow EMA on top of
        // the already-smoothed bands: geometry should sway, not flicker.
        const groups = [3]f32{
            (self.an.smooth[0] + self.an.smooth[1]) * 0.5,
            (self.an.smooth[2] + self.an.smooth[3]) * 0.5,
            (self.an.smooth[4] + self.an.smooth[5]) * 0.5,
        };
        for (0..3) |k| {
            const fk: f32 = @floatFromInt(k);
            const target = @min(groups[k], 1.0) * 0.035 + self.pluck * 0.015 * (1.0 + fk * 0.6);
            self.tune[k] += (target - self.tune[k]) * @min(1.0, 3.0 * dt);
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
            self.loc_tune = c.glGetUniformLocation(prog.program, "iWeftTune[0]");
            self.loc_scale = c.glGetUniformLocation(prog.program, "iWeftScale");
            self.loc_reach = c.glGetUniformLocation(prog.program, "iWeftReach");
            self.loc_grain = c.glGetUniformLocation(prog.program, "iWeftGrain");
        }
        if (self.loc_drift >= 0) c.glUniform1f(self.loc_drift, self.drift);
        if (self.loc_grain_t >= 0) c.glUniform1f(self.loc_grain_t, self.grain_clock);
        if (self.loc_tune >= 0) c.glUniform1fv(self.loc_tune, 3, &self.tune[0]);
        if (self.loc_scale >= 0) c.glUniform1f(self.loc_scale, self.scale);
        if (self.loc_reach >= 0) c.glUniform1f(self.loc_reach, self.reach);
        if (self.loc_grain >= 0) c.glUniform1f(self.loc_grain, self.grain);
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| {
            audio.stop();
            self.allocator.destroy(audio);
        }
    }
};
