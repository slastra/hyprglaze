const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const spectral = @import("spectral.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// Weft: windows shining through a diffraction weave. Three slightly
// detuned stripe lattices interfere into large drifting moiré fringes,
// visible only where window halos light the grating — born from the
// happy accident of a broken hash making interference bands in
// windowglow's film grain, kept deliberate here. The weave is all
// shader-side; this context paces it (accumulated clocks, never
// in-shader rate modulation) and feeds it music: energy breathes the
// halo reach and drift, treble quickens the grain dance, bass chunks
// the quantization cell, and kicks re-seat one lattice's phase (eased
// over ~50ms so it reads as a shift, not a strobe). All zero in
// silence — or with music = false — collapsing to a still weave.
pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    an: spectral.Bands = .{},
    onset: spectral.Onset = .{},
    beat_prev: f32 = 0,

    /// Lattice phase drift (slow; energy quickens gently).
    drift: f32 = 0,
    /// Grain reseed clock: ~10fps at rest, treble drives toward 24.
    grain_clock: f32 = 0,
    /// Kick re-seat: lattice 0's phase offset, eased toward its target.
    seat: f32 = 0,
    seat_target: f32 = 0,

    // Params.
    scale: f32,
    reach: f32,
    grain: f32,

    cached_program: c.GLuint = 0,
    loc_drift: c.GLint = -1,
    loc_grain_t: c.GLint = -1,
    loc_energy: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_seat: c.GLint = -1,
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
            if (self.onset.beat > self.beat_prev) self.seat_target += 1.0;
            self.beat_prev = self.onset.beat;
        }
        const treble = (self.an.smooth[4] + self.an.smooth[5]) * 0.5;
        self.grain_clock += dt * (10.0 + @min(treble, 1.0) * 14.0);
        self.drift += dt * (0.06 + self.an.energy_ema * 0.10);
        self.seat += (self.seat_target - self.seat) * @min(1.0, 20.0 * dt);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_drift = c.glGetUniformLocation(prog.program, "iWeftDrift");
            self.loc_grain_t = c.glGetUniformLocation(prog.program, "iWeftGrainT");
            self.loc_energy = c.glGetUniformLocation(prog.program, "iWeftEnergy");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iWeftBass");
            self.loc_seat = c.glGetUniformLocation(prog.program, "iWeftSeat");
            self.loc_scale = c.glGetUniformLocation(prog.program, "iWeftScale");
            self.loc_reach = c.glGetUniformLocation(prog.program, "iWeftReach");
            self.loc_grain = c.glGetUniformLocation(prog.program, "iWeftGrain");
        }
        if (self.loc_drift >= 0) c.glUniform1f(self.loc_drift, self.drift);
        if (self.loc_grain_t >= 0) c.glUniform1f(self.loc_grain_t, self.grain_clock);
        if (self.loc_energy >= 0) c.glUniform1f(self.loc_energy, self.an.energy_ema);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, (self.an.smooth[0] + self.an.smooth[1]) * 0.5);
        if (self.loc_seat >= 0) c.glUniform1f(self.loc_seat, self.seat);
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
