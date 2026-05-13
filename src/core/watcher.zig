const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const libc = @import("io_helper.zig").libc;

fn closeFd(fd: i32) void {
    _ = libc.close(fd);
}

fn inotifyInit1(flags: u32) !i32 {
    const r = std.c.inotify_init1(@intCast(flags));
    if (r < 0) return error.InotifyInitFailed;
    return @intCast(r);
}

fn inotifyAddWatch(fd: i32, path: [*:0]const u8, mask: u32) !i32 {
    const r = std.c.inotify_add_watch(fd, path, mask);
    if (r < 0) return switch (std.c._errno().*) {
        @intFromEnum(std.c.E.NOENT), @intFromEnum(std.c.E.ACCES) => error.FileNotFound,
        else => error.InotifyAddWatchFailed,
    };
    return @intCast(r);
}

pub const FileWatcher = struct {
    inotify_fd: i32,
    watch_fd: i32,
    dir_path: [:0]const u8,
    filename: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !FileWatcher {
        const sep = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidPath;

        const inotify_fd = try inotifyInit1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        errdefer closeFd(inotify_fd);

        const dir_path = try allocator.dupeZ(u8, path[0..sep]);
        errdefer allocator.free(dir_path);

        const filename = try allocator.dupe(u8, path[sep + 1 ..]);
        errdefer allocator.free(filename);

        // Watch the directory — survives editor atomic renames
        const watch_fd = try inotifyAddWatch(
            inotify_fd,
            dir_path,
            linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.CREATE,
        );

        return .{
            .inotify_fd = inotify_fd,
            .watch_fd = watch_fd,
            .dir_path = dir_path,
            .filename = filename,
            .allocator = allocator,
        };
    }

    /// Check if our config file was modified. Non-blocking.
    pub fn poll(self: *FileWatcher) bool {
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

        const n = posix.read(self.inotify_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return false,
        };

        if (n == 0) return false;

        // Check if any event matches our target filename
        var matched = false;
        var offset: usize = 0;
        while (offset < n) {
            const event: *const linux.inotify_event = @alignCast(@ptrCast(&buf[offset]));
            if (event.len > 0) {
                const name_start = offset + @sizeOf(linux.inotify_event);
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(buf[name_start..].ptr)), 0);
                if (std.mem.eql(u8, name, self.filename)) {
                    matched = true;
                }
            }
            offset += @sizeOf(linux.inotify_event) + event.len;
        }

        return matched;
    }

    pub fn rewatch(self: *FileWatcher) void {
        // Directory watch survives renames — no-op, kept for API compat
        _ = self;
    }

    pub fn deinit(self: *FileWatcher) void {
        _ = linux.inotify_rm_watch(self.inotify_fd, self.watch_fd);
        closeFd(self.inotify_fd);
        self.allocator.free(self.dir_path);
        self.allocator.free(self.filename);
    }
};

test "FileWatcher init/deinit frees all allocations" {
    var w = try FileWatcher.init(std.testing.allocator, "/tmp/hyprglaze-test.toml");
    defer w.deinit();
}

test "FileWatcher init rejects path without separator" {
    try std.testing.expectError(error.InvalidPath, FileWatcher.init(std.testing.allocator, "nosep.toml"));
}

test "FileWatcher init splits directory and filename" {
    var w = try FileWatcher.init(std.testing.allocator, "/tmp/foo.conf");
    defer w.deinit();
    try std.testing.expectEqualStrings("/tmp", w.dir_path);
    try std.testing.expectEqualStrings("foo.conf", w.filename);
}

test "FileWatcher init cleans up on missing directory (no leak)" {
    // /this/does/not/exist fails in inotify_add_watch after allocations —
    // errdefer must free them.
    try std.testing.expectError(
        error.FileNotFound,
        FileWatcher.init(std.testing.allocator, "/this/does/not/exist/cfg.toml"),
    );
}
