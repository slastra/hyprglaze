const std = @import("std");

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

pub fn loadTheme(allocator: std.mem.Allocator, theme_name: []const u8) !Palette {
    const themes_path = getThemesPath(allocator) catch |err| {
        std.debug.print("Failed to resolve themes path: {}\n", .{err});
        return err;
    };
    defer allocator.free(themes_path);

    const file = std.fs.openFileAbsolute(themes_path, .{}) catch |err| {
        std.debug.print("Failed to open {s}: {}\n", .{ themes_path, err });
        std.debug.print("Download Gogh themes: bgen --fetch, or manually place themes.json\n", .{});
        return err;
    };
    defer file.close();

    const data = file.readToEndAlloc(allocator, 64 * 1024 * 1024) catch |err| {
        std.debug.print("Failed to read themes.json: {}\n", .{err});
        return err;
    };
    defer allocator.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| {
        std.debug.print("Failed to parse themes.json: {}\n", .{err});
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

    std.debug.print("Theme '{s}' not found in themes.json\n", .{theme_name});
    return error.ThemeNotFound;
}

pub fn listThemes(allocator: std.mem.Allocator) !void {
    const themes_path = try getThemesPath(allocator);
    defer allocator.free(themes_path);

    const file = try std.fs.openFileAbsolute(themes_path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
    defer parsed.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
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

fn getThemesPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |config_home| {
        return std.fmt.allocPrint(allocator, "{s}/bgen/themes.json", .{config_home});
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.config/bgen/themes.json", .{home});
    }
    return error.NoHomeDir;
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
