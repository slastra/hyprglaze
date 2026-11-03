//! The window strip: what the watcher reports, turned into the GL-space
//! window rects the shaders and effects draw.
//!
//! A watcher snapshot carries the active workspace's windows (rel 0) and
//! its nearest neighbours on either side (rel -1 / +1). The neighbours are
//! parked one surface span off-screen along the slide axis, so the whole
//! strip moves as one piece under the workspace-slide camera.
//!
//! Everything here is pure (no compositor, no GL), which is the point of
//! keeping it out of main.zig: it is unit-tested below.

const std = @import("std");
const hypr = @import("core/hypr.zig");
const geometry = @import("core/geometry.zig");
const transition = @import("core/transition.zig");
const workspace_slide = @import("core/workspace_slide.zig");
const window_anim = @import("core/window_anim.zig");
const shader_mod = @import("core/shader.zig");
const effects = @import("effects.zig");

pub const WindowRect = shader_mod.ShaderProgram.WindowRect;
const max = hypr.max_visible_windows;

/// The surface the strip is laid out on.
pub const View = struct {
    /// Surface height in buffer pixels; the y-flip pivots on it.
    surf_h: f32,
    /// Logical-to-buffer pixel scale.
    scale: f32,
    axis: workspace_slide.Axis,
    /// One workspace's extent along `axis`, in buffer pixels.
    span: f32,

    pub fn init(surf_w: f32, surf_h: f32, scale: f32, axis: workspace_slide.Axis) View {
        return .{
            .surf_h = surf_h,
            .scale = scale,
            .axis = axis,
            .span = if (axis == .vertical) surf_h else surf_w,
        };
    }
};

pub const RawState = struct {
    win: transition.Rect,
    win_address: u64,
    windows: [max]WindowRect,
    window_count: u8,
    window_info: [max]effects.WindowInfo,
    focused_class: [64]u8,
    focused_class_len: u8,
    focused_title: [64]u8,
    focused_title_len: u8,
};

/// Apply a slide offset to a rect position in GL space. Offsets are in
/// layout space (y down); the GL y-axis points up, so vertical offsets
/// flip sign.
pub fn applyOffset(x: *f32, y: *f32, axis: workspace_slide.Axis, amount: f32) void {
    switch (axis) {
        .horizontal => x.* += amount,
        .vertical => y.* -= amount,
        .none => {},
    }
}

/// Feed every strip window's goal rect (layout space, as reported) to the
/// move-animation tracker.
pub fn noteWindowGoals(tracker: *window_anim.Tracker, snap: *const hypr.VisibleWindows, time: f64) void {
    var addrs: [max]u64 = undefined;
    var goals: [max]window_anim.Rect = undefined;
    for (snap.windows[0..snap.count], 0..) |vw, i| {
        addrs[i] = vw.address;
        goals[i] = .{ @floatFromInt(vw.x), @floatFromInt(vw.y), @floatFromInt(vw.w), @floatFromInt(vw.h) };
    }
    tracker.noteGoals(addrs[0..snap.count], goals[0..snap.count], time);
}

/// A window's remaining animation (shown - goal) converted from layout
/// space to a GL-space rect delta. toGl is affine per component, so the
/// monitor origin cancels; y is flipped about the rect's bottom edge.
pub fn animOffsetGl(tracker: *window_anim.Tracker, addr: u64, time: f64, scale: f32) geometry.Rect {
    const o = tracker.offset(addr, time);
    return .{
        .x = o[0] * scale,
        .y = -(o[1] + o[3]) * scale,
        .w = o[2] * scale,
        .h = o[3] * scale,
    };
}

/// `r` plus the part of its window's move animation still to play at `time`.
pub fn animated(tracker: *window_anim.Tracker, r: WindowRect, time: f64, scale: f32) WindowRect {
    const d = animOffsetGl(tracker, r.address, time, scale);
    var out = r;
    out.x += d.x;
    out.y += d.y;
    out.w += d.w;
    out.h += d.h;
    return out;
}

