const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const max_windows = 32;

// Bioluminescent ivy: glowing vines take root on window frames (windows are
// trellises) and climb them, sprouting leaves as they grow. Beats pop open
// blossoms which later shed petals that drift down on the breeze. Vine
// geometry is recomputed from the *current* window rect every frame
// (perimeter-parameterized, voltaic crawl pattern), so vines ride their
// window through moves and resizes.
const max_vines = 8;
const seg_step: f32 = 16.0; // arc length per uploaded stem segment
const max_segs = 200;
const seg_b_vec4s = max_segs / 4;
const max_leaves = 80;
const leaf_spacing: f32 = 40.0;
const max_blooms = 16;
const max_petals = 40;

const vine_die_secs: f32 = 1.2;
const bloom_life: f32 = 7.0;

const Vine = struct {
    active: bool = false,
    /// Seconds spent dying (window closed); fades out, then frees the slot.
    dying: f32 = 0,
    /// 0 = screen-bottom garden vine (empty workspace).
    addr: u64 = 0,
    t0: f32 = 0,
    dir: f32 = 1,
    dl: f32 = 0,
    target: f32 = 300,
    seed: f32 = 0,
};

const Bloom = struct {
    active: bool = false,
    vine: u8 = 0,
    s: f32 = 0,
    age: f32 = 0,
    phase: f32 = 0,
    color_idx: f32 = 5,
};

const Petal = struct {
    active: bool = false,
    pos: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    angle: f32 = 0,
    spin: f32 = 0,
    age: f32 = 0,
    life: f32 = 1,
    size: f32 = 4,
    color_idx: f32 = 5,
};

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Point on a rect's border at perimeter offset `t` (wraps), walking
/// bottom -> right -> top -> left (voltaic pattern), plus the outward
/// normal of the edge it lands on. Coordinates are y-up (frag space).
const PerimHit = struct { pos: [2]f32, normal: [2]f32 };

