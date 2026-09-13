const std = @import("std");
const posix = std.posix;
const libc = @import("io_helper.zig").libc;
const workspace_slide = @import("workspace_slide.zig");

const log = std.log.scoped(.hypr_ipc);

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
    /// Workspace strip slot: -1 previous, 0 active, +1 next, where
    /// previous/next are the nearest existing workspace ids on this
    /// monitor. Neighbor windows are parked one screen off-screen along
    /// the slide axis so the whole strip moves as one piece on a
    /// workspace switch. During a slide the daemon swaps the bucket
    /// behind the camera for the workspace actually being left (see
    /// main's `captureOutgoing`), since for a multi-step jump that is not
    /// the nearest id.
    rel: i8 = 0,
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
    /// Active workspace id carried with the snapshot (atomic with the
    /// window set, so a workspace switch can never race its geometry).
    /// 0 = unknown: old-format watcher payload or parse failure.
    workspace_id: i64 = 0,
    /// Layout-space origin of the monitor this snapshot describes. Window
    /// rects arrive as global layout coords; subtracting this makes them
    /// surface-local. Carried inside the snapshot so a monitor that moves
    /// can never leave rects rebased against a stale origin.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
};

/// Effective workspace-animation config detected from Hyprland, used to
/// mirror the compositor's own workspace slide. `axis == .none` covers
/// disabled animations and the fade style (no direction to mirror).
pub const WorkspaceAnim = struct {
    axis: workspace_slide.Axis,
    duration: f32,
    ease: workspace_slide.Ease,
};

/// One monitor as Hyprland reports it. Note the mixed units: `width`/`height`
/// are the physical mode in pixels, while `x`/`y` are the *logical* layout
/// origin (a 3840x2160 monitor at scale 1.25 occupies 3072x1728 of layout
/// space, so its right-hand neighbour starts at x=3072). Window and cursor
/// coordinates are logical too, so `x`/`y` are what to subtract; the logical
/// size, if ever needed, is `width / scale`.
pub const MonitorInfo = struct {
    /// Output name, copied inline: it is read out of a std.json tree that
    /// parseMonitor frees before returning.
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    scale: f32,

    pub fn outputName(self: *const MonitorInfo) []const u8 {
        return self.name[0..self.name_len];
    }
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
        // A reply that exactly fills the buffer is indistinguishable from one
        // that was cut short, and silently handing back a truncated JSON body
        // turns into a confusing parse failure several frames later. Say so.
        if (total == buf.len) return error.ReplyTruncated;
        return buf[0..total];
    }

    /// Evaluate a Lua chunk in Hyprland's config Lua state. Requires the
    /// Lua config manager (Hyprland ≥0.55). Returns error.EvalRejected
    /// when the compositor reports anything other than "ok" — typically a
    /// Lua error, or a classic hyprlang config where eval is unsupported.
    /// Upper bound on a chunk this can send. watcher.lua is the only caller
    /// and sits well inside it; the headroom is so its documentation header
    /// never has to be traded against the buffer size.
    pub const max_eval_chunk = eval_cmd_buf_len - "eval ".len;
    const eval_cmd_buf_len = 16384;

    pub fn eval(self: *const HyprIpc, code: []const u8) !void {
        var cmd_buf: [eval_cmd_buf_len]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "eval {s}", .{code}) catch return error.CodeTooLong;

        // Roomy enough for a multi-line Lua traceback: truncating the error
        // reply would itself surface as a bare EvalRejected with no clue why.
        var reply_buf: [8192]u8 = undefined;
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

    /// Detect the workspace animation Hyprland is configured with, so the
    /// slide transition can mirror its direction, duration, and easing.
    /// Spring curves are detected by name only — their parameters are not
    /// exposed over IPC, so hyprutils' defaults are used unless the config
    /// overrides them (`[transition] workspace_spring`).
    pub fn workspaceAnim(self: *const HyprIpc, allocator: std.mem.Allocator) !WorkspaceAnim {
        var buf: [16384]u8 = undefined;
        const response = try self.query("j/animations", &buf);
        return parseWorkspaceAnim(allocator, response);
    }

    /// The monitor to render on. `want` names an output exactly; when it is
    /// null the focused monitor is chosen, falling back to the first enabled
    /// one. Split from `parseMonitor` the same way `workspaceAnim` is split
    /// from `parseWorkspaceAnim`, so the selection rules are unit-testable
    /// without a live compositor.
    pub fn monitor(self: *const HyprIpc, allocator: std.mem.Allocator, want: ?[]const u8) !MonitorInfo {
        // `j/monitors` runs ~1.8KiB per monitor — `availableModes` alone is
        // over a kilobyte — so the old 8KiB buffer truncated from about five
        // monitors up, which is exactly the population this flag serves.
        var buf: [32768]u8 = undefined;
        const response = try self.query("j/monitors", &buf);
        return parseMonitor(allocator, response, want);
    }

    /// Log every output Hyprland currently reports, so a name that matched
    /// nothing can be diagnosed without a second command.
    pub fn logMonitorNames(self: *const HyprIpc, allocator: std.mem.Allocator) void {
        var buf: [32768]u8 = undefined;
        const response = self.query("j/monitors", &buf) catch return;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .array) return;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const n = item.object.get("name") orelse continue;
            if (n != .string) continue;
            const disabled = if (item.object.get("disabled")) |d| d == .bool and d.bool else false;
            log.info("  available output: {s}{s}", .{ n.string, if (disabled) " (disabled)" else "" });
        }
    }
};

