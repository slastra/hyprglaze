const std = @import("std");
const hypr = @import("core/hypr.zig");
const iohelp = @import("core/io_helper.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const io_local = std.Io.Threaded.global_single_threaded.io();
    const io = io_local;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    const ipc = hypr.HyprIpc.init() catch |err| {
        try stderr.print("Failed to init Hyprland IPC: {}\n", .{err});
        try stderr.flush();
        return err;
    };

    // One-shot monitor info
    const mon = try ipc.primaryMonitor(allocator);
    try stdout.print("Monitor: {d}x{d} at ({d},{d})\n", .{ mon.width, mon.height, mon.x, mon.y });

    // Poll loop — 30fps for ~5 seconds (150 frames)
    try stdout.print("\nPolling cursor + active window (150 frames @ 30fps)...\n", .{});
    try stdout.print("{s:<20} {s:<30} {s}\n", .{ "cursor", "window pos/size", "class" });
    try stdout.print("{s:-<80}\n", .{""});
    try stdout.flush();

    const t_start = iohelp.nowNs();
    _ = t_start;

    var frame: u32 = 0;
    while (frame < 150) : (frame += 1) {
        const cursor = ipc.cursorPos() catch |err| {
            try stderr.print("cursorpos error: {}\n", .{err});
            try stderr.flush();
            continue;
        };

        var class_name: []const u8 = "(none)";
        var win_str_buf: [64]u8 = undefined;
        var win_str: []const u8 = "(none)";

        if (ipc.activeWindow(allocator) catch null) |win| {
            class_name = win.className();
            win_str = std.fmt.bufPrint(&win_str_buf, "{d},{d} {d}x{d}", .{ win.x, win.y, win.w, win.h }) catch "(fmt err)";
        }

        try stdout.print("\r{d:>5},{d:<5}       {s:<30} {s}", .{ cursor.x, cursor.y, win_str, class_name });
        try stdout.flush();

        // Sleep ~33ms (30fps)
        iohelp.sleepNs(33 * std.time.ns_per_ms);
    }

    try stdout.print("\n\nDone. {d} frames polled.\n", .{frame});
    try stdout.flush();
}
