const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const FileWatcher = struct {
    inotify_fd: i32,
    watch_fd: i32,
    path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !FileWatcher {
        const inotify_fd = try posix.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);

        // Watch for modifications and close-write (editors often write to temp then rename)
        const watch_fd = try posix.inotify_add_watch(
            inotify_fd,
            path,
            linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.MOVE_SELF,
        );

        return .{
            .inotify_fd = inotify_fd,
            .watch_fd = watch_fd,
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
        };
    }

    /// Check if the file was modified. Non-blocking.
    pub fn poll(self: *FileWatcher) bool {
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

        const n = posix.read(self.inotify_fd, &buf) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return false,
        };

        if (n == 0) return false;

        // Drain all events, we just care that something changed
        // Re-add watch in case of MOVE_SELF (editor save via rename)
        var changed = false;
        var offset: usize = 0;
        while (offset < n) {
            const event: *const linux.inotify_event = @alignCast(@ptrCast(&buf[offset]));
            if (event.mask & linux.IN.MOVE_SELF != 0) {
                // File was renamed — re-add watch on the path
                self.rewatch();
            }
            changed = true;
            offset += @sizeOf(linux.inotify_event) + event.len;
        }

        return changed;
    }

    pub fn rewatch(self: *FileWatcher) void {
        posix.inotify_rm_watch(self.inotify_fd, self.watch_fd);
        self.watch_fd = posix.inotify_add_watch(
            self.inotify_fd,
            self.path,
            linux.IN.MODIFY | linux.IN.CLOSE_WRITE | linux.IN.MOVE_SELF,
        ) catch return;
    }

    pub fn deinit(self: *FileWatcher) void {
        posix.inotify_rm_watch(self.inotify_fd, self.watch_fd);
        posix.close(self.inotify_fd);
        self.allocator.free(self.path);
    }
};
