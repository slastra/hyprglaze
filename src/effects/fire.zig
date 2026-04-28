const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const effects = @import("../effects.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const max_windows = 32;

// Velocity from a 48-sample position ring buffer, as a windowed finite
// difference (pos_now - pos_120ms_ago) / elapsed. Smooth regardless of the
// source sample rate — avoids staircase artifacts from single-frame dx/dt when
// Hyprland updates at ~60Hz and we render faster.
const hist_size = 48;
const vel_window_secs: f32 = 0.12;
const min_vel_dt: f32 = 0.03;

// Speed thresholds (pixels/second).
const speed_fade_lo: f32 = 100.0; // below: flame fully present
const speed_fade_hi: f32 = 1800.0; // above: flame fully hidden
const speed_dir_update: f32 = 80.0; // update wipe axis only above this

// Fade time constants (seconds).
const tau_out: f32 = 0.033; // fast attack when motion starts
const tau_in: f32 = 2.25; // slow release when motion stops
const tau_dir: f32 = 0.25; // smoothing for wipe axis rotation

// Velocity caps to reject outliers.
const win_vel_cap: f32 = 8000.0;

const Sample = struct {
    t: f32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    valid: bool = false,
};

const History = struct {
    samples: [hist_size]Sample = [_]Sample{.{}} ** hist_size,
    idx: u8 = 0,

    fn push(self: *History, t: f32, x: f32, y: f32) void {
        self.samples[self.idx] = .{ .t = t, .x = x, .y = y, .valid = true };
        self.idx = (self.idx + 1) % hist_size;
    }

    fn reset(self: *History) void {
        for (&self.samples) |*s| s.valid = false;
        self.idx = 0;
    }

    /// Return mean velocity over the last `target_age` seconds. Picks the
    /// sample whose age is closest to `target_age`.
    fn velocity(self: *const History, now: f32, target_age: f32) [2]f32 {
        const recent = self.samples[(self.idx + hist_size - 1) % hist_size];
        if (!recent.valid) return .{ 0, 0 };

        const target_t = now - target_age;
        var best: Sample = .{};
        var best_diff: f32 = std.math.floatMax(f32);
        for (self.samples) |s| {
            if (!s.valid) continue;
            if (s.t >= recent.t - 0.001) continue;
            const diff = @abs(s.t - target_t);
            if (diff < best_diff) {
                best_diff = diff;
                best = s;
            }
        }
        if (!best.valid) return .{ 0, 0 };

        const dt = recent.t - best.t;
        if (dt < min_vel_dt) return .{ 0, 0 };
        return .{ (recent.x - best.x) / dt, (recent.y - best.y) / dt };
    }
};

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

pub const Context = struct {
    now: f32 = 0,
    win_hist: [max_windows]History = [_]History{.{}} ** max_windows,
    win_vel: [max_windows][2]f32 = [_][2]f32{.{ 0, 0 }} ** max_windows,

    /// Motion fade: 1 = stationary (full flame), 0 = moving (hidden).
    /// Asymmetric first-order filter so the flame doesn't snap back in.
    win_fade: [max_windows]f32 = [_]f32{1.0} ** max_windows,

    /// Latched wipe axis (unit vector). Updated only when motion is meaningful,
    /// so the axis stays stable across the long fade-in after motion stops.
    win_dir: [max_windows][2]f32 = [_][2]f32{.{ 1.0, 0.0 }} ** max_windows,

    /// Cached uniform locations — resolved on first upload, then reused.
    cached_program: c.GLuint = 0,
    loc_vel: c.GLint = -1,
    loc_dir: c.GLint = -1,
    loc_fade: c.GLint = -1,
    loc_time: c.GLint = -1,

    pub fn init() Context {
        return .{};
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.1);
        self.now += dt;

        const count = @min(state.windows.len, max_windows);
        const k_dir = 1.0 - @exp(-dt / tau_dir);

        for (0..count) |i| {
            const w = state.windows[i];
            self.win_hist[i].push(self.now, w.x, w.y);

            const v = self.win_hist[i].velocity(self.now, vel_window_secs);
            self.win_vel[i][0] = std.math.clamp(v[0], -win_vel_cap, win_vel_cap);
            self.win_vel[i][1] = std.math.clamp(v[1], -win_vel_cap, win_vel_cap);

            const speed = @sqrt(self.win_vel[i][0] * self.win_vel[i][0] +
                self.win_vel[i][1] * self.win_vel[i][1]);

            // Asymmetric fade toward target.
            const target = 1.0 - smoothstep(speed_fade_lo, speed_fade_hi, speed);
            const tau = if (target < self.win_fade[i]) tau_out else tau_in;
            const k_fade = 1.0 - @exp(-dt / tau);
            self.win_fade[i] += (target - self.win_fade[i]) * k_fade;

            // Smoothly rotate the wipe axis toward the current velocity
            // direction, but only while there's actual motion.
            if (speed > speed_dir_update) {
                const inv = 1.0 / speed;
                const tx = self.win_vel[i][0] * inv;
                const ty = self.win_vel[i][1] * inv;
                self.win_dir[i][0] += (tx - self.win_dir[i][0]) * k_dir;
                self.win_dir[i][1] += (ty - self.win_dir[i][1]) * k_dir;
                const mag = @sqrt(self.win_dir[i][0] * self.win_dir[i][0] +
                    self.win_dir[i][1] * self.win_dir[i][1]);
                if (mag > 0.001) {
                    self.win_dir[i][0] /= mag;
                    self.win_dir[i][1] /= mag;
                } else {
                    self.win_dir[i] = .{ tx, ty };
                }
            }
        }

        // Clear dead slots so a new window filling the slot doesn't inherit
        // stale trajectory data.
        for (count..max_windows) |i| {
            self.win_vel[i] = .{ 0, 0 };
            self.win_fade[i] = 1.0;
            self.win_dir[i] = .{ 1.0, 0.0 };
            self.win_hist[i].reset();
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        // Resolve uniform locations once per program — re-resolve if the shader
        // was reloaded (program ID changes on hot-reload).
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_vel = c.glGetUniformLocation(prog.program, "iWindowVel[0]");
            self.loc_dir = c.glGetUniformLocation(prog.program, "iWindowDir[0]");
            self.loc_fade = c.glGetUniformLocation(prog.program, "iWindowFade[0]");
            self.loc_time = c.glGetUniformLocation(prog.program, "iFireTime");
        }

        // Flatten the vec2 arrays into [x0,y0, x1,y1, ...] for glUniform2fv.
        var vel_flat: [max_windows * 2]f32 = undefined;
        var dir_flat: [max_windows * 2]f32 = undefined;
        for (0..max_windows) |i| {
            vel_flat[i * 2 + 0] = self.win_vel[i][0];
            vel_flat[i * 2 + 1] = self.win_vel[i][1];
            dir_flat[i * 2 + 0] = self.win_dir[i][0];
            dir_flat[i * 2 + 1] = self.win_dir[i][1];
        }

        if (self.loc_vel >= 0) c.glUniform2fv(self.loc_vel, max_windows, &vel_flat[0]);
        if (self.loc_dir >= 0) c.glUniform2fv(self.loc_dir, max_windows, &dir_flat[0]);
        if (self.loc_fade >= 0) c.glUniform1fv(self.loc_fade, max_windows, &self.win_fade[0]);
        // Fire-local time, resets each activation. Keeps noise-coordinate
        // magnitudes small so the inner fbm hash retains f32 precision —
        // global iTime grows unbounded and stalls the noise pattern after
        // a couple of minutes of uptime.
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
    }

    pub fn deinit(_: *Context) void {}
};
