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
        if (std.c.write(sock, command.ptr, command.len) < 0) return error.SocketWriteFailed;

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

        const root = parsed.value.object;
        const at = root.get("at") orelse return null;
        const size = root.get("size") orelse return null;

        var result = WindowGeometry{
            .x = @intCast(at.array.items[0].integer),
            .y = @intCast(at.array.items[1].integer),
            .w = @intCast(size.array.items[0].integer),
            .h = @intCast(size.array.items[1].integer),
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

        // Use first monitor
        const mon = parsed.value.array.items[0].object;
        const scale_val = mon.get("scale");
        const scale: f32 = if (scale_val) |sv| switch (sv) {
            .float => @floatCast(sv.float),
            .integer => @floatFromInt(sv.integer),
            else => 1.0,
        } else 1.0;

        return .{
            .x = @intCast(mon.get("x").?.integer),
            .y = @intCast(mon.get("y").?.integer),
            .width = @intCast(mon.get("width").?.integer),
            .height = @intCast(mon.get("height").?.integer),
            .scale = scale,
        };
    }
};
