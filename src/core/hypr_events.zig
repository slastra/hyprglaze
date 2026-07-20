const std = @import("std");
const posix = std.posix;
const iohelp = @import("io_helper.zig");
const hypr = @import("hypr.zig");
const libc = iohelp.libc;

const log = std.log.scoped(.hypr_events);

/// Subscribes to Hyprland's `.socket2.sock` event stream in a background
/// thread. All window/cursor state arrives as push: the in-compositor Lua
/// watcher (`watcher.lua`, installed via `HyprIpc.eval`) emits
/// `custom>>hg:*` events, so the main thread never polls `.socket.sock`.
///
///   hg:cur:<x>,<y>   cursor moved — stored in atomics
///   hg:geo:<records> visible-window snapshot — stored under mutex,
///                    generation counter bumped
///   hg:hb            watcher heartbeat (~2s) — timestamp stored so the
///                    main loop can detect a dead watcher and reinstall
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

    /// Cursor position in layout coordinates, from `hg:cur` events,
    /// packed x-high/y-low into one atomic so a reader can never observe
    /// a torn (new x, old y) pair. The watcher emits unconditionally on
    /// its first tick after install, so this is valid within ~16ms of
    /// startup.
    cursor_xy: std.atomic.Value(u64) = .init(0),

    /// Visible-window snapshot from the latest `hg:geo` event. Written by
    /// the reader thread under `snapshot_mutex`; `snapshot_gen` is bumped
    /// after each write so the main thread can copy only when it changed.
    /// The lock is a spin-on-tryLock: both critical sections are a single
    /// struct copy (~7KB) and contention is at most 60Hz vs frame rate.
    snapshot_mutex: std.atomic.Mutex = .unlocked,
    snapshot: hypr.VisibleWindows = .{},
    snapshot_gen: std.atomic.Value(u64) = .init(0),

    /// Millisecond timestamp of the last `hg:hb` heartbeat. Seeded by
    /// `noteHeartbeat` when the watcher is (re)installed so a fresh
    /// install isn't immediately flagged as dead.
    last_hb_ms: std.atomic.Value(i64) = .init(0),

    /// Set when the socket2 connection is (re)established. The watcher
    /// lives in the compositor and keeps running while we're disconnected,
    /// but its change-only events may have been missed — the main loop
    /// reinstalls the watcher (idempotent), forcing a full re-emit.
    resync_needed: std.atomic.Value(bool) = .init(false),

    /// Set when monitors are added or removed.
    monitor_dirty: std.atomic.Value(bool) = .init(false),

    /// Set when Hyprland reloaded its config. The config Lua state is
    /// recreated on reload, killing the watcher — the main loop reinstalls.
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
        // sockaddr.un.path is 108 bytes on Linux; reject here rather than
        // panicking on the memcpy in connectSocket.
        if (path.len >= @typeInfo(std.meta.fieldInfo(posix.sockaddr.un, .path).type).array.len)
            return error.PathTooLong;
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
        resync: bool = false,
        monitor: bool = false,
        config: bool = false,
    };

    /// Snapshot and clear all dirty flags atomically. The flags rearm on
    /// the next event of the corresponding kind.
    pub fn takeDirty(self: *HyprEvents) Dirty {
        return .{
            .resync = self.resync_needed.swap(false, .acq_rel),
            .monitor = self.monitor_dirty.swap(false, .acq_rel),
            .config = self.config_dirty.swap(false, .acq_rel),
        };
    }

    pub fn focusedAddress(self: *const HyprEvents) u64 {
        return self.focused_address.load(.acquire);
    }

    pub fn cursorPos(self: *const HyprEvents) hypr.CursorPos {
        const packed_xy = self.cursor_xy.load(.acquire);
        return .{
            .x = @bitCast(@as(u32, @truncate(packed_xy >> 32))),
            .y = @bitCast(@as(u32, @truncate(packed_xy))),
        };
    }

    pub fn snapshotGen(self: *const HyprEvents) u64 {
        return self.snapshot_gen.load(.acquire);
    }

    /// Copy the latest window snapshot. Call when `snapshotGen` advanced.
    pub fn copySnapshot(self: *HyprEvents, out: *hypr.VisibleWindows) void {
        lockSpin(&self.snapshot_mutex);
        defer self.snapshot_mutex.unlock();
        out.* = self.snapshot;
    }

    pub fn lastHeartbeatMs(self: *const HyprEvents) i64 {
        return self.last_hb_ms.load(.acquire);
    }

    /// Seed the heartbeat clock. Call right after installing the watcher
    /// so the lapse detector measures from the install, not from 0.
    pub fn noteHeartbeat(self: *HyprEvents) void {
        self.last_hb_ms.store(nowMs(), .release);
    }
};

