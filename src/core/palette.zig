const std = @import("std");
const iohelp = @import("io_helper.zig");

const log = std.log.scoped(.palette);

const embedded_themes_json = @embedFile("../data/themes.json");

pub const max_palette_colors = 16;

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,

    pub fn fromHex(hex: []const u8) !Color {
        // Accept "#RRGGBB" or "RRGGBB"
        const s = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
        if (s.len != 6) return error.InvalidHexColor;

        const r = std.fmt.parseUnsigned(u8, s[0..2], 16) catch return error.InvalidHexColor;
        const g = std.fmt.parseUnsigned(u8, s[2..4], 16) catch return error.InvalidHexColor;
        const b = std.fmt.parseUnsigned(u8, s[4..6], 16) catch return error.InvalidHexColor;

        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
        };
    }
};

pub const Palette = struct {
    name: [128]u8 = undefined,
    name_len: u8 = 0,
    colors: [max_palette_colors]Color = undefined,
    color_count: u8 = 0,
    background: Color = .{ .r = 0, .g = 0, .b = 0 },
    foreground: Color = .{ .r = 1, .g = 1, .b = 1 },

    pub fn themeName(self: *const Palette) []const u8 {
        return self.name[0..self.name_len];
    }
};

const color_keys = [16][]const u8{
    "color_01", "color_02", "color_03", "color_04",
    "color_05", "color_06", "color_07", "color_08",
    "color_09", "color_10", "color_11", "color_12",
    "color_13", "color_14", "color_15", "color_16",
};

const ThemesData = struct {
    data: []const u8,
    owned: bool,
};

/// Returns the themes.json payload. Prefers a user override at
/// `$XDG_CONFIG_HOME/hyprglaze/themes.json` (or `~/.config/hyprglaze/themes.json`);
/// otherwise falls back to the embedded Gogh snapshot baked in at build time.
fn readThemesData(allocator: std.mem.Allocator) !ThemesData {
    var path_buf: [512]u8 = undefined;
    const override_path = blk: {
        if (std.c.getenv("XDG_CONFIG_HOME")) |config_home_z| {
            const config_home = std.mem.span(config_home_z);
            break :blk std.fmt.bufPrint(&path_buf, "{s}/hyprglaze/themes.json", .{config_home}) catch null;
        }
        if (std.c.getenv("HOME")) |home_z| {
            const home = std.mem.span(home_z);
            break :blk std.fmt.bufPrint(&path_buf, "{s}/.config/hyprglaze/themes.json", .{home}) catch null;
        }
        break :blk null;
    };

    if (override_path) |p| {
        if (iohelp.readFileAlloc(allocator, p, 64 * 1024 * 1024)) |data| {
            log.info("using theme override: {s}", .{p});
            return .{ .data = data, .owned = true };
        } else |_| {}
    }

    return .{ .data = embedded_themes_json, .owned = false };
}

pub fn loadTheme(allocator: std.mem.Allocator, theme_name: []const u8) !Palette {
    const td = try readThemesData(allocator);
    defer if (td.owned) allocator.free(td.data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, td.data, .{}) catch |err| {
        log.err("failed to parse themes.json: {}", .{err});
        return err;
    };
    defer parsed.deinit();

    const themes = parsed.value.array.items;

    // Case-insensitive name search
    for (themes) |theme| {
        const obj = theme.object;
        const name_val = obj.get("name") orelse continue;
        if (name_val != .string) continue;

        if (eqlInsensitive(name_val.string, theme_name)) {
            return parseTheme(obj, name_val.string);
        }
    }

    log.err("theme '{s}' not found", .{theme_name});
    return error.ThemeNotFound;
}

pub fn listThemes(allocator: std.mem.Allocator) !void {
    const td = try readThemesData(allocator);
    defer if (td.owned) allocator.free(td.data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, td.data, .{});
    defer parsed.deinit();

    var stdout_buf: [4096]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var count: usize = 0;
    for (parsed.value.array.items) |theme| {
        const obj = theme.object;
        if (obj.get("name")) |name_val| {
            if (name_val == .string) {
                try stdout.print("{s}\n", .{name_val.string});
                count += 1;
            }
        }
    }
    try stdout.print("\n{d} themes available\n", .{count});
    try stdout.flush();
}

fn parseTheme(obj: std.json.ObjectMap, name: []const u8) Palette {
    var palette = Palette{};

    const name_len: u8 = @intCast(@min(name.len, 128));
    @memcpy(palette.name[0..name_len], name[0..name_len]);
    palette.name_len = name_len;

    // Parse 16 colors
    for (color_keys) |key| {
        if (obj.get(key)) |val| {
            if (val == .string) {
                if (Color.fromHex(val.string)) |color| {
                    palette.colors[palette.color_count] = color;
                    palette.color_count += 1;
                } else |_| {}
            }
        }
    }

    // Parse background/foreground
    if (obj.get("background")) |val| {
        if (val == .string) {
            palette.background = Color.fromHex(val.string) catch palette.background;
        }
    }
    if (obj.get("foreground")) |val| {
        if (val == .string) {
            palette.foreground = Color.fromHex(val.string) catch palette.foreground;
        }
    }

    return palette;
}

fn eqlInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(ch: u8) u8 {
    return if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
}

test "Color.fromHex parses RRGGBB with and without #" {
    const c1 = try Color.fromHex("#ff8040");
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c1.r, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), c1.g, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), c1.b, 0.01);

    const c2 = try Color.fromHex("000000");
    try std.testing.expectEqual(@as(f32, 0.0), c2.r);
}

test "Color.fromHex rejects invalid input" {
    try std.testing.expectError(error.InvalidHexColor, Color.fromHex("#xyz"));
    try std.testing.expectError(error.InvalidHexColor, Color.fromHex("#abcd"));
    try std.testing.expectError(error.InvalidHexColor, Color.fromHex(""));
}

test "parseTheme extracts colors and bg/fg from JSON object" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test-theme",
        \\  "background": "#101010",
        \\  "foreground": "#e0e0e0",
        \\  "color_01": "#ff0000",
        \\  "color_02": "#00ff00",
        \\  "color_03": "#0000ff"
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();

    const pal = parseTheme(parsed.value.object, "test-theme");
    try std.testing.expectEqual(@as(u8, 3), pal.color_count);
    try std.testing.expectEqualStrings("test-theme", pal.themeName());
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pal.colors[0].r, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0 / 255.0), pal.background.r, 0.01);
}

test "eqlInsensitive matches case-insensitively" {
    try std.testing.expect(eqlInsensitive("Rose-Pine", "rose-pine"));
    try std.testing.expect(eqlInsensitive("DRACULA", "dracula"));
    try std.testing.expect(!eqlInsensitive("rose", "roses"));
}
