const std = @import("std");
const toml = @import("toml");
const iohelp = @import("io_helper.zig");
const workspace_slide = @import("workspace_slide.zig");

const log = std.log.scoped(.config);

/// Workspace-slide override. `auto` mirrors whatever animation is
/// detected from Hyprland; the rest force an axis or disable sliding.
pub const WorkspaceSlideOverride = enum { auto, horizontal, vertical, none };

/// Generic key-value params for effects to read from their config section.
/// Avoids coupling effects to the Config struct.
pub const EffectParams = struct {
    table: ?toml.Table,

    pub fn getFloat(self: EffectParams, key: []const u8, default: f32) f32 {
        if (self.table) |t| {
            if (t.get(key)) |val| {
                return switch (val) {
                    .float => @floatCast(val.float),
                    .integer => @floatFromInt(val.integer),
                    else => default,
                };
            }
        }
        return default;
    }

    pub fn getInt(self: EffectParams, key: []const u8, default: i64) i64 {
        if (self.table) |t| {
            if (t.get(key)) |val| {
                return switch (val) {
                    .integer => val.integer,
                    else => default,
                };
            }
        }
        return default;
    }

    /// Returns a string value from the section, or `default` if missing.
    ///
    /// LIFETIME: the returned slice points into `Config.raw_arena` (the
    /// arena owned by the parent Config). It is invalidated by the next
    /// `reloadConfig` in the main loop. **Consume immediately** — pass it
    /// to a function that copies it (e.g. `Texture.loadFromFile`,
    /// `bufPrint`). Do NOT store it on a Context struct that survives
    /// across frames; that's a use-after-free waiting to happen.
    pub fn getString(self: EffectParams, key: []const u8, default: ?[]const u8) ?[]const u8 {
        if (self.table) |t| {
            if (t.get(key)) |val| {
                return switch (val) {
                    .string => val.string,
                    else => default,
                };
            }
        }
        return default;
    }

    pub fn getBool(self: EffectParams, key: []const u8, default: bool) bool {
        if (self.table) |t| {
            if (t.get(key)) |val| {
                return switch (val) {
                    .boolean => val.boolean,
                    else => default,
                };
            }
        }
        return default;
    }

    pub const empty = EffectParams{ .table = null };
};

