const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const effects = @import("../../effects.zig");
const audio_mod = @import("../visualizer/audio.zig");
const rhythm_mod = @import("rhythm.zig");
const beatnet_mod = @import("beatnet.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

/// Audio-reactive 5x5 mesh-gradient effect.
///
/// Pipeline:
///   AudioCapture (60 Hz, shared with visualizer/milkdrop/starfield/glitch)
///     -> RhythmEngine.tick → per-band envelopes + onsets + beat clock
///     -> upload bands/onsets/beat_phase/down_phase/tempo as shader uniforms
///
/// Config:
///   [meshflow]
///   sink = "..."        # optional PulseAudio sink override
///   intensity = 1.0     # global mesh-displacement multiplier (shader-side)
pub const Context = struct {
    audio: *audio_mod.AudioCapture,
    rhythm: rhythm_mod.RhythmEngine,
    beatnet: ?*beatnet_mod.BeatNet,
    state: rhythm_mod.RhythmState = .{},
    intensity: f32 = 1.0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, params: config_mod.EffectParams) !Context {
        const sink = params.getString("sink", null);
        const use_beatnet = params.getBool("use_beatnet", true);

        const audio = try allocator.create(audio_mod.AudioCapture);
        errdefer allocator.destroy(audio);
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();

        // Only spawn the BeatNet audio thread + 22 kHz PulseAudio stream when
        // the locked beat clock is actually wanted.
        var beatnet: ?*beatnet_mod.BeatNet = null;
        if (use_beatnet) {
            const bn = try allocator.create(beatnet_mod.BeatNet);
            errdefer allocator.destroy(bn);
            bn.* = beatnet_mod.BeatNet.init(sink);
            bn.start();
            beatnet = bn;
        }

        const rhythm = try rhythm_mod.RhythmEngine.init(allocator);
        return .{
            .audio = audio,
            .beatnet = beatnet,
            .rhythm = rhythm,
            .intensity = params.getFloat("intensity", 1.0),
            .allocator = allocator,
        };
    }

    pub fn update(self: *Context, fs: effects.FrameState) void {
        const wave = self.audio.getWaveform();
        self.state = self.rhythm.tick(&wave, fs.dt);
        // When BeatNet is locked, override the cheap layer's free-running
        // beat clock with its tempo-locked phase. Bands & onsets keep coming
        // from the cheap layer (lower latency, frame-accurate reactivity).
        if (self.beatnet) |bn_ptr| {
            const bn = bn_ptr.getState();
            if (bn.locked) {
                self.state.beat_phase = bn.beat_phase;
                self.state.down_phase = bn.down_phase;
                self.state.tempo = bn.tempo;
                self.state.locked = true;
            }
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        // 6 bands, 6 onsets — bound as a flat float array each.
        var bands_loc: [rhythm_mod.n_bands]c.GLint = undefined;
        var onsets_loc: [rhythm_mod.n_bands]c.GLint = undefined;
        var name_buf: [16]u8 = undefined;
        for (0..rhythm_mod.n_bands) |i| {
            const bn = std.fmt.bufPrintZ(&name_buf, "iBands[{d}]", .{i}) catch continue;
            bands_loc[i] = c.glGetUniformLocation(prog.program, bn.ptr);
            const on = std.fmt.bufPrintZ(&name_buf, "iOnsets[{d}]", .{i}) catch continue;
            onsets_loc[i] = c.glGetUniformLocation(prog.program, on.ptr);
        }
        for (0..rhythm_mod.n_bands) |i| {
            if (bands_loc[i] >= 0) c.glUniform1f(bands_loc[i], self.state.bands[i]);
            if (onsets_loc[i] >= 0) c.glUniform1f(onsets_loc[i], self.state.onsets[i]);
        }

        const beat_loc = c.glGetUniformLocation(prog.program, "iBeatPhase");
        if (beat_loc >= 0) c.glUniform1f(beat_loc, self.state.beat_phase);
        const down_loc = c.glGetUniformLocation(prog.program, "iDownPhase");
        if (down_loc >= 0) c.glUniform1f(down_loc, self.state.down_phase);
        const tempo_loc = c.glGetUniformLocation(prog.program, "iTempo");
        if (tempo_loc >= 0) c.glUniform1f(tempo_loc, self.state.tempo);
        const intensity_loc = c.glGetUniformLocation(prog.program, "iIntensity");
        if (intensity_loc >= 0) c.glUniform1f(intensity_loc, self.intensity);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
        if (self.beatnet) |bn| {
            bn.stop();
            self.allocator.destroy(bn);
        }
        self.rhythm.deinit();
    }
};
