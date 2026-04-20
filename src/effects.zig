const std = @import("std");
const shader_mod = @import("core/shader.zig");
const transition_mod = @import("core/transition.zig");
const config_mod = @import("core/config.zig");
const palette_mod = @import("core/palette.zig");

const particles_sys = @import("effects/particles/system.zig");
const particles = @import("effects/particles/context.zig");
const windowglow = @import("effects/windowglow.zig");
const static = @import("effects/static.zig");
const cellbloom = @import("effects/cellbloom.zig");
const concentric = @import("effects/concentric.zig");
const fluid = @import("effects/fluid.zig");
const aurora = @import("effects/aurora.zig");
const starfield = @import("effects/starfield.zig");
const visualizer = @import("effects/visualizer/context.zig");
const milkdrop = @import("effects/milkdrop/context.zig");
const buddy = @import("effects/buddy/context.zig");
const ai_buddy = @import("effects/ai_buddy/context.zig");

pub const WindowInfo = struct {
    class: [64]u8 = undefined,
    class_len: u8 = 0,
    title: [64]u8 = undefined,
    title_len: u8 = 0,
};

pub const FrameState = struct {
    dt: f32,
    time: f32,
    cursor: [2]f32,
    focused_win: transition_mod.Rect,
    windows: []const shader_mod.ShaderProgram.WindowRect,
    collision_rects: []const particles_sys.Rect,
    window_info: ?[]const WindowInfo = null,
    focused_class: [64]u8 = [_]u8{0} ** 64,
    focused_class_len: u8 = 0,
    focused_title: [64]u8 = [_]u8{0} ** 64,
    focused_title_len: u8 = 0,
    palette: ?*const palette_mod.Palette = null,
};

pub const Effect = union(enum) {
    particles: particles.Context,
    windowglow: windowglow.Context,
    static: static.Context,
    buddy: buddy.Context,
    ai_buddy: ai_buddy.Context,
    cellbloom: cellbloom.Context,
    concentric: concentric.Context,
    fluid: fluid.Context,
    aurora: aurora.Context,
    starfield: starfield.Context,
    visualizer: visualizer.Context,
    milkdrop: milkdrop.Context,

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
        } else if (std.mem.eql(u8, name, "cellbloom")) {
            return .{ .cellbloom = cellbloom.Context.init() };
        } else if (std.mem.eql(u8, name, "concentric")) {
            return .{ .concentric = concentric.Context.init() };
        } else if (std.mem.eql(u8, name, "fluid")) {
            return .{ .fluid = fluid.Context.init() };
        } else if (std.mem.eql(u8, name, "aurora")) {
            return .{ .aurora = aurora.Context.init() };
        } else if (std.mem.eql(u8, name, "starfield")) {
            const params = config_mod.effectParams(cfg, "visualizer");
            return .{ .starfield = starfield.Context.init(allocator, params) };
        } else if (std.mem.eql(u8, name, "visualizer")) {
            const params = config_mod.effectParams(cfg, "visualizer");
            return .{ .visualizer = visualizer.Context.init(allocator, params) };
        } else if (std.mem.eql(u8, name, "milkdrop")) {
            const params = config_mod.effectParams(cfg, "visualizer");
            return .{ .milkdrop = milkdrop.Context.init(allocator, width, height, params) };
        }
        std.debug.print("Unknown effect: '{s}'. Available: particles, windowglow, cellbloom, concentric, fluid, aurora, visualizer, milkdrop, static, buddy, ai-buddy\n", .{name});
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
            .cellbloom => "shaders/cellbloom.frag",
            .concentric => "shaders/concentric.frag",
            .fluid => "shaders/fluid.frag",
            .aurora => "shaders/aurora.frag",
            .starfield => "shaders/starfield.frag",
            .visualizer => "shaders/visualizer.frag",
            .milkdrop => "shaders/milkdrop.frag",
        };
    }
};