/// Pick a monitor out of a `j/monitors` reply.
///
/// A disabled monitor has no `wl_output`, so selecting one would only fail
/// later when the layer surface tries to bind it — they are skipped unless
/// named explicitly.
fn parseMonitor(allocator: std.mem.Allocator, response: []const u8, want: ?[]const u8) !MonitorInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();

    // Guard every access: an error reply or an empty monitor list must error
    // out, not panic.
    if (parsed.value != .array or parsed.value.array.items.len == 0)
        return error.BadMonitorReply;
    const items = parsed.value.array.items;

    if (want) |name| {
        for (items) |item| {
            if (item != .object) continue;
            const n = item.object.get("name") orelse continue;
            if (n == .string and std.mem.eql(u8, n.string, name)) return monitorFromJson(item.object);
        }
        // Never fall back to another monitor here. Reporting one monitor's
        // geometry while the surface lands on a different output is far
        // harder to diagnose than an outright failure.
        return error.MonitorNotFound;
    }

    var first_enabled: ?std.json.ObjectMap = null;
    for (items) |item| {
        if (item != .object) continue;
        const mon = item.object;
        const disabled = if (mon.get("disabled")) |d| d == .bool and d.bool else false;
        if (disabled) continue;
        if (first_enabled == null) first_enabled = mon;
        if (mon.get("focused")) |f| {
            if (f == .bool and f.bool) return monitorFromJson(mon);
        }
    }
    if (first_enabled) |mon| return monitorFromJson(mon);

    if (items[0] != .object) return error.BadMonitorReply;
    return monitorFromJson(items[0].object);
}

fn monitorFromJson(mon: std.json.ObjectMap) !MonitorInfo {
    const scale: f32 = if (mon.get("scale")) |sv| switch (sv) {
        .float => @floatCast(sv.float),
        .integer => @floatFromInt(sv.integer),
        else => 1.0,
    } else 1.0;

    var result = MonitorInfo{
        .x = jsonInt(mon.get("x")) orelse return error.BadMonitorReply,
        .y = jsonInt(mon.get("y")) orelse return error.BadMonitorReply,
        .width = jsonInt(mon.get("width")) orelse return error.BadMonitorReply,
        .height = jsonInt(mon.get("height")) orelse return error.BadMonitorReply,
        .scale = scale,
    };

    // Copy the name rather than borrow it: the JSON tree it points into is
    // freed by the caller's `defer parsed.deinit()` before this value is used.
    if (mon.get("name")) |n| {
        if (n == .string) {
            const len: u8 = @intCast(@min(n.string.len, result.name.len));
            if (len < n.string.len)
                log.warn("output name '{s}' truncated to {d} bytes", .{ n.string, len });
            @memcpy(result.name[0..len], n.string[0..len]);
            result.name_len = len;
        }
    }
    return result;
}