/// Copy the active-workspace windows of `from` into `out`, parked at
/// `rel = -dir`: the set the camera will slide out. Same monitor, same
/// origin, so the coordinates carry over untouched.
pub fn captureOutgoing(out: *hypr.VisibleWindows, from: *const hypr.VisibleWindows, dir: f32) void {
    out.* = .{ .workspace_id = from.workspace_id, .origin_x = from.origin_x, .origin_y = from.origin_y };
    const rel: i8 = if (dir > 0) -1 else 1;
    for (from.windows[0..from.count]) |vw| {
        if (vw.rel != 0) continue;
        out.windows[out.count] = vw;
        out.windows[out.count].rel = rel;
        out.count += 1;
    }
}

/// Accumulates strip windows in GL surface space with their rel offsets
/// applied, in the order the caller emits them, capped at the uniform
/// array size.
const StripBuilder = struct {
    windows: [max]WindowRect = undefined,
    win_info: [max]effects.WindowInfo = undefined,
    focused_idx: ?usize = null,
    count: u8 = 0,
    view: View,
    focused_address: u64,

    fn add(self: *StripBuilder, vw: *const hypr.WindowGeometry, origin_x: i32, origin_y: i32) void {
        if (self.count >= max) return;
        const out = self.count;
        const v = self.view;
        const r = geometry.toGl(vw.x, vw.y, vw.w, vw.h, origin_x, origin_y, v.surf_h, v.scale);
        self.windows[out] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .address = vw.address };
        applyOffset(&self.windows[out].x, &self.windows[out].y, v.axis, @as(f32, @floatFromInt(vw.rel)) * v.span);
        var info = effects.WindowInfo{};
        const clen: u8 = @intCast(@min(vw.class_len, 64));
        if (clen > 0) @memcpy(info.class[0..clen], vw.class[0..clen]);
        info.class_len = clen;
        const tlen: u8 = @intCast(@min(vw.title_len, 64));
        if (tlen > 0) @memcpy(info.title[0..tlen], vw.title[0..tlen]);
        info.title_len = tlen;
        self.win_info[out] = info;
        self.count += 1;
        if (self.focused_address != 0 and vw.address == self.focused_address) self.focused_idx = out;
    }
};

/// Build the window strip from a snapshot, looking up the focused window
/// by `focused_address` (from the event stream, or a one-time bootstrap
/// query at startup). Strip windows (rel ±1) are parked one `view.span`
/// off-screen along the slide axis; with sliding disabled they are dropped.
/// With `outgoing` set (a slide is running), the snapshot's `skip_rel`
/// bucket is replaced by it: the workspace being left slides out, not
/// whichever workspace happens to have the nearest id. Emission order is
/// active, outgoing, far side, so the cap drops what is off-screen anyway.
///
/// `win_address` in the result is 0 when the focused window is not present
/// in the visible list (e.g. focus is on another monitor's workspace).
pub fn deriveRawState(
    visible: *const hypr.VisibleWindows,
    view: View,
    focused_address: u64,
    outgoing: ?*const hypr.VisibleWindows,
    skip_rel: i8,
) RawState {
    var b = StripBuilder{ .view = view, .focused_address = focused_address };

    for (visible.windows[0..visible.count]) |*vw| {
        if (vw.rel == 0) b.add(vw, visible.origin_x, visible.origin_y);
    }
    if (view.axis != .none) {
        if (outgoing) |og| {
            for (og.windows[0..og.count]) |*vw| b.add(vw, og.origin_x, og.origin_y);
        }
        for (visible.windows[0..visible.count]) |*vw| {
            if (vw.rel == 0) continue;
            if (outgoing != null and vw.rel == skip_rel) continue;
            b.add(vw, visible.origin_x, visible.origin_y);
        }
    }

    var out = RawState{
        .win = .{},
        .win_address = 0,
        .windows = b.windows,
        .window_count = b.count,
        .window_info = b.win_info,
        .focused_class = @splat(0),
        .focused_class_len = 0,
        .focused_title = @splat(0),
        .focused_title_len = 0,
    };
    if (b.focused_idx) |fi| {
        const wf = b.windows[fi];
        out.win = .{ .x = wf.x, .y = wf.y, .w = wf.w, .h = wf.h };
        out.win_address = wf.address;
        out.focused_class = b.win_info[fi].class;
        out.focused_class_len = b.win_info[fi].class_len;
        out.focused_title = b.win_info[fi].title;
        out.focused_title_len = b.win_info[fi].title_len;
    }
    return out;
}

