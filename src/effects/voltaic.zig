const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("audio.zig");
const bands_mod = @import("bands.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

const max_windows = 32;

const WindowRect = shader_mod.ShaderProgram.WindowRect;

/// Active arc pool. Arcs only strike between window borders.
const max_arcs = 12;

// Geometry budget. Every channel is a polyline of short segments, emitted
// in chunks of eight consecutive segments. A chunk is one row of an
// RGBA32F texture (eight endpoint texels, then eight parameter texels) and
// carries a padded bounding box, so the shader rejects a whole chunk with
// one test and only walks the segments near the pixel.
const seg_per_chunk = 8;
const max_chunks = 256;
const tex_w = seg_per_chunk * 2;
const row_floats = tex_w * 4;

/// How far a channel's glow reaches, in px at 1440 lines (scaled by `px`).
/// The shader subtracts each falloff's value at this radius so the chunk
/// boxes never show as a cutoff.
const glow_reach: f32 = 170.0;

/// Most points one channel is cut into.
const max_pts = 96;

// A channel's fine structure (the crackle) re-seeds this many times per
// beat while its gross path drifts continuously: 32 Hz at the 120 BPM
// fallback. Real arcs do the same thing, re-igniting along a hot channel
// that itself only wanders.
const crackle_per_beat: f64 = 16.0;

// Stepped-leader propagation time: how long a fresh stroke takes to bridge
// the gap from source window to target. A hot tip rides the advancing front.
// Kept very brief: real leaders cross in microseconds; this is just enough
// frames (~3-4 at 60fps) to read as a reach rather than an instant flash.
const leader_extend: f32 = 0.055;

// Pre-beat feeler streamers: how far ahead of a downbeat the groping sparks
// begin to reach out from window edges (seconds).
const tendril_lead: f32 = 0.12;

// Storm mode: sustained energy holds a standing arc between the two
// largest windows. Engages above this smoothed-energy threshold, with
// asymmetric ramps so it snaps on with a chorus and lingers a beat after.
const storm_threshold: f32 = 0.32;
const storm_tau_in: f32 = 0.4;
const storm_tau_out: f32 = 1.6;

// Ambient spawn cadence bounds (seconds), divided by the arc_rate param.
const spawn_min: f32 = 0.30;
const spawn_max: f32 = 1.10;

// Focus aura: short arcs crawling along the focused window's border,
// plasma-globe style. Both endpoints live on the frame, parameterized by
// perimeter position so they ride the window through moves and focus
// transitions (the smoothed rect glides; the crawls glide with it).
const max_crawls = 6;

// Live channels one pair of windows carries before a new discharge takes
// an existing channel instead, and the longest such a channel is kept lit.
const pair_channels = 2;
const max_burn: f32 = 2.5;

// Side streamers a main channel can carry at once, and how many crackle
// ticks each one lives.
const fork_slots = 3;
const fork_ticks: f32 = 5.0;

// Afterglow: an arc that has gone out leaves its channel cooling in place,
// violet, for this many seconds (a hard strike's lingers longest).
const cool_min: f32 = 0.18;
const cool_max: f32 = 0.50;

const Crawl = struct {
    /// Perimeter offset of the start point and arc-length of the walk to
    /// the end point, resolved against the *current* focused rect each
    /// frame, never cached as coordinates.
    t0: f32 = 0,
    dl: f32 = 0,
    seed: u32 = 0,
    age: f32 = 0,
    life: f32 = 0,
    intensity: f32 = 0,
    active: bool = false,
};

/// Where an arc roots on a window: a point on its border in the window's
/// own 0..1 space, so the root rides the window through moves and resizes.
const Anchor = struct {
    addr: u64 = 0,
    idx: u8 = 0,
    n: [2]f32 = .{ 0, 0 },
    /// On a top or bottom edge, so the root slides in x.
    horiz: bool = false,

    fn of(win: WindowRect, idx: usize, p: [2]f32) Anchor {
        const w = @max(win.w, 1.0);
        const h = @max(win.h, 1.0);
        const dx = @min(p[0] - win.x, win.x + win.w - p[0]);
        const dy = @min(p[1] - win.y, win.y + win.h - p[1]);
        return .{
            .addr = win.address,
            .idx = @intCast(idx),
            .n = .{
                std.math.clamp((p[0] - win.x) / w, 0.0, 1.0),
                std.math.clamp((p[1] - win.y) / h, 0.0, 1.0),
            },
            .horiz = dy <= dx,
        };
    }

    /// This frame's root, `slide` px along its edge. Null once the window
    /// is gone, which puts the arc out.
    fn resolve(self: Anchor, windows: []const WindowRect, slide: f32) ?[2]f32 {
        const win = find: {
            if (self.addr != 0) {
                for (windows) |w| if (w.address == self.addr) break :find w;
                return null;
            }
            if (self.idx >= windows.len) return null;
            break :find windows[self.idx];
        };
        var p = [2]f32{ win.x + self.n[0] * win.w, win.y + self.n[1] * win.h };
        if (self.horiz) {
            p[0] = std.math.clamp(p[0] + slide, win.x, win.x + win.w);
        } else {
            p[1] = std.math.clamp(p[1] + slide, win.y, win.y + win.h);
        }
        return p;
    }
};

const Arc = struct {
    from: Anchor = .{},
    to: Anchor = .{},
    seed: u32 = 0,
    age: f32 = 0,
    life: f32 = 0,
    intensity: f32 = 0,
    /// This channel's own looseness, around 1.
    amp: f32 = 1,
    /// Which side the channel bows to as it stretches, -1 or 1.
    bow: f32 = 1,
    /// Seconds after the leader lands that the channel re-ignites (a second
    /// flash down the same path), 0 for none.
    restrike: f32 = 0,
    /// Age at which a later discharge last took this channel, -1 for never.
    kicked: f32 = -1,
    /// How long the dead channel takes to cool, and the crackle tick it
    /// froze on when the current stopped.
    cool: f32 = 0,
    froze_at: ?u32 = null,
    active: bool = false,
};

/// One channel's points for this frame.
const Path = struct {
    pts: [max_pts + 1][2]f32 = undefined,
    n: usize = 0,
};

fn hash32(x: u32) u32 {
    var h = x;
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    return h;
}

fn hashU(seed: u32, a: u32, b: u32) u32 {
    return hash32(seed ^ hash32(a *% 0x9E3779B1 +% hash32(b *% 0x85EBCA6B +% 0x27d4eb2f)));
}

/// 0..1 from three integers.
fn hash01(seed: u32, a: u32, b: u32) f32 {
    return @as(f32, @floatFromInt(hashU(seed, a, b) >> 8)) * (1.0 / 16777216.0);
}

fn lattice(v: f32) u32 {
    return @bitCast(@as(i32, @intFromFloat(v)));
}

/// Value noise over (x, t), -1..1, always smooth in t. `kinked` joins the
/// lattice values along x with straight runs, so the curve turns sharp
/// corners instead of rounding them.
fn vnoise(seed: u32, x: f32, t: f32, kinked: bool) f32 {
    const xi = @floor(x);
    const ti = @floor(t);
    const fx = x - xi;
    const ft = t - ti;
    const ux = if (kinked) fx else fx * fx * (3.0 - 2.0 * fx);
    const ut = ft * ft * (3.0 - 2.0 * ft);
    const X = lattice(xi);
    const T = lattice(ti);
    const a = hash01(seed, X, T);
    const b = hash01(seed, X +% 1, T);
    const cc = hash01(seed, X, T +% 1);
    const d = hash01(seed, X +% 1, T +% 1);
    const lo = a + (b - a) * ux;
    const hi = cc + (d - cc) * ux;
    return (lo + (hi - lo) * ut) * 2.0 - 1.0;
}

const smoothstep = bands_mod.smoothstep;

/// Closest point on a window's border to `p`. Points inside the rect get
/// pushed out to the nearest edge so arcs always root on the frame, not
/// somewhere under the window.
fn closestOnBorder(win: WindowRect, p: [2]f32) [2]f32 {
    const x0 = win.x;
    const y0 = win.y;
    const x1 = win.x + win.w;
    const y1 = win.y + win.h;
    var cx = std.math.clamp(p[0], x0, x1);
    var cy = std.math.clamp(p[1], y0, y1);

    if (cx > x0 and cx < x1 and cy > y0 and cy < y1) {
        const d_left = cx - x0;
        const d_right = x1 - cx;
        const d_bot = cy - y0;
        const d_top = y1 - cy;
        const m = @min(@min(d_left, d_right), @min(d_bot, d_top));
        if (m == d_left) {
            cx = x0;
        } else if (m == d_right) {
            cx = x1;
        } else if (m == d_bot) {
            cy = y0;
        } else {
            cy = y1;
        }
    }
    return .{ cx, cy };
}

/// Point on a rect's border at perimeter offset `t` (wraps), walking
/// bottom → right → top → left.
fn perimeterPoint(rect: anytype, t: f32) [2]f32 {
    const w = @max(rect.w, 1.0);
    const h = @max(rect.h, 1.0);
    const per = 2.0 * (w + h);
    var s = @mod(t, per);
    if (s < w) return .{ rect.x + s, rect.y };
    s -= w;
    if (s < h) return .{ rect.x + w, rect.y + s };
    s -= h;
    if (s < w) return .{ rect.x + w - s, rect.y + h };
    s -= w;
    return .{ rect.x, rect.y + h - s };
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    /// Pixel scale against a 1440-line screen, so a channel keeps its
    /// proportions at 4K.
    px: f32,
    now: f64 = 0,

    arcs: [max_arcs]Arc = @splat(.{}),
    next_slot: u8 = 0,
    spawn_timer: f32 = 0,
    arc_rate: f32 = 1.0,

    /// The standing arc of storm mode, outside the pool so strikes never
    /// recycle its slot.
    storm_arc: Arc = .{},

    crawls: [max_crawls]Crawl = @splat(.{}),
    next_crawl: u8 = 0,
    crawl_timer: f32 = 0,

    /// Chance a fork slot carries a streamer, treble-driven, set each frame.
    branch_chance: f32 = 0.15,

    // This frame's geometry: max_chunks rows of row_floats (see the budget
    // notes above), plus one padded box per row.
    tex_data: []f32,
    boxes: [max_chunks][4]f32 = undefined,
    chunk_count: u32 = 0,
    /// Segments already in the open chunk (row `chunk_count`).
    fill: u32 = 0,
    tex: c.GLuint = 0,

    // Thunder flash: full-screen ambient brighten on big downbeat discharges,
    // fast decay, the room lighting up.
    flash: f32 = 0,

    // Audio analysis (glitch.zig pattern, shared in bands.zig)
    an: bands_mod.Splitter = .{},
    energy_ema: f32 = 0,
    storm: f32 = 0,

    // BPM phase sync: beat_phase_total accumulates beats at bpm_est per
    // minute; detected beats snap it to the nearest integer to keep the
    // clock anchored to real music across passages of different energy.
    bpm_est: f32 = 120.0,
    beat_phase_total: f64 = 0,
    last_beat_now: f64 = -1.0,

    /// Cached uniform locations, resolved on first upload and re-resolved
    /// on shader hot-reload (program ID changes).
    u: Uniforms(.{
        .segtex = "iSegTex",
        .boxes = "iChunkBox[0]",
        .chunks = "iChunkCount",
        .px = "iPx",
        .time = "iVoltTime",
        .beat = "iBeat",
        .bass = "iBass",
        .treble = "iTreble",
        .flash = "iFlash",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const tex_data = try allocator.alloc(f32, max_chunks * row_floats);
        errdefer allocator.free(tex_data);
        @memset(tex_data, 0);
        const audio = try audio_mod.spawnIfMusic(allocator, params);

        return .{
            .allocator = allocator,
            .audio = audio,
            .rng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15),
            .width = width,
            .height = height,
            .px = std.math.clamp(height / 1440.0, 0.6, 2.0),
            .arc_rate = params.getFloat("arc_rate", 1.0),
            .tex_data = tex_data,
        };
    }

    /// Roots for an arc between windows `i` and `j`, on the facing borders,
    /// jittered so repeated strikes wander. False when the borders touch
    /// and there is no gap to strike across.
    fn rootPair(self: *Context, windows: []const WindowRect, i: usize, j: usize, from: *Anchor, to: *Anchor) bool {
        const r = self.rng.random();
        const aim_j = [2]f32{
            windows[j].x + windows[j].w * (0.2 + r.float(f32) * 0.6),
            windows[j].y + windows[j].h * (0.2 + r.float(f32) * 0.6),
        };
        const a = closestOnBorder(windows[i], aim_j);
        const b = closestOnBorder(windows[j], a);
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        if (dx * dx + dy * dy < 24.0 * 24.0) return false;
        from.* = Anchor.of(windows[i], i, a);
        to.* = Anchor.of(windows[j], j, b);
        return true;
    }

    /// Pick a window and partner it with its nearest neighbor (or a random
    /// other half the time).
    fn pickPair(self: *Context, windows: []const WindowRect) ?[2]usize {
        const r = self.rng.random();
        const count = @min(windows.len, max_windows);
        if (count < 2) return null;

        const i = r.intRangeLessThan(usize, 0, count);
        var j: usize = 0;
        if (r.float(f32) < 0.5) {
            var best_d: f32 = std.math.floatMax(f32);
            for (0..count) |k| {
                if (k == i) continue;
                const dx = (windows[k].x + windows[k].w * 0.5) - (windows[i].x + windows[i].w * 0.5);
                const dy = (windows[k].y + windows[k].h * 0.5) - (windows[i].y + windows[i].h * 0.5);
                const d = dx * dx + dy * dy;
                if (d < best_d) {
                    best_d = d;
                    j = k;
                }
            }
        } else {
            j = r.intRangeLessThan(usize, 0, count - 1);
            if (j >= i) j += 1;
        }
        return .{ i, j };
    }

    /// A fresh arc. `sustain` (0..1) is how long it holds: a beat's
    /// discharge snaps and is gone, an idle arc burns on and stretches.
    fn spawnArc(self: *Context, windows: []const WindowRect, intensity: f32, sustain: f32) void {
        const r = self.rng.random();
        const pair = self.pickPair(windows) orelse return;

        // Current takes the path that is already ionized. Once a gap holds
        // its channels, a new discharge re-ignites the freshest of them
        // rather than opening another beside it.
        const wa = windows[pair[0]].address;
        const wb = windows[pair[1]].address;
        var live: u32 = 0;
        var freshest: ?*Arc = null;
        for (&self.arcs) |*o| {
            if (!o.active or o.age >= o.life) continue;
            const same = (o.from.addr == wa and o.to.addr == wb) or (o.from.addr == wb and o.to.addr == wa);
            if (!same) continue;
            live += 1;
            if (freshest == null or o.age < freshest.?.age) freshest = o;
        }
        if (live >= pair_channels) {
            const o = freshest.?;
            o.kicked = o.age;
            o.intensity = @max(o.intensity, intensity);
            if (o.age < max_burn) o.life = @max(o.life, o.age + 0.2);
            return;
        }

        var arc = Arc{};
        if (!self.rootPair(windows, pair[0], pair[1], &arc.from, &arc.to)) return;

        const snap = 0.22 + r.float(f32) * 0.22;
        const hold = 0.60 + r.float(f32) * 0.90;
        arc.seed = r.int(u32);
        arc.life = snap + (hold - snap) * sustain + intensity * 0.08;
        arc.intensity = intensity;
        arc.amp = 0.8 + r.float(f32) * 0.45;
        arc.bow = if (r.boolean()) 1.0 else -1.0;
        // A hard discharge re-ignites once down the same channel, the
        // flicker of a multi-stroke flash.
        if (intensity >= 0.75) arc.restrike = 0.05 + r.float(f32) * 0.06;
        arc.cool = cool_min + (cool_max - cool_min) * smoothstep(0.6, 1.2, intensity);
        arc.active = true;

        self.arcs[self.next_slot] = arc;
        self.next_slot = (self.next_slot + 1) % max_arcs;
    }

    /// Hand the standing arc to the pool to cool where it broke, freeing
    /// its slot for the re-strike.
    fn retire(self: *Context, arc: Arc) void {
        var gone = arc;
        gone.intensity *= self.storm * (0.55 + self.an.bass * 0.6);
        gone.age = @max(gone.age, gone.life);
        self.arcs[self.next_slot] = gone;
        self.next_slot = (self.next_slot + 1) % max_arcs;
        self.storm_arc.active = false;
    }

    // ---- geometry emission ----

    fn row(self: *Context, chunk: u32) []f32 {
        return self.tex_data[chunk * row_floats ..][0..row_floats];
    }

    /// Close the open chunk, so the next segment starts a new one. Called
    /// between channels: a chunk's box only stays tight while its segments
    /// are neighbors.
    fn closeChunk(self: *Context) void {
        if (self.fill == 0) return;
        const data = self.row(self.chunk_count);
        // Unused slots: zero brightness, which the shader skips.
        @memset(data[(seg_per_chunk + self.fill) * 4 ..], 0);
        const pad = glow_reach * self.px;
        const box = &self.boxes[self.chunk_count];
        box.* = .{ box[0] - pad, box[1] - pad, box[2] + pad, box[3] + pad };
        self.chunk_count += 1;
        self.fill = 0;
    }

    /// One segment. `cool` runs from 0, a live channel, to 1, an ember.
    fn pushSeg(self: *Context, p: [2]f32, q: [2]f32, bright: f32, half_w: f32, cool: f32) void {
        if (self.chunk_count >= max_chunks or bright < 0.004) return;
        const data = self.row(self.chunk_count);
        const box = &self.boxes[self.chunk_count];
        const lo = [2]f32{ @min(p[0], q[0]), @min(p[1], q[1]) };
        const hi = [2]f32{ @max(p[0], q[0]), @max(p[1], q[1]) };
        if (self.fill == 0) {
            box.* = .{ lo[0], lo[1], hi[0], hi[1] };
        } else {
            box.* = .{ @min(box[0], lo[0]), @min(box[1], lo[1]), @max(box[2], hi[0]), @max(box[3], hi[1]) };
        }
        data[self.fill * 4 ..][0..4].* = .{ p[0], p[1], q[0], q[1] };
        data[(seg_per_chunk + self.fill) * 4 ..][0..4].* = .{ bright, half_w, cool, 0 };
        self.fill += 1;
        if (self.fill == seg_per_chunk) self.closeChunk();
    }

    /// The channel from `a` to `b`: the chord cut into short segments and
    /// pushed sideways by fractal noise sampled along its length. Each
    /// octave halves the wavelength and scales the excursion by `gain`, so
    /// the path is jagged at every scale down to the segment length.
    ///
    /// The long octaves drift smoothly in `drift_t` (the channel wanders);
    /// the short ones re-seed on every crackle `tick` (it buzzes). `amp` is
    /// the longest octave's excursion in px and `bow` an arch added at
    /// mid-span. A `free_end` path is a streamer: rooted at `a` only, its
    /// tip wanders.
    fn buildPath(self: *const Context, out: *Path, a: [2]f32, b: [2]f32, seed: u32, amp: f32, bow: [2]f32, drift_t: f32, tick: u32, free_end: bool) void {
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const chord = @sqrt(dx * dx + dy * dy);
        out.pts[0] = a;
        if (chord < 4.0) {
            out.pts[1] = b;
            out.n = 1;
            return;
        }
        const ux = dx / chord;
        const uy = dy / chord;

        const seg_len = 11.0 * self.px;
        const n = std.math.clamp(@as(usize, @intFromFloat(@round(chord / seg_len))), 4, max_pts);
        const n_f: f32 = @floatFromInt(n);
        // How far from a root the channel is held to it.
        const pin_len = @min(chord * 0.22, 70.0 * self.px);
        const gain: f32 = 0.66;
        // Octaves shorter than this buzz instead of drifting.
        const crackle_below = 90.0 * self.px;
        // Per-point jitter under the shortest octave: the hairy edge.
        const fuzz = std.math.clamp(amp * 0.09, 0.8 * self.px, 4.0 * self.px);

        for (1..n + 1) |i| {
            const s = @as(f32, @floatFromInt(i)) / n_f;
            const x = s * chord;

            var side: f32 = 0;
            var along: f32 = 0;
            var lambda = chord * 0.6;
            var a_o = amp;
            var o: u32 = 0;
            while (o < 7 and lambda >= seg_len * 2.2) : (o += 1) {
                const t: f32 = if (lambda < crackle_below)
                    @floatFromInt(tick & 0xffff)
                else
                    drift_t * 0.5 * std.math.pow(f32, 1.6, @floatFromInt(o));
                // The two longest octaves are the channel's sweep and stay
                // round; the rest are its zigzag.
                const kinked = o >= 2;
                // Each octave starts at its own phase, or their corners
                // would line up into a regular sawtooth.
                const xo = x / lambda + hash01(seed, o, 9) * 16.0;
                side += a_o * vnoise(seed +% o *% 7919, xo, t, kinked);
                along += a_o * 0.3 * vnoise(seed +% o *% 7919 +% 0x51ed, xo, t, kinked);
                lambda *= 0.5;
                a_o *= gain;
            }
            side += fuzz * (hash01(seed, @intCast(i), tick) * 2.0 - 1.0);

            // Held at the roots, free in between. The linear start lets the
            // channel leave a border at an angle.
            const near = @min(1.0, x / pin_len);
            const far = if (free_end) 1.0 else @min(1.0, (chord - x) / pin_len);
            const hold = (1.0 - (1.0 - near) * (1.0 - near)) * (1.0 - (1.0 - far) * (1.0 - far));
            const arch = if (free_end) s else @sin(std.math.pi * s);

            out.pts[i] = .{
                a[0] + ux * (x + along * hold) - uy * side * hold + bow[0] * arch,
                a[1] + uy * (x + along * hold) + ux * side * hold + bow[1] * arch,
            };
        }
        if (!free_end) out.pts[n] = b;
        out.n = n;
    }

    /// Emit a path as one channel. `reach` (0..1) draws only as far as an
    /// advancing leader has got, its frontier segment burning hot. A
    /// tapered channel thins and dims to nothing at its tip.
    fn emitPath(self: *Context, path: *const Path, reach: f32, bright: f32, half_w: f32, taper: bool, cool: f32) void {
        self.closeChunk();
        const n_f: f32 = @floatFromInt(path.n);
        const reach_n = std.math.clamp(reach, 0.0, 1.0) * n_f;
        for (0..path.n) |i| {
            const fi: f32 = @floatFromInt(i);
            if (fi >= reach_n) break;
            const frac = @min(reach_n - fi, 1.0);
            const t = fi / n_f;
            var sb = bright;
            var sw = half_w;
            if (taper) {
                sb *= (1.0 - t) * (1.0 - t * 0.5);
                sw *= 1.0 - t * 0.45;
            }
            if (frac < 1.0) sb *= 1.0 + (1.0 - frac) * 1.4;
            const p = path.pts[i];
            const q = [2]f32{
                p[0] + (path.pts[i + 1][0] - p[0]) * frac,
                p[1] + (path.pts[i + 1][1] - p[1]) * frac,
            };
            self.pushSeg(p, q, sb, sw, cool);
        }
        self.closeChunk();
    }

    /// One arc for this frame: its channel and its side streamers while
    /// it burns, then the same channel cooling once it is out. `gain`
    /// scales its light.
    fn drawArc(self: *Context, arc: *Arc, windows: []const WindowRect, tick_now: u32, tick_f: f32, wander: f32, gain: f32) void {
        const age = arc.age;
        const out = age >= arc.life;
        // With the current gone nothing re-ignites the channel: its fine
        // structure holds the shape it died in and only drifts.
        if (out and arc.froze_at == null) arc.froze_at = tick_now;
        const tick = if (out) arc.froze_at.? else tick_now;

        // The roots creep along their borders, as an arc's feet do on an
        // electrode.
        const slide = 34.0 * self.px;
        const a = arc.from.resolve(windows, vnoise(arc.seed ^ 0xA53C, age * 0.9, 0, false) * slide) orelse {
            arc.active = false;
            return;
        };
        const b = arc.to.resolve(windows, vnoise(arc.seed ^ 0x5AC3, age * 0.9, 0, false) * slide) orelse {
            arc.active = false;
            return;
        };
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const chord = @sqrt(dx * dx + dy * dy);
        if (chord < 24.0) return;

        const p = @min(age / arc.life, 1.0);
        const reach = std.math.clamp(age / leader_extend, 0.0, 1.0);
        // Seconds since the leader landed and the channel lit.
        const lit = age - leader_extend;

        var env: f32 = 0.55;
        if (lit >= 0) {
            var pulse = @exp(-lit / 0.07);
            if (arc.restrike > 0 and lit > arc.restrike) pulse += 0.8 * @exp(-(lit - arc.restrike) / 0.05);
            if (arc.kicked >= 0) pulse += @exp(-(age - arc.kicked) / 0.06);
            env = 0.62 + 0.8 * pulse;
        }
        // Dying: the channel dims, cools from white through blue to violet
        // and starts to drop out. Once it is out the ember fades on alone.
        const dying = smoothstep(0.6, 1.0, p);
        env *= 1.0 - 0.45 * dying;
        if (out) {
            const q = (age - arc.life) / arc.cool;
            env *= (1.0 - q) * (1.0 - q);
        } else {
            if (hash01(arc.seed, tick, 2) < dying * 0.5) env *= 0.35;
            env *= 0.82 + 0.30 * hash01(arc.seed, tick, 1);
        }
        env *= arc.intensity * gain;
        if (env < 0.012) return;

        // A fresh strike is taut. As it burns the hot channel loosens,
        // bows to one side and lifts, until it is too long to hold.
        const grow = smoothstep(0.0, 1.0, age / (arc.life + arc.cool));
        const amp = std.math.clamp(chord * 0.07, 6.0 * self.px, 64.0 * self.px) * arc.amp * wander * (0.55 + 0.85 * grow);
        const lean = arc.bow * chord * 0.09 * grow;
        const bow = [2]f32{ -dy / chord * lean, dx / chord * lean + chord * 0.05 * grow };

        var path: Path = .{};
        self.buildPath(&path, a, b, arc.seed, amp, bow, age + @as(f32, @floatFromInt(arc.seed & 0xff)), tick, false);
        const half_w = self.px * (0.6 + 0.3 * @min(env, 1.2));
        self.emitPath(&path, reach, env, half_w, false, dying);
        if (out) return;

        // Side streamers: short sparks that shoot off a node of the
        // channel, each alive for a few crackle ticks.
        const n_f: f32 = @floatFromInt(path.n);
        var fork: Path = .{};
        for (0..fork_slots) |k| {
            const ku: u32 = @intCast(k);
            const e_f = (tick_f + @as(f32, @floatFromInt(k)) * 1.37) / fork_ticks;
            const epoch: u32 = @intFromFloat(e_f);
            const ph = e_f - @floor(e_f);
            const fseed = hashU(arc.seed, epoch, ku);
            if (hash01(fseed, 0, 0) > self.branch_chance) continue;
            const node_f = (0.12 + 0.76 * hash01(fseed, 1, 0)) * n_f;
            if (node_f >= reach * n_f) continue; // the leader has not got there
            const node: usize = @intFromFloat(node_f);
            if (node < 1 or node + 1 > path.n) continue;
            var tx = path.pts[node + 1][0] - path.pts[node - 1][0];
            var ty = path.pts[node + 1][1] - path.pts[node - 1][1];
            const tl = @sqrt(tx * tx + ty * ty);
            if (tl < 1.0) continue;
            tx /= tl;
            ty /= tl;
            const sign: f32 = if (hash01(fseed, 2, 0) < 0.5) -1.0 else 1.0;
            const ang = (0.45 + 0.6 * hash01(fseed, 3, 0)) * sign;
            const ca = @cos(ang);
            const sa = @sin(ang);
            // It shoots out over the first third of its life, then fades.
            const shot = smoothstep(0.0, 0.3, ph);
            const len = std.math.clamp(chord * (0.10 + 0.20 * hash01(fseed, 4, 0)), 30.0 * self.px, 260.0 * self.px) * shot;
            const root = path.pts[node];
            const tip = [2]f32{ root[0] + (tx * ca - ty * sa) * len, root[1] + (tx * sa + ty * ca) * len };
            self.buildPath(&fork, root, tip, fseed, len * 0.10, .{ 0, 0 }, age, tick, true);
            self.emitPath(&fork, 1.0, env * 0.6 * (1.0 - ph), half_w * 0.75, true, dying);
        }
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;
        const r = self.rng.random();

        // ---- audio analysis (same band split as glitch/swarm) ----
        // Band split + beat detection (spectral flux on bass), see bands.zig.
        const wave = audio_mod.waveformOr0(self.audio);
        const beat_hit = self.an.update(&wave, dt);

        // Slow energy envelope + asymmetric storm ramp: choruses snap the
        // storm on, and it lets go a moment after the section ends.
        self.energy_ema += (self.an.energy - self.energy_ema) * @min(1.0, 2.0 * dt);
        const storm_target: f32 = if (self.energy_ema > storm_threshold) 1.0 else 0.0;
        const storm_tau = if (storm_target > self.storm) storm_tau_in else storm_tau_out;
        self.storm += (storm_target - self.storm) * (1.0 - @exp(-dt / storm_tau));

        // Thunder flash decays fast (snap on, quick falloff). Triggered below
        // on strong downbeat discharges; storm passages keep it flickering.
        self.flash *= @exp(-7.0 * dt);
        if (self.flash < 0.004) self.flash = 0;

        // ---- BPM-phase sync ----
        // Advance before snap so crossing detection uses the pre-snap fraction.
        const prev_phase_total = self.beat_phase_total;
        self.beat_phase_total += dt * (self.bpm_est / 60.0);

        if (beat_hit) {
            // Update tempo estimate from inter-onset interval (IOI).
            if (self.last_beat_now > 0.0) {
                const ioi: f32 = @floatCast(self.now - self.last_beat_now);
                if (ioi >= 0.25 and ioi <= 2.0) {
                    var ioi_bpm: f32 = 60.0 / ioi;
                    while (ioi_bpm > 180.0) { ioi_bpm *= 0.5; }
                    while (ioi_bpm < 60.0) { ioi_bpm *= 2.0; }
                    self.bpm_est += (ioi_bpm - self.bpm_est) * 0.25;
                }
            }
            self.last_beat_now = self.now;
            // Phase-lock: snap to nearest downbeat. frac(beat_phase_total) → ~0.
            self.beat_phase_total = @round(self.beat_phase_total);
        }

        // Fractional phases for crossing detection.
        const ppf: f32 = @floatCast(prev_phase_total - @floor(prev_phase_total));
        const cpf: f32 = @floatCast(self.beat_phase_total - @floor(self.beat_phase_total));

        // Half-beat "and": 8th-note syncopation.
        const half_crossed = ppf < 0.5 and cpf >= 0.5;
        // Coasting arc: full beat elapsed without a detected hit, which keeps
        // the display alive during quiet passages at the fallback 120 BPM.
        const full_crossed = cpf < ppf and !beat_hit;

        // Pre-beat charge: in the lead window before the next predicted
        // downbeat, feeler streamers grope out from window edges. Ramps 0→1
        // across the window. Gated on music energy so silence stays calm and
        // the free-running clock can't make the edges twitch in the quiet.
        const beat_period = 60.0 / @max(self.bpm_est, 1.0);
        const lead_frac = std.math.clamp(tendril_lead / beat_period, 0.0, 0.85);
        const charge: f32 = if (self.an.energy > 0.08 and cpf > (1.0 - lead_frac))
            smoothstep(1.0 - lead_frac, 1.0, cpf)
        else
            0.0;

        // ---- arc lifecycle ----
        for (&self.arcs) |*arc| {
            if (!arc.active) continue;
            arc.age += dt;
            if (arc.age >= arc.life + arc.cool) arc.active = false;
        }
        if (self.storm_arc.active) {
            self.storm_arc.age += dt;
            if (self.storm_arc.age >= self.storm_arc.life) self.retire(self.storm_arc);
        }

        // Treble bushes the channels out: hi-hats raise the streamer chance.
        self.branch_chance = std.math.clamp(0.18 + self.an.treble * 0.45, 0.18, 0.6);

        // Idle arcs fill silences and burn long; with music they come
        // faster and shorter, and the beat's own discharges take over.
        const calm = 1.0 - std.math.clamp(self.an.energy * 3.0, 0.0, 1.0);
        self.spawn_timer -= dt * self.arc_rate * (0.18 + self.an.energy * 1.2);
        if (self.spawn_timer <= 0) {
            self.spawn_timer = spawn_min + r.float(f32) * (spawn_max - spawn_min);
            self.spawnArc(state.windows, 0.7 + r.float(f32) * 0.4, calm);
        }

        // Downbeat discharge: bright pair on every detected beat.
        // Punch factor rewards sharp transients over soft hits.
        if (beat_hit) {
            const punch = std.math.clamp(self.an.flux / (self.an.flux_avg * 3.0 + 0.03), 1.0, 2.0);
            self.spawnArc(state.windows, 1.1 * punch, 0);
            self.spawnArc(state.windows, 0.9 * punch, 0);
            // Thunder flash: the room lights up, scaled by how hard the drop hit.
            self.flash = @max(self.flash, std.math.clamp((punch - 1.0) * 0.9 + 0.35, 0.0, 1.0));
        }

        // Half-beat arc: softer, syncopated eighth-note feel.
        if (half_crossed) self.spawnArc(state.windows, 0.55 + r.float(f32) * 0.15, 0);
        // Coasting arc: one per beat when flux detection misses (quiet passages).
        if (full_crossed and self.an.energy > 0.02) self.spawnArc(state.windows, 0.6 + r.float(f32) * 0.2, 0.3);

        // ---- focus crawls ----
        const focused = state.focused_win;
        for (&self.crawls) |*cr| {
            if (!cr.active) continue;
            cr.age += dt;
            if (cr.age >= cr.life) cr.active = false;
        }
        // The focus rect outlives the last window, so ask for one too.
        const framed = focused.hasArea() and state.windows.len > 0;
        if (framed) {
            // Treble makes the border fizz harder: faster spawns, hotter arcs.
            self.crawl_timer -= dt * (1.0 + self.an.treble * 2.0);
            if (self.crawl_timer <= 0) {
                self.crawl_timer = 0.06 + r.float(f32) * 0.18;
                const per = 2.0 * (focused.w + focused.h);
                const slot = self.next_crawl;
                self.next_crawl = (self.next_crawl + 1) % max_crawls;
                self.crawls[slot] = .{
                    .t0 = r.float(f32) * per,
                    .dl = 60.0 + r.float(f32) * 200.0,
                    .seed = r.int(u32),
                    .age = 0,
                    .life = 0.10 + r.float(f32) * 0.22,
                    .intensity = (0.35 + r.float(f32) * 0.25) * (0.8 + self.an.treble * 0.8),
                    .active = true,
                };
            }
        }

        // ---- geometry ----
        // Rebuilt every frame from each arc's seed, its age and the crackle
        // tick, so a channel holds its gross shape and only drifts while its
        // fine structure re-seeds with every tick.
        self.chunk_count = 0;
        self.fill = 0;
        const tick_f: f32 = @floatCast(@mod(@max(self.beat_phase_total, 0.0) * crackle_per_beat, 1048576.0));
        const tick: u32 = @intFromFloat(tick_f);

        // Mids drive the wander: a thick chorus makes live channels writhe
        // wider.
        const wander = 1.0 + self.an.mid * 0.8;

        for (&self.arcs) |*arc| {
            if (!arc.active) continue;
            self.drawArc(arc, state.windows, tick, tick_f, wander, 1.0);
        }

        // Storm arc: while sustained energy holds, a standing discharge
        // burns between the two largest windows. It stretches and bows like
        // any arc, and when it breaks (or a beat lands) it re-strikes across
        // a fresh, shorter path: a Jacob's ladder.
        if (self.storm > 0.05) {
            if (self.storm_arc.active and beat_hit) self.retire(self.storm_arc);
            if (!self.storm_arc.active) {
                const wcount = @min(state.windows.len, max_windows);
                var big: [2]usize = .{ 0, 0 };
                var big_area: [2]f32 = .{ 0, 0 };
                for (0..wcount) |i| {
                    const w = state.windows[i];
                    const area = w.w * w.h;
                    if (area > big_area[0]) {
                        big[1] = big[0];
                        big_area[1] = big_area[0];
                        big[0] = i;
                        big_area[0] = area;
                    } else if (area > big_area[1]) {
                        big[1] = i;
                        big_area[1] = area;
                    }
                }
                var arc = Arc{};
                if (big_area[1] > 0 and self.rootPair(state.windows, big[0], big[1], &arc.from, &arc.to)) {
                    arc.seed = r.int(u32);
                    arc.life = 1.3 + r.float(f32) * 1.2;
                    arc.intensity = 1.0;
                    arc.amp = 0.9 + r.float(f32) * 0.4;
                    arc.bow = if (r.boolean()) 1.0 else -1.0;
                    arc.cool = cool_max;
                    arc.active = true;
                    self.storm_arc = arc;
                }
            }
            if (self.storm_arc.active) {
                const gain = self.storm * (0.55 + self.an.bass * 0.6);
                self.drawArc(&self.storm_arc, state.windows, tick, tick_f, wander, gain);
            }
        } else if (self.storm_arc.active) {
            self.retire(self.storm_arc);
        }

        // Crawl geometry: endpoints resolved against the current focused
        // rect, so the arcs hug the frame wherever it is this frame.
        var path: Path = .{};
        if (framed) {
            for (&self.crawls) |*cr| {
                if (!cr.active) continue;
                const p = cr.age / cr.life;
                const flick = 0.75 + 0.5 * hash01(cr.seed, tick, 1);
                const env = smoothstep(0.0, 0.15, p) * (1.0 - p) * cr.intensity * flick;
                if (env < 0.012) continue;
                const a = perimeterPoint(focused, cr.t0);
                const b = perimeterPoint(focused, cr.t0 + cr.dl);
                self.buildPath(&path, a, b, cr.seed, @min(cr.dl * 0.09, 12.0 * self.px), .{ 0, 0 }, cr.age * 3.0, tick, false);
                self.emitPath(&path, 1.0, env, self.px * 0.7, false, 0);
            }
        }

        // ---- pre-beat feeler streamers ----
        // As a downbeat approaches, faint sparks reach out from each window's
        // edge toward its nearest neighbor, groping partway across the gap.
        // They never fully bridge: the beat discharge completes the circuit.
        if (charge > 0.02) {
            const wcount = @min(state.windows.len, max_windows);
            const ntend = @min(wcount, 6);
            const beat_no: u32 = @intFromFloat(@mod(@max(self.beat_phase_total, 0.0), 1048576.0));
            for (0..ntend) |i| {
                const wi = state.windows[i];
                // Nearest neighbor by center distance.
                var jbest: usize = i;
                var dbest: f32 = std.math.floatMax(f32);
                for (0..wcount) |k| {
                    if (k == i) continue;
                    const dx = (state.windows[k].x + state.windows[k].w * 0.5) - (wi.x + wi.w * 0.5);
                    const dy = (state.windows[k].y + state.windows[k].h * 0.5) - (wi.y + wi.h * 0.5);
                    const d = dx * dx + dy * dy;
                    if (d < dbest) {
                        dbest = d;
                        jbest = k;
                    }
                }
                if (jbest == i) continue;
                const wj = state.windows[jbest];
                const cj = [2]f32{ wj.x + wj.w * 0.5, wj.y + wj.h * 0.5 };
                const a = closestOnBorder(wi, cj);
                const target = closestOnBorder(wj, a);
                const dx = target[0] - a[0];
                const dy = target[1] - a[1];
                const dist = @sqrt(dx * dx + dy * dy);
                if (dist < 24.0) continue;
                // One shape per window per beat, so a feeler grows rather
                // than re-rolling on every tick.
                const seed = hashU(0x7e4d, @intCast(i), beat_no);
                const flick = 0.75 + 0.5 * hash01(seed, tick, 1);
                // Grope partway only; the discharge finishes the connection.
                const reach = charge * (0.45 + 0.35 * hash01(seed, 0, 0));
                const bright = (0.10 + 0.20 * charge) * flick * (1.0 - self.storm * 0.6);
                if (bright < 0.012) continue;
                const tip = [2]f32{ a[0] + dx * reach, a[1] + dy * reach };
                const amp = std.math.clamp(dist * reach * 0.10, 4.0 * self.px, 40.0 * self.px);
                self.buildPath(&path, a, tip, seed, amp * wander, .{ 0, 0 }, charge, tick, true);
                self.emitPath(&path, 1.0, bright, self.px * 0.7, true, 0);
            }
        }

        self.closeChunk();
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        if (self.tex == 0) {
            c.glGenTextures(1, &self.tex);
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
            // Float data textures must be NEAREST to be complete.
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA32F, tex_w, max_chunks, 0, c.GL_RGBA, c.GL_FLOAT, null);
        }
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        const n = self.chunk_count;
        if (n > 0) c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, tex_w, @intCast(n), c.GL_RGBA, c.GL_FLOAT, @ptrCast(self.tex_data.ptr));

        self.u.use(prog.program);
        self.u.int(.segtex, 0);
        self.u.f4v(.boxes, @intCast(n), &self.boxes[0]);
        self.u.int(.chunks, @intCast(n));
        self.u.f1(.px, self.px);

        // Effect-local time (fire.zig pattern) keeps the grain's noise
        // coordinates small so f32 precision holds over long sessions.
        self.u.f1(.time, @floatCast(self.now));
        self.u.f1(.beat, self.an.beat);
        self.u.f1(.bass, self.an.bass);
        self.u.f1(.treble, self.an.treble);
        self.u.f1(.flash, self.flash);
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |cap| audio_mod.shutdown(cap, self.allocator);
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
        self.allocator.free(self.tex_data);
    }
};

