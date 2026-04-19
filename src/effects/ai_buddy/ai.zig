const std = @import("std");
const sprite = @import("../buddy/sprite.zig");

pub const QueuedAction = struct {
    behavior: sprite.Behavior,
    duration: f32,
    dir: f32,
};

pub fn mapAction(name: []const u8) ?QueuedAction {
    const map = [_]struct { n: []const u8, b: sprite.Behavior, d: f32 }{
        .{ .n = "idle", .b = .idle, .d = 2.0 },
        .{ .n = "wander", .b = .wander, .d = 3.0 },
        .{ .n = "chase", .b = .chase, .d = 4.0 },
        .{ .n = "jump", .b = .jump_to, .d = 2.0 },
        .{ .n = "wave", .b = .wave, .d = 1.5 },
        .{ .n = "push", .b = .push, .d = 2.0 },
        .{ .n = "throw", .b = .throw_rock, .d = 1.2 },
        .{ .n = "trip", .b = .trip, .d = 1.0 },
        .{ .n = "death", .b = .dramatic_death, .d = 3.0 },
        .{ .n = "climb", .b = .climb, .d = 1.5 },
        .{ .n = "celebrate", .b = .celebrate, .d = 1.5 },
    };
    for (map) |m| {
        if (std.mem.eql(u8, name, m.n)) return .{ .behavior = m.b, .duration = m.d, .dir = 1.0 };
    }
    return null;
}

pub fn actionName(b: sprite.Behavior) []const u8 {
    return switch (b) {
        .idle => "idle", .wander => "wander", .chase => "chase",
        .jump_to => "jump", .wave => "wave", .push => "push",
        .throw_rock => "throw", .trip => "trip", .dramatic_death => "death",
        .climb => "climb", .celebrate => "celebrate",
        .curious => "curious", .flee => "flee",
    };
}