/// Move the drawn window rects one frame toward `targets` (where each
/// window will be on screen when the frame is shown).
///
/// - Mid workspace slide (`camera` set), the whole strip — targets already
///   carry their rel offsets — shifts by the camera. Positions are
///   analytic, so per-frame smoothing is bypassed.
/// - A changed window count, or `snap` (a workspace boundary crossed
///   without a slide), snaps every rect to its target.
/// - Otherwise each rect is smoothed by `alpha` toward the target with the
///   same address. Hyprland can reorder windows on focus change; matching by
///   address keeps the pairing stable across the whole strip. Any mismatch
///   means the set changed, so it snaps rather than glide unrelated windows
///   into each other. This is also the landing path after a slide settles:
///   the camera's last offset is <= 0.1% of a span, smoothed away invisibly.
pub fn follow(
    shown: *[max]WindowRect,
    shown_count: *u8,
    targets: []const WindowRect,
    camera: ?f32,
    axis: workspace_slide.Axis,
    snap: bool,
    alpha: f32,
) void {
    const n: u8 = @intCast(targets.len);
    if (camera) |cam| {
        for (targets, 0..) |t, i| {
            shown[i] = t;
            applyOffset(&shown[i].x, &shown[i].y, axis, cam);
        }
        shown_count.* = n;
        return;
    }
    if (n == shown_count.* and !snap) {
        if (matchByAddress(shown[0..n], targets)) |matched| {
            for (shown[0..n], matched[0..n]) |*s, t| {
                s.x += (t.x - s.x) * alpha;
                s.y += (t.y - s.y) * alpha;
                s.w += (t.w - s.w) * alpha;
                s.h += (t.h - s.h) * alpha;
                s.address = t.address;
            }
            return;
        }
    }
    @memcpy(shown[0..n], targets);
    shown_count.* = n;
}

/// `targets` reordered to line up with `shown` by address, or null when
/// the two are not the same set (an unknown or zero address).
fn matchByAddress(shown: []const WindowRect, targets: []const WindowRect) ?[max]WindowRect {
    var used: [max]bool = @splat(false);
    var matched: [max]WindowRect = undefined;
    next: for (targets) |t| {
        if (t.address == 0) return null;
        for (shown, 0..) |s, i| {
            if (!used[i] and s.address == t.address) {
                used[i] = true;
                matched[i] = t;
                continue :next;
            }
        }
        return null;
    }
    return matched;
}

// --- tests ---

const testing = std.testing;

fn win(addr: u64, rel: i8, x: i32, y: i32, w: i32, h: i32) hypr.WindowGeometry {
    return .{ .x = x, .y = y, .w = w, .h = h, .address = addr, .rel = rel };
}

fn snapshot(ws: []const hypr.WindowGeometry) hypr.VisibleWindows {
    var s = hypr.VisibleWindows{ .workspace_id = 1 };
    for (ws) |w| {
        s.windows[s.count] = w;
        s.count += 1;
    }
    return s;
}

// 1000x500 surface, horizontal slides, scale 1.
const view_h = View.init(1000, 500, 1.0, .horizontal);

test "applyOffset moves along the axis, flipping y for vertical" {
    var x: f32 = 10;
    var y: f32 = 20;
    applyOffset(&x, &y, .horizontal, 5);
    try testing.expectEqual(@as(f32, 15), x);
    applyOffset(&x, &y, .vertical, 5);
    try testing.expectEqual(@as(f32, 15), y);
    applyOffset(&x, &y, .none, 99);
    try testing.expectEqual(@as(f32, 15), x);
    try testing.expectEqual(@as(f32, 15), y);
}

test "View.init picks the span along the slide axis" {
    try testing.expectEqual(@as(f32, 1000), View.init(1000, 500, 1, .horizontal).span);
    try testing.expectEqual(@as(f32, 500), View.init(1000, 500, 1, .vertical).span);
}

