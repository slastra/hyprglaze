const std = @import("std");
const shader_mod = @import("core/shader.zig");
const transition_mod = @import("core/transition.zig");
const config_mod = @import("core/config.zig");

const particles = @import("effects/particles.zig");
const windowglow = @import("effects/windowglow.zig");
const static = @import("effects/static.zig");
const buddy = @import("effects/buddy.zig");
const ai_buddy = @import("effects/ai_buddy.zig");

pub const FrameState = struct {
    dt: f32,
    time: f32,
    cursor: [2]f32,
    focused_win: transition_mod.Rect,
    windows: []const shader_mod.ShaderProgram.WindowRect,
    collision_rects: []const particles.Rect,
};

pub const Effect = union(enum) {
    particles: particles.Context,
    windowglow: windowglow.Context,
    static: static.Context,
    buddy: buddy.Context,
    ai_buddy: ai_buddy.Context,

    pub fn init(name: []const u8, allocator: std.mem.Allocator, width: f32, height: f32, cfg: *const config_mod.Config) !Effect {
        if (std.mem.eql(u8, name, "particles")) {
            const params = config_mod.effectParams(cfg, "particles");
            return .{ .particles = particles.Context.init(allocator, width, height, params) };
        } else if (std.mem.eql(u8, name, "windowglow")) {
            return .{ .windowglow = windowglow.Context.init() };
        } else if (std.mem.eql(u8, name, "static")) {
            return .{ .static = static.Context.init() };
        } else if (std.mem.eql(u8, name, "buddy")) {
            const params = config_mod.effectParams(cfg, "buddy");
            return .{ .buddy = buddy.Context.init(allocator, width, height, params) };
        } else if (std.mem.eql(u8, name, "ai-buddy")) {
            const params = config_mod.effectParams(cfg, "buddy");
            return .{ .ai_buddy = ai_buddy.Context.init(allocator, width, height, params) };
        }
        std.debug.print("Unknown effect: '{s}'. Available: particles, windowglow, static, buddy, ai-buddy\n", .{name});
        return error.UnknownEffect;
    }

    pub fn update(self: *Effect, state: FrameState) void {
        switch (self.*) {
            inline else => |*ctx| ctx.update(state),
        }
    }

    pub fn upload(self: *Effect, prog: *const shader_mod.ShaderProgram) void {
        switch (self.*) {
            inline else => |*ctx| ctx.upload(prog),
        }
    }

    pub fn deinit(self: *Effect) void {
        switch (self.*) {
            inline else => |*ctx| ctx.deinit(),
        }
    }

    pub fn defaultShader(self: *const Effect) []const u8 {
        return switch (self.*) {
            .particles => "shaders/particles.frag",
            .windowglow => "shaders/windowglow.frag",
            .static => "shaders/test.frag",
            .buddy => "shaders/buddy.frag",
            .ai_buddy => "shaders/buddy.frag",
        };
    }
};
