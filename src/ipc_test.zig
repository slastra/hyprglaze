const std = @import("std");
const hypr = @import("core/hypr.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
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

    var timer = try std.time.Timer.start();

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
        std.Thread.sleep(33 * std.time.ns_per_ms);
    }

    const elapsed = timer.read();
    const elapsed_ms = elapsed / std.time.ns_per_ms;
    try stdout.print("\n\nDone. {d} frames in {d}ms ({d:.1}fps avg)\n", .{
        frame,
        elapsed_ms,
        @as(f64, @floatFromInt(frame)) / (@as(f64, @floatFromInt(elapsed_ms)) / 1000.0),
    });
    try stdout.print("Per-query latency: ~{d:.2}ms\n", .{
        @as(f64, @floatFromInt(elapsed_ms)) / @as(f64, @floatFromInt(frame)) - 33.0,
    });
    try stdout.flush();
}