/// Hyprland's built-in `default` bezier — last-resort easing when the
/// configured curve can't be resolved from the reply.
const default_bezier = [4]f32{ 0.0, 0.75, 0.15, 1.0 };

/// Parse a `j/animations` reply: `[[{name,overridden,bezier,enabled,
/// speed,style}, ...], [{name,X0,Y0,X1,Y1}, ...]]`.
fn parseWorkspaceAnim(allocator: std.mem.Allocator, response: []const u8) !WorkspaceAnim {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch
        return error.BadAnimationsReply;
    defer parsed.deinit();

    if (parsed.value != .array or parsed.value.array.items.len < 2) return error.BadAnimationsReply;
    const anims_v = parsed.value.array.items[0];
    const beziers_v = parsed.value.array.items[1];
    if (anims_v != .array or beziers_v != .array) return error.BadAnimationsReply;
    const anims = anims_v.array.items;

    const ws = findAnim(anims, "workspaces") orelse return error.BadAnimationsReply;
    // A non-overridden node reports zeroed speed/bezier; its effective
    // values are inherited from the tree root ("global").
    const effective = if (jsonBool(ws.get("overridden")))
        ws
    else
        findAnim(anims, "global") orelse ws;

    // Style lives on the workspaces node itself (global carries no
    // workspace style); empty means Hyprland's default, which slides.
    const style = jsonString(ws.get("style")) orelse "";
    const enabled = jsonBool(effective.get("enabled"));
    const axis: workspace_slide.Axis = if (!enabled or std.mem.eql(u8, style, "fade"))
        .none
    else if (std.mem.indexOf(u8, style, "vert") != null)
        .vertical
    else
        .horizontal;

    // Hyprland speed unit is 100ms. Springs ignore it, but keep the
    // value: it stays the bezier duration if config later swaps easing.
    const speed = jsonF32(effective.get("speed")) orelse 0;
    const duration: f32 = if (speed > 0) speed * 0.1 else 0.4;

    const bezier_name = jsonString(effective.get("bezier")) orelse "";
    const ease: workspace_slide.Ease = if (std.mem.startsWith(u8, bezier_name, "spring:"))
        .{ .spring = .{} }
    else
        .{ .cubic_bezier = findBezier(beziers_v.array.items, bezier_name) orelse
            findBezier(beziers_v.array.items, "default") orelse default_bezier };

    return .{ .axis = axis, .duration = duration, .ease = ease };
}

fn findAnim(items: []const std.json.Value, name: []const u8) ?std.json.ObjectMap {
    for (items) |item| {
        if (item != .object) continue;
        const n = jsonString(item.object.get("name")) orelse continue;
        if (std.mem.eql(u8, n, name)) return item.object;
    }
    return null;
}

fn findBezier(items: []const std.json.Value, name: []const u8) ?[4]f32 {
    for (items) |item| {
        if (item != .object) continue;
        const n = jsonString(item.object.get("name")) orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        return .{
            jsonF32(item.object.get("X0")) orelse return null,
            jsonF32(item.object.get("Y0")) orelse return null,
            jsonF32(item.object.get("X1")) orelse return null,
            jsonF32(item.object.get("Y1")) orelse return null,
        };
    }
    return null;
}

fn jsonBool(val: ?std.json.Value) bool {
    const v = val orelse return false;
    return v == .bool and v.bool;
}

fn jsonString(val: ?std.json.Value) ?[]const u8 {
    const v = val orelse return null;
    if (v != .string) return null;
    return v.string;
}

fn jsonF32(val: ?std.json.Value) ?f32 {
    const v = val orelse return null;
    return switch (v) {
        .float => @floatCast(v.float),
        .integer => @floatFromInt(v.integer),
        else => null,
    };
}

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

test "parseWorkspaceAnim detects spring slide" {
    const reply =
        \\[[{"name":"global","overridden":true,"bezier":"default","enabled":true,"speed":10.0,"style":""},
        \\  {"name":"workspaces","overridden":true,"bezier":"spring:springy","enabled":true,"speed":1.94,"style":"slide"}],
        \\ [{"name":"default","X0":0.0,"Y0":0.75,"X1":0.15,"Y1":1.0}]]
    ;
    const anim = try parseWorkspaceAnim(std.testing.allocator, reply);
    try std.testing.expectEqual(workspace_slide.Axis.horizontal, anim.axis);
    try std.testing.expect(anim.ease == .spring);
    try std.testing.expectApproxEqAbs(@as(f32, 0.194), anim.duration, 0.001);
}

