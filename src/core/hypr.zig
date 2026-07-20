const std = @import("std");
const posix = std.posix;
const libc = @import("io_helper.zig").libc;

pub const CursorPos = struct {
    x: i32,
    y: i32,
};

pub const WindowGeometry = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    address: u64 = 0,
    class: [128]u8 = undefined,
    class_len: u8 = 0,
    title: [128]u8 = undefined,
    title_len: u8 = 0,

    pub fn className(self: *const WindowGeometry) []const u8 {
        return self.class[0..self.class_len];
    }

    pub fn titleStr(self: *const WindowGeometry) []const u8 {
        return self.title[0..self.title_len];
    }
};

pub const max_visible_windows = 32;

pub const VisibleWindows = struct {
    windows: [max_visible_windows]WindowGeometry = undefined,
    count: u8 = 0,
};

pub const MonitorInfo = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    scale: f32,
};

fn parseAddress(val: std.json.Value) u64 {
    if (val != .string) return 0;
    const s = val.string;
    const hex = if (s.len > 2 and s[0] == '0' and s[1] == 'x') s[2..] else s;
    return std.fmt.parseUnsigned(u64, hex, 16) catch 0;
}

pub const HyprIpc = struct {
    socket_path: [256]u8,
    socket_path_len: usize,

    pub fn init() !HyprIpc {
        const xdg_runtime_z = std.c.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;
        const xdg_runtime = std.mem.span(xdg_runtime_z);
        const instance_sig_z = std.c.getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return error.NoHyprlandInstance;
        const instance_sig = std.mem.span(instance_sig_z);

        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/hypr/{s}/.socket.sock", .{ xdg_runtime, instance_sig }) catch return error.PathTooLong;
        // sockaddr.un.path is 108 bytes on Linux (NUL-terminated); reject
        // here instead of panicking on the memcpy at connect time.
        if (path.len >= @typeInfo(std.meta.fieldInfo(std.posix.sockaddr.un, .path).type).array.len)
            return error.PathTooLong;

        var result = HyprIpc{
            .socket_path = undefined,
            .socket_path_len = path.len,
        };
        @memcpy(result.socket_path[0..path.len], path);
        return result;
    }

    fn query(self: *const HyprIpc, command: []const u8, buf: []u8) ![]const u8 {
        var addr: std.posix.sockaddr.un = .{ .path = undefined };
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..self.socket_path_len], self.socket_path[0..self.socket_path_len]);

        const sock_rc = libc.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        if (sock_rc < 0) return error.SocketCreateFailed;
        const sock: i32 = sock_rc;
        defer _ = libc.close(sock);

        if (libc.connect(sock, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) < 0) {
            return error.SocketConnectFailed;
        }
        // Stream sockets may write short, especially for multi-KiB eval
        // commands; loop until the full command is on the wire.
        var written: usize = 0;
        while (written < command.len) {
            const w = std.c.write(sock, command.ptr + written, command.len - written);
            if (w < 0) return error.SocketWriteFailed;
            if (w == 0) return error.SocketWriteFailed;
            written += @intCast(w);
        }

        var total: usize = 0;
        while (total < buf.len) {
            const n = std.posix.read(sock, buf[total..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (n == 0) break;
            total += n;
        }
        return buf[0..total];
    }

    /// Evaluate a Lua chunk in Hyprland's config Lua state. Requires the
    /// Lua config manager (Hyprland ≥0.55). Returns error.EvalRejected
    /// when the compositor reports anything other than "ok" — typically a
    /// Lua error, or a classic hyprlang config where eval is unsupported.
    pub fn eval(self: *const HyprIpc, code: []const u8) !void {
        var cmd_buf: [8192]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "eval {s}", .{code}) catch return error.CodeTooLong;

        var reply_buf: [4096]u8 = undefined;
        const reply = try self.query(cmd, &reply_buf);
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, reply, "\n"), "ok")) {
            std.log.scoped(.hypr_ipc).err("eval rejected: {s}", .{reply});
            return error.EvalRejected;
        }
    }

    pub fn activeWindow(self: *const HyprIpc, allocator: std.mem.Allocator) !?WindowGeometry {
        var buf: [4096]u8 = undefined;
        const response = try self.query("j/activewindow", &buf);
        if (response.len == 0) return null;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
        defer parsed.deinit();

        // Never trust reply shape: an error string, empty object, or a
        // truncated reply (fixed 4KiB buffer) must yield null, not a
        // union-tag panic.
        if (parsed.value != .object) return null;
        const root = parsed.value.object;
        const at = jsonIntPair(root.get("at")) orelse return null;
        const size = jsonIntPair(root.get("size")) orelse return null;

        var result = WindowGeometry{
            .x = at[0],
            .y = at[1],
            .w = size[0],
            .h = size[1],
        };

        if (root.get("address")) |addr_val| result.address = parseAddress(addr_val);

        if (root.get("class")) |class_val| {
            if (class_val == .string) {
                const class = class_val.string;
                const len: u8 = @intCast(@min(class.len, 128));
                @memcpy(result.class[0..len], class[0..len]);
                result.class_len = len;
            }
        }

        if (root.get("title")) |title_val| {
            if (title_val == .string) {
                const title = title_val.string;
                const len: u8 = @intCast(@min(title.len, 128));
                @memcpy(result.title[0..len], title[0..len]);
                result.title_len = len;
            }
        }

        return result;
    }

    pub fn primaryMonitor(self: *const HyprIpc, allocator: std.mem.Allocator) !MonitorInfo {
        var buf: [8192]u8 = undefined;
        const response = try self.query("j/monitors", &buf);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();

        // Use first monitor. Guard every access: an error reply or an
        // empty monitor list must error out, not panic.
        if (parsed.value != .array or parsed.value.array.items.len == 0)
            return error.BadMonitorReply;
        const first = parsed.value.array.items[0];
        if (first != .object) return error.BadMonitorReply;
        const mon = first.object;

        const scale_val = mon.get("scale");
        const scale: f32 = if (scale_val) |sv| switch (sv) {
            .float => @floatCast(sv.float),
            .integer => @floatFromInt(sv.integer),
            else => 1.0,
        } else 1.0;

        return .{
            .x = jsonInt(mon.get("x")) orelse return error.BadMonitorReply,
            .y = jsonInt(mon.get("y")) orelse return error.BadMonitorReply,
            .width = jsonInt(mon.get("width")) orelse return error.BadMonitorReply,
            .height = jsonInt(mon.get("height")) orelse return error.BadMonitorReply,
            .scale = scale,
        };
    }
};

