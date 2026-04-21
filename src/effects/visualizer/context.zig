const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const effects = @import("../../effects.zig");
const audio_mod = @import("audio.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

pub const Context = struct {
    audio: *audio_mod.AudioCapture,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        const sink = params.getString("sink", null);
        const audio = try allocator.create(audio_mod.AudioCapture);
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();
        return .{ .audio = audio, .allocator = allocator };
    }

    pub fn update(_: *Context, _: effects.FrameState) void {}

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        const wave = self.audio.getWaveform();

        // Pack 4 samples per vec4
        // [0..31] = left channel (128 samples)
        // [32..63] = right channel (128 samples)
        var slot: u32 = 0;
        var i: u32 = 0;
        while (i < 256) : (i += 4) {
            if (slot >= 300) break;
            if (prog.i_particles[slot] >= 0)
                c.glUniform4f(prog.i_particles[slot],
                    wave[i], wave[i + 1], wave[i + 2], wave[i + 3]);
            slot += 1;
        }

        if (prog.i_particle_count >= 0)
            c.glUniform1i(prog.i_particle_count, 64);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
    }
};
