const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const bands_mod = @import("bands.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

pub const Context = struct {
    audio: *audio_mod.AudioCapture,
    allocator: std.mem.Allocator,

    // 6 bands (mapped to 6 palette colors) + spectral-flux beats
    an: bands_mod.Splitter = .{},
    velocity: f32 = 1.0,     // smoothed flight speed multiplier
    wobble: f32 = 0,         // velocity offset from beat
    flight_time: f32 = 0,    // accumulated time scaled by velocity (only increases)

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        const audio = try audio_mod.spawn(allocator, params);
        return .{ .audio = audio, .allocator = allocator };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
        const wave = self.audio.getWaveform();

        // 6 spectrum bands (mapped to palette colors 1-6) + flux beats
        const beat_hit = self.an.update(&wave, dt);
        if (beat_hit) self.wobble = 1.0;

        // Wobble: gentle pulse that decays, no oscillation
        self.wobble *= @exp(-2.0 * dt);

        // Velocity: cruise speed + beat kick
        const target_vel = 0.4 + self.an.bass * 0.15;
        self.velocity += (target_vel - self.velocity) * @min(1.0, 3.0 * dt);
        // Beat adds an instant kick that decays naturally via the wobble
        self.velocity += self.wobble * 2.0 * dt;
        self.velocity = @max(self.velocity, 0.3);

        // Accumulate flight time — only ever increases
        self.flight_time += self.velocity * dt;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        // Pack bands + beat into iParticles[0] and [1]
        // [0] = (band0, band1, band2, band3)
        // [1] = (band4, band5, beat, bass)
        if (prog.i_particles[0] >= 0)
            c.glUniform4f(prog.i_particles[0],
                self.an.bands[0], self.an.bands[1], self.an.bands[2], self.an.bands[3]);
        if (prog.i_particles[1] >= 0)
            c.glUniform4f(prog.i_particles[1],
                self.an.bands[4], self.an.bands[5], self.an.beat, self.flight_time);
        if (prog.i_particle_count >= 0)
            c.glUniform1i(prog.i_particle_count, 2);
    }

    pub fn deinit(self: *Context) void {
        audio_mod.shutdown(self.audio, self.allocator);
    }
};