test "deriveRawState flips into GL space and finds the focused window" {
    var s = snapshot(&.{ win(0xa, 0, 100, 50, 200, 100), win(0xb, 0, 400, 300, 100, 100) });
    s.windows[1].class_len = 5;
    @memcpy(s.windows[1].class[0..5], "kitty");
    const raw = deriveRawState(&s, view_h, 0xb, null, 0);
    try testing.expectEqual(@as(u8, 2), raw.window_count);
    // y: 500 - (50 + 100) = 350
    try testing.expectEqual(@as(f32, 350), raw.windows[0].y);
    try testing.expectEqual(@as(u64, 0xb), raw.win_address);
    try testing.expectEqual(@as(f32, 400), raw.win.x);
    try testing.expectEqual(@as(f32, 100), raw.win.y);
    try testing.expectEqualStrings("kitty", raw.focused_class[0..raw.focused_class_len]);
}

test "deriveRawState reports no focus when the address is not visible" {
    const s = snapshot(&.{win(0xa, 0, 0, 0, 10, 10)});
    const raw = deriveRawState(&s, view_h, 0xdead, null, 0);
    try testing.expectEqual(@as(u64, 0), raw.win_address);
    try testing.expectEqual(@as(u8, 0), raw.focused_class_len);
}

test "deriveRawState parks neighbours a span away, or drops them without an axis" {
    const s = snapshot(&.{ win(1, -1, 100, 0, 10, 10), win(2, 0, 100, 0, 10, 10), win(3, 1, 100, 0, 10, 10) });
    const raw = deriveRawState(&s, view_h, 0, null, 0);
    try testing.expectEqual(@as(u8, 3), raw.window_count);
    // Active first, then the neighbours in snapshot order.
    try testing.expectEqual(@as(u64, 2), raw.windows[0].address);
    try testing.expectEqual(@as(f32, 100), raw.windows[0].x);
    try testing.expectEqual(@as(f32, -900), raw.windows[1].x);
    try testing.expectEqual(@as(f32, 1100), raw.windows[2].x);

    const vert = deriveRawState(&s, View.init(1000, 500, 1.0, .vertical), 0, null, 0);
    // rel -1 sits one surface height ABOVE in layout space, so higher in GL.
    try testing.expectEqual(@as(f32, 490 + 500), vert.windows[1].y);

    const flat = deriveRawState(&s, View.init(1000, 500, 1.0, .none), 0, null, 0);
    try testing.expectEqual(@as(u8, 1), flat.window_count);
    try testing.expectEqual(@as(u64, 2), flat.windows[0].address);
}

test "deriveRawState swaps the skipped bucket for the outgoing set" {
    // Switching 1 -> 5 sliding right: the strip's -1 bucket is workspace 3,
    // but what slides out is workspace 1, captured as `outgoing`.
    const prev = snapshot(&.{ win(0x1, 0, 0, 0, 10, 10), win(0x2, 1, 0, 0, 10, 10) });
    var outgoing: hypr.VisibleWindows = .{};
    captureOutgoing(&outgoing, &prev, 1.0);
    try testing.expectEqual(@as(u8, 1), outgoing.count);
    try testing.expectEqual(@as(i8, -1), outgoing.windows[0].rel);

    const now = snapshot(&.{ win(0x5, 0, 0, 0, 10, 10), win(0x3, -1, 0, 0, 10, 10), win(0x6, 1, 0, 0, 10, 10) });
    const raw = deriveRawState(&now, view_h, 0, &outgoing, -1);
    try testing.expectEqual(@as(u8, 3), raw.window_count);
    try testing.expectEqual(@as(u64, 0x5), raw.windows[0].address);
    try testing.expectEqual(@as(u64, 0x1), raw.windows[1].address);
    try testing.expectEqual(@as(f32, -1000), raw.windows[1].x);
    try testing.expectEqual(@as(u64, 0x6), raw.windows[2].address);
}

test "captureOutgoing parks on the side opposite the slide direction" {
    const prev = snapshot(&.{win(0x1, 0, 0, 0, 10, 10)});
    var out: hypr.VisibleWindows = .{};
    captureOutgoing(&out, &prev, -1.0);
    try testing.expectEqual(@as(i8, 1), out.windows[0].rel);
}

