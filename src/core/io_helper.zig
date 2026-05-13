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

/// Sleep `ns` nanoseconds. Replaces std.Thread.sleep (removed in 0.16).
pub fn sleepNs(ns: u64) void {
    const sec: i64 = @intCast(ns / std.time.ns_per_s);
    const nsec: i64 = @intCast(ns % std.time.ns_per_s);
    _ = nanosleep(&.{ .sec = sec, .nsec = nsec }, null);
}

/// Monotonic-clock nanoseconds — for seeding RNGs (was std.time.timestamp() pre-0.16).
pub fn nowNs() u64 {
    var ts: Timespec = .{ .sec = 0, .nsec = 0 };
    _ = clock_gettime(1, &ts); // CLOCK_MONOTONIC
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Minimal monotonic timer (replaces std.time.Timer, removed in 0.16).
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
/// Replaces the Zig 0.15 pattern: `std.fs.openFileAbsolute(p, .{}) → file.readToEndAlloc`.
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
