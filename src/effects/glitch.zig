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

    // 6 bands (mapped to palette colors 1-6) + spectral-flux beats
    an: bands_mod.Splitter = .{},
    flight_time: f32 = 0,

    // Glitch-specific
    glitch_seed: f32 = 0,
    total_energy: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        const audio = try audio_mod.spawn(allocator, params);
        return .{ .audio = audio, .allocator = allocator };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
        const wave = self.audio.getWaveform();

        // 6 spectrum bands + spectral-flux beat detection
        const beat_hit = self.an.update(&wave, dt);
        self.total_energy = self.an.energy;

        if (beat_hit) {
            // New seed on beat — drives block/jitter randomness
            self.glitch_seed = @mod(@sin(self.flight_time * 12345.6789) * 43758.5453, 1.0);
            if (self.glitch_seed < 0) self.glitch_seed += 1.0;
        }

        self.flight_time += dt;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        // [0] = (band0, band1, band2, band3)
        if (prog.i_particles[0] >= 0)
            c.glUniform4f(prog.i_particles[0],
                self.an.bands[0], self.an.bands[1], self.an.bands[2], self.an.bands[3]);
        // [1] = (band4, band5, beat, flight_time)
        if (prog.i_particles[1] >= 0)
            c.glUniform4f(prog.i_particles[1],
                self.an.bands[4], self.an.bands[5], self.an.beat, self.flight_time);
        // [2] = (glitch_seed, total_energy, bass_smooth, 0)
        if (prog.i_particles[2] >= 0)
            c.glUniform4f(prog.i_particles[2],
                self.glitch_seed, self.total_energy, self.an.bass_smooth, 0);
        if (prog.i_particle_count >= 0)
            c.glUniform1i(prog.i_particle_count, 3);
    }

    pub fn deinit(self: *Context) void {
        audio_mod.shutdown(self.audio, self.allocator);
    }
};