test "parseWorkspaceAnim resolves bezier points and vertical style" {
    const reply =
        \\[[{"name":"workspaces","overridden":true,"bezier":"easeOutQuint","enabled":true,"speed":6.0,"style":"slidefadevert"}],
        \\ [{"name":"easeOutQuint","X0":0.23,"Y0":1.0,"X1":0.32,"Y1":1.0}]]
    ;
    const anim = try parseWorkspaceAnim(std.testing.allocator, reply);
    try std.testing.expectEqual(workspace_slide.Axis.vertical, anim.axis);
    try std.testing.expect(anim.ease == .cubic_bezier);
    try std.testing.expectApproxEqAbs(@as(f32, 0.23), anim.ease.cubic_bezier[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), anim.duration, 0.001);
}

test "parseWorkspaceAnim inherits from global when not overridden" {
    const reply =
        \\[[{"name":"global","overridden":true,"bezier":"default","enabled":true,"speed":10.0,"style":""},
        \\  {"name":"workspaces","overridden":false,"bezier":"","enabled":true,"speed":0.0,"style":""}],
        \\ [{"name":"default","X0":0.0,"Y0":0.75,"X1":0.15,"Y1":1.0}]]
    ;
    const anim = try parseWorkspaceAnim(std.testing.allocator, reply);
    // Empty style = Hyprland's default workspace behavior: slide.
    try std.testing.expectEqual(workspace_slide.Axis.horizontal, anim.axis);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), anim.duration, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), anim.ease.cubic_bezier[1], 0.001);
}

test "parseWorkspaceAnim fade or disabled means no slide axis" {
    const fade =
        \\[[{"name":"workspaces","overridden":true,"bezier":"default","enabled":true,"speed":2.0,"style":"fade"}],[]]
    ;
    try std.testing.expectEqual(
        workspace_slide.Axis.none,
        (try parseWorkspaceAnim(std.testing.allocator, fade)).axis,
    );
    const off =
        \\[[{"name":"workspaces","overridden":true,"bezier":"default","enabled":false,"speed":2.0,"style":"slide"}],[]]
    ;
    const anim = try parseWorkspaceAnim(std.testing.allocator, off);
    try std.testing.expectEqual(workspace_slide.Axis.none, anim.axis);
    // Unknown bezier with an empty list falls back to the built-in default.
    try std.testing.expectApproxEqAbs(default_bezier[3], anim.ease.cubic_bezier[3], 0.001);
}

test "parseWorkspaceAnim rejects malformed replies" {
    try std.testing.expectError(error.BadAnimationsReply, parseWorkspaceAnim(std.testing.allocator, "unknown request"));
    try std.testing.expectError(error.BadAnimationsReply, parseWorkspaceAnim(std.testing.allocator, "[[]]"));
    try std.testing.expectError(error.BadAnimationsReply, parseWorkspaceAnim(std.testing.allocator, "[[],[]]"));
}

// Two monitors side by side. The second is focused and carries the non-zero
// origin, so the fixture distinguishes "focused" from "first" and logical
// origin from physical size in one shot.
const two_monitors =
    \\[{"id":0,"name":"DP-1","width":3840,"height":2160,"x":0,"y":0,"scale":1.25,"focused":false,"disabled":false},
    \\ {"id":1,"name":"HDMI-A-1","width":1920,"height":1080,"x":3072,"y":0,"scale":1.0,"focused":true,"disabled":false}]
;

test "parseMonitor selects by exact name" {
    const mon = try parseMonitor(std.testing.allocator, two_monitors, "DP-1");
    try std.testing.expectEqualStrings("DP-1", mon.outputName());
    try std.testing.expectEqual(@as(i32, 0), mon.x);
    try std.testing.expectEqual(@as(i32, 3840), mon.width);
    try std.testing.expectApproxEqAbs(@as(f32, 1.25), mon.scale, 0.001);

    const other = try parseMonitor(std.testing.allocator, two_monitors, "HDMI-A-1");
    try std.testing.expectEqualStrings("HDMI-A-1", other.outputName());
    try std.testing.expectEqual(@as(i32, 3072), other.x);
}

