const std = @import("std");
const posix = std.posix;
const iohelp = @import("io_helper.zig");
const libc = iohelp.libc;

const log = std.log.scoped(.hypr_events);

/// Subscribes to Hyprland's `.socket2.sock` event stream in a background
/// thread. The main thread reads atomic snapshot fields to learn about
/// state changes without polling `hyprctl j/activewindow` and
/// `j/activeworkspace`.
///
/// Geometry still requires polling `j/clients` because Hyprland emits no
/// events during interactive drag/resize.
pub const HyprEvents = struct {
    socket_path: [256]u8,
    socket_path_len: usize,

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    sock_fd: std.atomic.Value(i32) = .init(-1),

    /// Address of the currently focused window. Updated from `activewindowv2`.
    /// 0 = no focus / not yet known. Bootstrap by storing an initial value
    /// from a one-time `j/activewindow` query before starting the reader.
    focused_address: std.atomic.Value(u64) = .init(0),

    /// Active workspace ID. Updated from `workspacev2` and `focusedmonv2`.
    /// -1 = unknown until the first event arrives.
    workspace_id: std.atomic.Value(i64) = .init(-1),

    /// Set when the visible-windows list may have changed: open/close,
    /// move-to-workspace, fullscreen, float toggle, group changes,
    /// minimization, workspace switches, monitor focus changes. Cleared
    /// by `takeDirty`. Defaults true so the first poll picks up any state
    /// that drifted between bootstrap and reader connect.
    windows_dirty: std.atomic.Value(bool) = .init(true),

    /// Set when the focused workspace or monitor changed.
    workspace_dirty: std.atomic.Value(bool) = .init(false),

    /// Set when monitors are added or removed.
    monitor_dirty: std.atomic.Value(bool) = .init(false),

    /// Set when Hyprland reloaded its own config (informational — our
    /// own config watcher handles our config file).
    config_dirty: std.atomic.Value(bool) = .init(false),

    pub fn init() !HyprEvents {
        const xdg_z = std.c.getenv("XDG_RUNTIME_DIR") orelse return error.NoXdgRuntime;
        const xdg = std.mem.span(xdg_z);
        const sig_z = std.c.getenv("HYPRLAND_INSTANCE_SIGNATURE") orelse return error.NoHyprlandInstance;
        const sig = std.mem.span(sig_z);

        var self = HyprEvents{
            .socket_path = undefined,
            .socket_path_len = 0,
        };
        const path = std.fmt.bufPrint(&self.socket_path, "{s}/hypr/{s}/.socket2.sock", .{ xdg, sig }) catch return error.PathTooLong;
        self.socket_path_len = path.len;
        return self;
    }

    pub fn start(self: *HyprEvents) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, readerLoop, .{self});
    }

    pub fn deinit(self: *HyprEvents) void {
        self.running.store(false, .release);
        // Wake any blocked read() so the thread can observe `running=false`.
        const fd = self.sock_fd.load(.acquire);
        if (fd >= 0) {
            _ = libc.shutdown(fd, libc.SHUT_RDWR);
        }
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub const Dirty = struct {
        windows: bool = false,
        workspace: bool = false,
        monitor: bool = false,
        config: bool = false,
    };

    /// Snapshot and clear all dirty flags atomically. The flags rearm on
    /// the next event of the corresponding kind.
    pub fn takeDirty(self: *HyprEvents) Dirty {
        return .{
            .windows = self.windows_dirty.swap(false, .acq_rel),
            .workspace = self.workspace_dirty.swap(false, .acq_rel),
            .monitor = self.monitor_dirty.swap(false, .acq_rel),
            .config = self.config_dirty.swap(false, .acq_rel),
        };
    }

    pub fn focusedAddress(self: *const HyprEvents) u64 {
        return self.focused_address.load(.acquire);
    }

    pub fn workspaceId(self: *const HyprEvents) i64 {
        return self.workspace_id.load(.acquire);
    }
};

fn readerLoop(self: *HyprEvents) void {
    var read_buf: [8192]u8 = undefined;
    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;

    while (self.running.load(.acquire)) {
        const fd = connectSocket(self) catch |err| {
            log.warn("socket2 connect failed: {} — retrying in 1s", .{err});
            iohelp.sleepNs(std.time.ns_per_s);
            continue;
        };

        self.sock_fd.store(fd, .release);
        log.info("socket2 connected", .{});

        // Mark windows dirty on (re)connect — state may have drifted while
        // the events stream was down. Workspace/monitor dirty are NOT set
        // here to avoid a spurious "monitor topology changed" log on every
        // reconnect; those flags only fire from real events.
        self.windows_dirty.store(true, .release);

        line_len = 0;
        readSocket(self, fd, &read_buf, &line_buf, &line_len);

        _ = self.sock_fd.swap(-1, .acq_rel);
        _ = libc.close(fd);
    }
}