pub const Config = struct {
    effect: []const u8,
    shader: []const u8,
    theme: ?[]const u8,
    /// `output` — name of the monitor to render on, as reported by
    /// `hyprctl monitors`. null = the focused monitor at startup. Bound when
    /// the layer surface is created, so a change needs a restart.
    output: ?[]const u8,
    /// `output_wait` — seconds to wait for the output to come back after it
    /// is removed (a monitor power cycle, a mode change) before giving up
    /// and exiting non-zero. 0 = wait forever. Default 60 when `output` is
    /// set (a pinned instance has a supervisor that restarts it), 0
    /// otherwise (an unpinned one usually does not).
    output_wait: f32,
    /// Whether `output_wait` was written in the file. The default depends
    /// on `output`, which `--output` can set after parsing.
    output_wait_set: bool,
    transition_duration: f32,
    /// `[transition] fade_in` — seconds to fade in from the theme
    /// background on launch and whenever the surface is rebuilt (a
    /// reconnect, a lost context, the output coming back). 0 disables.
    fade_in: f32,
    cursor_smoothing: f32,
    geometry_smoothing: f32,
    /// `[transition] workspace_slide` — axis override, default auto.
    workspace_slide: WorkspaceSlideOverride,
    /// `[transition] workspace_duration` — seconds; 0 = auto (detected
    /// from Hyprland's animation speed). Bezier easing only.
    workspace_duration: f32,
    /// `[transition] workspace_spring = "mass,stiffness,dampening"` —
    /// mirrors a custom `hl.curve` spring (Hyprland does not expose
    /// spring parameters over IPC). null = hyprutils defaults.
    workspace_spring: ?workspace_slide.Spring,
    config_path: []const u8,

    /// Arena that owns every string slice inside `raw_table` (and hence
    /// every slice returned by `EffectParams.getString`). Freed in
    /// `Config.deinit`, which means a `reloadConfig` swap invalidates all
    /// outstanding string slices borrowed from this Config.
    raw_arena: ?std.heap.ArenaAllocator = null,
    /// Top-level TOML table. Effect params are read out of it lazily via
    /// `effectParams(cfg, "<section>")`. Slices into nested string values
    /// live in `raw_arena` — see the lifetime warning on
    /// `EffectParams.getString`.
    raw_table: ?toml.Table = null,
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const expanded = try expandHome(allocator, path);
    defer allocator.free(expanded);

    const data = readFile(allocator, expanded) catch |err| {
        log.err("failed to read config '{s}': {}", .{ expanded, err });
        return err;
    };
    defer allocator.free(data);

    return parse(allocator, data, path);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8, source_path: []const u8) !Config {
    // Parse as generic Table to retain all sections
    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    const result = parser.parseString(data) catch |err| {
        if (parser.error_info) |info| {
            switch (info) {
                .parse => |pos| log.warn("TOML parse error at line {d} (pos {d})", .{ pos.line, pos.pos }),
                .struct_mapping => log.warn("TOML struct mapping error", .{}),
            }
        }
        return err;
    };
    // Don't deinit result — we keep the arena alive for effect params

    const t = result.value;

    // Helper to read top-level string
    const effect_name = if (t.get("effect")) |v| (if (v == .string) v.string else "particles") else "particles";
    const shader_str = if (t.get("shader")) |v| (if (v == .string) v.string else "") else "";
    const theme_str = if (t.get("theme")) |v| (if (v == .string) v.string else null) else null;
    // Unlike the keys above, a wrong-typed `output` is not silently ignored:
    // falling back to "the focused monitor" would put two instances driven
    // from the same config template onto the same screen, and the adjacent
    // failure — a well-formed name that matches nothing — is already fatal.
    // Warn so the two paths do not give opposite diagnostics for one key.
    const output_str = if (t.get("output")) |v| blk: {
        if (v == .string) break :blk v.string;
        log.warn("config key 'output' must be a quoted string — ignoring it", .{});
        break :blk null;
    } else null;

    const output_wait = if (t.get("output_wait")) |v| switch (v) {
        .float => |f| @as(f32, @floatCast(f)),
        .integer => |i| @as(f32, @floatFromInt(i)),
        else => defaultOutputWait(output_str),
    } else defaultOutputWait(output_str);

    // Read core sections
    const transition_params = effectParamsFromTable(t, "transition");
    const cursor_params = effectParamsFromTable(t, "cursor");
    const geometry_params = effectParamsFromTable(t, "geometry");

    const effect_dup = try allocator.dupe(u8, effect_name);
    errdefer allocator.free(effect_dup);
    const shader_dup = try allocator.dupe(u8, shader_str);
    errdefer allocator.free(shader_dup);
    const theme_dup = if (theme_str) |ts| try allocator.dupe(u8, ts) else null;
    errdefer if (theme_dup) |td| allocator.free(td);
    const output_dup = if (output_str) |os| try allocator.dupe(u8, os) else null;
    errdefer if (output_dup) |od| allocator.free(od);

    return .{
        .effect = effect_dup,
        .shader = shader_dup,
        .theme = theme_dup,
        .output = output_dup,
        .output_wait = @max(0.0, output_wait),
        .output_wait_set = t.get("output_wait") != null,
        .transition_duration = transition_params.getFloat("duration", 0.3),
        .fade_in = @max(0.0, transition_params.getFloat("fade_in", 1.0)),
        .cursor_smoothing = cursor_params.getFloat("smoothing", 0.15),
        .geometry_smoothing = geometry_params.getFloat("smoothing", 0.12),
        .workspace_slide = parseSlideOverride(transition_params.getString("workspace_slide", null)),
        .workspace_duration = transition_params.getFloat("workspace_duration", 0),
        .workspace_spring = parseSpring(transition_params.getString("workspace_spring", null)),
        .config_path = try allocator.dupe(u8, source_path),
        .raw_arena = result.arena,
        .raw_table = t,
    };
}

