const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const max_windows = 32;

/// Active arc pool. Arcs only strike between window borders.
const max_arcs = 10;

// Segment budget shared by all bolts in a frame. Geometry is regenerated
// every frame (deterministic per re-strike tick), so this is also the
// uniform array size in the shader.
const max_segments = 240;
const seg_b_vec4s = max_segments / 4;

// Bolt geometry re-randomizes at this rate; the strike index seeds the
// midpoint-displacement RNG, so each strike is a brand-new jagged path.
const restrike_hz: f32 = 13.0;

// Main bolts subdivide to this many segments (power of two <= 16).
const bolt_segs = 16;
const branch_segs = 4;

// Storm mode: sustained energy locks a persistent arc between the two
// largest windows. Engages above this smoothed-energy threshold, with
// asymmetric ramps so it snaps on with a chorus and lingers a beat after.
const storm_threshold: f32 = 0.32;
const storm_tau_in: f32 = 0.4;
const storm_tau_out: f32 = 1.6;

// Ambient spawn cadence bounds (seconds), divided by the arc_rate param.
const spawn_min: f32 = 0.30;
const spawn_max: f32 = 1.10;

// Focus aura: short bolts crawling along the focused window's border,
// plasma-globe style. Both endpoints live on the frame, parameterized by
// perimeter position so they ride the window through moves and focus
// transitions (the smoothed rect glides; the crawls glide with it).
const max_crawls = 6;
const crawl_segs = 8;

const Crawl = struct {
    /// Perimeter offset of the start point and arc-length of the walk to
    /// the end point — resolved against the *current* focused rect each
    /// frame, never cached as coordinates.
    t0: f32 = 0,
    dl: f32 = 0,
    seed: u32 = 0,
    age: f32 = 0,
    life: f32 = 0,
    intensity: f32 = 0,
    active: bool = false,
};

