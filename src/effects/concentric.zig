const shader_mod = @import("../core/shader.zig");
const effects = @import("../effects.zig");

pub const Context = struct {
    pub fn init() Context {
        return .{};
    }

    pub fn update(_: *Context, _: effects.FrameState) void {}

    pub fn upload(_: *Context, _: *const shader_mod.ShaderProgram) void {}

    pub fn deinit(_: *Context) void {}
};