pub fn defaultOutputWait(output: ?[]const u8) f32 {
    return if (output != null) 60.0 else 0.0;
}

fn parseSlideOverride(value: ?[]const u8) WorkspaceSlideOverride {
    const s = value orelse return .auto;
    return std.meta.stringToEnum(WorkspaceSlideOverride, s) orelse {
        log.warn("unknown workspace_slide '{s}' — using auto", .{s});
        return .auto;
    };
}

/// "mass,stiffness,dampening" → Spring; anything malformed → null.
fn parseSpring(value: ?[]const u8) ?workspace_slide.Spring {
    const s = std.mem.trim(u8, value orelse return null, " \t");
    if (s.len == 0) return null;
    var it = std.mem.splitScalar(u8, s, ',');
    const mass = parseSpringField(it.next()) orelse return warnSpring(s);
    const stiffness = parseSpringField(it.next()) orelse return warnSpring(s);
    const damping = parseSpringField(it.next()) orelse return warnSpring(s);
    if (it.next() != null) return warnSpring(s);
    return .{ .mass = mass, .stiffness = stiffness, .damping = damping };
}

fn parseSpringField(field: ?[]const u8) ?f32 {
    const f = std.mem.trim(u8, field orelse return null, " \t");
    const v = std.fmt.parseFloat(f32, f) catch return null;
    if (!std.math.isFinite(v) or v <= 0) return null;
    return v;
}

fn warnSpring(s: []const u8) ?workspace_slide.Spring {
    log.warn("invalid workspace_spring '{s}' (want \"mass,stiffness,dampening\") — using defaults", .{s});
    return null;
}

/// Get effect-specific params from a TOML section by name
pub fn effectParams(cfg: *const Config, section: []const u8) EffectParams {
    return effectParamsFromTable(cfg.raw_table, section);
}

fn effectParamsFromTable(table: ?toml.Table, section: []const u8) EffectParams {
    if (table) |t| {
        if (t.get(section)) |val| {
            return switch (val) {
                .table => EffectParams{ .table = val.table.* },
                else => EffectParams.empty,
            };
        }
    }
    return EffectParams.empty;
}

pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
    allocator.free(self.effect);
    if (self.shader.len > 0) allocator.free(self.shader);
    if (self.theme) |t2| allocator.free(t2);
    if (self.output) |o| allocator.free(o);
    allocator.free(self.config_path);
    if (self.raw_arena) |*arena| arena.deinit();
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return iohelp.readFileAlloc(allocator, path, 1024 * 1024);
}

pub fn expandHome(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Only expand `~/...` or a lone `~` — a `~user/...` path would
    // otherwise silently become `$HOMEuser/...`.
    if (std.mem.eql(u8, path, "~") or std.mem.startsWith(u8, path, "~/")) {
        const home_z = std.c.getenv("HOME") orelse return error.NoHomeDir;
        const home = std.mem.span(home_z);
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
    }
    return allocator.dupe(u8, path);
}

