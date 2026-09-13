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
///   hg:geo:<wsid>\x1d<records>
///                    workspace id + visible-window snapshot — stored
///                    under mutex, generation counter bumped
///   hg:hb2           watcher heartbeat (~2s) — timestamp stored so the
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

    /// Millisecond timestamp of the last `hg:hb2` heartbeat. Seeded by
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

    /// A legacy (non-per-monitor) `hg:geo` arrived while a monitor filter is
    /// set: an older hyprglaze installed its watcher over ours. Its payload
    /// is not monitor-scoped, so the main loop reinstalls rather than
    /// consuming another monitor's windows.
    legacy_watcher: std.atomic.Value(bool) = .init(false),

    /// Output this daemon renders on. `hg:mgeo` events for other monitors
    /// are dropped, which is what lets one watcher serve one daemon per
    /// monitor. Length 0 accepts every monitor (tests, and the untargeted
    /// case).
    monitor_name: [64]u8 = undefined,
    monitor_name_len: u8 = 0,

    pub fn monitorName(self: *const HyprEvents) []const u8 {
        return self.monitor_name[0..self.monitor_name_len];
    }

    /// Scope this daemon to one output. Must be called before `start`.
    pub fn setMonitor(self: *HyprEvents, name: []const u8) void {
        self.monitor_name_len = @intCast(@min(name.len, self.monitor_name.len));
        @memcpy(self.monitor_name[0..self.monitor_name_len], name[0..self.monitor_name_len]);
    }

    /// Layout origin of the monitor this daemon follows, taken under the
    /// snapshot mutex so the reader thread cannot interleave a rebase.
    pub fn setOrigin(self: *HyprEvents, x: i32, y: i32) void {
        lockSpin(&self.snapshot_mutex);
        defer self.snapshot_mutex.unlock();
        self.snapshot.origin_x = x;
        self.snapshot.origin_y = y;
    }

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
        legacy: bool = false,
    };

    /// Snapshot and clear all dirty flags atomically. The flags rearm on
    /// the next event of the corresponding kind.
    pub fn takeDirty(self: *HyprEvents) Dirty {
        return .{
            .resync = self.resync_needed.swap(false, .acq_rel),
            .monitor = self.monitor_dirty.swap(false, .acq_rel),
            .config = self.config_dirty.swap(false, .acq_rel),
            .legacy = self.legacy_watcher.swap(false, .acq_rel),
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
    // snapshot within one watcher tick. That includes workspacev2:
    // workspace identity rides inside hg:geo so it stays atomic with
    // the window set it describes.
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

    if (std.mem.startsWith(u8, data, "hg:mgeo:")) {
        const payload = data["hg:mgeo:".len..];
        // Reject another monitor's event before parsing any records: with
        // one watcher serving every daemon, most traffic is not ours.
        const gi = std.mem.indexOfScalar(u8, payload, group_sep) orelse return;
        if (self.monitor_name_len != 0 and
            !std.mem.eql(u8, payload[0..gi], self.monitorName())) return;

        // A short header means we could not read the origin. Dropping the
        // event leaves the previous good snapshot in place; publishing a
        // zero-initialised one would rebase every window against origin (0,0)
        // — a whole-screen jump on any monitor that is not at the layout
        // origin.
        const snap = parseGeoM(payload[gi + 1 ..]) orelse return;
        lockSpin(&self.snapshot_mutex);
        self.snapshot = snap;
        self.snapshot_mutex.unlock();
        _ = self.snapshot_gen.fetchAdd(1, .acq_rel);
        return;
    }

    if (std.mem.startsWith(u8, data, "hg:geo:")) {
        // A pre-per-monitor watcher is installed, which means an older
        // hyprglaze is running and overwrote ours. Its payload is not scoped
        // to a monitor, so consuming it would silently mix monitors —
        // flag a reinstall instead and let the newer daemon win.
        if (self.monitor_name_len != 0) {
            self.legacy_watcher.store(true, .release);
            return;
        }
        const snap = parseGeo(data["hg:geo:".len..]);
        lockSpin(&self.snapshot_mutex);
        self.snapshot = snap;
        self.snapshot_mutex.unlock();
        _ = self.snapshot_gen.fetchAdd(1, .acq_rel);
        return;
    }

    // hb2 is this protocol's heartbeat; a bare hb comes from a pre-per-monitor
    // watcher, and accepting it would keep this daemon's lapse detector quiet
    // while no hg:mgeo ever arrived.
    if (std.mem.eql(u8, data, "hg:hb2")) {
        self.last_hb_ms.store(nowMs(), .release);
        return;
    }

    // Other custom events (not ours) are ignored.
}

const field_sep = 0x1F; // unit separator, between fields of a record
const record_sep = 0x1E; // record separator, between windows
const group_sep = 0x1D; // group separator, between workspace id and records

/// Parse an `hg:geo` payload: `<wsid> \x1D <records>`, records separated
/// by \x1E, fields by \x1F:
///   address \x1F x \x1F y \x1F w \x1F h \x1F class \x1F title \x1F rel
/// `rel` is the workspace-strip slot (-1/0/+1); a record without it (an
/// old in-compositor watcher) defaults to 0, and a payload without \x1D
/// parses as records only, workspace_id 0. An empty record section is a
/// valid zero-window snapshot. Malformed records are skipped; the
/// watcher strips control characters from class/title so the separators
/// cannot appear inside fields.
fn parseGeo(payload: []const u8) hypr.VisibleWindows {
    var result = hypr.VisibleWindows{};

    var records_payload = payload;
    if (std.mem.indexOfScalar(u8, payload, group_sep)) |gi| {
        result.workspace_id = std.fmt.parseInt(i64, payload[0..gi], 10) catch 0;
        records_payload = payload[gi + 1 ..];
    }
    parseRecords(records_payload, &result);
    return result;
}

/// Parse the monitor-scoped tail of an `hg:mgeo` payload — everything after
/// the output name: `<wsid> \x1D <ox> \x1D <oy> \x1D <records>`.
///
/// The origin travels with the geometry it describes, so a monitor that moves
/// (a display added to its left, say) cannot leave window rects rebased
/// against a stale origin even for one frame.
/// Returns null when the header is incomplete, so the caller can keep the
/// previous snapshot rather than publish one with a fabricated origin.
/// Unparsable *values* inside a complete header still degrade to 0 — the
/// shape being right is what makes the event trustworthy.
fn parseGeoM(payload: []const u8) ?hypr.VisibleWindows {
    var result = hypr.VisibleWindows{};

    var rest = payload;

    // wsid
    var gi = std.mem.indexOfScalar(u8, rest, group_sep) orelse return null;
    result.workspace_id = std.fmt.parseInt(i64, rest[0..gi], 10) catch 0;
    rest = rest[gi + 1 ..];
    // origin x
    gi = std.mem.indexOfScalar(u8, rest, group_sep) orelse return null;
    result.origin_x = std.fmt.parseInt(i32, rest[0..gi], 10) catch 0;
    rest = rest[gi + 1 ..];
    // origin y
    gi = std.mem.indexOfScalar(u8, rest, group_sep) orelse return null;
    result.origin_y = std.fmt.parseInt(i32, rest[0..gi], 10) catch 0;
    rest = rest[gi + 1 ..];

    parseRecords(rest, &result);
    return result;
}

fn parseRecords(records_payload: []const u8, result: *hypr.VisibleWindows) void {
    if (records_payload.len == 0) return;

    var records = std.mem.splitScalar(u8, records_payload, record_sep);
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

        if (fields.next()) |rel_s| {
            const rel = std.fmt.parseInt(i8, rel_s, 10) catch 0;
            win.rel = std.math.clamp(rel, -1, 1);
        }

        result.windows[result.count] = win;
        result.count += 1;
    }
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

test "handleLine hg:geo workspace id prefix" {
    var ev = testEvents();
    handleLine(&ev, "custom>>hg:geo:5\x1d0x1\x1f0\x1f0\x1f10\x1f10\x1fa\x1fb");
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(i64, 5), snap.workspace_id);
    try std.testing.expectEqual(@as(u8, 1), snap.count);

    // Special workspaces have negative ids.
    handleLine(&ev, "custom>>hg:geo:-98\x1d");
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(i64, -98), snap.workspace_id);
    try std.testing.expectEqual(@as(u8, 0), snap.count);

    // Garbage id degrades to 0 (unknown); records still parse.
    handleLine(&ev, "custom>>hg:geo:junk\x1d0x2\x1f1\x1f2\x1f3\x1f4\x1fc\x1fd");
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(i64, 0), snap.workspace_id);
    try std.testing.expectEqual(@as(u8, 1), snap.count);
}

