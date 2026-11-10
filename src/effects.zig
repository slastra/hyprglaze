const std = @import("std");

const log = std.log.scoped(.effects);

const shader_mod = @import("core/shader.zig");
const transition_mod = @import("core/transition.zig");
const config_mod = @import("core/config.zig");
const palette_mod = @import("core/palette.zig");

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
const ivy = @import("effects/ivy.zig");
const whorl = @import("effects/whorl.zig");
const weft = @import("effects/weft.zig");
const crystal = @import("effects/crystal.zig");
const fur = @import("effects/fur.zig");
const amorphous = @import("effects/amorphous.zig");
const laser = @import("effects/laser/context.zig");
const flux = @import("effects/flux.zig");
const coral = @import("effects/coral.zig");

/// Class and title of one mapped window (truncated copies), parallel to
/// `FrameState.windows` by index.
pub const WindowInfo = struct {
    class: [64]u8 = undefined,
    class_len: u8 = 0,
    title: [64]u8 = undefined,
    title_len: u8 = 0,
};

/// Per-frame snapshot of the desktop handed to every effect's `update`.
/// The slice fields (`windows`, `window_info`) and the
/// `palette` pointer are only valid for the duration of the call - effects
/// that need them later (e.g. in `upload`) must copy what they keep.
pub const FrameState = struct {
    dt: f32,
    time: f32,
    cursor: [2]f32,
    focused_win: transition_mod.Rect,
    windows: []const shader_mod.ShaderProgram.WindowRect,
    window_info: ?[]const WindowInfo = null,
    focused_class: [64]u8 = @splat(0),
    focused_class_len: u8 = 0,
    focused_title: [64]u8 = @splat(0),
    focused_title_len: u8 = 0,
    palette: ?*const palette_mod.Palette = null,
    /// Workspace slide settling: 0 = switch just happened, 1 = settled.
    /// Effects can use it to suppress per-window churn mid-slide.
    workspace_slide: f32 = 1.0,
    /// Bumped on every workspace change, slid or snapped. Window rects jump
    /// across a switch without the windows themselves having moved.
    workspace_switches: u32 = 0,
    /// Windows whose `closewindow` event arrived since the last frame.
    /// Absence from `windows` alone is ambiguous: a window on another
    /// workspace is also absent.
    closed_windows: []const u64 = &.{},
};

/// The active desktop effect. Method contract for every variant Context:
/// - `init` never touches GL: it may run with no context current, or with
///   one that is about to be destroyed (a graphics rebuild builds the
///   replacement effect before tearing the old context down). GL resource
///   creation belongs in the first `upload` call.
/// - `update(state)` runs once per frame before rendering; it may assume a
///   monotonically advancing clock but nothing about GL. FrameState slices
///   are only valid during the call (see FrameState).
/// - `upload(prog)` runs with the GL context current and pushes uniforms
///   (and any lazily created GL state) to the program.
/// - `deinit` must release everything init/update/upload acquired,
///   including stopping any background threads. It runs with the context
///   that created the effect's GL names still current.
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
    ivy: ivy.Context,
    whorl: whorl.Context,
    weft: weft.Context,
    crystal: crystal.Context,
    fur: fur.Context,
    amorphous: amorphous.Context,
    laser: laser.Context,
    flux: flux.Context,
    coral: coral.Context,

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
        const n_args = @typeInfo(@TypeOf(T.init)).@"fn".param_types.len;
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
        inline for (@typeInfo(Effect).@"union".field_names, @typeInfo(Effect).@"union".field_types) |f_name, f_type| {
            if (std.mem.eql(u8, name, comptime cliName(f_name))) {
                return @unionInit(Effect, f_name, try initContext(f_type, allocator, width, height, cfg, comptime paramSection(f_name)));
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

    /// CLI-style name of the live variant (`ai_buddy` -> `ai-buddy`), so a
    /// caller can rebuild the same effect without going through config state
    /// that may have drifted from what is actually running.
    pub fn cliNameOf(self: *const Effect) []const u8 {
        return switch (self.*) {
            inline else => |_, tag| comptime cliName(@tagName(tag)),
        };
    }

    /// Fragment shader an effect loads by default: shaders/<variant>.frag,
    /// except ai_buddy which renders with buddy's frag.
    pub fn defaultShader(self: *const Effect) []const u8 {
        return switch (self.*) {
            inline else => |_, tag| comptime shaderOf(@tagName(tag)),
        };
    }

    /// The default shader for an effect by its CLI name, without building
    /// it (no audio thread, no GL); null for an unknown name.
    pub fn defaultShaderFor(name: []const u8) ?[]const u8 {
        inline for (@typeInfo(Effect).@"union".field_names) |f_name| {
            if (std.mem.eql(u8, name, comptime cliName(f_name))) return comptime shaderOf(f_name);
        }
        return null;
    }
};

fn shaderOf(comptime field_name: []const u8) []const u8 {
    const base = if (std.mem.eql(u8, field_name, "ai_buddy")) "buddy" else field_name;
    return "shaders/" ++ base ++ ".frag";
}

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
    for (@typeInfo(Effect).@"union".field_names, 0..) |f_name, i| {
        if (i > 0) out = out ++ ", ";
        out = out ++ cliName(f_name);
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

    inline for (@typeInfo(Effect).@"union".field_names) |f_name| {
        try w.print("{s}\n", .{comptime cliName(f_name)});
    }
    try w.flush();
}