/// Surgically replace (or insert) the top-level `theme = "..."` line in the
/// config file, preserving everything else verbatim. If the config doesn't
/// exist, it's created with just the theme line. Written atomically via
/// temp-file + rename so a running daemon either sees the old or new content.
pub fn setTheme(allocator: std.mem.Allocator, config_path: []const u8, new_theme: []const u8) !void {
    const contents: []u8 = readFileMut(allocator, config_path) catch |err| switch (err) {
        error.FileNotFound => try allocator.alloc(u8, 0),
        else => return err,
    };
    defer allocator.free(contents);

    // Locate existing top-level `theme = ...` (skip lines inside [section]s).
    var theme_start: ?usize = null;
    var theme_end: usize = 0;
    {
        var pos: usize = 0;
        var in_section = false;
        while (pos <= contents.len) {
            const end = std.mem.indexOfScalarPos(u8, contents, pos, '\n') orelse contents.len;
            const trimmed = std.mem.trim(u8, contents[pos..end], " \t\r");
            if (trimmed.len > 0 and trimmed[0] == '[') in_section = true;
            if (!in_section and isThemeLine(trimmed)) {
                theme_start = pos;
                theme_end = end;
                break;
            }
            if (end == contents.len) break;
            pos = end + 1;
        }
    }

    const line = try std.fmt.allocPrint(allocator, "theme = \"{s}\"", .{new_theme});
    defer allocator.free(line);

    const out = if (theme_start) |s| blk: {
        const total = s + line.len + (contents.len - theme_end);
        const buf = try allocator.alloc(u8, total);
        @memcpy(buf[0..s], contents[0..s]);
        @memcpy(buf[s .. s + line.len], line);
        @memcpy(buf[s + line.len ..], contents[theme_end..]);
        break :blk buf;
    } else blk: {
        const total = line.len + 1 + contents.len;
        const buf = try allocator.alloc(u8, total);
        @memcpy(buf[0..line.len], line);
        buf[line.len] = '\n';
        @memcpy(buf[line.len + 1 ..], contents);
        break :blk buf;
    };
    defer allocator.free(out);

    // Ensure parent directory exists (mkdir -p)
    if (std.fs.path.dirname(config_path)) |dir| {
        iohelp.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Atomic write
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{config_path});
    defer allocator.free(tmp);
    try iohelp.writeFileAbsolute(tmp, out);
    try iohelp.renameAbsolute(tmp, config_path);
}

fn isThemeLine(trimmed: []const u8) bool {
    if (trimmed.len < 6 or !std.mem.startsWith(u8, trimmed, "theme")) return false;
    const rest = std.mem.trimStart(u8, trimmed[5..], " \t");
    return rest.len > 0 and rest[0] == '=';
}

test "isThemeLine matches theme assignments only" {
    try std.testing.expect(isThemeLine("theme = \"Nord\""));
    try std.testing.expect(isThemeLine("theme=\"Nord\""));
    try std.testing.expect(isThemeLine("theme \t= x"));
    try std.testing.expect(!isThemeLine("theme"));
    try std.testing.expect(!isThemeLine("themes = 3"));
    try std.testing.expect(!isThemeLine("# theme = \"Nord\""));
    try std.testing.expect(!isThemeLine("effect = \"fire\""));
}

fn readFileMut(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return iohelp.readFileAlloc(allocator, path, 1024 * 1024);
}

pub fn resolveConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |config_home_z| {
        const config_home = std.mem.span(config_home_z);
        const path = try std.fmt.allocPrint(allocator, "{s}/hypr/hyprglaze.toml", .{config_home});
        if (fileExists(path)) return path;
        allocator.free(path);
    }
    if (std.c.getenv("HOME")) |home_z| {
        const home = std.mem.span(home_z);
        const path = try std.fmt.allocPrint(allocator, "{s}/.config/hypr/hyprglaze.toml", .{home});
        if (fileExists(path)) return path;
        allocator.free(path);
    }
    return error.ConfigNotFound;
}

fn fileExists(path: []const u8) bool {
    return iohelp.accessAbsolute(path);
}

test "parse minimal config" {
    const src =
        \\effect = "particles"
        \\shader = "shaders/particles.frag"
        \\theme = "rose-pine"
        \\
    ;
    var cfg = try parse(std.testing.allocator, src, "/tmp/test.toml");
    defer deinit(&cfg, std.testing.allocator);

    try std.testing.expectEqualStrings("particles", cfg.effect);
    try std.testing.expectEqualStrings("shaders/particles.frag", cfg.shader);
    try std.testing.expect(cfg.theme != null);
    try std.testing.expectEqualStrings("rose-pine", cfg.theme.?);
    try std.testing.expectEqualStrings("/tmp/test.toml", cfg.config_path);
}

test "parse config with no theme uses null" {
    const src = "effect = \"windowglow\"\n";
    var cfg = try parse(std.testing.allocator, src, "/tmp/x.toml");
    defer deinit(&cfg, std.testing.allocator);

    try std.testing.expectEqualStrings("windowglow", cfg.effect);
    try std.testing.expect(cfg.theme == null);
    try std.testing.expectEqualStrings("", cfg.shader);
}