fn readSocket(
    self: *HyprEvents,
    fd: i32,
    read_buf: *[8192]u8,
    line_buf: *[4096]u8,
    line_len: *usize,
) void {
    while (self.running.load(.acquire)) {
        const n = posix.read(fd, read_buf) catch |err| {
            log.warn("socket2 read error: {}", .{err});
            return;
        };
        if (n == 0) {
            // EOF — Hyprland disconnected, or stop() shut the socket down.
            return;
        }

        for (read_buf[0..n]) |b| {
            if (b == '\n') {
                handleLine(self, line_buf[0..line_len.*]);
                line_len.* = 0;
            } else if (line_len.* < line_buf.len) {
                line_buf[line_len.*] = b;
                line_len.* += 1;
            }
            // Overlong lines silently truncate. Hyprland event lines are
            // short; only window titles can grow, and we don't parse those.
        }
    }
}

fn connectSocket(self: *HyprEvents) !i32 {
    var addr: posix.sockaddr.un = .{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..self.socket_path_len], self.socket_path[0..self.socket_path_len]);

    const fd_rc = libc.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    if (fd_rc < 0) return error.SocketCreateFailed;
    const fd: i32 = fd_rc;
    errdefer _ = libc.close(fd);
    if (libc.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) < 0) return error.SocketConnectFailed;
    return fd;
}

fn handleLine(self: *HyprEvents, line: []const u8) void {
    const sep = std.mem.indexOf(u8, line, ">>") orelse return;
    const evt = line[0..sep];
    const data = line[sep + 2 ..];

    if (std.mem.eql(u8, evt, "activewindowv2")) {
        // data: hex address (no `0x` prefix) or empty when nothing focused.
        self.focused_address.store(parseHexAddr(data), .release);
        return;
    }

    if (std.mem.eql(u8, evt, "workspacev2")) {
        // data: WSID,WSNAME
        const comma = std.mem.indexOfScalar(u8, data, ',') orelse data.len;
        const id = std.fmt.parseInt(i64, data[0..comma], 10) catch -1;
        if (id >= 0) self.workspace_id.store(id, .release);
        self.workspace_dirty.store(true, .release);
        self.windows_dirty.store(true, .release);
        return;
    }

    if (std.mem.eql(u8, evt, "focusedmonv2")) {
        // data: MONNAME,WSID — workspace ID is the trailing field.
        const comma = std.mem.lastIndexOfScalar(u8, data, ',') orelse return;
        const id = std.fmt.parseInt(i64, data[comma + 1 ..], 10) catch -1;
        if (id >= 0) self.workspace_id.store(id, .release);
        self.workspace_dirty.store(true, .release);
        self.windows_dirty.store(true, .release);
        return;
    }

    // Lifecycle / state-change events that affect the visible-windows list
    // or per-window metadata. We only need a dirty flag — the next poll
    // re-queries `j/clients`.
    const window_events = [_][]const u8{
        "openwindow",
        "closewindow",
        "movewindow",
        "movewindowv2",
        "windowtitle",
        "windowtitlev2",
        "fullscreen",
        "minimized",
        "pin",
        "changefloatingmode",
        "moveintogroup",
        "moveoutofgroup",
        "togglegroup",
        "kill",
        "urgent",
    };
    inline for (window_events) |w| {
        if (std.mem.eql(u8, evt, w)) {
            self.windows_dirty.store(true, .release);
            return;
        }
    }

    const workspace_events = [_][]const u8{
        "workspace", // pre-v2 (still emitted alongside v2)
        "focusedmon", // pre-v2
        "createworkspace",
        "createworkspacev2",
        "destroyworkspace",
        "destroyworkspacev2",
        "moveworkspace",
        "moveworkspacev2",
        "renameworkspace",
        "activespecial",
        "activespecialv2",
    };
    inline for (workspace_events) |w| {
        if (std.mem.eql(u8, evt, w)) {
            self.workspace_dirty.store(true, .release);
            self.windows_dirty.store(true, .release);
            return;
        }
    }

    const monitor_events = [_][]const u8{
        "monitoradded",
        "monitoraddedv2",
        "monitorremoved",
        "monitorremovedv2",
    };
    inline for (monitor_events) |w| {
        if (std.mem.eql(u8, evt, w)) {
            self.monitor_dirty.store(true, .release);
            return;
        }
    }

    if (std.mem.eql(u8, evt, "configreloaded")) {
        self.config_dirty.store(true, .release);
        return;
    }

    // Ignored: bell, screencast[v2], submap, activelayout, openlayer,
    // closelayer, lockgroups, custom, ignoregrouplock — none affect what
    // we render.
}

