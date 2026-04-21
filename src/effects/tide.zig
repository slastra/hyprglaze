const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
    @cInclude("time.h");
});

/// Time-aware tide effect. A rising water line tracks wall-clock time:
///   start_hour → end_hour: fill rises 0 → 1
///   end_hour → start_hour (next day, wrapping midnight): drain 1 → 0
///
/// Config:
///   [tide]
///   start_hour = 6.0     # hour at which the tide is empty (0..24)
///   end_hour   = 24.0    # hour at which the tide is full (> start_hour, ≤ 24)
pub const Context = struct {
    start_hour: f32 = 6.0,
    end_hour: f32 = 24.0,
    fill: f32 = 0,

    pub fn init(params: config_mod.EffectParams) Context {
        var self = Context{
            .start_hour = std.math.clamp(params.getFloat("start_hour", 6.0), 0.0, 23.99),
            .end_hour = std.math.clamp(params.getFloat("end_hour", 24.0), 0.01, 24.0),
        };
        if (self.end_hour <= self.start_hour) self.end_hour = self.start_hour + 0.01;
        self.fill = computeFill(self.start_hour, self.end_hour);
        return self;
    }

    pub fn update(self: *Context, _: effects.FrameState) void {
        self.fill = computeFill(self.start_hour, self.end_hour);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        const loc = c.glGetUniformLocation(prog.program, "iFill");
        if (loc >= 0) c.glUniform1f(loc, self.fill);
    }

    pub fn deinit(_: *Context) void {}
};

fn computeFill(start: f32, end: f32) f32 {
    var t = c.time(null);
    const tm = c.localtime(&t) orelse return 0.5;

    const h: f32 = @floatFromInt(tm.*.tm_hour);
    const m: f32 = @floatFromInt(tm.*.tm_min);
    const s: f32 = @floatFromInt(tm.*.tm_sec);
    const hours = h + m / 60.0 + s / 3600.0;

    if (hours >= start and hours <= end) {
        return (hours - start) / (end - start);
    }

    // Drain phase wraps midnight.
    const drain_duration = (24.0 - end) + start;
    if (drain_duration <= 0.0) return 1.0;
    const drain_time = if (hours > end) hours - end else (24.0 - end) + hours;
    return 1.0 - drain_time / drain_duration;
}
