const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const effects = @import("../../effects.zig");
const audio_mod = @import("audio.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const bin_count = audio_mod.bin_count;

pub const Context = struct {
    audio: audio_mod.AudioCapture = .{},
    smoothed: [bin_count]f32 = [_]f32{0} ** bin_count,
    peak: [bin_count]f32 = [_]f32{0} ** bin_count,

    pub fn init(params: config_mod.EffectParams) Context {
        const sink = params.getString("sink", null);
        var ctx = Context{
            .audio = audio_mod.AudioCapture.init(sink),
        };
        ctx.audio.start();
        return ctx;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
        const raw = self.audio.getBins();

        for (0..bin_count) |i| {
            if (raw[i] > self.smoothed[i]) {
                self.smoothed[i] += (raw[i] - self.smoothed[i]) * @min(1.0, 20.0 * dt);
            } else {
                self.smoothed[i] += (raw[i] - self.smoothed[i]) * @min(1.0, 4.0 * dt);
            }
            if (self.smoothed[i] > self.peak[i]) {
                self.peak[i] = self.smoothed[i];
            } else {
                self.peak[i] -= 0.5 * dt;
                if (self.peak[i] < 0) self.peak[i] = 0;
            }
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        // iParticles[0..15] = smoothed bins (4 per vec4, 64 total)
        // iParticles[16..31] = peak values
        var slot: u32 = 0;
        var i: u32 = 0;
        while (i < bin_count) : (i += 4) {
            if (slot >= 300) break;
            if (prog.i_particles[slot] >= 0)
                c.glUniform4f(prog.i_particles[slot],
                    self.smoothed[i], self.smoothed[i + 1],
                    self.smoothed[i + 2], self.smoothed[i + 3]);
            slot += 1;
        }
        slot = 16;
        i = 0;
        while (i < bin_count) : (i += 4) {
            if (slot >= 300) break;
            if (prog.i_particles[slot] >= 0)
                c.glUniform4f(prog.i_particles[slot],
                    self.peak[i], self.peak[i + 1],
                    self.peak[i + 2], self.peak[i + 3]);
            slot += 1;
        }

        if (prog.i_particle_count >= 0)
            c.glUniform1i(prog.i_particle_count, 32);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
    }
};
