const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const bands_mod = @import("bands.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const max_windows = 32;

/// Active arc pool. Arcs only strike between window borders.
/// Larger pool accommodates multi-stroke follow-up arcs (one extra per spawn).
const max_arcs = 16;

// Segment budget shared by all bolts in a frame. Geometry is regenerated
// every frame (deterministic per re-strike tick), so this is also the
// uniform array size in the shader.
const max_segments = 240;
const seg_b_vec4s = max_segments / 4;

// Bolt geometry re-randomizes at this rate; the strike index seeds the
// midpoint-displacement RNG, so each strike is a brand-new jagged path.
const restrike_hz: f32 = 13.0;

// Main bolts subdivide to this many segments (power of two <= 16).
// Both values must be powers of two — the midpoint-displacement algorithm
// reads pts[i ± step/2] and requires a complete binary subdivision tree.
const bolt_segs = 16;
const branch_segs = 8;

// Stepped-leader propagation time: how long a fresh stroke takes to bridge
// the gap from source window to target. A hot tip rides the advancing front.
// Kept very brief — real leaders cross in microseconds; this is just enough
// frames (~3-4 at 60fps) to read as a reach rather than an instant flash.
const leader_extend: f32 = 0.055;

// Pre-beat feeler tendrils: how far ahead of a downbeat the groping sparks
// begin to reach out from window edges (seconds).
const tendril_lead: f32 = 0.12;

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

// Afterglow: a pool of frozen channel snapshots, each from a strong strike,
// fading independently. max_ghost caps one snapshot's segment count; max_embers
// is how many recent strikes leave lingering violet ghosts at once.
const max_ghost = 40;
const max_embers = 4;
const ember_life: f32 = 0.55;

/// A frozen imprint of a strong strike's channel — re-emitted each frame as
/// dim violet segments that fade over ember_life, outliving the bolt itself.
const Ember = struct {
    segs: [max_ghost][4]f32 = undefined,
    b: [max_ghost]f32 = undefined,
    count: u32 = 0,
    age: f32 = 0,
    active: bool = false,
};

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
    start_delay: f32 = 0, // seconds before this stroke begins (multi-stroke)
    life: f32 = 0,
    intensity: f32 = 0,
    amp: f32 = 0,
    captured: bool = false, // has this strike imprinted its afterglow ember yet
    active: bool = false,
};