fn readerLoop(self: *HyprEvents) void {
    var read_buf: [8192]u8 = undefined;
    // Geo lines can be large: up to 32 windows × ~150 bytes of record.
    var line_buf: [8192]u8 = undefined;
    var line_len: usize = 0;

    while (self.running.load(.acquire)) {
        const fd = connectSocket(self) catch |err| {
            log.warn("socket2 connect failed: {} — retrying in 1s", .{err});
            iohelp.sleepNs(std.time.ns_per_s);
            continue;
        };

        self.sock_fd.store(fd, .release);
        log.info("socket2 connected", .{});

        // Change-only events may have been missed while disconnected —
        // ask the main loop to reinstall the watcher, which re-emits
        // everything on its first tick.
        self.resync_needed.store(true, .release);

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
    line_buf: *[8192]u8,
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
            // Overlong lines silently truncate. The only long lines we
            // parse are hg:geo, whose worst case fits the buffer.
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

    if (std.mem.eql(u8, evt, "custom")) {
        handleCustom(self, data);
        return;
    }

    if (std.mem.eql(u8, evt, "activewindowv2")) {
        // data: hex address (no `0x` prefix) or empty when nothing focused.
        self.focused_address.store(parseHexAddr(data), .release);
        return;
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

    // Everything else (workspace/window lifecycle, submap, bell, …) is
    // ignored: the Lua watcher's hg:geo events supersede the old
    // dirty-flag machinery — any change that matters shows up as a new
    // snapshot within one watcher tick.
}

/// Watcher event payloads (the part after `custom>>`).
fn handleCustom(self: *HyprEvents, data: []const u8) void {
    if (std.mem.startsWith(u8, data, "hg:cur:")) {
        const pos = data["hg:cur:".len..];
        const comma = std.mem.indexOfScalar(u8, pos, ',') orelse return;
        const x = std.fmt.parseInt(i32, pos[0..comma], 10) catch return;
        const y = std.fmt.parseInt(i32, pos[comma + 1 ..], 10) catch return;
        const packed_xy = (@as(u64, @as(u32, @bitCast(x))) << 32) | @as(u32, @bitCast(y));
        self.cursor_xy.store(packed_xy, .release);
        return;
    }

    if (std.mem.startsWith(u8, data, "hg:geo:")) {
        const snap = parseGeo(data["hg:geo:".len..]);
        lockSpin(&self.snapshot_mutex);
        self.snapshot = snap;
        self.snapshot_mutex.unlock();
        _ = self.snapshot_gen.fetchAdd(1, .acq_rel);
        return;
    }

    if (std.mem.eql(u8, data, "hg:hb")) {
        self.last_hb_ms.store(nowMs(), .release);
        return;
    }

    // Other custom events (not ours) are ignored.
}

const field_sep = 0x1F; // unit separator, between fields of a record
const record_sep = 0x1E; // record separator, between windows

/// Parse an `hg:geo` payload: records separated by \x1E, fields by \x1F:
///   address \x1F x \x1F y \x1F w \x1F h \x1F class \x1F title
/// An empty payload is a valid zero-window snapshot. Malformed records
/// are skipped; the watcher strips control characters from class/title
/// so the separators cannot appear inside fields.
fn parseGeo(payload: []const u8) hypr.VisibleWindows {
    var result = hypr.VisibleWindows{};
    if (payload.len == 0) return result;

    var records = std.mem.splitScalar(u8, payload, record_sep);
    while (records.next()) |rec| {
        if (result.count >= hypr.max_visible_windows) break;

        var fields = std.mem.splitScalar(u8, rec, field_sep);
        const addr_s = fields.next() orelse continue;
        const x_s = fields.next() orelse continue;
        const y_s = fields.next() orelse continue;
        const w_s = fields.next() orelse continue;
        const h_s = fields.next() orelse continue;
        const class_s = fields.next() orelse continue;
        const title_s = fields.next() orelse continue;

        var win = hypr.WindowGeometry{
            .x = std.fmt.parseInt(i32, x_s, 10) catch continue,
            .y = std.fmt.parseInt(i32, y_s, 10) catch continue,
            .w = std.fmt.parseInt(i32, w_s, 10) catch continue,
            .h = std.fmt.parseInt(i32, h_s, 10) catch continue,
            .address = parseHexAddr(addr_s),
        };

        const clen: u8 = @intCast(@min(class_s.len, win.class.len));
        @memcpy(win.class[0..clen], class_s[0..clen]);
        win.class_len = clen;

        const tlen: u8 = @intCast(@min(title_s.len, win.title.len));
        @memcpy(win.title[0..tlen], title_s[0..tlen]);
        win.title_len = tlen;

        result.windows[result.count] = win;
        result.count += 1;
    }

    return result;
}

fn lockSpin(m: *std.atomic.Mutex) void {
    // Critical sections here are a single ~7KB struct copy, so the lock
    // is almost always free within a few spins. The yield fallback covers
    // the pathological case where the holder is preempted mid-copy, which
    // would otherwise burn a full core until the scheduler intervenes.
    var spins: u32 = 0;
    while (!m.tryLock()) {
        spins += 1;
        if (spins < 64) std.atomic.spinLoopHint() else std.Thread.yield() catch {};
    }
}

/// Monotonic milliseconds. Heartbeat lapse detection only needs deltas,
/// so a monotonic clock beats wall time (immune to NTP/DST jumps).
pub fn nowMs() i64 {
    return @intCast(iohelp.nowNs() / std.time.ns_per_ms);
}

fn parseHexAddr(s: []const u8) u64 {
    if (s.len == 0) return 0;
    const hex = if (s.len > 2 and s[0] == '0' and s[1] == 'x') s[2..] else s;
    return std.fmt.parseUnsigned(u64, hex, 16) catch 0;
}

// Tests cover the line parser only. Threading and socket connection
// require a live Hyprland instance and are exercised manually
// (`zig build ipc-test`).

fn testEvents() HyprEvents {
    return .{
        .socket_path = undefined,
        .socket_path_len = 0,
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

test "handleLine hg:cur updates cursor atomics" {
    var ev = testEvents();
    handleLine(&ev, "custom>>hg:cur:1234,-56");
    try std.testing.expectEqual(@as(i32, 1234), ev.cursorPos().x);
    try std.testing.expectEqual(@as(i32, -56), ev.cursorPos().y);
}

test "handleLine hg:geo parses records and bumps generation" {
    var ev = testEvents();
    const line = "custom>>hg:geo:0x1a2b\x1f100\x1f200\x1f800\x1f600\x1fkitty\x1f~ — fish" ++
        "\x1e" ++ "0x3c4d\x1f-10\x1f47\x1f1520\x1f1638\x1ffirefox\x1fReddit";
    handleLine(&ev, line);

    try std.testing.expectEqual(@as(u64, 1), ev.snapshotGen());
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(u8, 2), snap.count);
    try std.testing.expectEqual(@as(u64, 0x1a2b), snap.windows[0].address);
    try std.testing.expectEqual(@as(i32, 100), snap.windows[0].x);
    try std.testing.expectEqualStrings("kitty", snap.windows[0].className());
    try std.testing.expectEqualStrings("~ — fish", snap.windows[0].titleStr());
    try std.testing.expectEqual(@as(i32, -10), snap.windows[1].x);
    try std.testing.expectEqualStrings("firefox", snap.windows[1].className());
}

test "handleLine hg:geo empty payload is a zero-window snapshot" {
    var ev = testEvents();
    handleLine(&ev, "custom>>hg:geo:0x1\x1f0\x1f0\x1f10\x1f10\x1fa\x1fb");
    handleLine(&ev, "custom>>hg:geo:");
    try std.testing.expectEqual(@as(u64, 2), ev.snapshotGen());
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(u8, 0), snap.count);
}

test "handleLine hg:geo malformed records are skipped" {
    var ev = testEvents();
    handleLine(&ev, "custom>>hg:geo:notanumber\x1fnan\x1f2\x1f3" ++ "\x1e" ++
        "0x2\x1f5\x1f6\x1f7\x1f8\x1fok\x1ftitle");
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(u8, 1), snap.count);
    try std.testing.expectEqualStrings("ok", snap.windows[0].className());
}

test "handleLine hg:hb stores heartbeat timestamp" {
    var ev = testEvents();
    try std.testing.expectEqual(@as(i64, 0), ev.lastHeartbeatMs());
    handleLine(&ev, "custom>>hg:hb");
    try std.testing.expect(ev.lastHeartbeatMs() > 0);
}

test "handleLine foreign custom events are ignored" {
    var ev = testEvents();
    handleLine(&ev, "custom>>somebody-elses-event");
    handleLine(&ev, "custom>>hg:unknown:x");
    try std.testing.expectEqual(@as(u64, 0), ev.snapshotGen());
}

test "handleLine monitoraddedv2 only dirties monitor" {
    var ev = testEvents();
    handleLine(&ev, "monitoraddedv2>>0,DP-1,2560x1440@165");
    const d = ev.takeDirty();
    try std.testing.expect(d.monitor);
    try std.testing.expect(!d.resync);
    try std.testing.expect(!d.config);
}

test "handleLine configreloaded dirties config only" {
    var ev = testEvents();
    handleLine(&ev, "configreloaded>>");
    const d = ev.takeDirty();
    try std.testing.expect(d.config);
    try std.testing.expect(!d.monitor);
}

test "handleLine ignored events leave state untouched" {
    var ev = testEvents();
    handleLine(&ev, "submap>>resize");
    handleLine(&ev, "openwindow>>64ce,1,Alacritty,Alacritty");
    handleLine(&ev, "workspacev2>>5,coding");
    handleLine(&ev, "bell>>");
    const d = ev.takeDirty();
    try std.testing.expect(!d.monitor);
    try std.testing.expect(!d.config);
    try std.testing.expectEqual(@as(u64, 0), ev.snapshotGen());
}

test "handleLine malformed lines do not crash" {
    var ev = testEvents();
    handleLine(&ev, "");
    handleLine(&ev, "noseparator");
    handleLine(&ev, ">>only-data");
    handleLine(&ev, "custom>>hg:cur:nocomma");
    handleLine(&ev, "custom>>hg:cur:a,b");
    handleLine(&ev, "custom>>hg:geo");
}

test "takeDirty clears flags" {
    var ev = testEvents();
    ev.resync_needed.store(true, .release);
    ev.monitor_dirty.store(true, .release);
    const d1 = ev.takeDirty();
    try std.testing.expect(d1.resync);
    try std.testing.expect(d1.monitor);

    const d2 = ev.takeDirty();
    try std.testing.expect(!d2.resync);
    try std.testing.expect(!d2.monitor);
}
