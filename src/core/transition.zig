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

pub const TransitionState = struct {
    // Smoothed outputs
    current_win: Rect = .{},
    current_cursor: [2]f32 = .{ 0, 0 },

    // Focus tracking (by window address, not geometry)
    focused_address: u64 = 0,

    // Focus transition timing
    transition_start: f64 = 0,
    transition_duration: f64 = 0.3,
    transition_progress: f32 = 1.0, // 0 = just changed, 1 = settled

    // Smoothing factors (0 = instant, 1 = frozen)
    cursor_smoothing: f32 = 0.15,
    geometry_smoothing: f32 = 0.12,

    pub fn init() TransitionState {
        return .{};
    }

    pub fn update(self: *TransitionState, time: f64, raw_win: Rect, raw_cursor: [2]f32, win_address: u64) void {
        // --- Focus change detection (by identity, not geometry) ---
        if (win_address != 0 and win_address != self.focused_address) {
            self.focused_address = win_address;
            self.transition_start = time;
            self.transition_progress = 0;
        }

        // Advance transition timer
        if (self.transition_progress < 1.0) {
            const elapsed = time - self.transition_start;
            const t: f32 = @floatCast(@min(elapsed / self.transition_duration, 1.0));
            self.transition_progress = t;
        }

        // --- Exponential smoothing for window geometry ---
        if (raw_win.hasArea()) {
            const gs = self.geometry_smoothing;
            self.current_win.x = smoothValue(self.current_win.x, raw_win.x, gs);
            self.current_win.y = smoothValue(self.current_win.y, raw_win.y, gs);
            self.current_win.w = smoothValue(self.current_win.w, raw_win.w, gs);
            self.current_win.h = smoothValue(self.current_win.h, raw_win.h, gs);
        }

        // --- Exponential smoothing for cursor ---
        const cs = self.cursor_smoothing;
        self.current_cursor[0] = smoothValue(self.current_cursor[0], raw_cursor[0], cs);
        self.current_cursor[1] = smoothValue(self.current_cursor[1], raw_cursor[1], cs);
    }

    pub fn seed(self: *TransitionState, win: Rect, cursor: [2]f32, address: u64) void {
        self.current_win = win;
        self.current_cursor = cursor;
        self.focused_address = address;
    }
};

fn smoothValue(current: f32, target: f32, factor: f32) f32 {
    const result = current + (target - current) * (1.0 - factor);
    // Snap when very close to avoid perpetual drift
    if (@abs(result - target) < 0.5) return target;
    return result;
}
