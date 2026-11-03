//! MilkDrop presets: each is a set of per-frame equations, written as a
//! Zig function from this frame's inputs (time, bass/mid/treb, beat, the
//! waveform and spectrum, the desktop) to a Frame: the motion field the
//! warp pass re-samples the last frame through, the display filters, and
//! the waves, shapes and borders drawn on top. Colours come from the theme:
//! `hue` walks its chromatic slots.

const std = @import("std");
const palette_mod = @import("../../core/palette.zig");
const Batch = @import("../geometry.zig").Batch;

const tau = std.math.tau;

pub const Inputs = struct {
    t: f32 = 0,
    dt: f32 = 0,
    /// Smoothed bands, ~0..1 (breathing LFOs when no music plays).
    bass: f32 = 0,
    mid: f32 = 0,
    treb: f32 = 0,
    /// Kick envelope (1 on a kick, decaying), and kicks counted so far.
    beat: f32 = 0,
    beats: u32 = 0,
    /// 128 left then 128 right samples, about -1..1.
    wave: [256]f32 = @splat(0),
    spectrum: [64]f32 = @splat(0),
    aspect: f32 = 16.0 / 9.0,
    /// uv (0..1, y up).
    cursor: [2]f32 = .{ 0.5, 0.5 },
    focus: [2]f32 = .{ 0.5, 0.5 },
    windows: [32][4]f32 = undefined,
    window_count: usize = 0,
    colors: [16][3]f32 = default_colors,
    color_count: usize = 16,

    pub fn setPalette(self: *Inputs, pal: *const palette_mod.Palette) void {
        if (pal.color_count < 8) return;
        self.color_count = pal.color_count;
        for (0..pal.color_count) |i| self.colors[i] = .{ pal.colors[i].r, pal.colors[i].g, pal.colors[i].b };
    }

    /// A point on the loop through the theme's chromatic colours (normal,
    /// then bright when the theme has them), wrapping at 1.
    pub fn hue(self: *const Inputs, x: f32) [3]f32 {
        const slots = [_]usize{ 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14 };
        const n: usize = if (self.color_count >= 15) 12 else 6;
        const p = (x - @floor(x)) * @as(f32, @floatFromInt(n));
        const i: usize = @min(@as(usize, @intFromFloat(@floor(p))), n - 1);
        const f = p - @floor(p);
        const a = self.colors[slots[i]];
        const b = self.colors[slots[(i + 1) % n]];
        return .{ a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f };
    }

    /// Normalised spectrum bin k (0..63), 0..1.
    fn spec(self: *const Inputs, k: usize) f32 {
        var peak: f32 = 1e-4;
        for (self.spectrum[1..]) |v| peak = @max(peak, v);
        return std.math.clamp(self.spectrum[k] / peak, 0.0, 1.0);
    }
};

const default_colors = [16][3]f32{
    .{ 0.1, 0.1, 0.12 }, .{ 0.9, 0.3, 0.35 }, .{ 0.4, 0.85, 0.45 }, .{ 0.95, 0.8, 0.35 },
    .{ 0.35, 0.55, 0.95 }, .{ 0.8, 0.4, 0.9 }, .{ 0.35, 0.85, 0.9 }, .{ 0.85, 0.85, 0.85 },
    .{ 0.4, 0.4, 0.45 }, .{ 1.0, 0.45, 0.5 }, .{ 0.55, 1.0, 0.6 }, .{ 1.0, 0.9, 0.5 },
    .{ 0.5, 0.7, 1.0 }, .{ 0.9, 0.55, 1.0 }, .{ 0.5, 0.95, 1.0 }, .{ 1.0, 1.0, 1.0 },
};