test "deriveRawState caps the strip at the uniform array size, active first" {
    var s = hypr.VisibleWindows{};
    for (0..max) |i| {
        s.windows[i] = win(@intCast(i + 1), if (i < 4) 1 else 0, 0, 0, 10, 10);
    }
    s.count = max;
    const raw = deriveRawState(&s, view_h, 0, null, 0);
    try testing.expectEqual(@as(u8, max), raw.window_count);
    // All 28 active windows precede the 4 neighbours.
    try testing.expectEqual(@as(u64, 5), raw.windows[0].address);
    try testing.expectEqual(@as(u64, 1), raw.windows[max - 4].address);
}

test "animOffsetGl converts a layout offset into a GL delta" {
    var tr = window_anim.Tracker{ .anim = .{ .ease = .{ .cubic_bezier = .{ 0, 0, 1, 1 } }, .duration = 1.0 } };
    const s0 = snapshot(&.{win(7, 0, 0, 0, 100, 100)});
    noteWindowGoals(&tr, &s0, 0.0);
    // Moved 200 down and grew 100 taller; shown rect starts at the old one.
    const s1 = snapshot(&.{win(7, 0, 0, 200, 100, 200)});
    noteWindowGoals(&tr, &s1, 1.0);
    // Sampled the moment the replay starts, the window is still shown at
    // the old rect.
    const t0 = 1.0 - window_anim.report_latency;
    const d = animOffsetGl(&tr, 7, t0, 2.0);
    // Layout offset (0,-200,0,-100): GL y moves by -(-200 + -100)*2 = 600.
    try testing.expectApproxEqAbs(@as(f32, 600), d.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, -200), d.h, 0.01);

    const r = animated(&tr, .{ .x = 1, .y = 2, .w = 3, .h = 4, .address = 7 }, t0, 2.0);
    try testing.expectApproxEqAbs(@as(f32, 602), r.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), r.x, 0.01);
}

fn rect(addr: u64, x: f32) WindowRect {
    return .{ .x = x, .y = 0, .w = 10, .h = 10, .address = addr };
}

test "follow smooths each window toward the target with its address" {
    var shown: [max]WindowRect = undefined;
    shown[0] = rect(1, 0);
    shown[1] = rect(2, 100);
    var n: u8 = 2;
    // Same set, reordered: pairing is by address, not index.
    follow(&shown, &n, &.{ rect(2, 200), rect(1, 10) }, null, .horizontal, false, 0.5);
    try testing.expectEqual(@as(u8, 2), n);
    try testing.expectEqual(@as(u64, 1), shown[0].address);
    try testing.expectEqual(@as(f32, 5), shown[0].x);
    try testing.expectEqual(@as(f32, 150), shown[1].x);
}

test "follow snaps when the set changes, on request, or under the camera" {
    var shown: [max]WindowRect = undefined;
    shown[0] = rect(1, 0);
    var n: u8 = 1;
    // A different window with the same count snaps.
    follow(&shown, &n, &.{rect(3, 50)}, null, .horizontal, false, 0.5);
    try testing.expectEqual(@as(u64, 3), shown[0].address);
    try testing.expectEqual(@as(f32, 50), shown[0].x);
    // A count change snaps.
    follow(&shown, &n, &.{ rect(3, 60), rect(4, 70) }, null, .horizontal, false, 0.5);
    try testing.expectEqual(@as(u8, 2), n);
    try testing.expectEqual(@as(f32, 60), shown[0].x);
    // `snap` overrides smoothing for an unchanged set.
    follow(&shown, &n, &.{ rect(3, 0), rect(4, 0) }, null, .horizontal, true, 0.5);
    try testing.expectEqual(@as(f32, 0), shown[1].x);
    // The camera places the strip exactly, offset along the axis.
    follow(&shown, &n, &.{ rect(3, 20), rect(4, 30) }, -5, .horizontal, false, 0.5);
    try testing.expectEqual(@as(f32, 15), shown[0].x);
    try testing.expectEqual(@as(f32, 25), shown[1].x);
}
