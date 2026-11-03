//! Window move/resize animation, mirrored from Hyprland.
//!
//! The watcher reports each window's GOAL rect: Lua's `w.at`/`w.size` (and
//! `hyprctl clients`) jump to the destination the instant a move starts,
//! while Hyprland animates the window there over its `windowsMove` curve.
//! No IPC surface exposes the animated value (measured on 0.56.1 with
//! scripts/geom-anim.probe.sh). So, as workspace_slide.zig does for
//! workspace switches, the daemon replays the compositor's animation:
//! when a goal changes, the rect animates from where it is shown now to
//! the new goal on the same bezier or spring, restarting the clock on a
//! retarget exactly like hyprutils' animated variables.
//!
//! Interactive drags and resizes are NOT animated by Hyprland — the window
//! tracks the pointer. They arrive as a stream of goal changes one watcher
//! tick apart, where an animated move arrives as one isolated change, so a
//! goal that changes again within `drag_gap` of its last change is shown
//! as-is.
//!
//! Works in layout space (Hyprland's own units), keyed by address, so the
//! daemon's workspace-strip offsets and slide camera never read as motion.

const std = @import("std");
const workspace_slide = @import("workspace_slide.zig");

/// A goal changing again within this many seconds of its previous change
/// is being dragged. The watcher ticks every 16ms, so a drag's gaps are
/// 16-32ms; an animation starts from a change with no predecessor.
pub const drag_gap: f64 = 0.05;

/// Mean delay between Hyprland changing a goal and the watcher reporting
/// it: half of the watcher's 16ms tick. Animations are started this much
/// earlier than the snapshot that announced them.
pub const report_latency: f64 = 0.008;

pub const Anim = struct {
    enabled: bool = true,
    ease: workspace_slide.Ease = .{ .spring = .{} },
    /// Seconds; bezier easing only (springs run on the wall clock).
    duration: f32 = 0.4,
};

pub const Rect = [4]f32; // x, y, w, h in layout pixels

const Entry = struct {
    addr: u64 = 0,
    used: bool = false,
    seen: bool = false,
    goal: Rect = .{ 0, 0, 0, 0 },
    from: Rect = .{ 0, 0, 0, 0 },
    start: f64 = 0,
    animating: bool = false,
    last_change: f64 = -1e9,
};

pub const max_entries = 64;

pub const Tracker = struct {
    anim: Anim = .{},
    entries: [max_entries]Entry = @splat(.{}),

    /// Feed a new snapshot's goal rects. Windows missing from it are
    /// forgotten: whatever happened to them off-strip, Hyprland did not
    /// animate it on this screen.
    pub fn noteGoals(self: *Tracker, addrs: []const u64, goals: []const Rect, time: f64) void {
        for (&self.entries) |*e| e.seen = false;
        for (addrs, goals) |addr, goal| {
            if (addr == 0) continue;
            const e = self.find(addr) orelse self.claim(addr, goal) orelse continue;
            e.seen = true;
            if (sameRect(e.goal, goal)) continue;
            const shown = self.sampleEntry(e, time);
            if (!self.anim.enabled or time - e.last_change < drag_gap) {
                e.animating = false; // dragged: follow the pointer
            } else {
                e.from = shown;
                e.start = time - report_latency;
                e.animating = true;
            }
            e.goal = goal;
            e.last_change = time;
        }
        for (&self.entries) |*e| {
            if (e.used and !e.seen) e.* = .{};
        }
    }

    /// How far the shown rect currently is from the goal (shown - goal),
    /// in layout pixels; zeros when settled or unknown.
    pub fn offset(self: *Tracker, addr: u64, time: f64) Rect {
        const e = self.find(addr) orelse return .{ 0, 0, 0, 0 };
        const s = self.sampleEntry(e, time);
        return .{ s[0] - e.goal[0], s[1] - e.goal[1], s[2] - e.goal[2], s[3] - e.goal[3] };
    }

    fn sampleEntry(self: *const Tracker, e: *Entry, time: f64) Rect {
        if (!e.animating) return e.goal;
        const t: f32 = @floatCast(@max(time - e.start, 0));
        const k: f32 = switch (self.anim.ease) {
            .cubic_bezier => |pts| blk: {
                if (self.anim.duration <= 0 or t >= self.anim.duration) {
                    e.animating = false;
                    return e.goal;
                }
                break :blk workspace_slide.bezierY(pts, t / self.anim.duration);
            },
            .spring => |sp| blk: {
                const r = workspace_slide.springEval(sp, t);
                if (workspace_slide.springSettled(r.value, r.velocity)) {
                    e.animating = false;
                    return e.goal;
                }
                break :blk r.value;
            },
        };
        var out: Rect = undefined;
        for (0..4) |i| out[i] = e.from[i] + (e.goal[i] - e.from[i]) * k;
        return out;
    }

    fn find(self: *Tracker, addr: u64) ?*Entry {
        for (&self.entries) |*e| {
            if (e.used and e.addr == addr) return e;
        }
        return null;
    }

    /// A new window starts settled at its goal: Hyprland's open animation
    /// is a pop-in, not a move, and is not mirrored.
    fn claim(self: *Tracker, addr: u64, goal: Rect) ?*Entry {
        for (&self.entries) |*e| {
            if (e.used) continue;
            e.* = .{ .addr = addr, .used = true, .goal = goal, .from = goal };
            return e;
        }
        return null;
    }
};