/// The motion field and display filters: all numbers, so a transition can
/// interpolate them.
pub const Motion = struct {
    zoom: f32 = 1.0,
    zoomexp: f32 = 1.0,
    rot: f32 = 0,
    warp: f32 = 0,
    warp_speed: f32 = 1,
    warp_scale: f32 = 1,
    cx: f32 = 0.5,
    cy: f32 = 0.5,
    dx: f32 = 0,
    dy: f32 = 0,
    sx: f32 = 1,
    sy: f32 = 1,
    /// Zoom rippling out from the centre: amplitude, frequency, speed.
    ripple: f32 = 0,
    ripple_freq: f32 = 20,
    ripple_speed: f32 = 2,
    /// Extra rotation growing with radius (spirals).
    twist: f32 = 0,
    /// Mirror segments folded about the centre (0 = off).
    kaleido: f32 = 0,
    decay: f32 = 0.98,
    wrap: f32 = 1,
    // Display: video echo and filters.
    echo_alpha: f32 = 0,
    echo_zoom: f32 = 1,
    /// 0 normal, 1 flip x, 2 flip y, 3 both.
    echo_orient: f32 = 0,
    gamma: f32 = 1,
    brighten: f32 = 0,
    darken: f32 = 0,
    solarize: f32 = 0,
    invert: f32 = 0,

    /// The warp pass's five vec4s.
    pub fn pack(m: Motion) [20]f32 {
        return .{
            m.zoom,       m.zoomexp,    m.rot,          m.warp,
            m.warp_speed, m.warp_scale, m.cx,           m.cy,
            m.dx,         m.dy,         m.sx,           m.sy,
            m.ripple,     m.ripple_freq, m.ripple_speed, m.twist,
            m.kaleido,    m.decay,      m.wrap,         0,
        };
    }

    pub fn lerp(a: Motion, b: Motion, t: f32) Motion {
        var out: Motion = undefined;
        inline for (@typeInfo(Motion).@"struct".field_names) |f_name| {
            @field(out, f_name) = @field(a, f_name) + (@field(b, f_name) - @field(a, f_name)) * t;
        }
        return out;
    }
};

pub const WaveMode = enum { none, circle, scope, line, double_line, spectrum, dots, spiral };

pub const Wave = struct {
    mode: WaveMode = .none,
    x: f32 = 0.5,
    y: f32 = 0.5,
    /// Radius in screen heights (circle, dots, spectrum, spiral).
    rad: f32 = 0.25,
    ang: f32 = 0,
    scale: f32 = 1,
    alpha: f32 = 1,
    /// Line width in loop pixels.
    width: f32 = 3,
    color: [3]f32 = .{ 1, 1, 1 },
    /// End colour for a gradient along the wave; null = solid.
    color2: ?[3]f32 = null,
};

pub const Shape = struct {
    sides: u32 = 0,
    x: f32 = 0.5,
    y: f32 = 0.5,
    rad: f32 = 0.1,
    ang: f32 = 0,
    inner: [4]f32 = .{ 1, 1, 1, 0.5 },
    outer: [4]f32 = .{ 1, 1, 1, 0 },
    border: [4]f32 = .{ 1, 1, 1, 0 },
    border_width: f32 = 2,
    additive: bool = true,
};

pub const Frame = struct {
    motion: Motion = .{},
    waves: [2]Wave = .{ .{}, .{} },
    shapes: [4]Shape = .{ .{}, .{}, .{}, .{} },
    /// Outer border (at the screen edge) and inner border (inside it),
    /// thickness in screen heights.
    ob_size: f32 = 0,
    ob_color: [4]f32 = .{ 0, 0, 0, 0 },
    ib_size: f32 = 0,
    ib_color: [4]f32 = .{ 0, 0, 0, 0 },
    /// MilkDrop's darken_center: a dim disc at the motion centre, which
    /// otherwise re-samples itself every frame and burns to white.
    darken_center: bool = false,
    /// Window frames drawn into the loop (alpha 0 = off).
    win_alpha: f32 = 0,
    win_color: [3]f32 = .{ 1, 1, 1 },
    win_width: f32 = 3,

    pub fn draw(self: *const Frame, in: *const Inputs, alpha_b: *Batch, add_b: *Batch, fade: f32) void {
        if (fade <= 0.001) return;
        alpha_b.border(0, self.ob_size, faded(self.ob_color, fade));
        alpha_b.border(self.ob_size, self.ib_size, faded(self.ib_color, fade));
        if (self.darken_center) {
            alpha_b.polygon(.{ self.motion.cx, self.motion.cy }, 0.06, 24, 0, .{ 0, 0, 0, 0.35 * fade }, .{ 0, 0, 0, 0 });
        }

        for (self.shapes) |s| {
            if (s.sides < 3) continue;
            const b = if (s.additive) add_b else alpha_b;
            b.polygon(.{ s.x, s.y }, s.rad, s.sides, s.ang, faded(s.inner, fade), faded(s.outer, fade));
            if (s.border[3] > 0) b.ring(.{ s.x, s.y }, s.rad, s.sides, s.ang, s.border_width, faded(s.border, fade));
        }

        if (self.win_alpha > 0) {
            const col = [4]f32{ self.win_color[0], self.win_color[1], self.win_color[2], self.win_alpha * fade };
            for (in.windows[0..in.window_count]) |w| {
                if (w[2] <= 0) continue;
                const pts = [_][2]f32{ .{ w[0], w[1] }, .{ w[0] + w[2], w[1] }, .{ w[0] + w[2], w[1] + w[3] }, .{ w[0], w[1] + w[3] } };
                add_b.polyline(&pts, true, self.win_width, col);
            }
        }

        for (self.waves) |w| drawWave(w, in, add_b, fade);
    }
};