test "handleLine hg:geo strip rel field" {
    var ev = testEvents();
    handleLine(&ev, "custom>>hg:geo:4\x1d" ++
        "0x1\x1f0\x1f0\x1f10\x1f10\x1fa\x1ft\x1f0" ++ "\x1e" ++
        "0x2\x1f5\x1f5\x1f10\x1f10\x1fb\x1ft\x1f-1" ++ "\x1e" ++
        "0x3\x1f9\x1f9\x1f10\x1f10\x1fc\x1ft\x1f1" ++ "\x1e" ++
        "0x4\x1f9\x1f9\x1f10\x1f10\x1fd\x1ft\x1f7"); // out-of-range clamps
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(u8, 4), snap.count);
    try std.testing.expectEqual(@as(i8, 0), snap.windows[0].rel);
    try std.testing.expectEqual(@as(i8, -1), snap.windows[1].rel);
    try std.testing.expectEqual(@as(i8, 1), snap.windows[2].rel);
    try std.testing.expectEqual(@as(i8, 1), snap.windows[3].rel);
    // A record without the rel field (old watcher) defaults to 0.
    handleLine(&ev, "custom>>hg:geo:4\x1d0x9\x1f1\x1f1\x1f5\x1f5\x1fk\x1ft");
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(i8, 0), snap.windows[0].rel);
}

