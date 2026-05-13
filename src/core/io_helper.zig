const std = @import("std");

/// Returns the process-global synchronous Io. Cheap; safe to call per-op.
/// Used by every site that touches the new std.Io.File / std.Io.Dir APIs
/// to avoid threading an Io parameter through every function signature.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk_id: i32, tp: *Timespec) c_int;
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

/// Sleep `ns` nanoseconds.
pub fn sleepNs(ns: u64) void {
    const sec: i64 = @intCast(ns / std.time.ns_per_s);
    const nsec: i64 = @intCast(ns % std.time.ns_per_s);
    _ = nanosleep(&.{ .sec = sec, .nsec = nsec }, null);
}

/// Monotonic-clock nanoseconds.
pub fn nowNs() u64 {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(1, &ts); // CLOCK_MONOTONIC
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Minimal monotonic timer.
pub const Timer = struct {
    start_ns: u64,

    pub fn start() !Timer {
        return .{ .start_ns = nowNs() };
    }

    pub fn read(self: *const Timer) u64 {
        return nowNs() - self.start_ns;
    }

    pub fn reset(self: *Timer) void {
        self.start_ns = nowNs();
    }
};

/// Open an absolute-path file, read up to `max_size` bytes, allocate + return.
pub fn readFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
) ![]u8 {
    const i = io();
    const file = try std.Io.Dir.openFileAbsolute(i, path, .{});
    defer file.close(i);

    const size = try file.length(i);
    if (size > max_size) return error.FileTooLarge;

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(i, buf, 0);
    return buf;
}

pub fn writeFileAbsolute(path: []const u8, data: []const u8) !void {
    const i = io();
    const file = try std.Io.Dir.createFileAbsolute(i, path, .{});
    defer file.close(i);
    try file.writeStreamingAll(i, data);
}

pub fn renameAbsolute(old: []const u8, new: []const u8) !void {
    const i = io();
    try std.Io.Dir.renameAbsolute(old, new, i);
}

pub fn makeDirAbsolute(path: []const u8) !void {
    const i = io();
    try std.Io.Dir.createDirAbsolute(i, path, .default_dir);
}

pub fn deleteFileAbsolute(path: []const u8) !void {
    const i = io();
    try std.Io.Dir.deleteFileAbsolute(i, path);
}

pub fn accessAbsolute(path: []const u8) bool {
    const i = io();
    std.Io.Dir.accessAbsolute(i, path, .{}) catch return false;
    return true;
}

pub fn accessRelative(path: []const u8) bool {
    const i = io();
    std.Io.Dir.cwd().access(i, path, .{}) catch return false;
    return true;
}

/// Read a file at an absolute path into a null-terminated buffer (for GLSL source, etc.).
pub fn readFileAlloc0(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
) ![:0]u8 {
    const data = try readFileAlloc(allocator, path, max_size);
    defer allocator.free(data);
    const out = try allocator.allocSentinel(u8, data.len, 0);
    @memcpy(out, data);
    return out;
}

/// Read a file at a CWD-relative path. Returns null-terminated buffer.
pub fn readFileRelative0(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_size: usize,
) ![:0]u8 {
    const i = io();
    const file = try std.Io.Dir.cwd().openFile(i, path, .{});
    defer file.close(i);

    const size = try file.length(i);
    if (size > max_size) return error.FileTooLarge;

    const out = try allocator.allocSentinel(u8, @intCast(size), 0);
    errdefer allocator.free(out);
    _ = try file.readPositionalAll(i, out, 0);
    return out;
}

// libc shims, shared across modules so each one doesn't redeclare the externs.
pub const libc = struct {
    pub extern "c" fn close(fd: c_int) c_int;
    pub extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
    pub extern "c" fn connect(fd: c_int, addr: *const anyopaque, addrlen: u32) c_int;
    pub extern "c" fn shutdown(fd: c_int, how: c_int) c_int;
    pub extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
    pub extern "c" fn pclose(stream: *anyopaque) c_int;
    pub extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
    pub const SHUT_RDWR: c_int = 2;
};

/// Auto-detect the user's default PulseAudio sink and write its `.monitor`
/// source name into `buf`. Returns the length, or 0 on failure.
/// Shared by visualizer/audio.zig and meshflow/beatnet.zig.
pub fn autoDetectPulseMonitor(buf: *[256]u8) u16 {
    const stream = libc.popen("pactl get-default-sink 2>/dev/null", "r") orelse return 0;
    defer _ = libc.pclose(stream);

    var read_buf: [200]u8 = undefined;
    const n = libc.fread(@ptrCast(&read_buf), 1, read_buf.len, stream);
    if (n == 0) return 0;

    var len = n;
    while (len > 0 and (read_buf[len - 1] == '\n' or read_buf[len - 1] == '\r')) len -= 1;
    if (len == 0) return 0;

    const suffix = ".monitor";
    if (len + suffix.len >= buf.len) return 0;
    @memcpy(buf[0..len], read_buf[0..len]);
    @memcpy(buf[len .. len + suffix.len], suffix);
    return @intCast(len + suffix.len);
}
