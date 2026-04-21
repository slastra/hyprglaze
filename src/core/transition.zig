const std = @import("std");

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn hasArea(self: Rect) bool {
        return self.w > 0 and self.h > 0;
    }
};

/// Debounce window for committing a focus change (seconds). Filters the
/// brief focus flicks Hyprland reports when the cursor passes over other
/// windows during a drag, so the wallpaper's focus state stays on the
/// window the user is actually interacting with.
const focus_debounce_secs: f64 = 0.12;

pub const TransitionState = struct {
    // Smoothed outputs
    current_win: Rect = .{},
    current_cursor: [2]f32 = .{ 0, 0 },

    // Previously focused window — snapshotted at focus change so effects can
    // animate the outgoing state (e.g. fade out its crown glow).
    prev_win: Rect = .{},
    prev_focused_address: u64 = 0,

    // Focus tracking (by window address, not geometry)
    focused_address: u64 = 0,

    // Pending focus change — only commits after it's stable for focus_debounce_secs.
    pending_address: u64 = 0,
    pending_start: f64 = 0,

    // Focus transition timing
    transition_start: f64 = 0,
    transition_duration: f64 = 0.3,
    transition_progress: f32 = 1.0, // 0 = just changed, 1 = settled

    // Smoothing factors (0 = instant, 1 = frozen)
    cursor_smoothing: f32 = 0.15,
    geometry_smoothing: f32 = 0.12,

    // Timing for frame-rate independent smoothing
    last_time: f64 = 0,

    pub fn init() TransitionState {
        return .{};
    }

    pub fn update(self: *TransitionState, time: f64, raw_win: Rect, raw_cursor: [2]f32, win_address: u64) void {
        // Frame-rate independent dt
        const dt: f32 = if (self.last_time > 0)
            @floatCast(@min(time - self.last_time, 0.1))
        else
            1.0 / 30.0;
        self.last_time = time;

        // --- Focus change detection, debounced ---
        if (win_address != 0 and win_address != self.focused_address) {
            if (win_address != self.pending_address) {
                // New candidate — start the debounce timer.
                self.pending_address = win_address;
                self.pending_start = time;
            } else if (time - self.pending_start >= focus_debounce_secs) {
                // Candidate has been stable long enough — commit.
                if (self.focused_address != 0 and self.current_win.hasArea()) {
                    self.prev_win = self.current_win;
                    self.prev_focused_address = self.focused_address;
                }
                self.focused_address = win_address;
                self.transition_start = time;
                self.transition_progress = 0;
                if (raw_win.hasArea()) self.current_win = raw_win;
                self.pending_address = 0;
            }
        } else if (win_address == self.focused_address) {
            // Reverted back to the currently-focused window — cancel pending.
            self.pending_address = 0;
        }

        // Advance transition timer
        if (self.transition_progress < 1.0) {
            const elapsed = time - self.transition_start;
            const t: f32 = @floatCast(@min(elapsed / self.transition_duration, 1.0));
            self.transition_progress = t;
        }

        // --- Frame-rate independent exponential smoothing ---
        // Only smooth geometry when raw_win actually represents the focused
        // window. Skipping during a pending (non-committed) focus flicker
        // keeps current_win on the window the user is actively engaged with.
        if (raw_win.hasArea() and win_address == self.focused_address) {
            const ag = smoothAlpha(self.geometry_smoothing, dt);
            self.current_win.x += (raw_win.x - self.current_win.x) * ag;
            self.current_win.y += (raw_win.y - self.current_win.y) * ag;
            self.current_win.w += (raw_win.w - self.current_win.w) * ag;
            self.current_win.h += (raw_win.h - self.current_win.h) * ag;
        }

        const ac = smoothAlpha(self.cursor_smoothing, dt);
        self.current_cursor[0] += (raw_cursor[0] - self.current_cursor[0]) * ac;
        self.current_cursor[1] += (raw_cursor[1] - self.current_cursor[1]) * ac;
    }

    pub fn seed(self: *TransitionState, win: Rect, cursor: [2]f32, address: u64) void {
        self.current_win = win;
        self.current_cursor = cursor;
        self.focused_address = address;
    }
};

/// Convert a per-frame smoothing factor to a frame-rate independent alpha.
/// Factor is tuned for 30fps: 0 = instant, 1 = frozen.
fn smoothAlpha(factor: f32, dt: f32) f32 {
    const f = std.math.clamp(factor, 0.001, 0.999);
    const speed = -@log(f) * 30.0;
    return 1.0 - @exp(-speed * dt);
}