fn faded(c: [4]f32, f: f32) [4]f32 {
    return .{ c[0], c[1], c[2], c[3] * f };
}

fn mixColor(a: [3]f32, b: ?[3]f32, t: f32, alpha: f32) [4]f32 {
    const e = b orelse a;
    return .{ a[0] + (e[0] - a[0]) * t, a[1] + (e[1] - a[1]) * t, a[2] + (e[2] - a[2]) * t, alpha };
}

fn drawWave(w: Wave, in: *const Inputs, b: *Batch, fade: f32) void {
    if (w.mode == .none or w.alpha <= 0) return;
    const alpha = w.alpha * fade;
    const L = in.wave[0..128];
    const R = in.wave[128..256];
    const ca = @cos(w.ang);
    const sa = @sin(w.ang);
    var pts: [130][2]f32 = undefined;

    // A point `(u, v)` screen heights from the wave's centre, turned by its
    // angle, into uv.
    const P = struct {
        fn at(wv: Wave, asp: f32, cc: f32, ss: f32, u: f32, v: f32) [2]f32 {
            return .{ wv.x + (u * cc - v * ss) / asp, wv.y + u * ss + v * cc };
        }
    };

    switch (w.mode) {
        .none => {},
        .circle, .dots => {
            const n = 128;
            for (0..n) |i| {
                // Cross-fade the last samples into the first so it closes.
                const fi: f32 = @floatFromInt(i);
                var s = L[i];
                if (i >= n - 16) {
                    const k: f32 = (fi - (n - 16)) / 16.0;
                    s = s * (1 - k) + L[i - (n - 16)] * k;
                }
                const a = fi / n * tau;
                const r = w.rad + s * 0.18 * w.scale;
                pts[i] = P.at(w, in.aspect, ca, sa, @cos(a) * r, @sin(a) * r);
            }
            if (w.mode == .dots) {
                for (pts[0..n], 0..) |p, i| b.dot(p, w.width * 1.6, mixColor(w.color, w.color2, @as(f32, @floatFromInt(i)) / n, alpha));
            } else {
                for (0..n) |i| b.line(pts[i], pts[(i + 1) % n], w.width, mixColor(w.color, w.color2, @abs(@as(f32, @floatFromInt(i)) / n * 2 - 1), alpha));
            }
        },
        .scope => {
            // Phase space: left against a blend of right and a delayed left,
            // so even mono music draws loops rather than a diagonal.
            const n = 128;
            for (0..n) |i| {
                const u = L[i] * 0.42 * w.scale;
                const v = (R[i] * 0.5 + L[(i + 9) % 128] * 0.5) * 0.42 * w.scale;
                pts[i] = P.at(w, in.aspect, ca, sa, u, v);
            }
            for (0..n - 1) |i| b.line(pts[i], pts[i + 1], w.width, mixColor(w.color, w.color2, @as(f32, @floatFromInt(i)) / n, alpha));
        },
        .line, .double_line => {
            const n = 128;
            const half = 0.5 * in.aspect + 0.1;
            const rows: usize = if (w.mode == .double_line) 2 else 1;
            for (0..rows) |row| {
                const src = if (row == 0) L else R;
                const off: f32 = if (rows == 2) (if (row == 0) @as(f32, 0.09) else -0.09) else 0;
                for (0..n) |i| {
                    const fi: f32 = @floatFromInt(i);
                    const u = (fi / (n - 1) * 2 - 1) * half;
                    pts[i] = P.at(w, in.aspect, ca, sa, u, off + src[i] * 0.22 * w.scale);
                }
                for (0..n - 1) |i| b.line(pts[i], pts[i + 1], w.width, mixColor(w.color, w.color2, @as(f32, @floatFromInt(i)) / n, alpha));
            }
        },
        .spectrum => {
            // Mirrored spikes all the way round.
            const n = 96;
            for (0..n) |i| {
                const fi: f32 = @floatFromInt(i);
                const k = 1 + @min(i, n - i) * 62 / (n / 2);
                const m = in.spec(k);
                const a = fi / n * tau;
                const r1 = w.rad + m * 0.32 * w.scale;
                const p0 = P.at(w, in.aspect, ca, sa, @cos(a) * w.rad, @sin(a) * w.rad);
                const p1 = P.at(w, in.aspect, ca, sa, @cos(a) * r1, @sin(a) * r1);
                b.line(p0, p1, w.width, mixColor(w.color, w.color2, m, alpha));
            }
        },
        .spiral => {
            const n = 128;
            for (0..n) |i| {
                const fi: f32 = @floatFromInt(i);
                const k = fi / n;
                const a = k * tau * 3.0;
                const r = w.rad * k + L[i] * 0.06 * w.scale;
                pts[i] = P.at(w, in.aspect, ca, sa, @cos(a) * r, @sin(a) * r);
            }
            for (0..n - 1) |i| b.line(pts[i], pts[i + 1], w.width, mixColor(w.color, w.color2, @as(f32, @floatFromInt(i)) / n, alpha));
        },
    }
}

