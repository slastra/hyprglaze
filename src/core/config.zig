const std = @import("std");
const toml = @import("toml");

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
                    .bool => val.bool,
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
    transition_duration: f32,
    cursor_smoothing: f32,
    geometry_smoothing: f32,
    config_path: []const u8,

    // Raw TOML data retained for effect params
    raw_arena: ?std.heap.ArenaAllocator = null,
    raw_table: ?toml.Table = null,
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    const expanded = try expandHome(allocator, path);
    defer allocator.free(expanded);

    const data = readFile(allocator, expanded) catch |err| {
        std.debug.print("Failed to read config '{s}': {}\n", .{ expanded, err });
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
                .parse => |pos| std.debug.print("TOML parse error at line {d} (pos {d})\n", .{ pos.line, pos.pos }),
                .struct_mapping => std.debug.print("TOML struct mapping error\n", .{}),
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

    // Read core sections
    const transition_params = effectParamsFromTable(t, "transition");
    const cursor_params = effectParamsFromTable(t, "cursor");
    const geometry_params = effectParamsFromTable(t, "geometry");

    return .{
        .effect = try allocator.dupe(u8, effect_name),
        .shader = try allocator.dupe(u8, shader_str),
        .theme = if (theme_str) |ts| try allocator.dupe(u8, ts) else null,
        .transition_duration = transition_params.getFloat("duration", 0.3),
        .cursor_smoothing = cursor_params.getFloat("smoothing", 0.15),
        .geometry_smoothing = geometry_params.getFloat("smoothing", 0.12),
        .config_path = try allocator.dupe(u8, source_path),
        .raw_arena = result.arena,
        .raw_table = t,
    };
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
    allocator.free(self.config_path);
    if (self.raw_arena) |*arena| arena.deinit();
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, 1024 * 1024);
}

pub fn expandHome(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (path.len >= 1 and path[0] == '~') {
        const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ home, path[1..] });
    }
    return allocator.dupe(u8, path);
}

pub fn resolveConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |config_home| {
        const path = try std.fmt.allocPrint(allocator, "{s}/hypr/hyprglaze.toml", .{config_home});
        if (fileExists(path)) return path;
        allocator.free(path);
    }
    if (std.posix.getenv("HOME")) |home| {
        const path = try std.fmt.allocPrint(allocator, "{s}/.config/hypr/hyprglaze.toml", .{home});
        if (fileExists(path)) return path;
        allocator.free(path);
    }
    return error.ConfigNotFound;
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}
