const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const max_windows = 32;

// Story threads: luminous ribbons drifting on a curl-noise field. Each
// thread's rendered trail is a fixed number of samples pulled from a longer
// head-position history (moire pattern), so the ribbon is smooth without
// uploading every frame's position.
const max_threads = 8;
const trail_points = 24;
const history_len = 320; // ~5.3 s of head positions at 60 fps
const point_spacing = history_len / trail_points; // frames between samples
const pts_vec4s = max_threads * trail_points / 2; // 2 points packed per vec4

// Sparkle motes shed from thread heads on treble.
const max_motes = 24;

// Beat flourish: a decorative spiral swash curling off one thread's head.
const flourish_pts = 16;
const fl_vec4s = flourish_pts / 2;
const flourish_life: f32 = 0.85;

// Windows are pages: threads deflect inside this band around every rect,
// and within the hug band they steer along the edge like ink at a margin.
const avoid_margin: f32 = 90.0;
const hug_lo: f32 = 8.0;
const hug_hi: f32 = 60.0;

const Thread = struct {
    pos: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    color_idx: f32 = 1,
    /// Base half-width in px; bass fattens it at upload time.
    width: f32 = 2.0,
    /// Per-thread offset into the noise field so paths decorrelate.
    phase: f32 = 0,
};

const Mote = struct {
    pos: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    age: f32 = 0,
    life: f32 = 0,
    size: f32 = 1.5,
    color_idx: f32 = 1,
    active: bool = false,
};

const Flourish = struct {
    pts: [flourish_pts][2]f32 = undefined,
    color_idx: f32 = 1,
    age: f32 = 0,
    active: bool = false,
};

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// ---------- CPU value noise → curl field ----------
// Only thread heads sample the field (a handful of evals per frame), so a
// plain lattice value noise with finite-difference curl is plenty.

fn latticeHash(ix: i32, iy: i32) f32 {
    var h: u32 = @bitCast(ix *% 374761393 +% iy *% 668265263);
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xffffff)) / 16777215.0;
}

fn valueNoise(p: [2]f32) f32 {
    const fx = @floor(p[0]);
    const fy = @floor(p[1]);
    const ix: i32 = @intFromFloat(fx);
    const iy: i32 = @intFromFloat(fy);
    const tx = p[0] - fx;
    const ty = p[1] - fy;
    const sx = tx * tx * (3.0 - 2.0 * tx);
    const sy = ty * ty * (3.0 - 2.0 * ty);
    const a = latticeHash(ix, iy);
    const b = latticeHash(ix + 1, iy);
    const d = latticeHash(ix, iy + 1);
    const e = latticeHash(ix + 1, iy + 1);
    return (a + (b - a) * sx) + ((d - a) + (e - b - d + a) * sx) * sy;
}

/// Signed distance from `p` to a rect's border, with the outward normal and
/// an edge tangent at the nearest border point. Inside the rect, d < 0 and
/// the normal points toward the nearest edge (the escape direction).
const RectHit = struct { d: f32, normal: [2]f32, tangent: [2]f32 };