fn parseHexAddr(s: []const u8) u64 {
    if (s.len == 0) return 0;
    const hex = if (s.len > 2 and s[0] == '0' and s[1] == 'x') s[2..] else s;
    return std.fmt.parseUnsigned(u64, hex, 16) catch 0;
}

// Tests cover the line parser only. Threading and socket connection
// require a live Hyprland instance and are exercised manually.

fn testEvents() HyprEvents {
    return .{
        .socket_path = undefined,
        .socket_path_len = 0,
        .windows_dirty = .init(false),
    };
}

test "handleLine activewindowv2 sets focus address" {
    var ev = testEvents();
    handleLine(&ev, "activewindowv2>>64cea2525760");
    try std.testing.expectEqual(@as(u64, 0x64cea2525760), ev.focusedAddress());
}

test "handleLine activewindowv2 with 0x prefix" {
    var ev = testEvents();
    handleLine(&ev, "activewindowv2>>0xdeadbeef");
    try std.testing.expectEqual(@as(u64, 0xdeadbeef), ev.focusedAddress());
}

test "handleLine activewindowv2 empty clears focus" {
    var ev = testEvents();
    ev.focused_address.store(0xabc, .release);
    handleLine(&ev, "activewindowv2>>");
    try std.testing.expectEqual(@as(u64, 0), ev.focusedAddress());
}

test "handleLine workspacev2 updates id and dirties windows + workspace" {
    var ev = testEvents();
    handleLine(&ev, "workspacev2>>5,coding");
    try std.testing.expectEqual(@as(i64, 5), ev.workspaceId());
    const d = ev.takeDirty();
    try std.testing.expect(d.workspace);
    try std.testing.expect(d.windows);
    try std.testing.expect(!d.monitor);
}

test "handleLine focusedmonv2 reads ws id from trailing field" {
    var ev = testEvents();
    handleLine(&ev, "focusedmonv2>>HDMI-A-1,3");
    try std.testing.expectEqual(@as(i64, 3), ev.workspaceId());
}

test "handleLine openwindow only dirties windows" {
    var ev = testEvents();
    handleLine(&ev, "openwindow>>64ce,1,Alacritty,Alacritty");
    const d = ev.takeDirty();
    try std.testing.expect(d.windows);
    try std.testing.expect(!d.workspace);
    try std.testing.expect(!d.monitor);
}

test "handleLine monitoraddedv2 only dirties monitor" {
    var ev = testEvents();
    handleLine(&ev, "monitoraddedv2>>0,DP-1,2560x1440@165");
    const d = ev.takeDirty();
    try std.testing.expect(d.monitor);
    try std.testing.expect(!d.windows);
    try std.testing.expect(!d.workspace);
}

test "handleLine configreloaded dirties config only" {
    var ev = testEvents();
    handleLine(&ev, "configreloaded>>");
    const d = ev.takeDirty();
    try std.testing.expect(d.config);
    try std.testing.expect(!d.windows);
}

test "handleLine ignored events leave dirty flags clear" {
    var ev = testEvents();
    handleLine(&ev, "submap>>resize");
    handleLine(&ev, "bell>>");
    handleLine(&ev, "screencast>>1,0");
    handleLine(&ev, "activelayout>>kbd,us");
    const d = ev.takeDirty();
    try std.testing.expect(!d.windows);
    try std.testing.expect(!d.workspace);
    try std.testing.expect(!d.monitor);
    try std.testing.expect(!d.config);
}

test "handleLine malformed lines do not crash" {
    var ev = testEvents();
    handleLine(&ev, "");
    handleLine(&ev, "noseparator");
    handleLine(&ev, ">>only-data");
    handleLine(&ev, "workspacev2>>notanumber,name");
    handleLine(&ev, "focusedmonv2>>nocomma");
}

test "takeDirty clears flags" {
    var ev = testEvents();
    handleLine(&ev, "openwindow>>1,1,X,X");
    handleLine(&ev, "monitoraddedv2>>0,DP-1,1920x1080@60");
    const d1 = ev.takeDirty();
    try std.testing.expect(d1.windows);
    try std.testing.expect(d1.monitor);

    const d2 = ev.takeDirty();
    try std.testing.expect(!d2.windows);
    try std.testing.expect(!d2.monitor);
}
