//! A light that follows what it is told to stand behind, usually the
//! focused window. One lamp is lit at a time; when what should be lit
//! changes, the old lamp goes down as the new one comes up, so for a
//! moment there are two. Positions are screen px.

const std = @import("std");
const shader_mod = @import("../core/shader.zig");

const WindowRect = shader_mod.ShaderProgram.WindowRect;

fn smooth(x: f32) f32 {
    const t = std.math.clamp(x, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Lamps lit at once. Must match LAMPS in the shaders that take them.
pub const max_lamps = 3;
/// Seconds a lamp takes to come up or go down.
const fade_s = 0.9;
/// What a lamp stands behind: a window (its address), or one of these.
pub const home_id: u64 = 1;
pub const cursor_id: u64 = 2;

pub const Lamp = struct {
    /// 0 = not in use.
    id: u64 = 0,
    pos: [2]f32 = .{ 0, 0 },
    glow: f32 = 0,

    /// How bright it is. Eased at both ends, and such that a lamp going
    /// down and one coming up at the same time always add up to one.
    pub fn strength(self: Lamp) f32 {
        return smooth(self.glow);
    }
};

/// The light a scene is seen by. One lamp is lit at a time, and when
/// what should be lit changes, the old lamp goes down as the new one
/// comes up, so for a moment there are two.
pub const Lamps = struct {
    lamps: [max_lamps]Lamp = @splat(.{}),
    started: bool = false,

    /// `id` is what should be lit now, and `pos` where that is.
    pub fn step(self: *Lamps, dt: f32, id: u64, pos: [2]f32, windows: []const WindowRect) void {
        var lit: ?*Lamp = null;
        for (&self.lamps) |*lamp| {
            if (lamp.id == id) {
                lit = lamp;
                continue;
            }
            if (lamp.glow <= 0) lamp.id = 0;
            // A lamp going down stays behind its window while there is
            // one, and where it last was once there is not.
            for (windows) |w| {
                if (w.address == lamp.id and w.w >= 1.0 and w.h >= 1.0) lamp.pos = .{ w.x + w.w * 0.5, w.y + w.h * 0.5 };
            }
        }
        const now = lit orelse blk: {
            // A free one, or failing that the faintest. The very first
            // lamp is simply on.
            var pick = &self.lamps[0];
            for (&self.lamps) |*lamp| {
                if (lamp.id == 0 or (pick.id != 0 and lamp.glow < pick.glow)) pick = lamp;
                if (pick.id == 0) break;
            }
            pick.* = .{ .id = id, .glow = if (self.started) 0 else 1 };
            break :blk pick;
        };
        self.started = true;
        now.pos = pos;
        const by = std.math.clamp(dt, 0.0, 0.05) / fade_s;
        for (&self.lamps) |*lamp| {
            lamp.glow = if (lamp == now) @min(1.0, lamp.glow + by) else @max(0.0, lamp.glow - by);
        }
    }
};

test "when focus moves, one lamp goes down as the other comes up, and together they stay one lamp bright" {
    var lamps = Lamps{};
    const a = WindowRect{ .x = 100, .y = 100, .w = 400, .h = 300, .address = 0xa0 };
    const b = WindowRect{ .x = 900, .y = 500, .w = 600, .h = 400, .address = 0xb0 };
    const both = [_]WindowRect{ a, b };
    const dt: f32 = 1.0 / 120.0;

    // The first lamp is simply on, behind its window.
    lamps.step(dt, a.address, .{ 300, 250 }, &both);
    var lit: usize = 0;
    for (lamps.lamps) |lamp| {
        if (lamp.id == 0) continue;
        lit += 1;
        try std.testing.expectEqual(@as(f32, 1), lamp.strength());
        try std.testing.expectEqual([2]f32{ 300, 250 }, lamp.pos);
    }
    try std.testing.expectEqual(@as(usize, 1), lit);

    // Focus moves to the other window, and half way through moves back.
    var most: usize = 0;
    for (0..240) |i| {
        const to_b = i < 50 or i >= 120;
        lamps.step(dt, if (to_b) b.address else a.address, if (to_b) .{ 1200, 700 } else .{ 300, 250 }, &both);
        var sum: f32 = 0;
        var count: usize = 0;
        for (lamps.lamps) |lamp| {
            if (lamp.id == 0 or lamp.strength() <= 0) continue;
            sum += lamp.strength();
            count += 1;
        }
        most = @max(most, count);
        try std.testing.expectApproxEqAbs(@as(f32, 1), sum, 1e-4);
    }
    try std.testing.expectEqual(@as(usize, 2), most);
    for (lamps.lamps) |lamp| {
        if (lamp.id == b.address) try std.testing.expectEqual(@as(f32, 1), lamp.strength());
        if (lamp.id == a.address) try std.testing.expectEqual(@as(f32, 0), lamp.strength());
    }
}

test "a lamp going down stays behind its window as the window moves" {
    var lamps = Lamps{};
    var a = WindowRect{ .x = 100, .y = 100, .w = 400, .h = 300, .address = 0xa0 };
    lamps.step(0.01, a.address, .{ 300, 250 }, &.{a});
    a.x = 500;
    lamps.step(0.01, home_id, .{ 0, 0 }, &.{a});
    for (lamps.lamps) |lamp| {
        if (lamp.id == a.address) try std.testing.expectEqual([2]f32{ 700, 250 }, lamp.pos);
    }
}