fn sameRect(a: Rect, b: Rect) bool {
    for (0..4) |i| {
        if (@abs(a[i] - b[i]) > 0.5) return false;
    }
    return true;
}

// --- Tests ---

const linear = Anim{ .ease = .{ .cubic_bezier = .{ 0, 0, 1, 1 } }, .duration = 1.0 };

test "an isolated goal change replays the curve from the shown rect" {
    var tr = Tracker{ .anim = linear };
    tr.noteGoals(&.{7}, &.{.{ 0, 0, 100, 100 }}, 0.0);
    tr.noteGoals(&.{7}, &.{.{ 200, 0, 100, 100 }}, 1.0);
    // Halfway through a 1s linear move the window is 100px short of goal
    // (the clock starts report_latency before the snapshot arrived).
    try std.testing.expectApproxEqAbs(@as(f32, -100), tr.offset(7, 1.5 - report_latency)[0], 0.01);
    try std.testing.expectEqual(@as(f32, 0), tr.offset(7, 2.1)[0]);
}

test "a retarget mid-animation starts from where the window is shown" {
    var tr = Tracker{ .anim = linear };
    tr.noteGoals(&.{7}, &.{.{ 0, 0, 100, 100 }}, 0.0);
    tr.noteGoals(&.{7}, &.{.{ 200, 0, 100, 100 }}, 1.0);
    // Shown at x=100 half way; retarget back to 0 from there.
    const mid = 1.5 - report_latency;
    tr.noteGoals(&.{7}, &.{.{ 0, 0, 100, 100 }}, mid);
    try std.testing.expectApproxEqAbs(@as(f32, 100), tr.offset(7, mid - report_latency)[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), tr.offset(7, mid - report_latency + 0.5)[0], 0.01);
}

test "a stream of changes one tick apart is a drag and is followed exactly" {
    var tr = Tracker{ .anim = linear };
    tr.noteGoals(&.{7}, &.{.{ 0, 0, 100, 100 }}, 0.0);
    tr.noteGoals(&.{7}, &.{.{ 5, 0, 100, 100 }}, 1.0);
    tr.noteGoals(&.{7}, &.{.{ 10, 0, 100, 100 }}, 1.016);
    try std.testing.expectEqual(@as(f32, 0), tr.offset(7, 1.02)[0]);
    tr.noteGoals(&.{7}, &.{.{ 30, 0, 100, 100 }}, 1.032);
    try std.testing.expectEqual(@as(f32, 0), tr.offset(7, 1.04)[0]);
}

test "a new or returning window starts at its goal" {
    var tr = Tracker{ .anim = linear };
    tr.noteGoals(&.{7}, &.{.{ 0, 0, 100, 100 }}, 0.0);
    tr.noteGoals(&.{}, &.{}, 1.0); // left the strip
    tr.noteGoals(&.{7}, &.{.{ 500, 0, 100, 100 }}, 2.0); // back, elsewhere
    try std.testing.expectEqual(@as(f32, 0), tr.offset(7, 2.1)[0]);
}

test "spring moves settle on the goal" {
    var tr = Tracker{};
    tr.noteGoals(&.{7}, &.{.{ 0, 0, 100, 100 }}, 0.0);
    tr.noteGoals(&.{7}, &.{.{ 0, 300, 100, 100 }}, 1.0);
    try std.testing.expect(tr.offset(7, 1.05)[1] < -50);
    try std.testing.expectEqual(@as(f32, 0), tr.offset(7, 5.0)[1]);
}

test "disabled animations follow goals immediately" {
    var tr = Tracker{ .anim = .{ .enabled = false } };
    tr.noteGoals(&.{7}, &.{.{ 0, 0, 100, 100 }}, 0.0);
    tr.noteGoals(&.{7}, &.{.{ 200, 0, 100, 100 }}, 1.0);
    try std.testing.expectEqual(@as(f32, 0), tr.offset(7, 1.1)[0]);
}