test "parse config defaults when fields missing" {
    const src = "";
    var cfg = try parse(std.testing.allocator, src, "/tmp/empty.toml");
    defer deinit(&cfg, std.testing.allocator);

    try std.testing.expectEqualStrings("particles", cfg.effect);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), cfg.transition_duration, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cfg.fade_in, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), cfg.cursor_smoothing, 0.001);
    try std.testing.expectEqual(WorkspaceSlideOverride.auto, cfg.workspace_slide);
    try std.testing.expectEqual(@as(f32, 0), cfg.workspace_duration);
    try std.testing.expectEqual(@as(?workspace_slide.Spring, null), cfg.workspace_spring);
    // Unpinned: wait for the output forever.
    try std.testing.expectEqual(@as(f32, 0), cfg.output_wait);
}

test "output_wait defaults to 60 for a pinned instance and parses either number form" {
    var pinned = try parse(std.testing.allocator, "output = \"DP-1\"\n", "/tmp/p.toml");
    defer deinit(&pinned, std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 60), pinned.output_wait);

    var explicit = try parse(std.testing.allocator, "output = \"DP-1\"\noutput_wait = 7.5\n", "/tmp/e.toml");
    defer deinit(&explicit, std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 7.5), explicit.output_wait, 0.001);

    var whole = try parse(std.testing.allocator, "output_wait = 30\n", "/tmp/w.toml");
    defer deinit(&whole, std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 30), whole.output_wait);
}

test "parse workspace slide overrides" {
    // Suppress the intentional bad-value warnings on a green run.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;

    const src =
        \\[transition]
        \\workspace_slide = "none"
        \\workspace_duration = 0.6
        \\workspace_spring = "1, 71.26, 15.83"
        \\fade_in = 0.4
        \\
    ;
    var cfg = try parse(std.testing.allocator, src, "/tmp/ws.toml");
    defer deinit(&cfg, std.testing.allocator);

    try std.testing.expectEqual(WorkspaceSlideOverride.none, cfg.workspace_slide);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), cfg.fade_in, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), cfg.workspace_duration, 0.001);
    const sp = cfg.workspace_spring.?;
    try std.testing.expectApproxEqAbs(@as(f32, 71.26), sp.stiffness, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 15.83), sp.damping, 0.001);

    // Unknown mode and malformed springs degrade, not fail.
    try std.testing.expectEqual(WorkspaceSlideOverride.auto, parseSlideOverride("diagonal"));
    try std.testing.expectEqual(@as(?workspace_slide.Spring, null), parseSpring("1,2"));
    try std.testing.expectEqual(@as(?workspace_slide.Spring, null), parseSpring("a,b,c"));
    try std.testing.expectEqual(@as(?workspace_slide.Spring, null), parseSpring("1,-5,3"));
    try std.testing.expectEqual(@as(?workspace_slide.Spring, null), parseSpring("1,2,3,4"));
}

test "parse invalid toml returns error" {
    // The parse failure logs a warning by design; suppress it so the build
    // runner doesn't echo a misleading "failed command:" on a green run.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;

    const src = "this is = = not valid\n";
    const result = parse(std.testing.allocator, src, "/tmp/bad.toml");
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "effectParams reads section values" {
    const src =
        \\effect = "particles"
        \\[particles]
        \\count = 100
        \\speed = 0.5
        \\
    ;
    var cfg = try parse(std.testing.allocator, src, "/tmp/e.toml");
    defer deinit(&cfg, std.testing.allocator);

    const params = effectParams(&cfg, "particles");
    try std.testing.expectEqual(@as(i64, 100), params.getInt("count", 0));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), params.getFloat("speed", 0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.23), params.getFloat("missing", 1.23), 0.001);
}

test "expandHome leaves absolute paths alone" {
    const out = try expandHome(std.testing.allocator, "/etc/foo");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("/etc/foo", out);
}
