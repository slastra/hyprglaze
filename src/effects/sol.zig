const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const rhythm_mod = @import("meshflow/rhythm.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

/// A kinetic light instrument. Besides audio analysis, the CPU side extracts
/// gesture and window-motion impulses so interaction has momentum and decay.
pub const Context = struct {
    audio: *audio_mod.AudioCapture,
    rhythm: rhythm_mod.RhythmEngine,
    state: rhythm_mod.RhythmState = .{},
    intensity: f32,
    allocator: std.mem.Allocator,
    canvas: [2]f32,
    prev_cursor: [2]f32 = .{ 0, 0 },
    cursor_velocity: [2]f32 = .{ 0, 0 },
    gesture_energy: f32 = 0,
    prev_window_center: [2]f32 = .{ 0, 0 },
    window_velocity: [2]f32 = .{ 0, 0 },
    window_impulse: f32 = 0,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const audio = try allocator.create(audio_mod.AudioCapture);
        errdefer allocator.destroy(audio);
        audio.* = audio_mod.AudioCapture.init(params.getString("sink", null));
        audio.start();
        errdefer audio.stop();

        return .{
            .audio = audio,
            .rhythm = try rhythm_mod.RhythmEngine.init(allocator),
            .intensity = params.getFloat("intensity", 1.0),
            .allocator = allocator,
            .canvas = .{ width, height },
        };
    }

    pub fn update(self: *Context, fs: effects.FrameState) void {
        const wave = self.audio.getWaveform();
        self.state = self.rhythm.tick(&wave, fs.dt);

        const dt = @max(1.0 / 240.0, @min(fs.dt, 0.05));
        const win_center = [2]f32{
            fs.focused_win.x + fs.focused_win.w * 0.5,
            fs.focused_win.y + fs.focused_win.h * 0.5,
        };
        if (!self.initialized) {
            self.prev_cursor = fs.cursor;
            self.prev_window_center = win_center;
            self.initialized = true;
        }

        const cursor_raw = [2]f32{
            (fs.cursor[0] - self.prev_cursor[0]) / dt,
            (fs.cursor[1] - self.prev_cursor[1]) / dt,
        };
        const cursor_alpha = 1.0 - @exp(-dt * 15.0);
        self.cursor_velocity[0] += (cursor_raw[0] - self.cursor_velocity[0]) * cursor_alpha;
        self.cursor_velocity[1] += (cursor_raw[1] - self.cursor_velocity[1]) * cursor_alpha;
        const cursor_speed = @sqrt(cursor_raw[0] * cursor_raw[0] + cursor_raw[1] * cursor_raw[1]);
        const cursor_target = @min(cursor_speed / @max(self.canvas[0], self.canvas[1]) * 1.8, 1.0);
        self.gesture_energy = @max(cursor_target, self.gesture_energy * @exp(-dt * 2.6));

        const win_raw = [2]f32{
            (win_center[0] - self.prev_window_center[0]) / dt,
            (win_center[1] - self.prev_window_center[1]) / dt,
        };
        const win_alpha = 1.0 - @exp(-dt * 10.0);
        self.window_velocity[0] += (win_raw[0] - self.window_velocity[0]) * win_alpha;
        self.window_velocity[1] += (win_raw[1] - self.window_velocity[1]) * win_alpha;
        const win_speed = @sqrt(win_raw[0] * win_raw[0] + win_raw[1] * win_raw[1]);
        const win_target = @min(win_speed / @max(self.canvas[0], self.canvas[1]), 1.0);
        self.window_impulse = @max(win_target, self.window_impulse * @exp(-dt * 1.8));

        self.prev_cursor = fs.cursor;
        self.prev_window_center = win_center;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        var buf: [20]u8 = undefined;
        for (0..rhythm_mod.n_bands) |i| {
            const band = std.fmt.bufPrintZ(&buf, "iSolBands[{d}]", .{i}) catch continue;
            const band_loc = c.glGetUniformLocation(prog.program, band.ptr);
            if (band_loc >= 0) c.glUniform1f(band_loc, self.state.bands[i]);
            const onset = std.fmt.bufPrintZ(&buf, "iSolOnsets[{d}]", .{i}) catch continue;
            const onset_loc = c.glGetUniformLocation(prog.program, onset.ptr);
            if (onset_loc >= 0) c.glUniform1f(onset_loc, self.state.onsets[i]);
        }
        setFloat(prog.program, "iSolBeat", self.state.beat_phase);
        setFloat(prog.program, "iSolDownbeat", self.state.down_phase);
        setFloat(prog.program, "iSolIntensity", self.intensity);
        const gesture_loc = c.glGetUniformLocation(prog.program, "iSolGesture");
        if (gesture_loc >= 0) c.glUniform4f(gesture_loc, self.cursor_velocity[0], self.cursor_velocity[1], self.gesture_energy, 0);
        const motion_loc = c.glGetUniformLocation(prog.program, "iSolWindowMotion");
        if (motion_loc >= 0) c.glUniform4f(motion_loc, self.window_velocity[0], self.window_velocity[1], self.window_impulse, 0);
    }

    fn setFloat(program: c.GLuint, name: [*:0]const u8, value: f32) void {
        const loc = c.glGetUniformLocation(program, name);
        if (loc >= 0) c.glUniform1f(loc, value);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
        self.rhythm.deinit();
    }
};