test "handleLine hg:geo old format without wsid still parses" {
    var ev = testEvents();
    handleLine(&ev, "custom>>hg:geo:0x1\x1f0\x1f0\x1f10\x1f10\x1fa\x1fb");
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(i64, 0), snap.workspace_id);
    try std.testing.expectEqual(@as(u8, 1), snap.count);
}

test "handleLine hg:hb2 stores heartbeat timestamp" {
    var ev = testEvents();
    try std.testing.expectEqual(@as(i64, 0), ev.lastHeartbeatMs());
    handleLine(&ev, "custom>>hg:hb2");
    try std.testing.expect(ev.lastHeartbeatMs() > 0);
}

test "handleLine a legacy hg:hb does not satisfy this daemon's heartbeat" {
    // The pre-per-monitor watcher emits hg:hb and hg:geo. If a bare hg:hb
    // counted, an older hyprglaze installing its watcher over ours would keep
    // our lapse detector quiet while no hg:mgeo ever arrived — the wallpaper
    // would freeze silently instead of triggering a reinstall.
    var ev = testEvents();
    handleLine(&ev, "custom>>hg:hb");
    try std.testing.expectEqual(@as(i64, 0), ev.lastHeartbeatMs());
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

// --- per-monitor geometry (hg:mgeo) ---

fn scopedEvents(name: []const u8) HyprEvents {
    var ev = testEvents();
    ev.setMonitor(name);
    return ev;
}

/// `<mon> GS <wsid> GS <ox> GS <oy> GS <records>`
const mgeo_dp1 = "custom>>hg:mgeo:DP-1\x1d3\x1d3072\x1d0\x1d" ++
    "0x1a2b\x1f3172\x1f200\x1f800\x1f600\x1fkitty\x1f~ — fish\x1f0";

test "handleLine hg:mgeo parses the header, origin and records" {
    var ev = scopedEvents("DP-1");
    handleLine(&ev, mgeo_dp1);

    try std.testing.expectEqual(@as(u64, 1), ev.snapshotGen());
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(i64, 3), snap.workspace_id);
    try std.testing.expectEqual(@as(i32, 3072), snap.origin_x);
    try std.testing.expectEqual(@as(i32, 0), snap.origin_y);
    try std.testing.expectEqual(@as(u8, 1), snap.count);
    // Wire coordinates stay global; rebasing happens in geometry.zig.
    try std.testing.expectEqual(@as(i32, 3172), snap.windows[0].x);
    try std.testing.expectEqualStrings("kitty", snap.windows[0].className());
}

test "handleLine hg:mgeo for another monitor is ignored entirely" {
    // The core multi-instance guarantee: one watcher serves every daemon, so
    // each must drop the others' events without touching its own state.
    var ev = scopedEvents("HDMI-A-1");
    handleLine(&ev, mgeo_dp1);
    try std.testing.expectEqual(@as(u64, 0), ev.snapshotGen());
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(u8, 0), snap.count);
}

test "handleLine hg:mgeo with no monitor filter accepts any monitor" {
    var ev = testEvents();
    handleLine(&ev, mgeo_dp1);
    try std.testing.expectEqual(@as(u64, 1), ev.snapshotGen());
}

