const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// Cyclic cellular automaton (the classic "demons"). N states form a ring;
// a cell in state s flips to s+1 when enough neighbors already carry s+1.
// From random noise the grid self-organizes: debris -> droplets -> traveling
// waves -> self-sustaining spiral defects. Unlike Life it never settles,
// which is what an ambient wallpaper needs.
//
// The sim runs on a coarse CPU grid at sim_hz and ships to the GPU as a
// small RGBA texture: R = state, G = previous state (for temporal crossfade
// in the shader), B = freshness (ticks since last flip -> wavefront glow),
// A = wall. The shader does the pretty part.
//
// Window rects rasterize into the grid as wall cells each tick — waves break
// and pinwheel around real window geometry, and moving a window carves
// through the pattern (freed cells reseed as noise and get reabsorbed).
// The cursor injects a slowly-cycling state, stirring new defects into being.

/// Cap on catch-up sim steps after a frame stall.
const max_catchup = 3;

pub const Context = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    /// Optional system-audio capture (music = false skips it entirely).
    audio: ?*audio_mod.AudioCapture,

    width: f32,
    height: f32,
    now: f32 = 0,

    // -- parameters --
    cell_px: f32,
    n_states: u8,
    threshold: u8,
    /// Neighborhood radius. Range 2 (24 neighbors) with threshold ~3 is the
    /// sustained-spiral regime: settled cells stay frozen (invisible), fronts
    /// sweep through once per ring period, spiral cores never die. Range 1
    /// with threshold 1 is full turbulence; threshold 2+ at range 1 burns out.
    range: i64,
    /// Freshness lost per tick (255 / trail ticks).
    fresh_decay: u8,
    sim_dt: f32,
    warmup: u32,
    stir: bool,
    stir_radius: f32,
    wall_inset: f32,
    /// Palette slots for the two phosphor colors; -1 = theme foreground.
    /// Fronts carrying states from the lower half of the ring glow in
    /// `accent`, upper half in `accent2` — successive waves trade colors.
    accent: f32,
    accent2: f32,
    /// Consecutive near-still ticks; threshold >= 2 can burn out, so a few
    /// calm ticks in a row trigger a defect blob to reignite the culture.
    calm_ticks: u8 = 0,

    // -- CRT filter dials (all safe: no geometry warp, nothing strobes) --
    misconv: f32,
    halation: f32,
    vignette: f32,
    scanbar: f32,

    // -- audio analysis (glitch.zig band split) --
    bands: [6]f32 = [_]f32{0} ** 6,
    bass: f32 = 0,
    treble: f32 = 0,
    bass_smooth: f32 = 0,
    treble_smooth: f32 = 0,
    energy_ema: f32 = 0,
    bass_prev: f32 = 0,
    flux_avg: f32 = 0,
    beat_cooldown: f32 = 0,
    seed_cooldown: f32 = 0,

    // -- grid --
    gw: usize,
    gh: usize,
    /// Double-buffered states; `cur` indexes the live buffer.
    cells: [2][]u8,
    cur: u1 = 0,
    fresh: []u8,
    fresh_prev: []u8,
    wall: []u8,
    old_wall: []u8,
    rgba: []u8,

    acc: f32 = 0,
    tick_frac: f32 = 0,
    tick_count: u32 = 0,
    warmed: bool = false,
    dirty: bool = true,

    /// State the cursor paints; advances every other tick so the stir point
    /// becomes a rotating wave source rather than a dead monochrome blot.
    stir_state: u8 = 0,

    // -- GL --
    tex: c.GLuint = 0,
    cached_program: c.GLuint = 0,
    loc_grid: c.GLint = -1,
    loc_grid_dim: c.GLint = -1,
    loc_cell_px: c.GLint = -1,
    loc_states: c.GLint = -1,
    loc_tick_frac: c.GLint = -1,
    loc_time: c.GLint = -1,
    loc_accent: c.GLint = -1,
    loc_accent2: c.GLint = -1,
    loc_misconv: c.GLint = -1,
    loc_halation: c.GLint = -1,
    loc_vignette: c.GLint = -1,
    loc_scanbar: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_treble: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const cell_px = std.math.clamp(params.getFloat("cell_px", 10.0), 4.0, 64.0);
        const gw: usize = @intFromFloat(@ceil(width / cell_px));
        const gh: usize = @intFromFloat(@ceil(height / cell_px));
        const n = gw * gh;

        const a = try allocator.alloc(u8, n);
        errdefer allocator.free(a);
        const b = try allocator.alloc(u8, n);
        errdefer allocator.free(b);
        const fresh = try allocator.alloc(u8, n);
        errdefer allocator.free(fresh);
        const fresh_prev = try allocator.alloc(u8, n);
        errdefer allocator.free(fresh_prev);
        const wall = try allocator.alloc(u8, n);
        errdefer allocator.free(wall);
        const old_wall = try allocator.alloc(u8, n);
        errdefer allocator.free(old_wall);
        const rgba = try allocator.alloc(u8, n * 4);
        errdefer allocator.free(rgba);

        const n_states: u8 = @intCast(std.math.clamp(params.getInt("states", 16), 3, 32));
        var rng = std.Random.DefaultPrng.init(0xC0FFEE5EED);
        const r = rng.random();
        for (a, b) |*ca, *cb| {
            ca.* = r.intRangeLessThan(u8, 0, n_states);
            cb.* = ca.*;
        }
        @memset(fresh, 0);
        @memset(fresh_prev, 0);
        @memset(wall, 0);
        @memset(old_wall, 0);

        const sim_hz = std.math.clamp(params.getFloat("sim_hz", 14.0), 1.0, 60.0);

        var audio: ?*audio_mod.AudioCapture = null;
        if (params.getBool("music", true)) {
            const cap = try allocator.create(audio_mod.AudioCapture);
            cap.* = audio_mod.AudioCapture.init(params.getString("sink", null));
            cap.start();
            audio = cap;
        }

        return .{
            .allocator = allocator,
            .rng = rng,
            .audio = audio,
            .width = width,
            .height = height,
            .cell_px = cell_px,
            .n_states = n_states,
            .threshold = @intCast(std.math.clamp(params.getInt("threshold", 3), 1, 12)),
            .range = std.math.clamp(params.getInt("range", 2), 1, 3),
            .fresh_decay = @intFromFloat(255.0 / std.math.clamp(params.getFloat("trail", 2.5), 1.0, 20.0)),
            .sim_dt = 1.0 / sim_hz,
            .warmup = @intCast(std.math.clamp(params.getInt("warmup", 140), 0, 2000)),
            .stir = params.getBool("stir", false),
            .stir_radius = std.math.clamp(params.getFloat("stir_radius", 2.2), 0.5, 8.0),
            .wall_inset = std.math.clamp(params.getFloat("wall_inset", 2.0), 0.0, 32.0),
            .accent = @floatFromInt(std.math.clamp(params.getInt("accent", 1), -1, 15)),
            .accent2 = @floatFromInt(std.math.clamp(params.getInt("accent2", 2), -1, 15)),
            .misconv = std.math.clamp(params.getFloat("misconverge", 1.5), 0.0, 8.0),
            .halation = std.math.clamp(params.getFloat("halation", 0.6), 0.0, 3.0),
            .vignette = std.math.clamp(params.getFloat("vignette", 0.22), 0.0, 0.8),
            .scanbar = std.math.clamp(params.getFloat("scanbar", 0.05), 0.0, 0.5),
            .gw = gw,
            .gh = gh,
            .cells = .{ a, b },
            .fresh = fresh,
            .fresh_prev = fresh_prev,
            .wall = wall,
            .old_wall = old_wall,
            .rgba = rgba,
        };
    }

    /// Stamp window rects into the wall mask. Rects are deflated by
    /// wall_inset and only cells *fully* inside count, so the boundary
    /// stays completely covered by the window — the pattern runs right up
    /// to the visible frame. Cells a departing window frees reseed as
    /// noise and get reabsorbed by the surrounding pattern within ticks.
    fn rasterizeWalls(self: *Context, windows: []const shader_mod.ShaderProgram.WindowRect) void {
        @memcpy(self.old_wall, self.wall);
        @memset(self.wall, 0);
        for (windows) |w| {
            const rx0 = w.x + self.wall_inset;
            const ry0 = w.y + self.wall_inset;
            const rx1 = w.x + w.w - self.wall_inset;
            const ry1 = w.y + w.h - self.wall_inset;
            if (rx1 - rx0 < self.cell_px or ry1 - ry0 < self.cell_px) continue;
            const x0 = self.clampCell(@ceil(rx0 / self.cell_px), self.gw);
            const x1 = self.clampCell(@floor(rx1 / self.cell_px) - 1, self.gw);
            const y0 = self.clampCell(@ceil(ry0 / self.cell_px), self.gh);
            const y1 = self.clampCell(@floor(ry1 / self.cell_px) - 1, self.gh);
            if (x1 < x0 or y1 < y0) continue;
            var y = y0;
            while (y <= y1) : (y += 1) {
                @memset(self.wall[y * self.gw + x0 .. y * self.gw + x1 + 1], 1);
            }
        }
        const r = self.rng.random();
        const curr = self.cells[self.cur];
        for (self.wall, self.old_wall, curr, self.fresh) |wn, wo, *cell, *fr| {
            if (wo == 1 and wn == 0) {
                cell.* = r.intRangeLessThan(u8, 0, self.n_states);
                fr.* = 0;
            }
        }
    }

    fn cellIndex(self: *const Context, px: f32, limit: usize) usize {
        return self.clampCell(@floor(px / self.cell_px), limit);
    }

    fn clampCell(self: *const Context, cell: f32, limit: usize) usize {
        _ = self;
        const i: i64 = @intFromFloat(cell);
        return @intCast(std.math.clamp(i, 0, @as(i64, @intCast(limit - 1))));
    }

    /// One CA tick: each non-wall cell flips to its successor state when at
    /// least `threshold` Moore neighbors already carry it. Screen edges and
    /// walls contribute nothing (the screen is a closed dish). Returns the
    /// number of cells that flipped, so the caller can spot a burnout.
    fn step(self: *Context) u32 {
        @memcpy(self.fresh_prev, self.fresh);
        const curr = self.cells[self.cur];
        const next = self.cells[self.cur ^ 1];
        const gw = self.gw;
        const gh = self.gh;
        var flips: u32 = 0;

        for (0..gh) |y| {
            const row = y * gw;
            for (0..gw) |x| {
                const i = row + x;
                if (self.wall[i] == 1) {
                    next[i] = curr[i];
                    self.fresh[i] = 0;
                    continue;
                }
                const s = curr[i];
                const t = if (s + 1 == self.n_states) 0 else s + 1;

                var cnt: u8 = 0;
                const rr: usize = @intCast(self.range);
                const y0 = y -| rr;
                const y1 = @min(y + rr, gh - 1);
                const x0 = x -| rr;
                const x1 = @min(x + rr, gw - 1);
                outer: for (y0..y1 + 1) |ny| {
                    const nrow = ny * gw;
                    for (x0..x1 + 1) |nx| {
                        const j = nrow + nx;
                        if (j == i) continue;
                        if (self.wall[j] == 0 and curr[j] == t) {
                            cnt += 1;
                            if (cnt >= self.threshold) break :outer;
                        }
                    }
                }

                if (cnt >= self.threshold) {
                    next[i] = t;
                    self.fresh[i] = 255;
                    flips += 1;
                } else {
                    next[i] = s;
                    self.fresh[i] -|= self.fresh_decay;
                }
            }
        }
        self.cur ^= 1;
        self.tick_count += 1;
        return flips;
    }

    /// Plant a spiral core: angular sectors of sequential states around a
    /// point. Each sector is eaten by the next, so the pinwheel is
    /// guaranteed to rotate and shed waves at any workable threshold —
    /// unlike a random blob, which can fizzle before organizing.
    fn seedPinwheel(self: *Context, cx: usize, cy: usize) void {
        const curr = self.cells[self.cur];
        const rad: usize = @max(self.gh / 12, 8);
        const x0 = cx -| rad;
        const y0 = cy -| rad;
        const x1 = @min(cx + rad, self.gw - 1);
        const y1 = @min(cy + rad, self.gh - 1);
        const n_f: f32 = @floatFromInt(self.n_states);
        for (y0..y1 + 1) |y| {
            for (x0..x1 + 1) |x| {
                const dx = @as(f32, @floatFromInt(x)) - @as(f32, @floatFromInt(cx));
                const dy = @as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(cy));
                if (dx * dx + dy * dy > @as(f32, @floatFromInt(rad * rad))) continue;
                const i = y * self.gw + x;
                if (self.wall[i] == 1) continue;
                const ang = (std.math.atan2(dy, dx) + std.math.pi) / (2.0 * std.math.pi);
                const s: u8 = @intFromFloat(@min(ang * n_f, n_f - 1.0));
                curr[i] = s;
            }
        }
    }

    fn seedRandomPinwheel(self: *Context) void {
        const r = self.rng.random();
        self.seedPinwheel(
            r.intRangeLessThan(usize, 0, self.gw),
            r.intRangeLessThan(usize, 0, self.gh),
        );
    }

    /// Paint a disc of the (slowly cycling) stir state under the cursor.
    /// A rotating pure-state source sheds fresh wavefronts continuously.
    fn stirAt(self: *Context, cursor: [2]f32) void {
        if (self.tick_count % 2 == 0) {
            self.stir_state = if (self.stir_state + 1 == self.n_states) 0 else self.stir_state + 1;
        }
        const cx = cursor[0] / self.cell_px;
        const cy = cursor[1] / self.cell_px;
        if (cx < 0 or cy < 0 or cx >= @as(f32, @floatFromInt(self.gw)) or cy >= @as(f32, @floatFromInt(self.gh))) return;

        const curr = self.cells[self.cur];
        const rad = self.stir_radius;
        const x0 = self.cellIndex((cx - rad) * self.cell_px, self.gw);
        const x1 = self.cellIndex((cx + rad) * self.cell_px, self.gw);
        const y0 = self.cellIndex((cy - rad) * self.cell_px, self.gh);
        const y1 = self.cellIndex((cy + rad) * self.cell_px, self.gh);
        for (y0..y1 + 1) |y| {
            for (x0..x1 + 1) |x| {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                if (dx * dx + dy * dy > rad * rad) continue;
                const i = y * self.gw + x;
                if (self.wall[i] == 1) continue;
                curr[i] = self.stir_state;
                self.fresh[i] = 220;
            }
        }
    }

    /// Pack the grid into the upload buffer. Both state AND freshness ship
    /// as (previous, current) pairs so every displayed quantity is a single
    /// continuous lerp over the tick — any per-tick snap reads as strobe.
    /// Walls are the reserved state 255 in R, freeing A for prev freshness.
    fn buildRgba(self: *Context) void {
        const curr = self.cells[self.cur];
        const prev = self.cells[self.cur ^ 1];
        for (0..curr.len) |i| {
            if (self.wall[i] == 1) {
                self.rgba[i * 4 + 0] = 255;
                self.rgba[i * 4 + 1] = 255;
                self.rgba[i * 4 + 2] = 0;
                self.rgba[i * 4 + 3] = 0;
            } else {
                self.rgba[i * 4 + 0] = curr[i];
                self.rgba[i * 4 + 1] = prev[i];
                self.rgba[i * 4 + 2] = self.fresh[i];
                self.rgba[i * 4 + 3] = self.fresh_prev[i];
            }
        }
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;

        // ---- audio analysis (glitch/voltaic band split) ----
        if (self.audio) |audio| {
            const wave = audio.getWaveform();
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
            self.treble = (self.bands[4] + self.bands[5]) * 0.5;
            const energy = (self.bands[0] + self.bands[1] + self.bands[2] +
                self.bands[3] + self.bands[4] + self.bands[5]) / 6.0;
            self.energy_ema += (energy - self.energy_ema) * @min(1.0, 2.0 * dt);
            self.bass_smooth += (self.bass - self.bass_smooth) * @min(1.0, 8.0 * dt);
            self.treble_smooth += (self.treble - self.treble_smooth) * @min(1.0, 8.0 * dt);

            // Downbeats plant new spiral cores: a song populates the dish.
            const flux = @max(0.0, self.bass - self.bass_prev);
            self.bass_prev = self.bass;
            self.flux_avg += (flux - self.flux_avg) * @min(1.0, 1.5 * dt);
            self.beat_cooldown -= dt;
            self.seed_cooldown -= dt;
            if (flux > self.flux_avg * 3.0 + 0.03 and self.beat_cooldown <= 0) {
                self.beat_cooldown = 0.25;
                if (self.seed_cooldown <= 0) {
                    self.seed_cooldown = 1.2;
                    self.seedRandomPinwheel();
                }
            }
        }

        // First frame with real window geometry: burn through the boring
        // pure-noise phase so launch reveals droplets already organizing,
        // with walls in place from tick zero.
        if (!self.warmed) {
            self.warmed = true;
            self.rasterizeWalls(state.windows);
            // A few planted spiral cores guarantee waves from the first
            // frame; the noise between them adds natural irregularity.
            for (0..3) |_| self.seedRandomPinwheel();
            for (0..self.warmup) |_| _ = self.step();
            self.buildRgba();
            self.dirty = true;
        }

        // Metabolism: music energy speeds the culture up (~0.6x at rest,
        // ~2x in a loud chorus). tick_frac interpolation keeps the display
        // smooth across the changing rate.
        const speed = 0.6 + 2.0 * std.math.clamp(self.energy_ema, 0.0, 0.8);
        const eff_dt = if (self.audio != null) self.sim_dt / speed else self.sim_dt;

        self.acc += dt;
        var steps: u8 = 0;
        while (self.acc >= eff_dt and steps < max_catchup) : (steps += 1) {
            self.acc -= eff_dt;
            self.rasterizeWalls(state.windows);
            const flips = self.step();
            // Burnout watch: a healthy culture flips >1% of cells per tick;
            // a few near-still ticks in a row means the waves died out.
            if (flips * 400 < self.gw * self.gh) {
                self.calm_ticks +|= 1;
            } else {
                self.calm_ticks = 0;
            }
            if (self.calm_ticks >= 3) {
                self.calm_ticks = 0;
                self.seedRandomPinwheel();
            }
            if (self.stir) self.stirAt(state.cursor);
            self.buildRgba();
            self.dirty = true;
        }
        if (self.acc >= eff_dt) self.acc = 0; // stalled; drop the backlog
        self.tick_frac = std.math.clamp(self.acc / eff_dt, 0.0, 1.0);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        if (self.tex == 0) {
            c.glGenTextures(1, &self.tex);
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA, @intCast(self.gw), @intCast(self.gh), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        }
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        if (self.dirty) {
            c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, @intCast(self.gw), @intCast(self.gh), c.GL_RGBA, c.GL_UNSIGNED_BYTE, self.rgba.ptr);
            self.dirty = false;
        }

        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_grid = c.glGetUniformLocation(prog.program, "iGrid");
            self.loc_grid_dim = c.glGetUniformLocation(prog.program, "iGridDim");
            self.loc_cell_px = c.glGetUniformLocation(prog.program, "iCellPx");
            self.loc_states = c.glGetUniformLocation(prog.program, "iStates");
            self.loc_tick_frac = c.glGetUniformLocation(prog.program, "iTickFrac");
            self.loc_time = c.glGetUniformLocation(prog.program, "iWhorlTime");
            self.loc_accent = c.glGetUniformLocation(prog.program, "iWhorlAccent");
            self.loc_accent2 = c.glGetUniformLocation(prog.program, "iWhorlAccent2");
            self.loc_misconv = c.glGetUniformLocation(prog.program, "iWhorlMisconv");
            self.loc_halation = c.glGetUniformLocation(prog.program, "iWhorlHalation");
            self.loc_vignette = c.glGetUniformLocation(prog.program, "iWhorlVignette");
            self.loc_scanbar = c.glGetUniformLocation(prog.program, "iWhorlScanbar");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iWhorlBass");
            self.loc_treble = c.glGetUniformLocation(prog.program, "iWhorlTreble");
        }

        if (self.loc_grid >= 0) c.glUniform1i(self.loc_grid, 0);
        if (self.loc_grid_dim >= 0) c.glUniform2f(self.loc_grid_dim, @floatFromInt(self.gw), @floatFromInt(self.gh));
        if (self.loc_cell_px >= 0) c.glUniform1f(self.loc_cell_px, self.cell_px);
        if (self.loc_states >= 0) c.glUniform1f(self.loc_states, @floatFromInt(self.n_states));
        if (self.loc_tick_frac >= 0) c.glUniform1f(self.loc_tick_frac, self.tick_frac);
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
        if (self.loc_accent >= 0) c.glUniform1f(self.loc_accent, self.accent);
        if (self.loc_accent2 >= 0) c.glUniform1f(self.loc_accent2, self.accent2);
        if (self.loc_misconv >= 0) c.glUniform1f(self.loc_misconv, self.misconv);
        if (self.loc_halation >= 0) c.glUniform1f(self.loc_halation, self.halation);
        if (self.loc_vignette >= 0) c.glUniform1f(self.loc_vignette, self.vignette);
        if (self.loc_scanbar >= 0) c.glUniform1f(self.loc_scanbar, self.scanbar);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.bass_smooth);
        if (self.loc_treble >= 0) c.glUniform1f(self.loc_treble, self.treble_smooth);
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| {
            audio.stop();
            self.allocator.destroy(audio);
        }
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
        self.allocator.free(self.cells[0]);
        self.allocator.free(self.cells[1]);
        self.allocator.free(self.fresh);
        self.allocator.free(self.fresh_prev);
        self.allocator.free(self.wall);
        self.allocator.free(self.old_wall);
        self.allocator.free(self.rgba);
    }
};