fn rgba(c: [3]f32, a: f32) [4]f32 {
    return .{ c[0], c[1], c[2], a };
}

pub const Preset = struct {
    name: []const u8,
    eval: *const fn (in: *const Inputs, f: *Frame) void,
};

pub const all = [_]Preset{
    .{ .name = "kaleido-bloom", .eval = kaleidoBloom },
    .{ .name = "tunnel", .eval = tunnel },
    .{ .name = "liquid", .eval = liquid },
    .{ .name = "galaxy", .eval = galaxy },
    .{ .name = "lissajous", .eval = lissajous },
    .{ .name = "starburst", .eval = starburst },
    .{ .name = "fountain", .eval = fountain },
    .{ .name = "ripples", .eval = ripples },
    .{ .name = "window-frames", .eval = windowFrames },
    .{ .name = "polygons", .eval = polygons },
    .{ .name = "plasma-storm", .eval = plasmaStorm },
};

pub fn find(name: []const u8) ?usize {
    for (all, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
    return null;
}

/// The original hyprglaze milkdrop: kaleidoscope folds that change count
/// on every kick, two crossed scopes.
fn kaleidoBloom(in: *const Inputs, f: *Frame) void {
    const segs = [_]f32{ 3, 4, 6, 8, 10, 12 };
    const m = &f.motion;
    m.kaleido = segs[in.beats % segs.len];
    m.zoom = 1.004 + in.bass * 0.012 + in.beat * 0.02;
    m.rot = (0.003 + in.mid * 0.006) * (1 + in.beat * 3);
    m.warp = 0.6 + in.treb * 1.5;
    m.decay = 0.955;
    f.waves[0] = .{ .mode = .line, .scale = 1.2, .alpha = 0.9, .width = 3, .color = in.hue(in.t * 0.05) };
    f.waves[1] = .{ .mode = .line, .ang = tau / 4.0, .scale = 0.9, .alpha = 0.6, .width = 2.5, .color = in.hue(in.t * 0.05 + 0.5) };
}

/// Shrinking frames: the outer border is redrawn every frame and the
/// zoom pulls each copy inward, down a tunnel that wanders.
fn tunnel(in: *const Inputs, f: *Frame) void {
    const m = &f.motion;
    m.zoom = 0.955 - in.bass * 0.025;
    m.zoomexp = 1.15;
    m.rot = 0.02 * @sin(in.t * 0.27) + in.beat * 0.03;
    m.cx = 0.5 + 0.12 * @sin(in.t * 0.21);
    m.cy = 0.5 + 0.1 * @cos(in.t * 0.17);
    m.decay = 0.985;
    m.wrap = 0;
    f.ob_size = 0.005;
    f.ob_color = rgba(in.hue(in.t * 0.09), 0.3 + in.beat * 0.3);
    f.waves[0] = .{ .mode = .circle, .x = m.cx, .y = m.cy, .rad = 0.06 + in.bass * 0.05, .scale = 0.5, .width = 3, .color = in.hue(in.t * 0.04 + 0.5) };
}

/// Heavy warp and a tilted scope, echoed larger behind itself.
fn liquid(in: *const Inputs, f: *Frame) void {
    const m = &f.motion;
    m.zoom = 1.008 + in.bass * 0.01;
    m.warp = 2.2 + in.bass * 2.5;
    m.warp_speed = 0.9;
    m.warp_scale = 1.6;
    m.rot = 0.004 * @sin(in.t * 0.3);
    m.dx = 0.002 * @sin(in.t * 0.4);
    m.decay = 0.97;
    m.echo_alpha = 0.35;
    m.echo_zoom = 1.25;
    f.waves[0] = .{
        .mode = .line,
        .y = 0.5 + 0.12 * @sin(in.t * 0.3),
        .ang = 0.25 * @sin(in.t * 0.2),
        .scale = 1.4,
        .width = 4,
        .color = in.hue(in.t * 0.03),
        .color2 = in.hue(in.t * 0.03 + 0.3),
    };
}

/// Rotation that grows with radius winds dotted rings into arms.
fn galaxy(in: *const Inputs, f: *Frame) void {
    const m = &f.motion;
    m.zoom = 1.015 + in.bass * 0.01;
    m.rot = 0.03;
    m.twist = -0.12 - in.mid * 0.05;
    m.decay = 0.975;
    f.waves[0] = .{ .mode = .dots, .rad = 0.18 + in.bass * 0.05, .scale = 0.8, .width = 2.5, .color = in.hue(in.t * 0.05) };
    f.waves[1] = .{ .mode = .dots, .rad = 0.32, .ang = in.t * 0.5, .alpha = 0.6, .width = 2, .color = in.hue(in.t * 0.05 + 0.4) };
    f.darken_center = true;
}

/// The oscilloscope in phase space, mirrored four ways by the echo.
fn lissajous(in: *const Inputs, f: *Frame) void {
    const m = &f.motion;
    m.zoom = 1.025 + in.bass * 0.015;
    m.rot = 0.012;
    m.decay = 0.94;
    m.echo_alpha = 0.5;
    m.echo_orient = 3;
    m.gamma = 1.4;
    f.waves[0] = .{ .mode = .scope, .scale = 1.6 + in.bass, .width = 3, .color = in.hue(in.t * 0.07), .color2 = in.hue(in.t * 0.07 + 0.25) };
}

/// Spectrum spikes blasted outward, harder on every kick.
fn starburst(in: *const Inputs, f: *Frame) void {
    const m = &f.motion;
    m.zoom = 1.03 + in.beat * 0.05;
    m.rot = 0.01 * @sin(in.t * 0.5);
    m.warp = 0.3;
    m.decay = 0.93;
    f.waves[0] = .{ .mode = .spectrum, .rad = 0.05, .width = 2.5, .color = in.hue(in.t * 0.06), .color2 = in.hue(in.t * 0.06 + 0.5) };
    const core = in.hue(in.t * 0.06 + 0.25);
    f.shapes[0] = .{ .sides = 32, .rad = 0.025 + in.bass * 0.04, .inner = rgba(core, 0.3), .outer = rgba(core, 0) };
    f.darken_center = true;
}

/// Everything rises and spreads from a wave along the bottom edge.
fn fountain(in: *const Inputs, f: *Frame) void {
    const m = &f.motion;
    m.dy = 0.011 + in.bass * 0.008;
    m.sx = 1.004;
    m.warp = 1.4 + in.treb;
    m.decay = 0.988;
    m.wrap = 0;
    f.waves[0] = .{ .mode = .line, .y = 0.08, .scale = 1.6, .width = 5, .color = in.hue(0.0), .color2 = in.hue(2.0 / 6.0) };
    f.waves[1] = .{ .mode = .line, .y = 0.08, .scale = 1.0, .alpha = 0.5, .width = 3, .color = in.hue(1.0 / 6.0) };
}

/// Rings of zoom roll out from the cursor, which wears a small scope.
fn ripples(in: *const Inputs, f: *Frame) void {
    const m = &f.motion;
    // Ripples stay smaller than the zoom, so every ring still moves out.
    m.zoom = 1.014 + in.bass * 0.01;
    m.ripple = 0.007 + in.bass * 0.008;
    m.ripple_freq = 28;
    m.ripple_speed = 3;
    m.rot = 0.003;
    m.warp = 0.4;
    m.cx = in.cursor[0];
    m.cy = in.cursor[1];
    m.decay = 0.975;
    f.waves[0] = .{ .mode = .circle, .x = in.cursor[0], .y = in.cursor[1], .rad = 0.05 + in.bass * 0.03, .scale = 0.6, .alpha = 0.6, .width = 3, .color = in.hue(in.t * 0.05) };
    f.darken_center = true;
    f.waves[1] = .{ .mode = .double_line, .scale = 0.8, .alpha = 0.45, .width = 2.5, .color = in.hue(in.t * 0.05 + 0.4), .color2 = in.hue(in.t * 0.05 + 0.7) };
}

/// The desktop as custom shapes: every window frame is drawn into the
/// loop and zoomed outward from the focused one.
fn windowFrames(in: *const Inputs, f: *Frame) void {
    const m = &f.motion;
    m.cx = in.focus[0];
    m.cy = in.focus[1];
    m.zoom = 1.03 + in.bass * 0.02;
    m.rot = 0.008 * @sin(in.t * 0.2);
    m.warp = 0.3;
    m.decay = 0.95;
    m.wrap = 0;
    f.win_alpha = 0.55;
    f.win_color = in.hue(in.t * 0.05);
    f.waves[0] = .{ .mode = .scope, .x = in.focus[0], .y = in.focus[1], .scale = 0.7, .alpha = 0.8, .width = 3, .color = in.hue(in.t * 0.05 + 0.5) };
}

/// Three polygons orbiting and spinning, with mirrored echo.
fn polygons(in: *const Inputs, f: *Frame) void {
    const m = &f.motion;
    m.zoom = 0.99 - in.bass * 0.01;
    m.rot = -0.01;
    m.warp = 0.6;
    m.decay = 0.975;
    m.echo_alpha = 0.3;
    m.echo_orient = 1;
    for (0..3) |k| {
        const fk: f32 = @floatFromInt(k);
        const a = in.t * 0.4 + fk * tau / 3.0;
        const spin: f32 = if (k % 2 == 0) 1.0 else -1.0;
        const col = in.hue(in.t * 0.05 + fk / 3.0);
        f.shapes[k] = .{
            .sides = @intCast(3 + k),
            .x = 0.5 + 0.25 * @cos(a) / in.aspect,
            .y = 0.5 + 0.25 * @sin(a),
            .rad = 0.08 + in.bass * 0.05,
            .ang = in.t * (0.5 + fk * 0.3) * spin,
            .inner = rgba(col, 0.35),
            .outer = rgba(in.hue(in.t * 0.05 + fk / 3.0 + 0.2), 0.05),
            .border = rgba(col, 0.8),
        };
    }
    f.waves[0] = .{ .mode = .circle, .rad = 0.1, .scale = 0.5, .alpha = 0.5, .width = 2, .color = in.hue(in.t * 0.05 + 0.5) };
}

/// Maximum warp, a spiral scope, brightened.
fn plasmaStorm(in: *const Inputs, f: *Frame) void {
    const m = &f.motion;
    m.warp = 4.5 + in.treb * 3;
    m.warp_speed = 1.6;
    m.warp_scale = 0.8;
    m.zoom = 1.0 + 0.01 * @sin(in.t * 0.3);
    m.rot = 0.006;
    m.decay = 0.975;
    f.waves[0] = .{ .mode = .spiral, .rad = 0.4, .ang = in.t * 0.3, .alpha = 0.55, .width = 3, .color = in.hue(in.t * 0.06), .color2 = in.hue(in.t * 0.06 + 0.35) };
}
