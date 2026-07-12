const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");

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

/// Freshness lost per tick for cells that didn't flip (~13 ticks to fade).
/// Keep in sync with the 0.078 (= 20/255) decay constant in whorl.frag.
const fresh_decay = 20;

/// Cap on catch-up sim steps after a frame stall.
const max_catchup = 3;

pub const Context = struct {
    allocator: std.mem.Allocator,
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    now: f32 = 0,

    // -- parameters --
    cell_px: f32,
    n_states: u8,
    threshold: u8,
    sim_dt: f32,
    warmup: u32,
    stir: bool,
    stir_radius: f32,
    wall_inset: f32,

    // -- grid --
    gw: usize,
    gh: usize,
    /// Double-buffered states; `cur` indexes the live buffer.
    cells: [2][]u8,
    cur: u1 = 0,
    fresh: []u8,
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
        const wall = try allocator.alloc(u8, n);
        errdefer allocator.free(wall);
        const old_wall = try allocator.alloc(u8, n);
        errdefer allocator.free(old_wall);
        const rgba = try allocator.alloc(u8, n * 4);
        errdefer allocator.free(rgba);

        const n_states: u8 = @intCast(std.math.clamp(params.getInt("states", 14), 3, 32));
        var rng = std.Random.DefaultPrng.init(0xC0FFEE5EED);
        const r = rng.random();
        for (a, b) |*ca, *cb| {
            ca.* = r.intRangeLessThan(u8, 0, n_states);
            cb.* = ca.*;
        }
        @memset(fresh, 0);
        @memset(wall, 0);
        @memset(old_wall, 0);

        const sim_hz = std.math.clamp(params.getFloat("sim_hz", 14.0), 1.0, 60.0);
        return .{
            .allocator = allocator,
            .rng = rng,
            .width = width,
            .height = height,
            .cell_px = cell_px,
            .n_states = n_states,
            .threshold = @intCast(std.math.clamp(params.getInt("threshold", 1), 1, 4)),
            .sim_dt = 1.0 / sim_hz,
            .warmup = @intCast(std.math.clamp(params.getInt("warmup", 140), 0, 2000)),
            .stir = params.getBool("stir", true),
            .stir_radius = std.math.clamp(params.getFloat("stir_radius", 2.2), 0.5, 8.0),
            .wall_inset = std.math.clamp(params.getFloat("wall_inset", 2.0), 0.0, 32.0),
            .gw = gw,
            .gh = gh,
            .cells = .{ a, b },
            .fresh = fresh,
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
    /// walls contribute nothing (the screen is a closed dish).
    fn step(self: *Context) void {
        const curr = self.cells[self.cur];
        const next = self.cells[self.cur ^ 1];
        const gw = self.gw;
        const gh = self.gh;

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
                const y0 = if (y > 0) y - 1 else y;
                const y1 = if (y + 1 < gh) y + 1 else y;
                const x0 = if (x > 0) x - 1 else x;
                const x1 = if (x + 1 < gw) x + 1 else x;
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
                } else {
                    next[i] = s;
                    self.fresh[i] -|= fresh_decay;
                }
            }
        }
        self.cur ^= 1;
        self.tick_count += 1;
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

    /// Pack the grid into the upload buffer. G carries the pre-tick state so
    /// the shader can crossfade between ticks instead of snapping.
    fn buildRgba(self: *Context) void {
        const curr = self.cells[self.cur];
        const prev = self.cells[self.cur ^ 1];
        for (0..curr.len) |i| {
            self.rgba[i * 4 + 0] = curr[i];
            self.rgba[i * 4 + 1] = prev[i];
            self.rgba[i * 4 + 2] = self.fresh[i];
            self.rgba[i * 4 + 3] = if (self.wall[i] == 1) 255 else 0;
        }
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;

        // First frame with real window geometry: burn through the boring
        // pure-noise phase so launch reveals droplets already organizing,
        // with walls in place from tick zero.
        if (!self.warmed) {
            self.warmed = true;
            self.rasterizeWalls(state.windows);
            for (0..self.warmup) |_| self.step();
            self.buildRgba();
            self.dirty = true;
        }

        self.acc += dt;
        var steps: u8 = 0;
        while (self.acc >= self.sim_dt and steps < max_catchup) : (steps += 1) {
            self.acc -= self.sim_dt;
            self.rasterizeWalls(state.windows);
            self.step();
            if (self.stir) self.stirAt(state.cursor);
            self.buildRgba();
            self.dirty = true;
        }
        if (self.acc >= self.sim_dt) self.acc = 0; // stalled; drop the backlog
        self.tick_frac = std.math.clamp(self.acc / self.sim_dt, 0.0, 1.0);
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
        }

        if (self.loc_grid >= 0) c.glUniform1i(self.loc_grid, 0);
        if (self.loc_grid_dim >= 0) c.glUniform2f(self.loc_grid_dim, @floatFromInt(self.gw), @floatFromInt(self.gh));
        if (self.loc_cell_px >= 0) c.glUniform1f(self.loc_cell_px, self.cell_px);
        if (self.loc_states >= 0) c.glUniform1f(self.loc_states, @floatFromInt(self.n_states));
        if (self.loc_tick_frac >= 0) c.glUniform1f(self.loc_tick_frac, self.tick_frac);
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
    }

    pub fn deinit(self: *Context) void {
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
        self.allocator.free(self.cells[0]);
        self.allocator.free(self.cells[1]);
        self.allocator.free(self.fresh);
        self.allocator.free(self.wall);
        self.allocator.free(self.old_wall);
        self.allocator.free(self.rgba);
    }
};
