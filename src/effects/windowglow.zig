const shader_mod = @import("../core/shader.zig");
const effects = @import("../effects.zig");

/// Shader-only effect — all logic is in the fragment shader.
/// No CPU-side state needed.
pub const Context = struct {
    pub fn init() Context {
        return .{};
    }

    pub fn update(_: *Context, _: effects.FrameState) void {}

    pub fn upload(_: *Context, _: *const shader_mod.ShaderProgram) void {}

    pub fn deinit(_: *Context) void {}
};