fn testContext() Context {
    return .{
        .allocator = std.testing.allocator,
        .audio = null,
        .rng = std.Random.DefaultPrng.init(1),
        .width = 2560,
        .height = 1440,
        .px = 1.0,
        .tex_data = &.{},
    };
}

test "an anchor rides its window and goes out with it" {
    const win = WindowRect{ .x = 100, .y = 200, .w = 400, .h = 300, .address = 7 };
    const an = Anchor.of(win, 0, .{ 500, 350 }); // right edge, halfway up
    try std.testing.expect(!an.horiz);

    const moved = [_]WindowRect{.{ .x = 900, .y = 50, .w = 200, .h = 100, .address = 7 }};
    const p = an.resolve(&moved, 0).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1100), p[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 100), p[1], 1e-3);
    // A slide stays on the edge.
    const q = an.resolve(&moved, 500).?;
    try std.testing.expectApproxEqAbs(@as(f32, 150), q[1], 1e-3);

    const others = [_]WindowRect{.{ .x = 0, .y = 0, .w = 10, .h = 10, .address = 8 }};
    try std.testing.expect(an.resolve(&others, 0) == null);
}

test "a channel is rooted at both ends and a streamer at one" {
    const ctx = testContext();
    var path: Path = .{};
    const a = [2]f32{ 100, 100 };
    const b = [2]f32{ 900, 400 };
    ctx.buildPath(&path, a, b, 0xC0FFEE, 40, .{ 0, 30 }, 1.5, 12, false);
    try std.testing.expect(path.n >= 4 and path.n <= max_pts);
    try std.testing.expectEqual(a, path.pts[0]);
    try std.testing.expectEqual(b, path.pts[path.n]);
    // The same seed, time and tick give the same channel: nothing in a
    // frame's geometry depends on call order.
    var again: Path = .{};
    ctx.buildPath(&again, a, b, 0xC0FFEE, 40, .{ 0, 30 }, 1.5, 12, false);
    try std.testing.expectEqual(path.pts[path.n / 2], again.pts[path.n / 2]);

    ctx.buildPath(&path, a, b, 0xC0FFEE, 40, .{ 0, 0 }, 1.5, 12, true);
    try std.testing.expectEqual(a, path.pts[0]);
    try std.testing.expect(path.pts[path.n][0] != b[0] or path.pts[path.n][1] != b[1]);
}

test "chunks hold eight segments and pad their box by the glow's reach" {
    var ctx = testContext();
    ctx.tex_data = try std.testing.allocator.alloc(f32, max_chunks * row_floats);
    defer std.testing.allocator.free(ctx.tex_data);

    for (0..10) |i| {
        const x: f32 = @floatFromInt(i * 10);
        ctx.pushSeg(.{ x, 0 }, .{ x + 10, 5 }, 1.0, 1.0, 0);
    }
    ctx.closeChunk();
    try std.testing.expectEqual(@as(u32, 2), ctx.chunk_count);
    try std.testing.expectApproxEqAbs(-glow_reach, ctx.boxes[0][0], 1e-3);
    try std.testing.expectApproxEqAbs(80 + glow_reach, ctx.boxes[0][2], 1e-3);
    // The second chunk's six unused slots are dark.
    const second = ctx.row(1);
    try std.testing.expectEqual(@as(f32, 1.0), second[(seg_per_chunk + 1) * 4]);
    try std.testing.expectEqual(@as(f32, 0.0), second[(seg_per_chunk + 2) * 4]);
}
