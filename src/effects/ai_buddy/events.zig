const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const transition_mod = @import("../../core/transition.zig");

pub const max_events = 16;

pub const Event = struct {
    text: [128]u8 = undefined,
    len: u8 = 0,

    pub fn set(self: *Event, msg: []const u8) void {
        const l: u8 = @intCast(@min(msg.len, 128));
        @memcpy(self.text[0..l], msg[0..l]);
        self.len = l;
    }

    pub fn slice(self: *const Event) []const u8 {
        return self.text[0..self.len];
    }
};

pub const EventLog = struct {
    events: [max_events]Event = [_]Event{.{}} ** max_events,
    count: u8 = 0,

    pub fn log(self: *EventLog, comptime fmt: []const u8, args: anytype) void {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        if (self.count >= max_events) {
            for (0..max_events - 1) |i| {
                self.events[i] = self.events[i + 1];
            }
            self.count = max_events - 1;
        }
        self.events[self.count].set(msg);
        self.count += 1;
    }
};

pub fn describeLayout(
    my_x: f32,
    my_y: f32,
    state_windows: []const shader_mod.ShaderProgram.WindowRect,
    focused: transition_mod.Rect,
    classes: *const [32][32]u8,
    class_lens: *const [32]u8,
    window_count: u8,
    buf: []u8,
) []const u8 {
    var pos: usize = 0;

    const me = std.fmt.bufPrint(buf[pos..], "You are at ({d:.0},{d:.0}). ", .{ my_x, my_y }) catch return buf[0..pos];
    pos += me.len;

    for (state_windows, 0..) |win, wi| {
        if (win.w < 1) continue;
        if (pos + 100 >= buf.len) break;
        const cx = win.x + win.w * 0.5;
        const cy = win.y + win.h * 0.5;
        const dx = cx - my_x;
        const dy = cy - my_y;

        const horiz: []const u8 = if (dx > 50) "right" else if (dx < -50) "left" else "here";
        const vert: []const u8 = if (dy > 50) "above" else if (dy < -50) "below" else "level";

        const is_focused = @abs(win.x - focused.x) < 2 and @abs(win.y - focused.y) < 2;

        // Use class name if available
        const class_name = if (wi < window_count and class_lens[wi] > 0)
            classes[wi][0..class_lens[wi]]
        else
            "Window";

        const desc = std.fmt.bufPrint(buf[pos..], "{s} {s}{s} to the {s}. ", .{
            class_name,
            if (is_focused) "(focused) " else "",
            vert,
            horiz,
        }) catch break;
        pos += desc.len;
    }

    return buf[0..pos];
}
