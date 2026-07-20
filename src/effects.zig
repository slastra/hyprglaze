const std = @import("std");

const log = std.log.scoped(.effects);

const shader_mod = @import("core/shader.zig");
const transition_mod = @import("core/transition.zig");
const config_mod = @import("core/config.zig");
const palette_mod = @import("core/palette.zig");

const particles_sys = @import("effects/particles/system.zig");
const particles = @import("effects/particles/context.zig");
const windowglow = @import("effects/windowglow.zig");
const glitch = @import("effects/glitch.zig");
const cellbloom = @import("effects/cellbloom.zig");
const concentric = @import("effects/concentric.zig");
const fluid = @import("effects/fluid.zig");
const starfield = @import("effects/starfield.zig");
const visualizer = @import("effects/visualizer/context.zig");
const milkdrop = @import("effects/milkdrop/context.zig");
const buddy = @import("effects/buddy/context.zig");
const ai_buddy = @import("effects/ai_buddy/context.zig");
const tide = @import("effects/tide.zig");
const fire = @import("effects/fire.zig");
const swarm = @import("effects/swarm/context.zig");
const voltaic = @import("effects/voltaic.zig");
const moire = @import("effects/moire.zig");
const fable = @import("effects/fable.zig");
const ivy = @import("effects/ivy.zig");
const whorl = @import("effects/whorl.zig");
const weft = @import("effects/weft.zig");

/// Class and title of one mapped window (truncated copies), parallel to
/// `FrameState.windows` by index.
pub const WindowInfo = struct {
    class: [64]u8 = undefined,
    class_len: u8 = 0,
    title: [64]u8 = undefined,
    title_len: u8 = 0,
};

/// Per-frame snapshot of the desktop handed to every effect's `update`.
/// The slice fields (`windows`, `collision_rects`, `window_info`) and the
/// `palette` pointer are only valid for the duration of the call - effects
/// that need them later (e.g. in `upload`) must copy what they keep.
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

/// The active desktop effect. Method contract for every variant Context:
/// - `init` may be called WITHOUT a current GL context, so GL resource
///   creation belongs in the first `upload` call (milkdrop is the lone
///   exception and requires a current context at init; see the note in
///   milkdrop/context.zig).
/// - `update(state)` runs once per frame before rendering; it may assume a
///   monotonically advancing clock but nothing about GL. FrameState slices
///   are only valid during the call (see FrameState).
/// - `upload(prog)` runs with the GL context current and pushes uniforms
///   (and any lazily created GL state) to the program.
/// - `deinit` must release everything init/update/upload acquired,
///   including stopping any background threads.
pub const Effect = union(enum) {
    particles: particles.Context,
    windowglow: windowglow.Context,
    glitch: glitch.Context,
    buddy: buddy.Context,
    ai_buddy: ai_buddy.Context,
    cellbloom: cellbloom.Context,
    concentric: concentric.Context,
    fluid: fluid.Context,
    starfield: starfield.Context,
    visualizer: visualizer.Context,
    milkdrop: milkdrop.Context,
    tide: tide.Context,
    fire: fire.Context,
    swarm: swarm.Context,
    voltaic: voltaic.Context,
    moire: moire.Context,
    fable: fable.Context,
    ivy: ivy.Context,
    whorl: whorl.Context,
    weft: weft.Context,

    /// Config section an effect reads its params from. Defaults to the
    /// variant name; the exceptions: starfield and milkdrop intentionally
    /// read the shared [visualizer] section (same audio knobs, e.g. sink),
    /// and ai_buddy shares [buddy] with the plain buddy.
    fn paramSection(comptime field_name: []const u8) []const u8 {
        if (std.mem.eql(u8, field_name, "starfield")) return "visualizer";
        if (std.mem.eql(u8, field_name, "milkdrop")) return "visualizer";
        if (std.mem.eql(u8, field_name, "ai_buddy")) return "buddy";
        return field_name;
    }

    /// Call `T.init` with whichever of the standard argument shapes it
    /// declares (arity-dispatched at comptime). The `!T` return normalizes
    /// plain and error-union inits.
    fn initContext(comptime T: type, allocator: std.mem.Allocator, width: f32, height: f32, cfg: *const config_mod.Config, comptime section: []const u8) !T {
        const n_args = @typeInfo(@TypeOf(T.init)).@"fn".params.len;
        if (comptime n_args == 0) return T.init();
        const params = config_mod.effectParams(cfg, section);
        return switch (comptime n_args) {
            1 => T.init(params),
            2 => T.init(allocator, params),
            4 => T.init(allocator, width, height, params),
            else => @compileError("unsupported Context.init signature on " ++ @typeName(T)),
        };
    }

    pub fn init(name: []const u8, allocator: std.mem.Allocator, width: f32, height: f32, cfg: *const config_mod.Config) !Effect {
        inline for (@typeInfo(Effect).@"union".fields) |f| {
            if (std.mem.eql(u8, name, comptime cliName(f.name))) {
                return @unionInit(Effect, f.name, try initContext(f.type, allocator, width, height, cfg, comptime paramSection(f.name)));
            }
        }
        log.err("unknown effect: '{s}'. Available: {s}", .{ name, effect_names_csv });
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

    /// Fragment shader an effect loads by default: shaders/<variant>.frag,
    /// except ai_buddy which renders with buddy's frag.
    pub fn defaultShader(self: *const Effect) []const u8 {
        return switch (self.*) {
            inline else => |_, tag| comptime blk: {
                const base = if (std.mem.eql(u8, @tagName(tag), "ai_buddy")) "buddy" else @tagName(tag);
                break :blk "shaders/" ++ base ++ ".frag";
            },
        };
    }
};

/// CLI-style effect name: the union field name with `_` rewritten to `-`
/// (e.g. `ai_buddy` -> `ai-buddy`). Comptime only.
fn cliName(comptime field_name: []const u8) []const u8 {
    var out: [field_name.len]u8 = undefined;
    for (field_name, 0..) |ch, i| out[i] = if (ch == '_') '-' else ch;
    const final = out;
    return &final;
}

/// Comma-joined list of all effect names with `_` rewritten to `-`.
/// Derived at comptime from the `Effect` union so error messages and CLI
/// help can't drift from the actual variant set.
pub const effect_names_csv: []const u8 = blk: {
    var out: []const u8 = "";
    for (@typeInfo(Effect).@"union".fields, 0..) |f, i| {
        if (i > 0) out = out ++ ", ";
        out = out ++ cliName(f.name);
    }
    break :blk out;
};

/// Print the list of effect names (one per line) to stdout. Derived at
/// comptime from the Effect union so new effects show up automatically —
/// underscores in field names are converted to hyphens for CLI style
/// (e.g. `ai_buddy` → `ai-buddy`).
pub fn listEffects() !void {
    var stdout_buf: [64]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    inline for (@typeInfo(Effect).@"union".fields) |f| {
        try w.print("{s}\n", .{comptime cliName(f.name)});
    }
    try w.flush();
}