const Arc = struct {
    a: [2]f32 = .{ 0, 0 },
    b: [2]f32 = .{ 0, 0 },
    seed: u32 = 0,
    age: f32 = 0,
    life: f32 = 0,
    intensity: f32 = 0,
    amp: f32 = 0,
    active: bool = false,
};

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Closest point on a window's border to `p`. Points inside the rect get
/// pushed out to the nearest edge so arcs always root on the frame, not
/// somewhere under the window.
fn closestOnBorder(win: shader_mod.ShaderProgram.WindowRect, p: [2]f32) [2]f32 {
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
    audio: *audio_mod.AudioCapture,
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    now: f32 = 0,

    arcs: [max_arcs]Arc = [_]Arc{.{}} ** max_arcs,
    next_slot: u8 = 0,
    spawn_timer: f32 = 0,
    arc_rate: f32 = 1.0,

    crawls: [max_crawls]Crawl = [_]Crawl{.{}} ** max_crawls,
    next_crawl: u8 = 0,
    crawl_timer: f32 = 0,

    /// Branch probability per interior node — treble-driven, set each frame.
    branch_chance: f32 = 0.15,

    // Frame's bolt geometry: segment endpoints + per-segment brightness.
    segs: [max_segments][4]f32 = undefined,
    seg_b: [max_segments]f32 = undefined,
    seg_count: u32 = 0,

    // Audio analysis (glitch.zig pattern)
    bands: [6]f32 = [_]f32{0} ** 6,
    bass: f32 = 0,
    mid: f32 = 0,
    treble: f32 = 0,
    energy: f32 = 0,
    energy_ema: f32 = 0,
    storm: f32 = 0,
    bass_instant: f32 = 0,
    bass_smooth: f32 = 0,
    bass_prev: f32 = 0,
    flux: f32 = 0,
    flux_avg: f32 = 0,
    beat: f32 = 0,
    beat_cooldown: f32 = 0,

    /// Cached uniform locations — resolved on first upload, re-resolved on
    /// shader hot-reload (program ID changes).
    cached_program: c.GLuint = 0,
    loc_segs: c.GLint = -1,
    loc_segb: c.GLint = -1,
    loc_segcount: c.GLint = -1,
    loc_time: c.GLint = -1,
    loc_beat: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_treble: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const sink = params.getString("sink", null);
        const audio = try allocator.create(audio_mod.AudioCapture);
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();

        return .{
            .allocator = allocator,
            .audio = audio,
            .rng = std.Random.DefaultPrng.init(0x9E3779B97F4A7C15),
            .width = width,
            .height = height,
            .arc_rate = params.getFloat("arc_rate", 1.0),
        };
    }

    /// Endpoints for a window-to-window arc: pick a window, partner with its
    /// nearest neighbor (or a random other half the time), root both ends on
    /// the facing borders with jitter so repeated strikes wander.
    fn pickEndpoints(self: *Context, windows: []const shader_mod.ShaderProgram.WindowRect, a: *[2]f32, b: *[2]f32) bool {
        const r = self.rng.random();
        const count = @min(windows.len, max_windows);
        if (count < 2) return false;

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

        const aim_j = [2]f32{
            windows[j].x + windows[j].w * (0.2 + r.float(f32) * 0.6),
            windows[j].y + windows[j].h * (0.2 + r.float(f32) * 0.6),
        };
        a.* = closestOnBorder(windows[i], aim_j);
        b.* = closestOnBorder(windows[j], a.*);
        return true;
    }

    fn spawnArc(self: *Context, windows: []const shader_mod.ShaderProgram.WindowRect, intensity: f32) void {
        const r = self.rng.random();
        var a: [2]f32 = undefined;
        var b: [2]f32 = undefined;
        if (!self.pickEndpoints(windows, &a, &b)) return;

        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const dist = @sqrt(dx * dx + dy * dy);
        if (dist < 24.0) return; // overlapping borders — nothing to strike across

        const slot = self.next_slot;
        self.next_slot = (self.next_slot + 1) % max_arcs;
        self.arcs[slot] = .{
            .a = a,
            .b = b,
            .seed = r.int(u32),
            .age = 0,
            .life = 0.18 + r.float(f32) * 0.30 + intensity * 0.12,
            .intensity = intensity,
            .amp = std.math.clamp(dist * 0.16, 14.0, 180.0) * (0.8 + r.float(f32) * 0.5),
            .active = true,
        };
    }

    fn pushSeg(self: *Context, p: [2]f32, q: [2]f32, bright: f32) void {
        if (self.seg_count >= max_segments) return;
        self.segs[self.seg_count] = .{ p[0], p[1], q[0], q[1] };
        self.seg_b[self.seg_count] = bright;
        self.seg_count += 1;
    }

    /// Midpoint-displacement bolt from `a` to `b`: split the chord in halves,
    /// shoving each new midpoint sideways (and a little lengthwise) by a
    /// shrinking random offset — the path wanders freely in 2D, diagonals
    /// included. Branches peel off interior nodes at an angle, dimmer and
    /// tapering, with their own (branch-free) subdivision.
    fn genBolt(self: *Context, a: [2]f32, b: [2]f32, amp: f32, bright: f32, r: std.Random, comptime n: usize, taper: bool, branches: bool) void {
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const chord = @sqrt(dx * dx + dy * dy);
        if (chord < 6.0) {
            self.pushSeg(a, b, bright);
            return;
        }
        const ux = dx / chord;
        const uy = dy / chord;

        var pts: [n + 1][2]f32 = undefined;
        pts[0] = a;
        pts[n] = b;

        var off = @min(amp * 1.4, chord * 0.32);
        var step: usize = n;
        while (step > 1) : (step >>= 1) {
            var i: usize = step / 2;
            while (i < n) : (i += step) {
                const p = pts[i - step / 2];
                const q = pts[i + step / 2];
                const side = (r.float(f32) * 2.0 - 1.0) * off;
                const along = (r.float(f32) * 2.0 - 1.0) * off * 0.35;
                pts[i] = .{
                    (p[0] + q[0]) * 0.5 - uy * side + ux * along,
                    (p[1] + q[1]) * 0.5 + ux * side + uy * along,
                };
            }
            off *= 0.45;
        }

        for (0..n) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
            const sb = if (taper) bright * (1.0 - t * 0.75) else bright;
            self.pushSeg(pts[i], pts[i + 1], sb);
        }

        if (branches) {
            for (2..n - 1) |i| {
                if (r.float(f32) > self.branch_chance) continue;
                // Branch continues roughly along the local bolt direction,
                // rotated outward — like a stepped leader forking.
                var ldx = pts[i + 1][0] - pts[i - 1][0];
                var ldy = pts[i + 1][1] - pts[i - 1][1];
                const ll = @sqrt(ldx * ldx + ldy * ldy);
                if (ll < 1.0) continue;
                ldx /= ll;
                ldy /= ll;
                const sign: f32 = if (r.boolean()) 1.0 else -1.0;
                const ang = (0.35 + r.float(f32) * 0.55) * sign;
                const ca = @cos(ang);
                const sa = @sin(ang);
                const bx = ldx * ca - ldy * sa;
                const by = ldx * sa + ldy * ca;
                const blen = chord * (0.15 + r.float(f32) * 0.25);
                const end = [2]f32{ pts[i][0] + bx * blen, pts[i][1] + by * blen };
                self.genBolt(pts[i], end, blen * 0.3, bright * 0.5, r, branch_segs, true, false);
            }
        }
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;
        const r = self.rng.random();

        // ---- audio analysis (same band split as glitch/swarm) ----
        const wave = self.audio.getWaveform();
        const ranges = [_][2]u8{ .{ 0, 10 }, .{ 10, 25 }, .{ 25, 45 }, .{ 45, 70 }, .{ 70, 95 }, .{ 95, 128 } };
        for (0..6) |bi| {
            var energy: f32 = 0;
            const lo = ranges[bi][0];
            const hi = ranges[bi][1];
            for (lo..hi) |j| {
                energy += @abs(wave[j]) + @abs(wave[128 + j]);
            }
            energy /= @as(f32, @floatFromInt((hi - lo) * 2));
            const raw = energy * 6.0;
            const attack = @min(1.0, 25.0 * dt);
            const decay = @min(1.0, 5.0 * dt);
            self.bands[bi] += (raw - self.bands[bi]) * (if (raw > self.bands[bi]) attack else decay);
        }
        self.bass = (self.bands[0] + self.bands[1]) * 0.5;
        self.mid = (self.bands[2] + self.bands[3]) * 0.5;
        self.treble = (self.bands[4] + self.bands[5]) * 0.5;
        self.energy = (self.bands[0] + self.bands[1] + self.bands[2] +
            self.bands[3] + self.bands[4] + self.bands[5]) / 6.0;

        // Slow energy envelope + asymmetric storm ramp: choruses snap the
        // storm on, and it lets go a moment after the section ends.
        self.energy_ema += (self.energy - self.energy_ema) * @min(1.0, 2.0 * dt);
        const storm_target: f32 = if (self.energy_ema > storm_threshold) 1.0 else 0.0;
        const storm_tau = if (storm_target > self.storm) storm_tau_in else storm_tau_out;
        self.storm += (storm_target - self.storm) * (1.0 - @exp(-dt / storm_tau));

        // Beat detection (spectral flux on bass)
        self.bass_instant = self.bass;
        self.bass_smooth += (self.bass - self.bass_smooth) * @min(1.0, 0.8 * dt);
        const flux_raw = @max(0.0, self.bass_instant - self.bass_prev);
        self.bass_prev = self.bass_instant;
        self.flux = flux_raw;
        self.flux_avg += (flux_raw - self.flux_avg) * @min(1.0, 1.5 * dt);

        self.beat_cooldown -= dt;
        var beat_hit = false;
        if (self.flux > self.flux_avg * 3.0 + 0.03 and self.beat_cooldown <= 0 and self.bass_instant > self.bass_smooth * 1.5) {
            self.beat = 1.0;
            self.beat_cooldown = 0.25;
            beat_hit = true;
        }
        self.beat *= @exp(-4.0 * dt);
        if (self.beat < 0.01) self.beat = 0;

        // ---- arc lifecycle ----
        for (&self.arcs) |*arc| {
            if (!arc.active) continue;
            arc.age += dt;
            if (arc.age >= arc.life) arc.active = false;
        }

        // Treble bushes the bolts out: hi-hats raise the fork probability.
        self.branch_chance = std.math.clamp(0.12 + self.treble * 0.45, 0.12, 0.55);

        // Ambient strikes on a randomized timer, scaled by total energy —
        // silence decays to rare pops, loud passages storm.
        self.spawn_timer -= dt * self.arc_rate * (0.35 + self.energy * 2.4);
        if (self.spawn_timer <= 0) {
            self.spawn_timer = spawn_min + r.float(f32) * (spawn_max - spawn_min);
            self.spawnArc(state.windows, 0.7 + r.float(f32) * 0.4);
        }

        // Discharge on the beat, brightness scaled by how hard the flux
        // spiked over its average — drops hit harder than pickup notes.
        if (beat_hit) {
            const punch = std.math.clamp(self.flux / (self.flux_avg * 3.0 + 0.03), 1.0, 2.0);
            self.spawnArc(state.windows, 1.1 * punch);
            self.spawnArc(state.windows, 0.9 * punch);
        }

        // ---- focus crawls ----
        const focused = state.focused_win;
        for (&self.crawls) |*cr| {
            if (!cr.active) continue;
            cr.age += dt;
            if (cr.age >= cr.life) cr.active = false;
        }
        if (focused.hasArea()) {
            // Treble makes the border fizz harder: faster spawns, hotter arcs.
            self.crawl_timer -= dt * (1.0 + self.treble * 2.0);
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
                    .life = 0.08 + r.float(f32) * 0.16,
                    .intensity = (0.35 + r.float(f32) * 0.25) * (0.8 + self.treble * 0.8),
                    .active = true,
                };
            }
        }

        // ---- bolt geometry ----
        // Regenerated every frame, but deterministically seeded from
        // (arc seed, strike index): the path holds steady within a strike
        // tick and snaps to a new shape restrike_hz times per second.
        self.seg_count = 0;
        const strike: u32 = @intFromFloat(@max(self.now, 0.0) * restrike_hz);

        // Mids drive the wander: geometry regenerates every strike, so a
        // thick chorus makes live bolts writhe wider mid-flight.
        const wander = 1.0 + self.mid * 0.8;

        for (&self.arcs) |*arc| {
            if (!arc.active) continue;
            var prng = std.Random.DefaultPrng.init(@as(u64, arc.seed) ^ (@as(u64, strike) *% 0x9E3779B97F4A7C15));
            const ar = prng.random();
            const flick = 0.55 + 0.9 * ar.float(f32);
            const p = arc.age / arc.life;
            const env = smoothstep(0.0, 0.08, p) * (1.0 - p) * (1.0 - p) * arc.intensity * flick;
            if (env < 0.012) continue;
            self.genBolt(arc.a, arc.b, arc.amp * wander, env, ar, bolt_segs, false, true);
        }

        // Storm arc: while sustained energy holds, a continuous discharge
        // locks between the two largest windows, dancing along their borders
        // with every re-strike. Endpoints resolve fresh each frame so it
        // tracks moving windows like the crawls do.
        if (self.storm > 0.05) {
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
            if (big_area[1] > 0) {
                var prng = std.Random.DefaultPrng.init(@as(u64, 0x57052) ^ (@as(u64, strike) *% 0x9E3779B97F4A7C15));
                const ar = prng.random();
                const wi = state.windows[big[0]];
                const wj = state.windows[big[1]];
                // Per-strike jittered aim so the arc dances along the borders.
                const aim = [2]f32{
                    wj.x + wj.w * (0.2 + ar.float(f32) * 0.6),
                    wj.y + wj.h * (0.2 + ar.float(f32) * 0.6),
                };
                const a = closestOnBorder(wi, aim);
                const b = closestOnBorder(wj, a);
                const dx = b[0] - a[0];
                const dy = b[1] - a[1];
                const dist = @sqrt(dx * dx + dy * dy);
                if (dist > 24.0) {
                    const flick = 0.55 + 0.9 * ar.float(f32);
                    const env = self.storm * (0.55 + self.bass * 0.6) * flick;
                    const amp = std.math.clamp(dist * 0.16, 14.0, 180.0);
                    self.genBolt(a, b, amp * wander, env, ar, bolt_segs, false, true);
                }
            }
        }

        // Crawl geometry: endpoints resolved against the current focused
        // rect, so the arcs hug the frame wherever it is this frame.
        if (focused.hasArea()) {
            for (&self.crawls) |*cr| {
                if (!cr.active) continue;
                var prng = std.Random.DefaultPrng.init(@as(u64, cr.seed) ^ (@as(u64, strike) *% 0x9E3779B97F4A7C15));
                const ar = prng.random();
                const flick = 0.55 + 0.9 * ar.float(f32);
                const p = cr.age / cr.life;
                const env = smoothstep(0.0, 0.15, p) * (1.0 - p) * cr.intensity * flick;
                if (env < 0.012) continue;
                const a = perimeterPoint(focused, cr.t0);
                const b = perimeterPoint(focused, cr.t0 + cr.dl);
                self.genBolt(a, b, @min(cr.dl * 0.30, 36.0), env, ar, crawl_segs, false, false);
            }
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_segs = c.glGetUniformLocation(prog.program, "iSegs[0]");
            self.loc_segb = c.glGetUniformLocation(prog.program, "iSegB[0]");
            self.loc_segcount = c.glGetUniformLocation(prog.program, "iSegCount");
            self.loc_time = c.glGetUniformLocation(prog.program, "iVoltTime");
            self.loc_beat = c.glGetUniformLocation(prog.program, "iBeat");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iBass");
            self.loc_treble = c.glGetUniformLocation(prog.program, "iTreble");
        }

        const n = self.seg_count;
        if (self.loc_segs >= 0 and n > 0) {
            c.glUniform4fv(self.loc_segs, @intCast(n), @ptrCast(&self.segs[0]));
        }
        if (self.loc_segb >= 0) {
            // Brightness packed 4-per-vec4; shader unpacks with [i>>2][i&3].
            var packed_b: [seg_b_vec4s][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** seg_b_vec4s;
            for (0..n) |i| packed_b[i / 4][i % 4] = self.seg_b[i];
            c.glUniform4fv(self.loc_segb, @intCast((n + 3) / 4), @ptrCast(&packed_b[0]));
        }
        if (self.loc_segcount >= 0) c.glUniform1i(self.loc_segcount, @intCast(n));

        // Effect-local time (fire.zig pattern) — keeps corona noise
        // coordinates small so f32 precision holds over long sessions.
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.beat);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.bass);
        if (self.loc_treble >= 0) c.glUniform1f(self.loc_treble, self.treble);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
    }
};
