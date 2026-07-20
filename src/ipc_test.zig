const std = @import("std");
const builtin = @import("builtin");
const hypr = @import("core/hypr.zig");
const hypr_events = @import("core/hypr_events.zig");
const iohelp = @import("core/io_helper.zig");

const watcher_lua = @embedFile("core/watcher.lua");

/// Diagnostic for the push pipeline: installs the in-compositor Lua
/// watcher, then prints the pushed cursor/window state for ~10 seconds.
/// Move the cursor and drag windows — the numbers should follow live.
pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.smp_allocator;

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

    // One-shot monitor info (startup-only query, same as the daemon)
    const mon = try ipc.primaryMonitor(allocator);
    try stdout.print("Monitor: {d}x{d} at ({d},{d})\n", .{ mon.width, mon.height, mon.x, mon.y });

    var events = try hypr_events.HyprEvents.init();
    try events.start();
    defer events.deinit();

    try ipc.eval(watcher_lua);
    events.noteHeartbeat();
    try stdout.print("Lua watcher installed. Streaming pushed state for ~10s...\n\n", .{});
    try stdout.print("{s:<16} {s:<8} {s:<30} {s}\n", .{ "cursor", "windows", "focused/first pos/size", "class" });
    try stdout.print("{s:-<80}\n", .{""});
    try stdout.flush();

    var snap = hypr.VisibleWindows{};
    var frame: u32 = 0;
    while (frame < 300) : (frame += 1) {
        events.copySnapshot(&snap);
        const cur = events.cursorPos();

        var class_name: []const u8 = "(none)";
        var win_str_buf: [64]u8 = undefined;
        var win_str: []const u8 = "(none)";
        if (snap.count > 0) {
            const focused = events.focusedAddress();
            var idx: usize = 0;
            for (0..snap.count) |i| {
                if (snap.windows[i].address == focused) idx = i;
            }
            const w = snap.windows[idx];
            class_name = w.className();
            win_str = std.fmt.bufPrint(&win_str_buf, "{d},{d} {d}x{d}", .{ w.x, w.y, w.w, w.h }) catch "(fmt err)";
        }

        try stdout.print("\r{d:>6},{d:<6}   {d:<8} {s:<30} {s}          ", .{ cur.x, cur.y, snap.count, win_str, class_name });
        try stdout.flush();

        iohelp.sleepNs(33 * std.time.ns_per_ms);
    }

    try stdout.print("\n\nDone. gen={d} last_hb_age={d}ms\n", .{
        events.snapshotGen(),
        hypr_events.nowMs() - events.lastHeartbeatMs(),
    });
    try stdout.flush();
}