test "parseMonitor errors rather than falling back on an unknown name" {
    // Silently substituting monitor[0] would report one monitor's geometry
    // while the surface landed on another output.
    try std.testing.expectError(
        error.MonitorNotFound,
        parseMonitor(std.testing.allocator, two_monitors, "DP-9"),
    );
}

test "parseMonitor without a name prefers the focused monitor over the first" {
    const mon = try parseMonitor(std.testing.allocator, two_monitors, null);
    try std.testing.expectEqualStrings("HDMI-A-1", mon.outputName());
}

test "parseMonitor without a name falls back to the first enabled monitor" {
    const none_focused =
        \\[{"name":"DP-1","width":1920,"height":1080,"x":0,"y":0,"scale":1.0,"focused":false},
        \\ {"name":"DP-2","width":1920,"height":1080,"x":1920,"y":0,"scale":1.0,"focused":false}]
    ;
    const mon = try parseMonitor(std.testing.allocator, none_focused, null);
    try std.testing.expectEqualStrings("DP-1", mon.outputName());
}

test "parseMonitor skips disabled monitors" {
    // A disabled monitor has no wl_output, so choosing one guarantees an
    // OutputNotFound when the layer surface tries to bind it.
    const with_disabled =
        \\[{"name":"DP-1","width":1920,"height":1080,"x":0,"y":0,"scale":1.0,"disabled":true},
        \\ {"name":"DP-2","width":2560,"height":1440,"x":0,"y":0,"scale":1.0,"disabled":false}]
    ;
    const mon = try parseMonitor(std.testing.allocator, with_disabled, null);
    try std.testing.expectEqualStrings("DP-2", mon.outputName());
    // ...but an explicit name still wins, so a disabled output can be named.
    const named = try parseMonitor(std.testing.allocator, with_disabled, "DP-1");
    try std.testing.expectEqualStrings("DP-1", named.outputName());
}

test "parseMonitor accepts integer and float scales" {
    const int_scale =
        \\[{"name":"DP-1","width":1920,"height":1080,"x":0,"y":0,"scale":2}]
    ;
    const mon = try parseMonitor(std.testing.allocator, int_scale, null);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), mon.scale, 0.001);

    const no_scale =
        \\[{"name":"DP-1","width":1920,"height":1080,"x":0,"y":0}]
    ;
    const dflt = try parseMonitor(std.testing.allocator, no_scale, null);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dflt.scale, 0.001);
}

test "parseMonitor rejects malformed replies" {
    try std.testing.expectError(error.BadMonitorReply, parseMonitor(std.testing.allocator, "[]", null));
    try std.testing.expectError(error.BadMonitorReply, parseMonitor(std.testing.allocator, "{}", null));
    // A missing coordinate must error, not default to zero: a silent 0 would
    // put the wallpaper's idea of the origin somewhere it is not.
    const no_x =
        \\[{"name":"DP-1","width":1920,"height":1080,"y":0,"scale":1.0}]
    ;
    try std.testing.expectError(error.BadMonitorReply, parseMonitor(std.testing.allocator, no_x, null));
    try std.testing.expectError(error.SyntaxError, parseMonitor(std.testing.allocator, "unknown request", null));
}

test "parseMonitor truncates an over-long name instead of failing" {
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const long = "A" ** 100;
    const reply = "[{\"name\":\"" ++ long ++ "\",\"width\":1,\"height\":1,\"x\":0,\"y\":0,\"scale\":1.0}]";
    const mon = try parseMonitor(std.testing.allocator, reply, null);
    try std.testing.expectEqual(@as(u8, 64), mon.name_len);
    try std.testing.expectEqualStrings(long[0..64], mon.outputName());
}

fn jsonIntPair(val: ?std.json.Value) ?[2]i32 {
    const v = val orelse return null;
    if (v != .array or v.array.items.len < 2) return null;
    return .{
        jsonInt(v.array.items[0]) orelse return null,
        jsonInt(v.array.items[1]) orelse return null,
    };
}