fn rectSdf(rect: anytype, p: [2]f32) RectHit {
    const x0 = rect.x;
    const y0 = rect.y;
    const x1 = rect.x + rect.w;
    const y1 = rect.y + rect.h;
    const cx = std.math.clamp(p[0], x0, x1);
    const cy = std.math.clamp(p[1], y0, y1);

    if (cx > x0 and cx < x1 and cy > y0 and cy < y1) {
        // Inside: nearest edge wins.
        const d_left = cx - x0;
        const d_right = x1 - cx;
        const d_bot = cy - y0;
        const d_top = y1 - cy;
        const m = @min(@min(d_left, d_right), @min(d_bot, d_top));
        var n = [2]f32{ 0, 0 };
        if (m == d_left) {
            n = .{ -1, 0 };
        } else if (m == d_right) {
            n = .{ 1, 0 };
        } else if (m == d_bot) {
            n = .{ 0, -1 };
        } else {
            n = .{ 0, 1 };
        }
        return .{ .d = -m, .normal = n, .tangent = .{ -n[1], n[0] } };
    }

    const dx = p[0] - cx;
    const dy = p[1] - cy;
    const d = @sqrt(dx * dx + dy * dy);
    if (d < 1e-4) return .{ .d = 0, .normal = .{ 0, 1 }, .tangent = .{ 1, 0 } };
    const n = [2]f32{ dx / d, dy / d };
    return .{ .d = d, .normal = n, .tangent = .{ -n[1], n[0] } };
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: *audio_mod.AudioCapture,
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    now: f32 = 0,

    threads: [max_threads]Thread = [_]Thread{.{}} ** max_threads,
    thread_count: u32 = 6,
    history: [max_threads][history_len][2]f32 = undefined,
    history_idx: u32 = 0,
    seeded: bool = false,

    motes: [max_motes]Mote = [_]Mote{.{}} ** max_motes,
    next_mote: u8 = 0,
    mote_timer: f32 = 0,

    flourish: Flourish = .{},
    glow_swell: f32 = 0,

    /// Window rects cached each update for the upload-time pop-in guard
    /// (upload has no FrameState).
    win_cache: [max_windows]shader_mod.ShaderProgram.WindowRect = undefined,
    win_cache_count: usize = 0,

    // Audio analysis (voltaic pattern: 6-band split + bass-flux beats).
    bands: [6]f32 = [_]f32{0} ** 6,
    bass: f32 = 0,
    mid: f32 = 0,
    treble: f32 = 0,
    energy: f32 = 0,
    bass_smooth: f32 = 0,
    bass_prev: f32 = 0,
    flux_avg: f32 = 0,
    beat: f32 = 0,
    beat_cooldown: f32 = 0,

    speed_scale: f32 = 1.0,
    brightness: f32 = 1.0,

    /// Cached uniform locations — resolved on first upload, re-resolved on
    /// shader hot-reload (program ID changes).
    cached_program: c.GLuint = 0,
    loc_pts: c.GLint = -1,
    loc_meta: c.GLint = -1,
    loc_motes: c.GLint = -1,
    loc_flpts: c.GLint = -1,
    loc_flmeta: c.GLint = -1,
    loc_count: c.GLint = -1,
    loc_time: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_mid: c.GLint = -1,
    loc_treble: c.GLint = -1,
    loc_beat: c.GLint = -1,
    loc_swell: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const sink = params.getString("sink", null);
        const audio = try allocator.create(audio_mod.AudioCapture);
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();

        var count: u32 = @intCast(std.math.clamp(params.getInt("threads", 6), 1, max_threads));
        count = @min(count, max_threads);

        return .{
            .allocator = allocator,
            .audio = audio,
            .rng = std.Random.DefaultPrng.init(0x6661626c65), // "fable"
            .width = width,
            .height = height,
            .thread_count = count,
            .speed_scale = params.getFloat("speed", 1.0),
            .brightness = params.getFloat("brightness", 1.0),
        };
    }

    /// Stream function for the flow field: two octaves of value noise
    /// drifting slowly in time, so the field itself evolves and threads
    /// never settle into a fixed circuit.
    fn psi(self: *const Context, p: [2]f32) f32 {
        const t = self.now * 0.03;
        const n1 = valueNoise(.{ p[0] / 520.0 + t, p[1] / 520.0 - t * 0.7 });
        const n2 = valueNoise(.{ p[0] / 260.0 - t * 1.3, p[1] / 260.0 + t });
        return n1 + 0.35 * n2;
    }

    /// Divergence-free flow direction: perpendicular gradient of psi via
    /// finite differences. Normalized — speed is set by the caller.
    fn curl(self: *const Context, p: [2]f32) [2]f32 {
        const eps: f32 = 8.0;
        const dpx = self.psi(.{ p[0] + eps, p[1] }) - self.psi(.{ p[0] - eps, p[1] });
        const dpy = self.psi(.{ p[0], p[1] + eps }) - self.psi(.{ p[0], p[1] - eps });
        var v = [2]f32{ dpy, -dpx };
        const len = @sqrt(v[0] * v[0] + v[1] * v[1]);
        if (len < 1e-6) return .{ 1, 0 };
        v[0] /= len;
        v[1] /= len;
        return v;
    }

    fn spawnThread(self: *Context, t: *Thread, i: usize, windows: []const shader_mod.ShaderProgram.WindowRect, palette_colors: u32) void {
        const r = self.rng.random();
        // Scatter outside window rects (best of a few tries — a fully
        // covered screen just accepts the last candidate).
        var pos = [2]f32{ 0, 0 };
        var tries: u8 = 0;
        while (tries < 8) : (tries += 1) {
            pos = .{ r.float(f32) * self.width, r.float(f32) * self.height };
            var inside = false;
            const wcount = @min(windows.len, max_windows);
            for (windows[0..wcount]) |w| {
                if (w.w < 8.0 or w.h < 8.0) continue;
                if (rectSdf(w, pos).d < hug_lo) {
                    inside = true;
                    break;
                }
            }
            if (!inside) break;
        }
        const ang = r.float(f32) * std.math.tau;
        t.* = .{
            .pos = pos,
            .vel = .{ @cos(ang) * 40.0, @sin(ang) * 40.0 },
            .color_idx = @floatFromInt(1 + (i * 2) % @max(palette_colors -| 1, 1)),
            .width = 1.2 + r.float(f32) * 1.6,
            .phase = @as(f32, @floatFromInt(i)) * 37.0,
        };
    }

    fn spawnFlourish(self: *Context, focused: anytype) void {
        const r = self.rng.random();
        // The thread nearest the focused window tells this beat's flourish;
        // with no focus, any thread will do.
        var ti: usize = r.intRangeLessThan(usize, 0, self.thread_count);
        if (focused.hasArea()) {
            const fc = [2]f32{ focused.x + focused.w * 0.5, focused.y + focused.h * 0.5 };
            var best: f32 = std.math.floatMax(f32);
            for (self.threads[0..self.thread_count], 0..) |t, i| {
                const dx = t.pos[0] - fc[0];
                const dy = t.pos[1] - fc[1];
                const d = dx * dx + dy * dy;
                if (d < best) {
                    best = d;
                    ti = i;
                }
            }
        }
        const t = self.threads[ti];
        const theta0 = std.math.atan2(t.vel[1], t.vel[0]);
        const dir: f32 = if (r.boolean()) 1.0 else -1.0;
        const r0 = 55.0 + self.bass * 50.0 + r.float(f32) * 25.0;
        // Calligraphic swash: sweep outward from the head while turning,
        // radius easing back near the tip so the stroke curls closed.
        for (0..flourish_pts) |k| {
            const fk = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(flourish_pts - 1));
            const ang = theta0 + dir * (0.3 + fk * fk * 4.2);
            const rad = r0 * fk * (1.15 - fk * 0.45);
            self.flourish.pts[k] = .{
                t.pos[0] + @cos(ang) * rad,
                t.pos[1] + @sin(ang) * rad,
            };
        }
        self.flourish.color_idx = t.color_idx;
        self.flourish.age = 0;
        self.flourish.active = true;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;
        const r = self.rng.random();

        // ---- audio analysis (voltaic band split + flux beats) ----
        const wave = self.audio.getWaveform();
        const ranges = [_][2]u8{ .{ 0, 10 }, .{ 10, 25 }, .{ 25, 45 }, .{ 45, 70 }, .{ 70, 95 }, .{ 95, 128 } };
        for (0..6) |bi| {
            var en: f32 = 0;
            const lo = ranges[bi][0];
            const hi = ranges[bi][1];
            for (lo..hi) |j| en += @abs(wave[j]) + @abs(wave[128 + j]);
            en /= @floatFromInt((hi - lo) * 2);
            const raw = en * 6.0;
            const attack = @min(1.0, 25.0 * dt);
            const decay = @min(1.0, 5.0 * dt);
            self.bands[bi] += (raw - self.bands[bi]) * (if (raw > self.bands[bi]) attack else decay);
        }
        self.bass = (self.bands[0] + self.bands[1]) * 0.5;
        self.mid = (self.bands[2] + self.bands[3]) * 0.5;
        self.treble = (self.bands[4] + self.bands[5]) * 0.5;
        self.energy = (self.bands[0] + self.bands[1] + self.bands[2] +
            self.bands[3] + self.bands[4] + self.bands[5]) / 6.0;

        self.bass_smooth += (self.bass - self.bass_smooth) * @min(1.0, 0.8 * dt);
        const flux = @max(0.0, self.bass - self.bass_prev);
        self.bass_prev = self.bass;
        self.flux_avg += (flux - self.flux_avg) * @min(1.0, 1.5 * dt);

        self.beat_cooldown -= dt;
        var beat_hit = false;
        if (flux > self.flux_avg * 3.0 + 0.03 and self.beat_cooldown <= 0 and self.bass > self.bass_smooth * 1.5) {
            self.beat = 1.0;
            self.beat_cooldown = 0.25;
            beat_hit = true;
        }
        self.beat *= @exp(-4.0 * dt);
        if (self.beat < 0.01) self.beat = 0;

        // Beat swell: a subtle full-screen breath, punchier on hard hits.
        self.glow_swell *= @exp(-5.0 * dt);
        if (beat_hit) {
            const punch = std.math.clamp(flux / (self.flux_avg * 3.0 + 0.03), 1.0, 2.0);
            self.glow_swell = @max(self.glow_swell, std.math.clamp(punch * 0.4, 0.2, 0.7));
        }

        const palette_colors: u32 = if (state.palette) |p| p.color_count else 15;

        if (!self.seeded) {
            self.seeded = true;
            for (self.threads[0..self.thread_count], 0..) |*t, i| {
                self.spawnThread(t, i, state.windows, palette_colors);
                for (0..history_len) |h| self.history[i][h] = t.pos;
            }
        }

        // ---- thread steering ----
        // Silence → slow, thin drift (but still fast enough to draw a long
        // stroke); music quickens the flow (mids) and raises the pace.
        const base_speed = (45.0 + self.energy * 45.0 + self.mid * 60.0) * self.speed_scale;
        const wcount = @min(state.windows.len, max_windows);
        const focused = state.focused_win;

        for (self.threads[0..self.thread_count], 0..) |*t, ti| {
            const flow = self.curl(.{ t.pos[0] + t.phase * 13.0, t.pos[1] - t.phase * 7.0 });
            var desired = [2]f32{ flow[0] * base_speed, flow[1] * base_speed };

            // Windows are pages: eject from interiors, deflect in the
            // approach band, and hug the edge like ink at a margin.
            for (state.windows[0..wcount]) |w| {
                if (w.w < 8.0 or w.h < 8.0) continue;
                const hit = rectSdf(w, t.pos);
                if (hit.d < 0) {
                    desired[0] += hit.normal[0] * 400.0;
                    desired[1] += hit.normal[1] * 400.0;
                } else if (hit.d < avoid_margin) {
                    const f = 1.0 - hit.d / avoid_margin;
                    desired[0] += hit.normal[0] * 180.0 * f * f;
                    desired[1] += hit.normal[1] * 180.0 * f * f;
                }
                if (hit.d > hug_lo and hit.d < hug_hi) {
                    const band = (hit.d - hug_lo) / (hug_hi - hug_lo);
                    const weight = band * (1.0 - band) * 4.0 * 0.6;
                    const sgn: f32 = if (t.vel[0] * hit.tangent[0] + t.vel[1] * hit.tangent[1] >= 0) 1.0 else -1.0;
                    const dmag = @sqrt(desired[0] * desired[0] + desired[1] * desired[1]);
                    desired[0] = desired[0] * (1.0 - weight) + hit.tangent[0] * sgn * dmag * weight;
                    desired[1] = desired[1] * (1.0 - weight) + hit.tangent[1] * sgn * dmag * weight;
                }
            }

            // The focused window is the current chapter: gather toward a
            // ring around it (never pile onto the window itself).
            if (focused.hasArea()) {
                const fc = [2]f32{ focused.x + focused.w * 0.5, focused.y + focused.h * 0.5 };
                const ring_r = 0.5 * @sqrt(focused.w * focused.w + focused.h * focused.h) + 140.0;
                const dx = fc[0] - t.pos[0];
                const dy = fc[1] - t.pos[1];
                const dist = @sqrt(dx * dx + dy * dy);
                if (dist > 1.0) {
                    const pull = std.math.clamp((dist - ring_r) / 200.0, -1.0, 1.0) * 40.0;
                    desired[0] += dx / dist * pull;
                    desired[1] += dy / dist * pull;
                }
            }

            // Screen edges are page margins too — no wrap (wrapping a head
            // would rubber-band a trail segment across the whole screen).
            // Like the window hug, steer along the border rather than
            // springing against it: a hard spring here just oscillates into
            // tight coils pinned at the edge.
            const bm: f32 = 140.0;
            var edge_n = [2]f32{ 0, 0 }; // inward normal of the nearest edge
            var edge_depth: f32 = 0; // 0 at margin start → 1 at the edge
            if (t.pos[0] < bm and 1.0 - t.pos[0] / bm > edge_depth) {
                edge_depth = 1.0 - t.pos[0] / bm;
                edge_n = .{ 1, 0 };
            }
            if (self.width - t.pos[0] < bm and 1.0 - (self.width - t.pos[0]) / bm > edge_depth) {
                edge_depth = 1.0 - (self.width - t.pos[0]) / bm;
                edge_n = .{ -1, 0 };
            }
            if (t.pos[1] < bm and 1.0 - t.pos[1] / bm > edge_depth) {
                edge_depth = 1.0 - t.pos[1] / bm;
                edge_n = .{ 0, 1 };
            }
            if (self.height - t.pos[1] < bm and 1.0 - (self.height - t.pos[1]) / bm > edge_depth) {
                edge_depth = 1.0 - (self.height - t.pos[1]) / bm;
                edge_n = .{ 0, -1 };
            }
            if (edge_depth > 0) {
                const tang = [2]f32{ -edge_n[1], edge_n[0] };
                const sgn: f32 = if (t.vel[0] * tang[0] + t.vel[1] * tang[1] >= 0) 1.0 else -1.0;
                const dmag = @sqrt(desired[0] * desired[0] + desired[1] * desired[1]);
                const w = edge_depth * 0.85;
                desired[0] = desired[0] * (1.0 - w) + tang[0] * sgn * dmag * w;
                desired[1] = desired[1] * (1.0 - w) + tang[1] * sgn * dmag * w;
                // Gentle inward drift so the glide peels back off the margin.
                desired[0] += edge_n[0] * edge_depth * edge_depth * 130.0;
                desired[1] += edge_n[1] * edge_depth * edge_depth * 130.0;
            }

            // Coil escape: when opposing forces trap a head, it wiggles in
            // place and inks a knot. If net travel over the last ~2.5 s has
            // stalled, kick it along its heading to break the balance.
            const back_idx = (self.history_idx -% 150) % history_len;
            const old_pos = self.history[ti][back_idx];
            const net_dx = t.pos[0] - old_pos[0];
            const net_dy = t.pos[1] - old_pos[1];
            const net = @sqrt(net_dx * net_dx + net_dy * net_dy);
            if (net < 60.0) {
                const sp = @sqrt(t.vel[0] * t.vel[0] + t.vel[1] * t.vel[1]);
                if (sp > 1e-3) {
                    const kick = (1.0 - net / 60.0) * 220.0;
                    desired[0] += t.vel[0] / sp * kick;
                    desired[1] += t.vel[1] / sp * kick;
                }
            }

            // Velocity relaxation: eases toward the desired heading so the
            // path reads as graceful ink, not a twitchy particle.
            const k = @min(1.0, 1.8 * dt);
            t.vel[0] += (desired[0] - t.vel[0]) * k;
            t.vel[1] += (desired[1] - t.vel[1]) * k;

            const speed = @sqrt(t.vel[0] * t.vel[0] + t.vel[1] * t.vel[1]);
            const max_speed = 320.0 * self.speed_scale;
            if (speed > max_speed) {
                const s = max_speed / speed;
                t.vel[0] *= s;
                t.vel[1] *= s;
            } else if (speed < 12.0 and speed > 1e-4) {
                const s = 12.0 / speed;
                t.vel[0] *= s;
                t.vel[1] *= s;
            }

            t.pos[0] = std.math.clamp(t.pos[0] + t.vel[0] * dt, 2.0, self.width - 2.0);
            t.pos[1] = std.math.clamp(t.pos[1] + t.vel[1] * dt, 2.0, self.height - 2.0);
        }

        const idx = self.history_idx % history_len;
        for (0..self.thread_count) |i| {
            self.history[i][idx] = self.threads[i].pos;
        }
        self.history_idx +%= 1;

        // Cache window rects for upload's trail pop-in guard.
        self.win_cache_count = 0;
        for (state.windows[0..wcount]) |w| {
            if (w.w < 8.0 or w.h < 8.0) continue;
            self.win_cache[self.win_cache_count] = w;
            self.win_cache_count += 1;
        }

        // ---- flourish ----
        if (self.flourish.active) {
            self.flourish.age += dt;
            if (self.flourish.age >= flourish_life) self.flourish.active = false;
        }
        if (beat_hit and (!self.flourish.active or self.flourish.age > flourish_life * 0.6)) {
            self.spawnFlourish(focused);
        }

        // ---- motes ----
        for (&self.motes) |*m| {
            if (!m.active) continue;
            m.age += dt;
            if (m.age >= m.life) {
                m.active = false;
                continue;
            }
            const damp = @exp(-1.2 * dt);
            m.vel[0] *= damp;
            m.vel[1] *= damp;
            m.pos[0] += m.vel[0] * dt;
            m.pos[1] += m.vel[1] * dt;
        }
        // Treble drives the shed rate; near-silence spawns almost none.
        self.mote_timer -= dt * (0.5 + self.treble * 10.0);
        if (self.mote_timer <= 0) {
            self.mote_timer = 0.05 + r.float(f32) * 0.15;
            const ti = r.intRangeLessThan(usize, 0, self.thread_count);
            const t = self.threads[ti];
            const slot = self.next_mote;
            self.next_mote = (self.next_mote + 1) % max_motes;
            self.motes[slot] = .{
                .pos = t.pos,
                .vel = .{
                    t.vel[0] * 0.4 + (r.float(f32) * 2.0 - 1.0) * 60.0,
                    t.vel[1] * 0.4 + (r.float(f32) * 2.0 - 1.0) * 60.0,
                },
                .age = 0,
                .life = 0.5 + r.float(f32) * 0.7,
                .size = 1.0 + r.float(f32) * 2.0,
                .color_idx = t.color_idx,
                .active = true,
            };
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_pts = c.glGetUniformLocation(prog.program, "iFablePts[0]");
            self.loc_meta = c.glGetUniformLocation(prog.program, "iThreadMeta[0]");
            self.loc_motes = c.glGetUniformLocation(prog.program, "iMotes[0]");
            self.loc_flpts = c.glGetUniformLocation(prog.program, "iFlPts[0]");
            self.loc_flmeta = c.glGetUniformLocation(prog.program, "iFlMeta");
            self.loc_count = c.glGetUniformLocation(prog.program, "iThreadCount");
            self.loc_time = c.glGetUniformLocation(prog.program, "iFableTime");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iBass");
            self.loc_mid = c.glGetUniformLocation(prog.program, "iMid");
            self.loc_treble = c.glGetUniformLocation(prog.program, "iTreble");
            self.loc_beat = c.glGetUniformLocation(prog.program, "iBeat");
            self.loc_swell = c.glGetUniformLocation(prog.program, "iSwell");
        }

        // Trail points, 2 per vec4, head first. Any sample caught inside a
        // window rect (a page just opened over it) is projected out to the
        // nearest border — threads never cross pages, not even for a frame.
        if (self.loc_pts >= 0) {
            var pts: [pts_vec4s][4]f32 = undefined;
            for (0..self.thread_count) |i| {
                var sampled: [trail_points][2]f32 = undefined;
                for (0..trail_points) |k| {
                    const h_idx = (self.history_idx -% @as(u32, @intCast(1 + k * point_spacing))) % history_len;
                    sampled[k] = self.history[i][h_idx];
                }
                // Two 3-tap smoothing passes round off polyline corners left
                // by steering flips, so the stroke stays calligraphic.
                for (0..2) |_| {
                    var prev = sampled[0];
                    for (1..trail_points - 1) |k| {
                        const cur = sampled[k];
                        sampled[k] = .{
                            prev[0] * 0.25 + cur[0] * 0.5 + sampled[k + 1][0] * 0.25,
                            prev[1] * 0.25 + cur[1] * 0.5 + sampled[k + 1][1] * 0.25,
                        };
                        prev = cur;
                    }
                }
                for (0..trail_points) |k| {
                    var p = sampled[k];
                    for (self.win_cache[0..self.win_cache_count]) |w| {
                        const hit = rectSdf(w, p);
                        if (hit.d < 0) {
                            p[0] += hit.normal[0] * (-hit.d + 4.0);
                            p[1] += hit.normal[1] * (-hit.d + 4.0);
                        }
                    }
                    const gi = i * trail_points + k;
                    pts[gi / 2][(gi % 2) * 2] = p[0];
                    pts[gi / 2][(gi % 2) * 2 + 1] = p[1];
                }
            }
            c.glUniform4fv(self.loc_pts, @intCast(self.thread_count * trail_points / 2), @ptrCast(&pts[0]));
        }

        if (self.loc_meta >= 0) {
            var meta: [max_threads][4]f32 = undefined;
            const env = self.brightness * (0.65 + self.energy * 0.45 + self.beat * 0.35);
            for (0..self.thread_count) |i| {
                const t = self.threads[i];
                meta[i] = .{ t.color_idx, t.width * (1.0 + self.bass * 0.6), env, 0 };
            }
            c.glUniform4fv(self.loc_meta, @intCast(self.thread_count), @ptrCast(&meta[0]));
        }

        if (self.loc_motes >= 0) {
            var mv: [max_motes][4]f32 = undefined;
            for (self.motes, 0..) |m, i| {
                if (m.active) {
                    // Sine envelope folded into size: grows in, fades out.
                    const p = m.age / m.life;
                    const env = @sin(p * std.math.pi);
                    mv[i] = .{ m.pos[0], m.pos[1], m.size * env, m.color_idx };
                } else {
                    mv[i] = .{ 0, 0, 0, 0 };
                }
            }
            c.glUniform4fv(self.loc_motes, max_motes, @ptrCast(&mv[0]));
        }

        if (self.loc_flpts >= 0 and self.loc_flmeta >= 0) {
            var fp: [fl_vec4s][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** fl_vec4s;
            var fm = [4]f32{ 0, 0, 0, 0 };
            if (self.flourish.active) {
                const p = self.flourish.age / flourish_life;
                const env = smoothstep(0.0, 0.12, p) * (1.0 - p) * (1.0 - p);
                for (0..flourish_pts) |k| {
                    fp[k / 2][(k % 2) * 2] = self.flourish.pts[k][0];
                    fp[k / 2][(k % 2) * 2 + 1] = self.flourish.pts[k][1];
                }
                fm = .{ self.flourish.color_idx, env, 0, 0 };
            }
            c.glUniform4fv(self.loc_flpts, fl_vec4s, @ptrCast(&fp[0]));
            c.glUniform4f(self.loc_flmeta, fm[0], fm[1], fm[2], fm[3]);
        }

        if (self.loc_count >= 0) c.glUniform1i(self.loc_count, @intCast(self.thread_count));
        // Effect-local time (fire.zig pattern) — keeps shader noise
        // coordinates small so f32 precision holds over long sessions.
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.bass);
        if (self.loc_mid >= 0) c.glUniform1f(self.loc_mid, self.mid);
        if (self.loc_treble >= 0) c.glUniform1f(self.loc_treble, self.treble);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.beat);
        if (self.loc_swell >= 0) c.glUniform1f(self.loc_swell, self.glow_swell);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
    }
};