fn perimeterAt(rect: anytype, t: f32) PerimHit {
    const w = @max(rect.w, 1.0);
    const h = @max(rect.h, 1.0);
    const per = 2.0 * (w + h);
    var s = @mod(t, per);
    if (s < 0) s += per;
    if (s < w) return .{ .pos = .{ rect.x + s, rect.y }, .normal = .{ 0, -1 } };
    s -= w;
    if (s < h) return .{ .pos = .{ rect.x + w, rect.y + s }, .normal = .{ 1, 0 } };
    s -= h;
    if (s < w) return .{ .pos = .{ rect.x + w - s, rect.y + h }, .normal = .{ 0, 1 } };
    s -= w;
    return .{ .pos = .{ rect.x, rect.y + h - s }, .normal = .{ -1, 0 } };
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: *audio_mod.AudioCapture,
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    now: f32 = 0,

    vines: [max_vines]Vine = [_]Vine{.{}} ** max_vines,
    spawn_timer: f32 = 0,

    blooms: [max_blooms]Bloom = [_]Bloom{.{}} ** max_blooms,
    petals: [max_petals]Petal = [_]Petal{.{}} ** max_petals,
    next_petal: u8 = 0,

    // Frame geometry, rebuilt every update.
    segs: [max_segs][4]f32 = undefined,
    seg_b: [max_segs]f32 = undefined,
    seg_count: u32 = 0,
    leaves: [max_leaves][4]f32 = undefined, // x, y, angle, size
    leaf_count: u32 = 0,

    // Window rects cached this frame so vine geometry helpers can resolve
    // their anchor rect without FrameState.
    win_cache: [max_windows]shader_mod.ShaderProgram.WindowRect = undefined,
    win_cache_count: usize = 0,
    focused_center: [2]f32 = .{ -1e9, -1e9 },

    // Audio analysis (voltaic pattern).
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

    growth: f32 = 1.0,
    brightness: f32 = 1.0,

    cached_program: c.GLuint = 0,
    loc_segs: c.GLint = -1,
    loc_segb: c.GLint = -1,
    loc_segcount: c.GLint = -1,
    loc_leaf: c.GLint = -1,
    loc_leafcount: c.GLint = -1,
    loc_bloom: c.GLint = -1,
    loc_petal: c.GLint = -1,
    loc_time: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_treble: c.GLint = -1,
    loc_beat: c.GLint = -1,
    loc_energy: c.GLint = -1,
    loc_bright: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const sink = params.getString("sink", null);
        const audio = try allocator.create(audio_mod.AudioCapture);
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();

        return .{
            .allocator = allocator,
            .audio = audio,
            .rng = std.Random.DefaultPrng.init(0x697679), // "ivy"
            .width = width,
            .height = height,
            .growth = params.getFloat("growth", 1.0),
            .brightness = params.getFloat("brightness", 1.0),
        };
    }

    /// Empty-workspace garden: each addr == 0 vine climbs an invisible thin
    /// trellis post rising from the screen bottom (a horizontal bed would
    /// only let the vine snake flat along the edge). The post's x position
    /// and height derive from the vine's seed so they're stable per vine.
    fn gardenPost(self: *const Context, seed: f32) shader_mod.ShaderProgram.WindowRect {
        const u = seed / 100.0;
        const x = self.width * (0.08 + 0.84 * (u * 7.13 - @floor(u * 7.13)));
        const h = self.height * (0.30 + 0.25 * (u * 3.71 - @floor(u * 3.71)));
        return .{ .x = x, .y = -10.0, .w = 3.0, .h = h, .address = 0 };
    }

    /// The rect a vine is rooted on: its window (by address), or a garden
    /// trellis post for addr == 0. Returns null if the window is gone this
    /// frame.
    fn vineRect(self: *const Context, v: *const Vine) ?shader_mod.ShaderProgram.WindowRect {
        if (v.addr == 0) return self.gardenPost(v.seed);
        for (self.win_cache[0..self.win_cache_count]) |w| {
            if (w.address == v.addr) return w;
        }
        return null;
    }

    /// A vine node at arc offset `s`: perimeter point lifted off the frame
    /// by an organic meander, swaying more toward the free tip.
    fn vinePoint(self: *const Context, rect: shader_mod.ShaderProgram.WindowRect, v: *const Vine, s: f32) [2]f32 {
        const hit = perimeterAt(rect, v.t0 + v.dir * s);
        const sway_amp = (1.5 + self.energy * 7.0) * @min(s / 140.0, 1.0);
        const lift = 4.0 +
            @sin(s * 0.11 + v.seed) * 4.0 +
            @sin(s * 0.045 + v.seed * 1.7) * 7.0 +
            @sin(self.now * 1.2 + s * 0.05 + v.seed) * sway_amp;
        const l = @max(lift, 1.5);
        return .{ hit.pos[0] + hit.normal[0] * l, hit.pos[1] + hit.normal[1] * l };
    }

    fn spawnVine(self: *Context, addr: u64, rect_in: ?shader_mod.ShaderProgram.WindowRect) void {
        const r = self.rng.random();
        const seed = r.float(f32) * 100.0;
        const rect = rect_in orelse self.gardenPost(seed);
        for (&self.vines) |*v| {
            if (v.active) continue;
            const per = 2.0 * (rect.w + rect.h);
            var t0 = r.float(f32) * per;
            var dir: f32 = if (r.boolean()) 1.0 else -1.0;
            var target = @min(120.0 + r.float(f32) * 260.0, per * 0.55);
            if (addr == 0) {
                // Root near the base of the post and climb one side upward,
                // stopping shy of the top so the tendril never crests the
                // (invisible) post and hairpins back down mid-air.
                const start = r.float(f32) * rect.h * 0.15;
                if (r.boolean()) {
                    t0 = rect.w + start; // right side, ascending
                    dir = 1.0;
                } else {
                    t0 = 2.0 * rect.w + 2.0 * rect.h - start; // left side, ascending
                    dir = -1.0;
                }
                target = @min(120.0 + r.float(f32) * 260.0, (rect.h - start) * 0.95);
            }
            v.* = .{
                .active = true,
                .addr = addr,
                .t0 = t0,
                .dir = dir,
                .dl = 0,
                .target = target,
                .seed = seed,
            };
            return;
        }
    }

    fn spawnPetalBurst(self: *Context, pos: [2]f32, color_idx: f32, n: u32) void {
        const r = self.rng.random();
        for (0..n) |_| {
            const slot = self.next_petal;
            self.next_petal = (self.next_petal + 1) % max_petals;
            self.petals[slot] = .{
                .active = true,
                .pos = pos,
                .vel = .{ (r.float(f32) * 2.0 - 1.0) * 45.0, 10.0 + r.float(f32) * 30.0 },
                .angle = r.float(f32) * std.math.tau,
                .spin = (r.float(f32) * 2.0 - 1.0) * 2.5,
                .age = 0,
                .life = 2.2 + r.float(f32) * 1.8,
                .size = 3.0 + r.float(f32) * 2.5,
                .color_idx = color_idx,
            };
        }
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

        // ---- cache windows + focused center ----
        self.win_cache_count = 0;
        const wcount = @min(state.windows.len, max_windows);
        for (state.windows[0..wcount]) |w| {
            if (w.w < 40.0 or w.h < 40.0) continue;
            self.win_cache[self.win_cache_count] = w;
            self.win_cache_count += 1;
        }
        self.focused_center = if (state.focused_win.hasArea())
            .{ state.focused_win.x + state.focused_win.w * 0.5, state.focused_win.y + state.focused_win.h * 0.5 }
        else
            .{ -1e9, -1e9 };

        // ---- vine lifecycle ----
        // Windows without a vine get one (staggered so a workspace switch
        // plants the garden over a second or two, not all at once).
        self.spawn_timer -= dt;
        if (self.spawn_timer <= 0) {
            self.spawn_timer = 0.6;
            if (self.win_cache_count == 0) {
                var garden: u32 = 0;
                for (self.vines) |v| {
                    if (v.active and v.addr == 0 and v.dying == 0) garden += 1;
                }
                if (garden < 3) self.spawnVine(0, null);
            } else outer: for (self.win_cache[0..self.win_cache_count]) |w| {
                for (self.vines) |v| {
                    if (v.active and v.addr == w.address and v.dying == 0) continue :outer;
                }
                self.spawnVine(w.address, w);
                break;
            }
        }

        for (&self.vines, 0..) |*v, vi| {
            if (!v.active) continue;

            const rect_opt = self.vineRect(v);
            const orphaned = rect_opt == null or (v.addr == 0 and self.win_cache_count > 0);
            if (orphaned and v.dying == 0) {
                v.dying = 0.0001;
                // The trellis fell: blossoms on this vine burst into petals.
                for (&self.blooms) |*b| {
                    if (!b.active or b.vine != vi) continue;
                    if (rect_opt) |rect| {
                        self.spawnPetalBurst(self.vinePoint(rect, v, b.s), b.color_idx, 4);
                    }
                    b.active = false;
                }
            }
            if (v.dying > 0) {
                v.dying += dt;
                if (v.dying >= vine_die_secs or rect_opt == null) {
                    v.active = false;
                    for (&self.blooms) |*b| {
                        if (b.active and b.vine == vi) b.active = false;
                    }
                }
                continue;
            }

            const rect = rect_opt.?;
            // The focused window is the tended plant: its vine grows faster.
            const cx = rect.x + rect.w * 0.5;
            const cy = rect.y + rect.h * 0.5;
            const is_focused = @abs(cx - self.focused_center[0]) < 40.0 and @abs(cy - self.focused_center[1]) < 40.0;
            const tend: f32 = if (is_focused) 1.8 else 1.0;
            // Silence -> a slow creep; music feeds the garden.
            v.dl = @min(v.dl + dt * self.growth * tend * (12.0 + self.energy * 70.0), v.target);
        }

        // ---- blossoms ----
        for (&self.blooms) |*b| {
            if (!b.active) continue;
            b.age += dt;
            if (b.age >= bloom_life) {
                b.active = false;
                continue;
            }
            // An aging blossom sheds a petal now and then.
            if (b.age > 2.0 and r.float(f32) < dt * 0.5) {
                const v = &self.vines[b.vine];
                if (self.vineRect(v)) |rect| {
                    self.spawnPetalBurst(self.vinePoint(rect, v, b.s), b.color_idx, 1);
                }
            }
        }
        if (beat_hit) {
            const bloom_colors = [_]f32{ 1, 3, 5, 9, 11, 13 };
            var spawned: u32 = 0;
            for (&self.blooms) |*b| {
                if (b.active or spawned >= 2) continue;
                // Pick a random grown vine to flower on.
                var tries: u8 = 0;
                while (tries < 8) : (tries += 1) {
                    const vi = r.intRangeLessThan(usize, 0, max_vines);
                    const v = &self.vines[vi];
                    if (!v.active or v.dying > 0 or v.dl < 80.0) continue;
                    b.* = .{
                        .active = true,
                        .vine = @intCast(vi),
                        .s = (0.35 + r.float(f32) * 0.6) * v.dl,
                        .age = 0,
                        .phase = r.float(f32) * std.math.tau,
                        .color_idx = bloom_colors[r.intRangeLessThan(usize, 0, bloom_colors.len)],
                    };
                    spawned += 1;
                    break;
                }
                if (tries >= 8) break;
            }
        }

        // ---- petals ----
        for (&self.petals) |*p| {
            if (!p.active) continue;
            p.age += dt;
            if (p.age >= p.life or p.pos[1] < -30.0) {
                p.active = false;
                continue;
            }
            const damp = @exp(-0.8 * dt);
            p.vel[0] *= damp;
            p.vel[1] *= damp;
            p.vel[1] -= 55.0 * dt; // y-up: petals fall
            p.vel[0] += @sin(self.now * 0.9 + p.pos[1] * 0.012) * 40.0 * dt; // breeze
            p.pos[0] += p.vel[0] * dt;
            p.pos[1] += p.vel[1] * dt;
            p.angle += p.spin * dt;
        }

        // ---- build frame geometry (stems + leaves) ----
        self.seg_count = 0;
        self.leaf_count = 0;
        for (&self.vines) |*v| {
            if (!v.active) continue;
            const rect = self.vineRect(v) orelse continue;
            const fade = 1.0 - v.dying / vine_die_secs;
            if (fade <= 0) continue;

            // Stem segments at fixed arc steps; the growing tip glows.
            var s: f32 = 0;
            while (s < v.dl and self.seg_count < max_segs) : (s += seg_step) {
                const s1 = @min(s + seg_step, v.dl);
                if (s1 - s < 2.0) break;
                const a = self.vinePoint(rect, v, s);
                const b = self.vinePoint(rect, v, s1);
                const tip = smoothstep(v.dl - 70.0, v.dl, s1);
                self.segs[self.seg_count] = .{ a[0], a[1], b[0], b[1] };
                self.seg_b[self.seg_count] = (0.4 + tip * 0.6) * fade;
                self.seg_count += 1;
            }

            // Leaves at fixed offsets, alternating sides, easing in as the
            // vine grows past each node.
            var li: u32 = 0;
            var ls: f32 = 22.0;
            while (ls < v.dl and self.leaf_count < max_leaves) : (ls += leaf_spacing) {
                const p0 = self.vinePoint(rect, v, ls);
                const pa = self.vinePoint(rect, v, @max(ls - 5.0, 0.0));
                const pb = self.vinePoint(rect, v, ls + 5.0);
                const tang = std.math.atan2(pb[1] - pa[1], pb[0] - pa[0]);
                const side: f32 = if (li % 2 == 0) 1.0 else -1.0;
                const flutter = @sin(self.now * 1.6 + ls * 0.3 + v.seed) * (0.08 + self.treble * 0.25);
                const angle = tang + side * (0.95 + @sin(v.seed + ls) * 0.2) + flutter;
                const grow_in = smoothstep(0.0, 35.0, v.dl - ls);
                const band = self.bands[@as(usize, @intFromFloat(ls)) % 6];
                const size = (6.5 + @sin(v.seed * 3.0 + ls * 0.7) * 2.0) * grow_in * (1.0 + band * 0.2) * fade;
                if (size > 0.5) {
                    self.leaves[self.leaf_count] = .{ p0[0], p0[1], angle, size };
                    self.leaf_count += 1;
                }
                li += 1;
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
            self.loc_leaf = c.glGetUniformLocation(prog.program, "iLeaf[0]");
            self.loc_leafcount = c.glGetUniformLocation(prog.program, "iLeafCount");
            self.loc_bloom = c.glGetUniformLocation(prog.program, "iBloom[0]");
            self.loc_petal = c.glGetUniformLocation(prog.program, "iPetal[0]");
            self.loc_time = c.glGetUniformLocation(prog.program, "iIvyTime");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iBass");
            self.loc_treble = c.glGetUniformLocation(prog.program, "iTreble");
            self.loc_beat = c.glGetUniformLocation(prog.program, "iBeat");
            self.loc_energy = c.glGetUniformLocation(prog.program, "iEnergy");
            self.loc_bright = c.glGetUniformLocation(prog.program, "iBright");
        }

        const n = self.seg_count;
        if (self.loc_segs >= 0 and n > 0) {
            c.glUniform4fv(self.loc_segs, @intCast(n), @ptrCast(&self.segs[0]));
        }
        if (self.loc_segb >= 0) {
            var packed_b: [seg_b_vec4s][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** seg_b_vec4s;
            for (0..n) |i| packed_b[i / 4][i % 4] = self.seg_b[i];
            c.glUniform4fv(self.loc_segb, @intCast((n + 3) / 4), @ptrCast(&packed_b[0]));
        }
        if (self.loc_segcount >= 0) c.glUniform1i(self.loc_segcount, @intCast(n));

        if (self.loc_leaf >= 0 and self.leaf_count > 0) {
            c.glUniform4fv(self.loc_leaf, @intCast(self.leaf_count), @ptrCast(&self.leaves[0]));
        }
        if (self.loc_leafcount >= 0) c.glUniform1i(self.loc_leafcount, @intCast(self.leaf_count));

        if (self.loc_bloom >= 0) {
            // (x, y, size, color_idx + phase/10): phase in [0, tau) packs
            // into the fraction; the shader unpacks with floor/fract.
            var bv: [max_blooms][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** max_blooms;
            for (self.blooms, 0..) |b, i| {
                if (!b.active) continue;
                const v = &self.vines[b.vine];
                const rect = self.vineRect(v) orelse continue;
                const fade = 1.0 - v.dying / vine_die_secs;
                const pos = self.vinePoint(rect, v, b.s);
                // Elastic open, hold, wilt.
                const open = smoothstep(0.0, 0.45, b.age) * (1.0 + 0.3 * @exp(-3.0 * b.age) * @sin(11.0 * b.age));
                const wilt = 1.0 - smoothstep(bloom_life - 1.2, bloom_life, b.age);
                const size = (9.0 + self.bass * 3.5) * open * wilt * @max(fade, 0.0);
                bv[i] = .{ pos[0], pos[1], size, b.color_idx + b.phase / 10.0 };
            }
            c.glUniform4fv(self.loc_bloom, max_blooms, @ptrCast(&bv[0]));
        }

        if (self.loc_petal >= 0) {
            // (x, y, angle + color_idx*10, size): angle < tau < 10.
            var pv: [max_petals][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** max_petals;
            for (self.petals, 0..) |p, i| {
                if (!p.active) continue;
                const env = @sin(std.math.pi * p.age / p.life);
                pv[i] = .{ p.pos[0], p.pos[1], @mod(p.angle, std.math.tau) + p.color_idx * 10.0, p.size * env };
            }
            c.glUniform4fv(self.loc_petal, max_petals, @ptrCast(&pv[0]));
        }

        // Effect-local time (fire.zig pattern) — keeps shader noise
        // coordinates small so f32 precision holds over long sessions.
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.bass);
        if (self.loc_treble >= 0) c.glUniform1f(self.loc_treble, self.treble);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.beat);
        if (self.loc_energy >= 0) c.glUniform1f(self.loc_energy, self.energy);
        if (self.loc_bright >= 0) c.glUniform1f(self.loc_bright, self.brightness);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
    }
};