test "handleLine hg:mgeo a monitor name must match exactly, not by prefix" {
    var ev = scopedEvents("DP-11");
    handleLine(&ev, mgeo_dp1);
    try std.testing.expectEqual(@as(u64, 0), ev.snapshotGen());
}

test "handleLine hg:mgeo empty record section is a valid zero-window snapshot" {
    var ev = scopedEvents("DP-1");
    handleLine(&ev, "custom>>hg:mgeo:DP-1\x1d7\x1d-1920\x1d1080\x1d");
    try std.testing.expectEqual(@as(u64, 1), ev.snapshotGen());
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(u8, 0), snap.count);
    try std.testing.expectEqual(@as(i32, -1920), snap.origin_x);
    try std.testing.expectEqual(@as(i32, 1080), snap.origin_y);
}

test "handleLine hg:mgeo truncated headers do not bump the generation" {
    var ev = scopedEvents("DP-1");
    handleLine(&ev, "custom>>hg:mgeo:DP-1"); // no separator at all
    try std.testing.expectEqual(@as(u64, 0), ev.snapshotGen());

    // A header that stops before the origin must not publish at all.
    // Publishing a zero-initialised snapshot would rebase every window
    // against origin (0,0) for a frame — on an offset monitor that is a
    // whole-screen jump, and it is indistinguishable from a monitor that
    // genuinely sits at the layout origin.
    handleLine(&ev, "custom>>hg:mgeo:DP-1\x1d3");
    try std.testing.expectEqual(@as(u64, 0), ev.snapshotGen());

    // Stops after the origin's x — still one field short of a usable header.
    handleLine(&ev, "custom>>hg:mgeo:DP-1\x1d3\x1d100");
    try std.testing.expectEqual(@as(u64, 0), ev.snapshotGen());

    // A complete header with garbage numerics is a different case: the shape
    // is right, so it publishes, and the unparsable fields degrade to zero.
    handleLine(&ev, "custom>>hg:mgeo:DP-1\x1dx\x1d10\x1d20\x1d");
    try std.testing.expectEqual(@as(u64, 1), ev.snapshotGen());
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(i64, 0), snap.workspace_id);
    try std.testing.expectEqual(@as(i32, 10), snap.origin_x);
    try std.testing.expectEqual(@as(i32, 20), snap.origin_y);
}

test "handleLine hg:mgeo unparsable origin fields degrade to zero" {
    // The watcher formats the origin with %.0f, which renders nan or inf for a
    // position Hyprland reports as non-finite. Letting that through would
    // rebase every window rect against junk, so the parse must fall back to 0
    // rather than to whatever parseInt left behind.
    var ev = scopedEvents("DP-1");
    handleLine(&ev, "custom>>hg:mgeo:DP-1\x1d3\x1dnan\x1dinf\x1d");
    try std.testing.expectEqual(@as(u64, 1), ev.snapshotGen());
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(i32, 0), snap.origin_x);
    try std.testing.expectEqual(@as(i32, 0), snap.origin_y);
    try std.testing.expectEqual(@as(i64, 3), snap.workspace_id);
}

test "handleLine legacy hg:geo while scoped triggers a reinstall instead of mixing monitors" {
    var ev = scopedEvents("DP-1");
    handleLine(&ev, "custom>>hg:geo:0x1\x1f0\x1f0\x1f10\x1f10\x1fa\x1fb");
    // The legacy payload is not monitor-scoped, so consuming it would render
    // another monitor's windows. State must be untouched.
    try std.testing.expectEqual(@as(u64, 0), ev.snapshotGen());
    try std.testing.expect(ev.takeDirty().legacy);
}

test "handleLine hg:mgeo honours the 32-window cap" {
    var ev = scopedEvents("DP-1");
    var buf: [4096]u8 = undefined;
    var end: usize = 0;
    const header = "custom>>hg:mgeo:DP-1\x1d1\x1d0\x1d0\x1d";
    @memcpy(buf[0..header.len], header);
    end = header.len;
    for (0..40) |i| {
        if (i > 0) {
            buf[end] = 0x1e;
            end += 1;
        }
        const rec = try std.fmt.bufPrint(buf[end..], "0x{x}\x1f{d}\x1f0\x1f10\x1f10\x1fc\x1ft\x1f0", .{ i + 1, i });
        end += rec.len;
    }
    handleLine(&ev, buf[0..end]);
    var snap: hypr.VisibleWindows = undefined;
    ev.copySnapshot(&snap);
    try std.testing.expectEqual(@as(u8, hypr.max_visible_windows), snap.count);
}