const smoothstep = bands_mod.smoothstep;

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

    // Afterglow: a pool of frozen channel snapshots from recent strong strikes,
    // each fading independently. The ionized air still glowing after each bolt.
    embers: [max_embers]Ember = [_]Ember{.{}} ** max_embers,
    next_ember: u8 = 0,
    // Index in segs[] where the appended ember segments begin — the shader
    // tints everything past this index violet.
    ghost_start_idx: u32 = 0,

    // Thunder flash: full-screen ambient brighten on big downbeat discharges,
    // fast decay — the room lighting up.
    flash: f32 = 0,

    // Audio analysis (glitch.zig pattern, shared in bands.zig)
    an: bands_mod.Splitter = .{},
    energy_ema: f32 = 0,
    storm: f32 = 0,

    // BPM phase sync: beat_phase_total accumulates beats at bpm_est per
    // minute; detected beats snap it to the nearest integer to keep the
    // clock anchored to real music across passages of different energy.
    bpm_est: f32 = 120.0,
    beat_phase_total: f32 = 0.0,
    beat_phase: f32 = 0.0,
    last_beat_now: f32 = -1.0,

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
    loc_beat_phase: c.GLint = -1,
    loc_flash: c.GLint = -1,
    loc_ghost_start: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const audio = try audio_mod.spawn(allocator, params);

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

        const amp = std.math.clamp(dist * 0.16, 14.0, 180.0) * (0.8 + r.float(f32) * 0.5);
        const slot = self.next_slot;
        self.next_slot = (self.next_slot + 1) % max_arcs;
        self.arcs[slot] = .{
            .a = a,
            .b = b,
            .seed = r.int(u32),
            .age = 0,
            .life = 0.18 + r.float(f32) * 0.30 + intensity * 0.12,
            .intensity = intensity,
            .amp = amp,
            .active = true,
        };

        // Multi-stroke: real lightning fires 2-5 return strokes along the
        // same channel ~60-90ms apart, each on a slightly different path.
        // One follow-up stroke at high intensity gives that characteristic flicker.
        if (intensity >= 0.75) {
            const follow_slot = self.next_slot;
            self.next_slot = (self.next_slot + 1) % max_arcs;
            self.arcs[follow_slot] = .{
                .a = a,
                .b = b,
                .seed = r.int(u32),
                .age = 0,
                .start_delay = 0.055 + r.float(f32) * 0.05,
                .life = 0.10 + r.float(f32) * 0.08,
                .intensity = intensity * 0.72,
                .amp = amp * 0.88,
                .active = true,
            };
        }
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
    fn genBolt(self: *Context, a: [2]f32, b: [2]f32, amp: f32, bright: f32, reach: f32, r: std.Random, comptime n: usize, taper: bool, branches: bool) void {
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

        // Continuous shimmer: a fast electric writhe layered on the discrete
        // midpoint shape, so the channel never freezes between restrike ticks.
        // Endpoints stay rooted on the window borders; only interior nodes
        // buzz. Two incommensurate sines with spatial phase read as chaotic
        // rather than a regular wave; treble (hi-hats) drives it harder.
        const sh = std.math.clamp(amp * 0.014, 0.3, 1.4) * (0.8 + self.an.treble * 0.3);
        for (1..n) |i| {
            const ph = pts[i][0] * 0.043 + pts[i][1] * 0.031;
            const wig = (@sin(self.now * 24.0 + ph) + 0.5 * @sin(self.now * 53.0 + ph * 1.7)) * sh;
            pts[i][0] -= uy * wig;
            pts[i][1] += ux * wig;
        }

        // Stepped-leader reach: only draw segments the advancing front has
        // reached. The frontier segment is partial (lerped) and glows hot —
        // the bright leader tip feeling its way toward the target window.
        const n_f = @as(f32, @floatFromInt(n));
        const reach_n = std.math.clamp(reach, 0.0, 1.0) * n_f;
        for (0..n) |i| {
            const fi = @as(f32, @floatFromInt(i));
            if (fi >= reach_n) break;
            const frac = @min(reach_n - fi, 1.0);
            const t = fi / n_f;
            var sb = if (taper) bright * (1.0 - t * 0.75) else bright;
            // Per-segment brightness ripple — an unstable arc's glow crawls
            // and stutters along the channel rather than burning evenly.
            const bz = pts[i][0] * 0.02 + pts[i][1] * 0.02;
            sb *= 0.90 + 0.10 * @sin(self.now * 40.0 + bz);
            // Hot leader tip: the advancing frontier segment burns brighter.
            if (frac < 1.0) sb *= 1.0 + (1.0 - frac) * 1.4;
            const q = [2]f32{
                pts[i][0] + (pts[i + 1][0] - pts[i][0]) * frac,
                pts[i][1] + (pts[i + 1][1] - pts[i][1]) * frac,
            };
            self.pushSeg(pts[i], q, sb);
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
                const blen = chord * (0.18 + r.float(f32) * 0.30);
                const end = [2]f32{ pts[i][0] + bx * blen, pts[i][1] + by * blen };
                // Branches near the source are brighter; tip branches are dim.
                const t_node = @as(f32, @floatFromInt(i)) / n_f;
                const branch_bright = bright * (0.58 - t_node * 0.22);
                // Draw the child seed unconditionally so the parent RNG stream
                // stays aligned whether or not the fork has sparked yet — keeps
                // branches from flickering as the leader front advances.
                const bseed = r.int(u32);
                // A fork only sparks once the leader front passes its node.
                if (@as(f32, @floatFromInt(i)) >= reach_n) continue;
                var bprng = std.Random.DefaultPrng.init(@as(u64, bseed) ^ 0xD1B54A32D192ED03);
                self.genBolt(pts[i], end, blen * 0.35, branch_bright, 1.0, bprng.random(), branch_segs, true, false);
            }
        }
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;
        const r = self.rng.random();

        // ---- audio analysis (same band split as glitch/swarm) ----
        // Band split + beat detection (spectral flux on bass), see bands.zig.
        const wave = self.audio.getWaveform();
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

        // Afterglow embers each age independently; strong strikes add new ones.
        for (&self.embers) |*e| {
            if (!e.active) continue;
            e.age += dt;
            if (e.age >= ember_life) e.active = false;
        }

        // ---- BPM-phase sync ----
        // Advance before snap so crossing detection uses the pre-snap fraction.
        const prev_phase_total = self.beat_phase_total;
        self.beat_phase_total += dt * (self.bpm_est / 60.0);

        if (beat_hit) {
            // Update tempo estimate from inter-onset interval (IOI).
            if (self.last_beat_now > 0.0) {
                const ioi = self.now - self.last_beat_now;
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
        const ppf = prev_phase_total - @floor(prev_phase_total);
        const cpf = self.beat_phase_total - @floor(self.beat_phase_total);
        self.beat_phase = cpf;

        // Half-beat "and": 8th-note syncopation.
        const half_crossed = ppf < 0.5 and cpf >= 0.5;
        // Coasting arc: full beat elapsed without a detected hit — keeps the
        // display alive during quiet passages at the fallback 120 BPM.
        const full_crossed = cpf < ppf and !beat_hit;

        // Pre-beat charge: in the lead window before the next predicted
        // downbeat, feeler tendrils grope out from window edges. Ramps 0→1
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
            if (arc.age >= arc.life) arc.active = false;
        }

        // Treble bushes the bolts out: hi-hats raise the fork probability.
        self.branch_chance = std.math.clamp(0.12 + self.an.treble * 0.45, 0.12, 0.55);

        // Ambient strikes fill silences; BPM-synced arcs take over during music.
        // Rate reduced so both systems don't stack to a busy tangle.
        self.spawn_timer -= dt * self.arc_rate * (0.18 + self.an.energy * 1.2);
        if (self.spawn_timer <= 0) {
            self.spawn_timer = spawn_min + r.float(f32) * (spawn_max - spawn_min);
            self.spawnArc(state.windows, 0.7 + r.float(f32) * 0.4);
        }

        // Downbeat discharge: bright pair on every detected beat.
        // Punch factor rewards sharp transients over soft hits.
        if (beat_hit) {
            const punch = std.math.clamp(self.an.flux / (self.an.flux_avg * 3.0 + 0.03), 1.0, 2.0);
            self.spawnArc(state.windows, 1.1 * punch);
            self.spawnArc(state.windows, 0.9 * punch);
            // Thunder flash: the room lights up, scaled by how hard the drop hit.
            self.flash = @max(self.flash, std.math.clamp((punch - 1.0) * 0.9 + 0.35, 0.0, 1.0));
        }

        // Half-beat arc: softer, syncopated eighth-note feel.
        if (half_crossed) self.spawnArc(state.windows, 0.55 + r.float(f32) * 0.15);
        // Coasting arc: one per beat when flux detection misses (quiet passages).
        if (full_crossed and self.an.energy > 0.02) self.spawnArc(state.windows, 0.6 + r.float(f32) * 0.2);

        // ---- focus crawls ----
        const focused = state.focused_win;
        for (&self.crawls) |*cr| {
            if (!cr.active) continue;
            cr.age += dt;
            if (cr.age >= cr.life) cr.active = false;
        }
        if (focused.hasArea()) {
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
                    .life = 0.08 + r.float(f32) * 0.16,
                    .intensity = (0.35 + r.float(f32) * 0.25) * (0.8 + self.an.treble * 0.8),
                    .active = true,
                };
            }
        }

        // ---- bolt geometry ----
        // Regenerated every frame, but deterministically seeded from
        // (arc seed, strike index): the path holds steady within a strike
        // tick and snaps to a new shape restrike_hz times per second.
        self.seg_count = 0;
        // BPM-locked restrike: 8th-note subdivisions (8 shapes per beat).
        // beat_phase_total is monotonic so the counter never jumps backward.
        const strike: u32 = @intFromFloat(@max(self.beat_phase_total, 0.0) * 8.0);

        // Mids drive the wander: geometry regenerates every strike, so a
        // thick chorus makes live bolts writhe wider mid-flight.
        const wander = 1.0 + self.an.mid * 0.8;

        for (&self.arcs) |*arc| {
            if (!arc.active) continue;
            // start_delay > 0: this return stroke hasn't fired yet
            const eff_age = arc.age - arc.start_delay;
            if (eff_age < 0) continue;
            var prng = std.Random.DefaultPrng.init(@as(u64, arc.seed) ^ (@as(u64, strike) *% 0x9E3779B97F4A7C15));
            const ar = prng.random();
            const flick = 0.55 + 0.9 * ar.float(f32);
            const p = eff_age / arc.life;
            const env = smoothstep(0.0, 0.08, p) * (1.0 - p) * (1.0 - p) * arc.intensity * flick;
            if (env < 0.012) continue;
            // Brief stepped-leader reach at the start of each (return) stroke.
            const reach = std.math.clamp(eff_age / leader_extend, 0.0, 1.0);
            const before = self.seg_count;
            self.genBolt(arc.a, arc.b, arc.amp * wander, env, reach, ar, bolt_segs, false, true);

            // Imprint a strong, fully-extended strike into a fresh ember slot,
            // exactly once (the frame its leader completes). Each ember then
            // ages on its own, outliving the bolt so the violet ghost lingers
            // at this spot while new strikes fire elsewhere.
            if (arc.intensity >= 0.9 and reach >= 1.0 and !arc.captured) {
                arc.captured = true;
                const slot = self.next_ember;
                self.next_ember = (self.next_ember + 1) % max_embers;
                const e = &self.embers[slot];
                var gi: u32 = 0;
                var k = before;
                while (k < self.seg_count and gi < max_ghost) : (k += 1) {
                    e.segs[gi] = self.segs[k];
                    e.b[gi] = self.seg_b[k];
                    gi += 1;
                }
                e.count = gi;
                e.age = 0;
                e.active = true;
            }
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
                    const env = self.storm * (0.55 + self.an.bass * 0.6) * flick;
                    const amp = std.math.clamp(dist * 0.16, 14.0, 180.0);
                    self.genBolt(a, b, amp * wander, env, 1.0, ar, bolt_segs, false, true);
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
                self.genBolt(a, b, @min(cr.dl * 0.30, 36.0), env, 1.0, ar, crawl_segs, false, false);
            }
        }

        // ---- pre-beat feeler tendrils ----
        // As a downbeat approaches, faint sparks reach out from each window's
        // edge toward its nearest neighbor, groping partway across the gap.
        // They never fully bridge — the beat discharge completes the circuit.
        // Reuses genBolt's reach to grow each stub in step with the charge.
        if (charge > 0.02) {
            const wcount = @min(state.windows.len, max_windows);
            const ntend = @min(wcount, 6);
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
                var prng = std.Random.DefaultPrng.init((@as(u64, @intCast(i)) *% 0x2545F4914F6CDD1D) ^ (@as(u64, strike) *% 0x9E3779B97F4A7C15));
                const ar = prng.random();
                const flick = 0.55 + 0.9 * ar.float(f32);
                // Grope partway only; the discharge finishes the connection.
                const reach = charge * 0.7;
                const bright = (0.08 + 0.16 * charge) * flick * (1.0 - self.storm * 0.6);
                if (bright < 0.012) continue;
                const amp = std.math.clamp(dist * 0.10, 8.0, 80.0);
                self.genBolt(a, target, amp * wander, bright, reach, ar, crawl_segs, true, false);
            }
        }

        // ---- afterglow re-emission ----
        // Append every active ember's frozen channel as dim segments that fade
        // linearly over its life. Everything past ghost_start_idx is tinted
        // violet by the shader. Embers from several recent strikes coexist, so
        // violet ghosts linger at old strike sites as new bolts fire elsewhere.
        self.ghost_start_idx = self.seg_count;
        for (&self.embers) |*e| {
            if (!e.active) continue;
            const gp = e.age / ember_life;
            const gfade = (1.0 - gp) * 0.5;
            for (0..e.count) |k| {
                if (self.seg_count >= max_segments) break;
                self.segs[self.seg_count] = e.segs[k];
                self.seg_b[self.seg_count] = e.b[k] * gfade;
                self.seg_count += 1;
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
            self.loc_beat_phase = c.glGetUniformLocation(prog.program, "iBeatPhase");
            self.loc_flash = c.glGetUniformLocation(prog.program, "iFlash");
            self.loc_ghost_start = c.glGetUniformLocation(prog.program, "iGhostStart");
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
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.an.beat);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.an.bass);
        if (self.loc_treble >= 0) c.glUniform1f(self.loc_treble, self.an.treble);
        if (self.loc_beat_phase >= 0) c.glUniform1f(self.loc_beat_phase, self.beat_phase);
        if (self.loc_flash >= 0) c.glUniform1f(self.loc_flash, self.flash);
        if (self.loc_ghost_start >= 0) c.glUniform1i(self.loc_ghost_start, @intCast(self.ghost_start_idx));
    }

    pub fn deinit(self: *Context) void {
        audio_mod.shutdown(self.audio, self.allocator);
    }
};