fn jsonInt(val: ?std.json.Value) ?i32 {
    const v = val orelse return null;
    if (v != .integer) return null;
    return std.math.cast(i32, v.integer);
}

test "parseAddress handles prefixed, bare, and malformed input" {
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), parseAddress(.{ .string = "0xdeadbeef" }));
    try std.testing.expectEqual(@as(u64, 0xabc), parseAddress(.{ .string = "abc" }));
    try std.testing.expectEqual(@as(u64, 0), parseAddress(.{ .string = "not-hex" }));
    try std.testing.expectEqual(@as(u64, 0), parseAddress(.{ .integer = 42 }));
}

test "jsonInt rejects wrong tags and overflow" {
    try std.testing.expectEqual(@as(?i32, 42), jsonInt(.{ .integer = 42 }));
    try std.testing.expectEqual(@as(?i32, null), jsonInt(.{ .string = "42" }));
    try std.testing.expectEqual(@as(?i32, null), jsonInt(null));
    try std.testing.expectEqual(@as(?i32, null), jsonInt(.{ .integer = 1 << 40 }));
}

fn jsonIntPair(val: ?std.json.Value) ?[2]i32 {
    const v = val orelse return null;
    if (v != .array or v.array.items.len < 2) return null;
    return .{
        jsonInt(v.array.items[0]) orelse return null,
        jsonInt(v.array.items[1]) orelse return null,
    };
}
