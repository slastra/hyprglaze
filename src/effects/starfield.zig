const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

pub const Context = struct {
    audio: *audio_mod.AudioCapture,
    allocator: std.mem.Allocator,

    // Smoothed energy bands (6 bands mapped to 6 palette colors)
    bands: [6]f32 = [_]f32{0} ** 6,
    bass: f32 = 0,

    // Beat detection: energy flux (derivative) based
    bass_instant: f32 = 0,
    bass_smooth: f32 = 0,    // slow-moving average
    bass_prev: f32 = 0,      // previous frame instant
    flux: f32 = 0,           // positive energy derivative
    flux_avg: f32 = 0,       // running average of flux
    beat: f32 = 0,           // 0-1, decays smoothly
    beat_cooldown: f32 = 0,
    velocity: f32 = 1.0,     // smoothed flight speed multiplier
    wobble: f32 = 0,         // oscillating velocity offset from beat

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) Context {
        const sink = params.getString("sink", null);
        const audio = allocator.create(audio_mod.AudioCapture) catch @panic("alloc failed");
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();
        return .{ .audio = audio, .allocator = allocator };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
        const wave = self.audio.getWaveform();

        // 6 spectrum bands from waveform (mapped to palette colors 1-6)
        // Band 0 (sub-bass): samples 0-10
        // Band 1 (bass): 10-25
        // Band 2 (low-mid): 25-45
        // Band 3 (mid): 45-70
        // Band 4 (high-mid): 70-95
        // Band 5 (high): 95-128
        const ranges = [_][2]u8{ .{ 0, 10 }, .{ 10, 25 }, .{ 25, 45 }, .{ 45, 70 }, .{ 70, 95 }, .{ 95, 128 } };

        for (0..6) |b| {
            var energy: f32 = 0;
            const lo = ranges[b][0];
            const hi = ranges[b][1];
            for (lo..hi) |i| {
                energy += @abs(wave[i]) + @abs(wave[128 + i]);
            }
            energy /= @as(f32, @floatFromInt((hi - lo) * 2));

            const raw = energy * 6.0;
            const attack = @min(1.0, 25.0 * dt);
            const decay = @min(1.0, 5.0 * dt);
            self.bands[b] += (raw - self.bands[b]) * (if (raw > self.bands[b]) attack else decay);
        }

        // Beat detection: spectral flux (energy derivative)
        const bass_e = (self.bands[0] + self.bands[1]) * 0.5;
        self.bass = bass_e;
        self.bass_instant = bass_e;
        self.bass_smooth += (bass_e - self.bass_smooth) * @min(1.0, 0.8 * dt);

        // Spectral flux: only count positive energy changes (onsets, not decays)
        const flux_raw = @max(0.0, self.bass_instant - self.bass_prev);
        self.bass_prev = self.bass_instant;
        self.flux = flux_raw;
        self.flux_avg += (flux_raw - self.flux_avg) * @min(1.0, 1.5 * dt);

        // Beat triggers when flux significantly exceeds its running average
        // Higher threshold + longer cooldown to avoid false triggers
        self.beat_cooldown -= dt;
        if (self.flux > self.flux_avg * 3.0 + 0.03 and self.beat_cooldown <= 0 and self.bass_instant > self.bass_smooth * 1.5) {
            self.beat = 1.0;
            self.wobble = 1.0;
            self.beat_cooldown = 0.25;
        }
        self.beat *= @exp(-4.0 * dt);
        if (self.beat < 0.01) self.beat = 0;

        // Wobble: damped oscillation, always positive (speed up then settle)
        self.wobble *= @exp(-3.0 * dt);
        const wobble_val = self.wobble * @abs(@sin(self.wobble * 15.0));

        // Velocity: always forward, wobble adds speed on top
        const target_vel = 0.4 + self.bass * 0.2 + wobble_val * 1.2;
        const vel_speed: f32 = 6.0;
        self.velocity += (target_vel - self.velocity) * @min(1.0, vel_speed * dt);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        // Pack bands + beat into iParticles[0] and [1]
        // [0] = (band0, band1, band2, band3)
        // [1] = (band4, band5, beat, bass)
        if (prog.i_particles[0] >= 0)
            c.glUniform4f(prog.i_particles[0],
                self.bands[0], self.bands[1], self.bands[2], self.bands[3]);
        if (prog.i_particles[1] >= 0)
            c.glUniform4f(prog.i_particles[1],
                self.bands[4], self.bands[5], self.beat, self.velocity);
        if (prog.i_particle_count >= 0)
            c.glUniform1i(prog.i_particle_count, 2);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
    }
};
