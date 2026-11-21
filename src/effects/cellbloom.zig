//! cellbloom: a culture of cells on a plate of food.
//!
//! Every cell is a soft disc. Fed, it grows; full grown, it divides: it
//! becomes two discs on one spot that part along an axis while they
//! shrink, so the outline pinches at the waist and the wall between the
//! daughters closes last. Cells that touch press flat against each other
//! and stick a little, which is all that holds a colony together and all
//! that shapes it.
//!
//! The plate decides who lives. Food is a coarse field that every cell
//! eats from where it sits, that seeps slowly from full places to empty
//! ones and grows back slower still. A lone cell barely dents it. A
//! colony eats its middle bare: the rim, with fresh food ahead of it,
//! keeps dividing outward, while the cells behind go hungry, live for a
//! while on what they stored, pale, and shrink away. So a bloom spreads
//! as a ring, leaves an eaten clearing behind it, and dies where it meets
//! another bloom's clearing. The food returns in a minute or so and the
//! next bloom starts from a survivor or from a spore that lands there.
//! Nothing schedules any of it.
//!
//! Windows are solid: cells are pushed off them, a dragged window plows
//! the culture aside, and one opened on top of a colony kills what it
//! buries. The plate is richer close to a window's edge, so blooms gather
//! round the frames. The cursor is a probe that nudges cells out of its
//! way.
//!
//! The culture is lit by a lamp behind the focused window. When focus
//! moves, that lamp goes down as one comes up behind the new window, so
//! for a moment there are two.
//!
//! All of it is seen down a microscope: specks of dust lie out of focus
//! on the glass and stay put while the culture moves beneath them, and
//! there is a little grain.
//!
//! Music is weather to the culture, not a signal to flash to. Loudness
//! quickens the whole metabolism and makes the plate grow back faster, so
//! a loud passage is a good season and the culture thickens over the
//! next minute. Every cell is tuned to one band of six, and a full-grown
//! cell waits for a strike in its band; then, as often as not, it takes
//! that as its cue and divides a moment later, so each beat sets off a
//! few divisions here and there. For the rest, each cell follows its
//! band slowly and at its own pace: it brightens a little with it, the
//! mids make its membrane a little slacker and the treble its grains a
//! little brighter. Nothing blinks.
//!
//! The shader (shaders/cellbloom.frag) draws each cell as a bubble: its
//! disc, lit as a ball, cut back by its neighbors along their radical
//! axes, which are the straight walls two overlapping circles share, with
//! the corners rounded. Nothing in it is quite regular: outlines wobble,
//! nuclei float and trail behind a cell that is pushed, and no two cells
//! are the same size.
//! The shader finds the few cells near a pixel through a grid of bins
//! packed into a texture here.

const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");

const Uniforms = @import("uniforms.zig").Uniforms;
const lamps_mod = @import("lamps.zig");
const Lamps = lamps_mod.Lamps;
const max_lamps = lamps_mod.max_lamps;
const home_id = lamps_mod.home_id;
const cursor_id = lamps_mod.cursor_id;

const c = @import("c");

const WindowRect = shader_mod.ShaderProgram.WindowRect;

pub const max_cells = 512;
/// What the shader is told of each cell, a column a cell (see `pack`).
pub const Info = [3][max_cells][4]f32;
/// Cells one bin can list. Must match SLOTS in the shader.
pub const slots = 8;

const none: u16 = 0xffff;

// Rates below are per second of the culture's own time, which runs at
// `speed` and quickens with the music.

/// Food grows back toward full at this rate.
const regrow = 1.0 / 80.0;
/// Food seeps between neighboring plate squares at this rate.
const seep = 0.05;
/// A plate square fully covered by cells loses food at this rate.
const uptake = 0.07;
/// Below this much food a cell lives on its reserve.
const hungry = 0.40;
/// Seconds a cell with no food at all lasts on a full reserve.
const starve_s = 30.0;
/// Seconds a well fed daughter takes to grow back to full size.
const cycle_s = 7.0;
/// Seconds a division takes.
const mitosis_s = 2.0;
/// How much of its radius a cell gives up in dividing: each daughter has
/// about half the mother's area.
const halving = 0.28;
/// A cell pressed harder than this (overlap summed over its neighbors, in
/// radii) loses its reserve to the squeeze.
const crush = 0.8;
/// Full-grown radii run from this to this, in `r0`.
const girth_min = 0.85;
const girth_max = 1.08;
/// Centers of two resting neighbors sit this far apart, in summed radii:
/// under one, so neighbors always share a wall.
const rest = 0.84;
/// Neighbors pull on each other out to this far, in summed radii.
const hold = 1.06;

fn smooth(x: f32) f32 {
    const t = std.math.clamp(x, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

pub const Cell = struct {
    alive: bool = false,
    pos: [2]f32 = .{ 0, 0 },
    /// Full radius, px. What is drawn and felt is `reach`.
    r: f32 = 0,
    /// 0 to 1 as a spore swells into a cell.
    grown: f32 = 1,
    /// Set once it has begun to die; `dying` then runs 0 to 1.
    doomed: bool = false,
    dying: f32 = 0,
    age: f32 = 0,
    span: f32 = 100,
    /// What it has stored, 0 to 1. Spent while it goes hungry.
    reserve: f32 = 1,
    /// How hard its neighbors are squeezing it, smoothed.
    press: f32 = 0,
    /// Which way they have been pushing it lately.
    lean: [2]f32 = .{ 0, 0 },
    /// Its full-grown radius, in the culture's `r0`, and how fast it
    /// grows: no two cells are quite alike, and daughters take after
    /// their mother.
    girth: f32 = 1,
    pace: f32 = 1,
    /// How slack its membrane is: 1 at rest, when the outline wobbles and
    /// the insides drift; 0 while it divides, when a cell pulls itself
    /// taut and round.
    flex: f32 = 0,
    /// Where its nucleus floats, px from its center, and which way that
    /// is wandering.
    core: [2]f32 = .{ 0, 0 },
    drift: f32 = 0,
    /// The band it listens to, and that band, the mids and the treble as
    /// it follows them, each cell at its own pace.
    band: u8 = 0,
    level: f32 = 0,
    mid: f32 = 0,
    treble: f32 = 0,
    /// A beat it has taken as its cue: seconds until it starts to divide
    /// (negative = none).
    cue: f32 = -1,
    /// 1 while it is full grown and waiting for a beat to divide on.
    ripe: f32 = 0,
    /// The other half, while dividing.
    mate: u16 = none,
    split: f32 = 0,
    r_from: f32 = 0,
    axis: [2]f32 = .{ 1, 0 },
    /// Seconds spent full grown and waiting to divide.
    ready: f32 = 0,
    heading: f32 = 0,
    seed: f32 = 0,

    pub fn reach(self: *const Cell) f32 {
        return self.r * smooth(self.grown) * (1.0 - smooth(self.dying));
    }

    pub fn dividing(self: *const Cell) bool {
        return self.mate != none;
    }
};

pub const Culture = struct {
    allocator: std.mem.Allocator,
    width: f32,
    height: f32,
    /// Radius of a full grown cell, px.
    r0: f32,
    speed: f32,
    cells: []Cell,

    /// Bins the cells are sorted into, a border of one all round the
    /// screen. A bin is wider than any cell is drawn, so the cells that
    /// can reach a pixel are all in the 3x3 round its own bin.
    bin: f32,
    gw: usize,
    gh: usize,
    bin_n: []u8,
    bin_at: []u16,
    /// Cells left out of a full bin at the last sort.
    crowded: usize = 0,

    /// The plate: food 0 to 1 on squares 1.5 radii wide.
    plot: f32,
    fw: usize,
    fh: usize,
    food: []f32,
    next: []f32,
    /// How much faster each square grows back (more near a window).
    rich: []f32,
    rich_due: f32 = 0,

    /// Each band's level lately, to tell a strike from a held note, and
    /// whether it has dropped back far enough to strike again.
    lately: [6]f32 = @splat(0),
    cocked: [6]bool = @splat(true),

    rng: std.Random.DefaultPrng,
    spore_due: f32 = 0,
    energy: f32 = 0,
    born: usize = 0,
    died: usize = 0,

    /// How far past its rim a cell can matter to a pixel, px. The shader
    /// rounds a cell's corners over 0.28 of its radius, and a neighbor
    /// shapes a corner from that far outside itself; and it lets the
    /// outline wobble up to a tenth of a radius out.
    pub fn margin(r0: f32) f32 {
        return 0.42 * girth_max * r0 + 3.0;
    }

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, size: f32, speed: f32) !Culture {
        const r0 = height * 0.034 * size;
        const bin = 1.01 * girth_max * r0 + margin(r0) + 2.0;
        const gw: usize = @as(usize, @intFromFloat(@ceil(width / bin))) + 2;
        const gh: usize = @as(usize, @intFromFloat(@ceil(height / bin))) + 2;
        const plot = 1.5 * r0;
        const fw: usize = @intFromFloat(@ceil(width / plot));
        const fh: usize = @intFromFloat(@ceil(height / plot));

        const cells = try allocator.alloc(Cell, max_cells);
        errdefer allocator.free(cells);
        @memset(cells, .{});
        const bin_n = try allocator.alloc(u8, gw * gh);
        errdefer allocator.free(bin_n);
        const bin_at = try allocator.alloc(u16, gw * gh * slots);
        errdefer allocator.free(bin_at);
        const food = try allocator.alloc(f32, fw * fh);
        errdefer allocator.free(food);
        const next = try allocator.alloc(f32, fw * fh);
        errdefer allocator.free(next);
        const rich = try allocator.alloc(f32, fw * fh);
        errdefer allocator.free(rich);
        @memset(food, 1.0);
        @memset(next, 1.0);
        @memset(rich, 1.0);
        @memset(bin_n, 0);

        var self = Culture{
            .allocator = allocator,
            .width = width,
            .height = height,
            .r0 = r0,
            .speed = speed,
            .cells = cells,
            .bin = bin,
            .gw = gw,
            .gh = gh,
            .bin_n = bin_n,
            .bin_at = bin_at,
            .plot = plot,
            .fw = fw,
            .fh = fh,
            .food = food,
            .next = next,
            .rich = rich,
            .rng = std.Random.DefaultPrng.init(0xce11b100),
        };

        // A few spores, then a couple of minutes of their own time gone
        // by, so the wallpaper opens on a culture and not on a bare plate.
        for (0..3) |_| _ = self.sow(&.{}, 0.0);
        if (speed > 0) {
            for (0..30 * 150) |_| self.step(1.0 / (30.0 * speed), &quiet, false, .{ -1e6, -1e6 }, &.{});
        }
        return self;
    }

    pub fn deinit(self: *Culture) void {
        self.allocator.free(self.cells);
        self.allocator.free(self.bin_n);
        self.allocator.free(self.bin_at);
        self.allocator.free(self.food);
        self.allocator.free(self.next);
        self.allocator.free(self.rich);
    }

    pub fn alive(self: *const Culture) usize {
        var n: usize = 0;
        for (self.cells) |cell| n += @intFromBool(cell.alive);
        return n;
    }

    pub fn step(self: *Culture, dt_in: f32, bands: *const [6]f32, kick: bool, cursor: [2]f32, windows: []const WindowRect) void {
        const dt = std.math.clamp(dt_in, 0.0, 0.05);
        if (dt <= 0) return;
        var all: f32 = 0;
        for (bands) |v| all += v / 6.0;
        self.energy += (std.math.clamp(all, 0.0, 1.0) - self.energy) * @min(1.0, 2.0 * dt);
        const life = dt * self.speed * (1.0 + 0.8 * self.energy);

        const strikes = self.listen(dt, bands, kick);
        self.feed(dt, life, windows);
        self.metabolize(dt, life, bands, strikes);
        self.sort();
        self.jostle(dt, life, cursor, windows);

        self.spore_due -= life;
        if (self.spore_due <= 0) {
            // Spores are rare while the culture is thriving, so a bloom
            // has the time and the ground to spread before the next one
            // starts. An empty plate takes one wherever there is anything
            // to eat; otherwise only well recovered ground does.
            const n = self.alive();
            self.spore_due = (if (n < 24) @as(f32, 3.0) else 12.0) * (0.6 + 0.8 * self.rng.random().float(f32));
            _ = self.sow(windows, if (n == 0) 0.2 else 0.8);
        }
    }

    // ------------------------------------------------------------ music

    /// Which bands strike now: bit b for band b. A strike is a level well
    /// over where the band has been lately, and it must fall back before
    /// it can strike again. A kick is a strike in the bass, whatever else
    /// it is.
    fn listen(self: *Culture, dt: f32, bands: *const [6]f32, kick: bool) u8 {
        var strikes: u8 = if (kick) 0b11 else 0;
        for (bands, 0..) |v, b| {
            const rise = v - self.lately[b];
            if (self.cocked[b] and rise > 0.16) {
                strikes |= @as(u8, 1) << @intCast(b);
                self.cocked[b] = false;
            } else if (rise < 0.06) self.cocked[b] = true;
            self.lately[b] += (v - self.lately[b]) * (1.0 - @exp(-dt / 0.3));
        }
        return strikes;
    }

    // ------------------------------------------------------------ plate

    fn foodAt(self: *const Culture, pos: [2]f32) f32 {
        const w = self.weights(pos);
        var sum: f32 = 0;
        for (w.at, w.share) |at, share| sum += self.food[at] * share;
        return sum;
    }

    /// Take `amount` (in squares' worth of food) from under `pos`.
    fn eat(self: *Culture, pos: [2]f32, amount: f32) void {
        const w = self.weights(pos);
        for (w.at, w.share) |at, share| self.food[at] = @max(self.food[at] - amount * share, 0.0);
    }

    /// The four plate squares round `pos` and how much of it each holds.
    fn weights(self: *const Culture, pos: [2]f32) struct { at: [4]usize, share: [4]f32 } {
        const u = std.math.clamp(pos[0] / self.plot - 0.5, 0.0, @as(f32, @floatFromInt(self.fw - 1)));
        const v = std.math.clamp(pos[1] / self.plot - 0.5, 0.0, @as(f32, @floatFromInt(self.fh - 1)));
        const x0: usize = @intFromFloat(@floor(u));
        const y0: usize = @intFromFloat(@floor(v));
        const x1 = @min(x0 + 1, self.fw - 1);
        const y1 = @min(y0 + 1, self.fh - 1);
        const fx = u - @floor(u);
        const fy = v - @floor(v);
        return .{
            .at = .{ y0 * self.fw + x0, y0 * self.fw + x1, y1 * self.fw + x0, y1 * self.fw + x1 },
            .share = .{ (1 - fx) * (1 - fy), fx * (1 - fy), (1 - fx) * fy, fx * fy },
        };
    }

    /// Food grows back and seeps.
    fn feed(self: *Culture, dt: f32, life: f32, windows: []const WindowRect) void {
        self.rich_due -= dt;
        if (self.rich_due <= 0) {
            self.rich_due = 0.25;
            for (0..self.fh) |y| {
                for (0..self.fw) |x| {
                    const p = [2]f32{ (@as(f32, @floatFromInt(x)) + 0.5) * self.plot, (@as(f32, @floatFromInt(y)) + 0.5) * self.plot };
                    var near: f32 = 0;
                    for (windows) |w| {
                        if (w.w < 1.0 or w.h < 1.0) continue;
                        near = @max(near, @exp(-@max(windowAway(p, w).d, 0.0) / (3.5 * self.r0)));
                    }
                    self.rich[y * self.fw + x] = 1.0 + 1.6 * near;
                }
            }
        }
        // Loud music is a good season: the plate grows back faster, and
        // over the next minute the culture grows denser on it.
        const plenty = 1.0 + 0.8 * self.energy;
        const k = @min(life * seep, 0.2);
        for (0..self.fh) |y| {
            const up = if (y > 0) y - 1 else y;
            const dn = @min(y + 1, self.fh - 1);
            for (0..self.fw) |x| {
                const lf = if (x > 0) x - 1 else x;
                const rt = @min(x + 1, self.fw - 1);
                const i = y * self.fw + x;
                const n = self.food[i];
                const lap = self.food[y * self.fw + lf] + self.food[y * self.fw + rt] +
                    self.food[up * self.fw + x] + self.food[dn * self.fw + x] - 4.0 * n;
                self.next[i] = std.math.clamp(n + k * lap + life * regrow * plenty * self.rich[i] * (1.0 - n), 0.0, 1.0);
            }
        }
        std.mem.swap([]f32, &self.food, &self.next);
    }

    // ------------------------------------------------------------- life

    /// Each cell eats, stores or starves, ages, grows, and divides.
    fn metabolize(self: *Culture, dt: f32, life: f32, bands: *const [6]f32, strikes: u8) void {
        const r = self.rng.random();
        // Is there music at all? Without it a cell divides in its own
        // time.
        const music = self.energy > 0.05;
        // How much of a plate square one full grown cell covers.
        const cover = std.math.pi * self.r0 * self.r0 / (self.plot * self.plot);
        for (0..self.cells.len) |i| {
            const cell = &self.cells[i];
            if (!cell.alive) continue;

            // Each follows its band, the mids and the treble slowly and
            // at its own pace, so the culture's light drifts with the
            // music and never blinks to it.
            const follow = @min(1.0, (0.8 + 2.2 * cell.seed) * dt);
            cell.level += (bands[cell.band] - cell.level) * follow;
            cell.mid += (0.5 * (bands[2] + bands[3]) - cell.mid) * follow;
            cell.treble += (0.5 * (bands[4] + bands[5]) - cell.treble) * follow;
            const slack: f32 = if (cell.dividing()) 0 else 1;
            cell.flex += (slack - cell.flex) * @min(1.0, (if (cell.dividing()) @as(f32, 5.0) else 0.5) * dt);
            if (cell.grown < 1) cell.grown = @min(1.0, cell.grown + dt / 2.5);

            if (cell.doomed) {
                cell.dying += dt / 2.5;
                if (cell.dying >= 1) {
                    cell.alive = false;
                    self.died += 1;
                }
                continue;
            }

            const size = cell.reach() / self.r0;
            const n = self.foodAt(cell.pos);
            self.eat(cell.pos, life * uptake * n * size * size * cover);
            if (n > hungry) {
                cell.reserve = @min(1.0, cell.reserve + life / 8.0);
            } else {
                cell.reserve = @max(0.0, cell.reserve - life * (1.0 - n / hungry) / starve_s);
            }
            // Squeezed past bearing, it gives up, as a cell crowded out of
            // a tissue does. That is what thins a jam against a window.
            if (cell.press > crush) cell.reserve = @max(0.0, cell.reserve - dt * (cell.press - crush));
            cell.age += life;
            // A division once begun is finished.
            if (cell.dividing()) continue;
            if (cell.reserve <= 0 or cell.age > cell.span) {
                cell.doomed = true;
                continue;
            }

            const fed = std.math.clamp((n - 0.15) / 0.45, 0.0, 1.0);
            const room = 1.0 - smooth((cell.press - 0.3) / 0.4);
            const full = self.r0 * cell.girth;
            cell.r = @min(full, cell.r + life * cell.pace * (halving / cycle_s) * self.r0 * fed * room);

            const waiting = cell.r >= 0.985 * full and cell.grown >= 1 and room > 0.5 and n > hungry;
            cell.ripe += ((if (waiting) @as(f32, 1) else 0) - cell.ripe) * @min(1.0, 5.0 * dt);
            if (waiting) {
                cell.ready += dt;
                // In music a full-grown cell waits for a strike in its
                // band, and then as often as not takes it as its cue and
                // divides a moment later. So each beat sets off a few
                // divisions here and there, not all of them at once. It
                // gives up waiting only after a long while with no
                // strike; in silence it has its own clock.
                const bit = @as(u8, 1) << @intCast(cell.band);
                if (cell.cue < 0 and strikes & bit != 0 and cell.ready > 0.15 and r.float(f32) < 0.5) {
                    cell.cue = 0.3 * r.float(f32);
                }
                const patience: f32 = if (music) 5.0 + 4.0 * cell.seed else 0.5 + 2.0 * cell.seed;
                if (cell.cue >= 0) {
                    cell.cue -= dt;
                    if (cell.cue < 0) self.divide(i);
                } else if (cell.ready > patience) self.divide(i);
            } else {
                cell.ready = 0;
                cell.cue = -1;
            }
        }
    }

    /// Cell `i` becomes two on the same spot, to part in `jostle`.
    fn divide(self: *Culture, i: usize) void {
        const a = &self.cells[i];
        a.ready = 0;
        a.cue = -1;
        const j = self.vacancy() orelse return;
        const r = self.rng.random();
        // Toward the open side if its neighbors are pushing it one way.
        var axis = a.lean;
        const len = @sqrt(axis[0] * axis[0] + axis[1] * axis[1]);
        if (len > 0.02 * self.r0) {
            axis = .{ axis[0] / len, axis[1] / len };
        } else {
            const th = r.float(f32) * std.math.tau;
            axis = .{ @cos(th), @sin(th) };
        }
        a.mate = @intCast(j);
        a.split = 0;
        a.r_from = a.r;
        a.axis = axis;
        const b = &self.cells[j];
        b.* = a.*;
        b.mate = @intCast(i);
        // Half a pixel apart, so the two always have a line between them.
        a.pos = .{ a.pos[0] - axis[0] * 0.25, a.pos[1] - axis[1] * 0.25 };
        b.pos = .{ b.pos[0] + axis[0] * 0.25, b.pos[1] + axis[1] * 0.25 };
        self.born += 1;
    }

    fn vacancy(self: *const Culture) ?usize {
        for (self.cells, 0..) |cell, i| if (!cell.alive) return i;
        return null;
    }

    /// A spore lands on the best fed of a few random spots, if that spot
    /// is clear and has at least `least` food. True if it took.
    fn sow(self: *Culture, windows: []const WindowRect, least: f32) bool {
        const j = self.vacancy() orelse return false;
        const r = self.rng.random();
        var best: ?[2]f32 = null;
        var best_food: f32 = least;
        tries: for (0..10) |_| {
            const p = [2]f32{ r.float(f32) * self.width, r.float(f32) * self.height };
            const n = self.foodAt(p);
            if (n < best_food) continue;
            for (windows) |w| {
                if (w.w < 1.0 or w.h < 1.0) continue;
                if (windowAway(p, w).d < self.r0) continue :tries;
            }
            for (self.cells) |cell| {
                if (!cell.alive) continue;
                const dx = cell.pos[0] - p[0];
                const dy = cell.pos[1] - p[1];
                if (dx * dx + dy * dy < 9.0 * self.r0 * self.r0) continue :tries;
            }
            best = p;
            best_food = n;
        }
        const p = best orelse return false;
        const girth = girth_min + (girth_max - girth_min) * r.float(f32);
        self.cells[j] = .{
            .alive = true,
            .pos = p,
            .r = self.r0 * girth * (1.0 - halving),
            .girth = girth,
            .pace = 0.8 + 0.45 * r.float(f32),
            .drift = r.float(f32) * std.math.tau,
            .grown = 0,
            .span = 90.0 + 80.0 * r.float(f32),
            .band = r.uintLessThan(u8, 6),
            .heading = r.float(f32) * std.math.tau,
            .seed = r.float(f32),
        };
        self.born += 1;
        return true;
    }

    // -------------------------------------------------------- mechanics

    fn binOf(self: *const Culture, pos: [2]f32) [2]usize {
        const bx = std.math.clamp(@floor(pos[0] / self.bin) + 1.0, 0.0, @as(f32, @floatFromInt(self.gw - 1)));
        const by = std.math.clamp(@floor(pos[1] / self.bin) + 1.0, 0.0, @as(f32, @floatFromInt(self.gh - 1)));
        return .{ @intFromFloat(bx), @intFromFloat(by) };
    }

    /// Sort the living into bins.
    pub fn sort(self: *Culture) void {
        @memset(self.bin_n, 0);
        self.crowded = 0;
        for (self.cells, 0..) |cell, i| {
            if (!cell.alive) continue;
            const b = self.binOf(cell.pos);
            const at = b[1] * self.gw + b[0];
            const n = self.bin_n[at];
            if (n >= slots) {
                self.crowded += 1;
                continue;
            }
            self.bin_at[at * slots + n] = @intCast(i);
            self.bin_n[at] = n + 1;
        }
    }

    /// Cells press each other apart and hold each other close, dividing
    /// pairs part, and windows, the cursor and the screen's edges shove.
    fn jostle(self: *Culture, dt: f32, life: f32, cursor: [2]f32, windows: []const WindowRect) void {
        var move: [max_cells][2]f32 = @splat(.{ 0, 0 });
        var press: [max_cells]f32 = @splat(0);
        const firm = @min(1.0, 8.0 * dt);
        const tack = @min(1.0, 0.8 * dt);

        for (self.cells, 0..) |a, i| {
            if (!a.alive) continue;
            const ra = a.reach();
            const home = self.binOf(a.pos);
            const y0 = if (home[1] >= 2) home[1] - 2 else 0;
            const y1 = @min(home[1] + 2, self.gh - 1);
            const x0 = if (home[0] >= 2) home[0] - 2 else 0;
            const x1 = @min(home[0] + 2, self.gw - 1);
            var by = y0;
            while (by <= y1) : (by += 1) {
                var bx = x0;
                while (bx <= x1) : (bx += 1) {
                    const at = by * self.gw + bx;
                    for (self.bin_at[at * slots ..][0..self.bin_n[at]]) |j| {
                        if (j <= i or a.mate == j) continue;
                        const b = self.cells[j];
                        const sum = ra + b.reach();
                        const dx = b.pos[0] - a.pos[0];
                        const dy = b.pos[1] - a.pos[1];
                        const d2 = dx * dx + dy * dy;
                        if (d2 >= hold * hold * sum * sum) continue;
                        const d = @sqrt(d2);
                        const dir: [2]f32 = if (d > 1e-3) .{ dx / d, dy / d } else .{ 1, 0 };
                        const gap = d - rest * sum;
                        // Positive pulls the two together, negative
                        // drives them apart.
                        const f = 0.5 * gap * (if (gap < 0) firm else tack);
                        move[i][0] += dir[0] * f;
                        move[i][1] += dir[1] * f;
                        move[j][0] -= dir[0] * f;
                        move[j][1] -= dir[1] * f;
                        if (gap < 0) {
                            press[i] += -gap / @max(ra, 1.0);
                            press[j] += -gap / @max(b.reach(), 1.0);
                        }
                    }
                }
            }
        }

        // Dividing pairs: one disc becomes two, parting as they shrink.
        for (0..self.cells.len) |i| {
            const a = &self.cells[i];
            if (!a.alive or a.mate == none or a.mate < i) continue;
            const b = &self.cells[a.mate];
            a.split += life / mitosis_s;
            const s = smooth(a.split);
            a.r = a.r_from * (1.0 - halving * s);
            b.r = a.r;
            b.split = a.split;
            const dx = b.pos[0] - a.pos[0];
            const dy = b.pos[1] - a.pos[1];
            const d = @sqrt(dx * dx + dy * dy);
            const dir: [2]f32 = if (d > 1e-2) .{ dx / d, dy / d } else a.axis;
            const want = s * rest * 2.0 * a.r * 0.97;
            const f = 0.5 * (want - d) * @min(1.0, 14.0 * dt);
            move[i][0] -= dir[0] * f;
            move[i][1] -= dir[1] * f;
            move[a.mate][0] += dir[0] * f;
            move[a.mate][1] += dir[1] * f;
            if (a.split >= 1) self.part(i);
        }

        const lo = -0.4 * self.r0;
        const edge = @min(1.0, 6.0 * dt);
        for (0..self.cells.len) |i| {
            const cell = &self.cells[i];
            if (!cell.alive) continue;
            cell.press += (press[i] - cell.press) * @min(1.0, 3.0 * dt);
            const fade = @exp(-dt);
            cell.lean = .{ cell.lean[0] * fade + move[i][0], cell.lean[1] * fade + move[i][1] };

            // A slow wander, so a fed colony never quite sits still.
            cell.heading += (self.rng.random().float(f32) - 0.5) * 2.0 * dt;
            var m = move[i];
            m[0] += @cos(cell.heading) * 0.02 * self.r0 * dt;
            m[1] += @sin(cell.heading) * 0.02 * self.r0 * dt;

            const cap = 0.25 * self.r0;
            const len = @sqrt(m[0] * m[0] + m[1] * m[1]);
            if (len > cap) m = .{ m[0] * cap / len, m[1] * cap / len };
            const was = cell.pos;
            cell.pos = .{ cell.pos[0] + m[0], cell.pos[1] + m[1] };

            const reach = cell.reach();
            for (windows) |w| {
                if (w.w < 1.0 or w.h < 1.0) continue;
                const away = windowAway(cell.pos, w);
                if (away.d < -1.2 * self.r0) {
                    // Buried. It dies there, out of sight.
                    self.doom(i);
                    cell.dying = @max(cell.dying, 0.5);
                } else {
                    const pen = 0.9 * reach + 4.0 - away.d;
                    if (pen > 0) {
                        const f = pen * @min(1.0, 12.0 * dt);
                        cell.pos = .{ cell.pos[0] + away.dir[0] * f, cell.pos[1] + away.dir[1] * f };
                    }
                }
            }

            const cx = cell.pos[0] - cursor[0];
            const cy = cell.pos[1] - cursor[1];
            const cd = @sqrt(cx * cx + cy * cy);
            const shy = 0.7 * self.r0 + reach - cd;
            if (shy > 0 and cd > 1e-3) {
                const f = 0.5 * shy * @min(1.0, 5.0 * dt);
                cell.pos = .{ cell.pos[0] + cx / cd * f, cell.pos[1] + cy / cd * f };
            }

            if (cell.pos[0] < lo) cell.pos[0] += (lo - cell.pos[0]) * edge;
            if (cell.pos[1] < lo) cell.pos[1] += (lo - cell.pos[1]) * edge;
            if (cell.pos[0] > self.width - lo) cell.pos[0] += (self.width - lo - cell.pos[0]) * edge;
            if (cell.pos[1] > self.height - lo) cell.pos[1] += (self.height - lo - cell.pos[1]) * edge;

            // The nucleus floats: it is left a little behind when the
            // cell is moved, and wanders on its own off the middle. A
            // dividing cell holds it dead center.
            cell.core = .{
                cell.core[0] - 0.6 * (cell.pos[0] - was[0]),
                cell.core[1] - 0.6 * (cell.pos[1] - was[1]),
            };
            cell.drift += (self.rng.random().float(f32) - 0.5) * 3.0 * dt;
            const stray: f32 = if (cell.dividing()) 0 else 0.2 * reach;
            const pull = @min(1.0, (if (cell.dividing()) @as(f32, 8.0) else 0.7) * dt);
            cell.core[0] += (@cos(cell.drift) * stray - cell.core[0]) * pull;
            cell.core[1] += (@sin(cell.drift) * stray - cell.core[1]) * pull;
            const off = @sqrt(cell.core[0] * cell.core[0] + cell.core[1] * cell.core[1]);
            const leash = 0.38 * reach;
            if (off > leash) cell.core = .{ cell.core[0] * leash / off, cell.core[1] * leash / off };
        }
    }

    /// A division is done: the two halves of `i` are cells of their own.
    fn part(self: *Culture, i: usize) void {
        const r = self.rng.random();
        const a = &self.cells[i];
        const b = &self.cells[a.mate];
        for ([_]*Cell{ a, b }) |cell| {
            cell.mate = none;
            cell.split = 0;
            cell.age = 0;
            cell.ready = 0;
            cell.span = 90.0 + 80.0 * r.float(f32);
            cell.heading = r.float(f32) * std.math.tau;
        }
        b.seed = r.float(f32);
        // Daughters take after their mother, near enough.
        for ([_]*Cell{ a, b }) |cell| {
            cell.girth = std.math.clamp(cell.girth + (r.float(f32) - 0.5) * 0.10, girth_min, girth_max);
            cell.pace = std.math.clamp(cell.pace * (0.9 + 0.2 * r.float(f32)), 0.8, 1.25);
            cell.drift = r.float(f32) * std.math.tau;
        }
        // Once in a long while one listens a band away.
        if (r.float(f32) < 0.04) {
            b.band = @intCast((@as(usize, b.band) + (if (r.boolean()) @as(usize, 1) else 5)) % 6);
        }
    }

    /// Cell `i` begins to die. Its other half, if it was dividing, is
    /// left a whole cell.
    fn doom(self: *Culture, i: usize) void {
        const cell = &self.cells[i];
        if (cell.doomed) return;
        if (cell.mate != none) {
            const other = &self.cells[cell.mate];
            other.mate = none;
            other.split = 0;
            cell.mate = none;
            cell.split = 0;
        }
        cell.doomed = true;
    }

    // ---------------------------------------------------------- drawing

    /// Fill `bins` (gw * slots texels a row, gh rows: center, drawn
    /// radius, index, with a zero radius ending each bin's list) and
    /// `info` (a column a cell; row 0: how slack it is, level, mate or
    /// -1, how far the wall between it and its mate has closed; row 1:
    /// vitality, how stirred up (waiting to divide, or dividing), its
    /// seed, the mids it hears; row 2: where its nucleus floats, px from
    /// its center, nothing, the treble it hears).
    pub fn pack(self: *Culture, bins: []f32, info: *Info) void {
        self.sort();
        @memset(bins, 0);
        for (0..self.gw * self.gh) |at| {
            var k: usize = 0;
            for (self.bin_at[at * slots ..][0..self.bin_n[at]]) |j| {
                const cell = &self.cells[j];
                // A spore just landed, or a cell all but gone, has no
                // size to draw, and a zero would end the list early.
                const reach = cell.reach();
                if (reach < 0.5) continue;
                bins[(at * slots + k) * 4 ..][0..4].* = .{ cell.pos[0], cell.pos[1], reach, @floatFromInt(j) };
                k += 1;
            }
        }
        for (self.cells, 0..) |cell, j| {
            if (!cell.alive) continue;
            const mate: f32 = if (cell.mate == none) -1.0 else @floatFromInt(cell.mate);
            info[0][j] = .{ cell.flex * smooth(cell.grown), cell.level, mate, smooth((cell.split - 0.55) / 0.45) };
            // A hungry cell pales as its reserve runs down.
            const vital = smooth(cell.reserve / 0.45) * (1.0 - smooth(cell.dying));
            // It glows a little while it waits to divide, and more
            // while it does.
            const stir = @max(0.4 * cell.ripe, @sin(std.math.pi * std.math.clamp(cell.split, 0.0, 1.0)));
            info[1][j] = .{ vital, stir, cell.seed, cell.mid };
            info[2][j] = .{ cell.core[0], cell.core[1], 0, cell.treble };
        }
    }
};

/// Signed distance from `p` to a window with its corners rounded, and the
/// shortest way out of (or away from) it.
fn windowAway(p: [2]f32, w: WindowRect) struct { d: f32, dir: [2]f32 } {
    const round = 12.0;
    const hx = w.w * 0.5;
    const hy = w.h * 0.5;
    const px = p[0] - (w.x + hx);
    const py = p[1] - (w.y + hy);
    const sx: f32 = if (px < 0) -1 else 1;
    const sy: f32 = if (py < 0) -1 else 1;
    const qx = @abs(px) - hx + round;
    const qy = @abs(py) - hy + round;
    if (qx > 0 and qy > 0) {
        const l = @sqrt(qx * qx + qy * qy);
        return .{ .d = l - round, .dir = .{ sx * qx / l, sy * qy / l } };
    }
    if (qx > qy) return .{ .d = qx - round, .dir = .{ sx, 0 } };
    return .{ .d = qy - round, .dir = .{ 0, sy } };
}

/// Specks of dust on the microscope's glass. Must match DUST in the
/// shader.
const n_dust = 14;

/// What lies on the glass: the same every time, like the marks on one's
/// own microscope.
const Glass = struct {
    /// px x, y, radius, and how far out of focus (0 to 1).
    dust: [n_dust][4]f32,
    /// How much each darkens, and how bright the ring round it.
    how: [n_dust][2]f32,

    fn init(width: f32, height: f32) Glass {
        var prng = std.Random.DefaultPrng.init(0x61a55);
        const r = prng.random();
        const px = @max(height / 2160.0, 0.5);
        var self: Glass = undefined;
        for (&self.dust, &self.how) |*d, *h| {
            // Mostly small, a few large and faint.
            const big = r.float(f32);
            const size = (22.0 + 130.0 * big * big) * px;
            d.* = .{ r.float(f32) * width, r.float(f32) * height, size, r.float(f32) };
            h.* = .{ (0.22 + 0.25 * r.float(f32)) * (1.0 - 0.4 * big), 0.045 + 0.055 * r.float(f32) };
        }
        return self;
    }
};

/// Where the light comes from.
const Light = enum {
    /// Behind the focused window; off the upper left when there is none.
    focus,
    /// Carried by the cursor, a little behind it.
    cursor,
    /// Off the upper left.
    fixed,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    culture: Culture,
    bins: []f32,
    info: *Info,
    /// Bins, cell info, food.
    tex: [3]c.GLuint = .{ 0, 0, 0 },
    /// The palette slot the cells are colored from: by default the
    /// accent the fur effect uses (-1 = the theme's foreground).
    color: f32,
    /// Runs the slow wobble of the membranes and the drift of what is
    /// inside the cells and round them: an angle, kept under a turn.
    clock: f64 = 0,
    frame: u32 = 0,
    /// How much of the microscope shows (0 = a clean view).
    lens: f32,
    glass: Glass,
    /// Time and a kick not yet given to the culture, and whether it has
    /// moved since its textures were last sent.
    owed: f32 = 0,
    kicked: bool = false,
    stale: bool = true,
    light: Light,
    lamps: Lamps = .{},
    /// Where the cursor's lamp has got to.
    carried: ?[2]f32 = null,

    u: Uniforms(.{
        .bins = "iCellBins",
        .info = "iCellInfo",
        .food = "iCellFood",
        .grid = "iCellGrid",
        .look = "iCellLook",
        .plate = "iCellPlate",
        .color = "iCellColor",
        .clock = "iCellClock",
        .lamp = "iCellLamp[0]",
        .lens = "iCellLens",
        .dust = "iCellDust[0]",
        .dust_how = "iCellDustHow[0]",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        var music = try spectral.Analyzer.init(allocator, params);
        errdefer music.deinit(allocator);
        var culture = try Culture.init(
            allocator,
            @max(width, 64.0),
            @max(height, 64.0),
            std.math.clamp(params.getFloat("size", 1.0), 0.6, 2.5),
            std.math.clamp(params.getFloat("speed", 1.0), 0.0, 4.0),
        );
        errdefer culture.deinit();
        const bins = try allocator.alloc(f32, culture.gw * culture.gh * slots * 4);
        errdefer allocator.free(bins);
        const info = try allocator.create(Info);
        info.* = @splat(@splat(.{ 0, 0, -1, 0 }));
        return .{
            .allocator = allocator,
            .music = music,
            .culture = culture,
            .bins = bins,
            .info = info,
            .color = @floatFromInt(std.math.clamp(params.getInt("color", 5), -1, 15)),
            .lens = std.math.clamp(params.getFloat("lens", 1.0), 0.0, 3.0),
            .glass = Glass.init(@max(width, 64.0), @max(height, 64.0)),
            .light = std.meta.stringToEnum(Light, params.getString("light", null) orelse "focus") orelse .focus,
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const kick = self.music.update(std.math.clamp(state.dt, 0.0, 0.05));
        // A workspace switch slides the whole strip of windows across the
        // screen. Those are not windows moving, so the culture is left
        // alone until they settle.
        const windows: []const WindowRect = if (state.workspace_slide < 1.0) &.{} else state.windows;
        // The culture moves slowly enough that seventy steps a second
        // show it as smoothly as more would, so on a fast display it
        // sits out every other frame and its textures are sent half as
        // often. A kick in a frame it sat out is kept for the next.
        self.owed += std.math.clamp(state.dt, 0.0, 0.05);
        self.kicked = self.kicked or kick;
        if (self.owed >= 1.0 / 70.0) {
            self.culture.step(self.owed, &self.music.bands.bands, self.kicked, state.cursor, windows);
            self.owed = 0;
            self.kicked = false;
            self.stale = true;
        }

        // A turn every twenty seconds or so, a little quicker in music.
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.clock = @mod(self.clock + dt * 0.3 * (1.0 + 0.5 * self.culture.energy), std.math.tau);
        self.frame +%= 1;

        const col = &self.culture;
        const home = [2]f32{ 0.18 * col.width, 0.86 * col.height };
        var id: u64 = home_id;
        var pos = home;
        switch (self.light) {
            .fixed => {},
            .cursor => {
                const goal = [2]f32{
                    std.math.clamp(state.cursor[0], -0.25 * col.width, 1.25 * col.width),
                    std.math.clamp(state.cursor[1], -0.25 * col.height, 1.25 * col.height),
                };
                const at = self.carried orelse goal;
                const ease = @min(1.0, 3.5 * dt);
                pos = .{ at[0] + (goal[0] - at[0]) * ease, at[1] + (goal[1] - at[1]) * ease };
                self.carried = pos;
                id = cursor_id;
            },
            .focus => if (state.focused_address > cursor_id) {
                for (state.windows) |w| {
                    if (w.address != state.focused_address or w.w < 1.0 or w.h < 1.0) continue;
                    id = w.address;
                    pos = .{ w.x + w.w * 0.5, w.y + w.h * 0.5 };
                    break;
                }
            },
        }
        self.lamps.step(dt, id, pos, state.windows);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        const col = &self.culture;
        const bins_w: c.GLsizei = @intCast(col.gw * slots);
        const bins_h: c.GLsizei = @intCast(col.gh);
        const food_w: c.GLsizei = @intCast(col.fw);
        const food_h: c.GLsizei = @intCast(col.fh);
        if (self.tex[0] == 0) {
            c.glGenTextures(3, &self.tex);
            for (self.tex, 0..) |tex, i| {
                // Bins and info are looked up texel by texel; food is a
                // smooth field.
                const filter: c.GLint = if (i == 2) c.GL_LINEAR else c.GL_NEAREST;
                c.glBindTexture(c.GL_TEXTURE_2D, tex);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, filter);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, filter);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            }
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex[0]);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA32F, bins_w, bins_h, 0, c.GL_RGBA, c.GL_FLOAT, null);
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex[1]);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA32F, max_cells, 3, 0, c.GL_RGBA, c.GL_FLOAT, null);
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex[2]);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R16F, food_w, food_h, 0, c.GL_RED, c.GL_FLOAT, null);
            self.stale = true;
        }

        if (self.stale) col.pack(self.bins, self.info);

        c.glActiveTexture(c.GL_TEXTURE2);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[2]);
        if (self.stale) c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, food_w, food_h, c.GL_RED, c.GL_FLOAT, col.food.ptr);
        c.glActiveTexture(c.GL_TEXTURE1);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[1]);
        if (self.stale) c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, max_cells, 3, c.GL_RGBA, c.GL_FLOAT, self.info);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[0]);
        if (self.stale) c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, bins_w, bins_h, c.GL_RGBA, c.GL_FLOAT, self.bins.ptr);
        self.stale = false;

        self.u.use(prog.program);
        self.u.int(.bins, 0);
        self.u.int(.info, 1);
        self.u.int(.food, 2);
        self.u.f3(.grid, col.bin, @floatFromInt(col.gw), @floatFromInt(col.gh));
        self.u.f4(.look, @max(col.height / 2160.0, 0.5), 0, col.energy, Culture.margin(col.r0));
        // The plate's squares run a little past the screen's far edges.
        self.u.f1(.color, self.color);
        self.u.f3(.clock, @floatCast(self.clock), @floatFromInt(self.frame % 1024), 1.2 * col.height);
        // A lamp hangs low over the plate, so its light rakes across all
        // but the few cells right under it: a highlight in the middle of
        // a ball, over its nucleus, reads as an eye.
        var lamps: [max_lamps][4]f32 = undefined;
        for (self.lamps.lamps, &lamps) |lamp, *out| {
            out.* = .{ lamp.pos[0], lamp.pos[1], 0.14 * col.height, if (lamp.id == 0) 0 else lamp.strength() };
        }
        self.u.f4v(.lamp, max_lamps, &lamps[0]);
        self.u.f1(.lens, self.lens);
        self.u.f4v(.dust, n_dust, &self.glass.dust[0]);
        self.u.f2v(.dust_how, n_dust, &self.glass.how[0]);
        self.u.f2(.plate, @as(f32, @floatFromInt(col.fw)) * col.plot, @as(f32, @floatFromInt(col.fh)) * col.plot);
    }

    pub fn deinit(self: *Context) void {
        if (self.tex[0] != 0) c.glDeleteTextures(3, &self.tex);
        self.allocator.destroy(self.info);
        self.allocator.free(self.bins);
        self.culture.deinit();
        self.music.deinit(self.allocator);
    }
};

const quiet: [6]f32 = @splat(0);
const nowhere = [2]f32{ -1e6, -1e6 };

test "the culture blooms, turns over, and never dies out or leaves the plate" {
    var culture = try Culture.init(std.testing.allocator, 3840, 2160, 1.0, 1.0);
    defer culture.deinit();
    const born0 = culture.born;
    const died0 = culture.died;
    var fewest: usize = max_cells;
    var most: usize = 0;
    var total: usize = 0;
    const steps = 60 * 480;
    for (0..steps) |_| {
        culture.step(1.0 / 60.0, &quiet, false, nowhere, &.{});
        const n = culture.alive();
        fewest = @min(fewest, n);
        most = @max(most, n);
        total += n;
        try std.testing.expectEqual(@as(usize, 0), culture.crowded);
    }
    for (culture.cells) |cell| {
        if (!cell.alive) continue;
        try std.testing.expect(std.math.isFinite(cell.pos[0]) and std.math.isFinite(cell.pos[1]));
        try std.testing.expect(cell.pos[0] > -culture.r0 and cell.pos[0] < culture.width + culture.r0);
        try std.testing.expect(cell.pos[1] > -culture.r0 and cell.pos[1] < culture.height + culture.r0);
    }
    for (culture.food) |n| try std.testing.expect(n >= 0 and n <= 1);
    // Eight minutes: several generations of blooms have come and gone,
    // and there was always a fair culture on the plate.
    try std.testing.expect(fewest >= 12);
    try std.testing.expect(most < max_cells);
    try std.testing.expect(total / steps >= 40);
    try std.testing.expect(culture.died - died0 >= 200);
    try std.testing.expect(culture.born - born0 >= 200);
}

/// A plate with one full grown, well fed cell in the middle.
fn single(culture: *Culture) *Cell {
    for (culture.cells) |*cell| cell.alive = false;
    @memset(culture.food, 1.0);
    culture.cells[0] = .{ .alive = true, .pos = .{ 1920, 1080 }, .r = culture.r0, .span = 1e6 };
    // No spores while the test watches.
    culture.spore_due = 1e9;
    return &culture.cells[0];
}

test "a dividing cell starts as one disc and ends as two" {
    var culture = try Culture.init(std.testing.allocator, 3840, 2160, 1.0, 1.0);
    defer culture.deinit();
    const a = single(&culture);
    var began = false;
    var done = false;
    for (0..60 * 30) |_| {
        const was = a.dividing();
        culture.step(1.0 / 60.0, &quiet, false, nowhere, &.{});
        if (a.dividing() and !was) {
            // The moment it begins: the same disc, twice.
            const b = culture.cells[a.mate];
            began = true;
            try std.testing.expectEqual(a.r, b.r);
            try std.testing.expect(@abs(a.pos[0] - b.pos[0]) < 2 and @abs(a.pos[1] - b.pos[1]) < 2);
            try std.testing.expect(a.r > 0.97 * culture.r0);
        }
        if (was and !a.dividing()) {
            done = true;
            break;
        }
    }
    try std.testing.expect(began and done);
    try std.testing.expectEqual(@as(usize, 2), culture.alive());
    var other: ?Cell = null;
    for (culture.cells[1..]) |cell| if (cell.alive) {
        other = cell;
    };
    const b = other.?;
    // Two smaller cells, side by side and still sharing a wall.
    const d = std.math.hypot(a.pos[0] - b.pos[0], a.pos[1] - b.pos[1]);
    try std.testing.expectApproxEqAbs(a.r, b.r, 1e-3);
    try std.testing.expect(a.r < 0.75 * culture.r0);
    try std.testing.expect(d > 1.4 * a.r and d < 2.0 * a.r);
}

test "a colony eats its middle bare while a lone cell barely dents the plate" {
    var culture = try Culture.init(std.testing.allocator, 3840, 2160, 1.0, 0.0);
    defer culture.deinit();
    _ = single(&culture);
    // A packed disc of cells far from the lone one. Speed zero froze
    // the culture in init; let it run now, but not long enough to breed.
    var n: usize = 1;
    var y: f32 = -4;
    while (y <= 4) : (y += 1) {
        var x: f32 = -4;
        while (x <= 4) : (x += 1) {
            if (x * x + y * y > 16.5) continue;
            culture.cells[n] = .{ .alive = true, .pos = .{ 900 + x * 1.5 * culture.r0, 1080 + y * 1.5 * culture.r0 }, .r = culture.r0 * 0.9, .span = 1e6 };
            n += 1;
        }
    }
    culture.speed = 1.0;
    for (0..60 * 12) |_| culture.step(1.0 / 60.0, &quiet, false, nowhere, &.{});
    try std.testing.expect(culture.foodAt(.{ 900, 1080 }) < hungry);
    try std.testing.expect(culture.foodAt(.{ 1920, 1080 }) > 0.7);
    try std.testing.expect(culture.foodAt(.{ 3000, 400 }) > 0.98);
}

test "cells keep off a window, and one opened over them buries only what is deep under it" {
    var culture = try Culture.init(std.testing.allocator, 3840, 2160, 1.0, 1.0);
    defer culture.deinit();
    const win = [_]WindowRect{.{ .x = 1200, .y = 600, .w = 1400, .h = 900 }};
    for (0..60 * 20) |_| culture.step(1.0 / 60.0, &quiet, false, nowhere, &win);
    for (culture.cells) |cell| {
        if (!cell.alive or cell.doomed) continue;
        try std.testing.expect(windowAway(cell.pos, win[0]).d > 0.5 * cell.reach());
    }
    try std.testing.expect(culture.alive() >= 8);
}

test "every living cell is listed once in the bins the shader reads" {
    var culture = try Culture.init(std.testing.allocator, 2560, 1440, 1.0, 1.0);
    defer culture.deinit();
    const bins = try std.testing.allocator.alloc(f32, culture.gw * culture.gh * slots * 4);
    defer std.testing.allocator.free(bins);
    var info: Info = undefined;
    culture.pack(bins, &info);
    var seen: [max_cells]u8 = @splat(0);
    for (0..culture.gw * culture.gh) |at| {
        var ended = false;
        for (0..slots) |k| {
            const s = bins[(at * slots + k) * 4 ..][0..4];
            if (s[2] <= 0) {
                ended = true;
                continue;
            }
            // No gaps: the shader stops at the first empty slot.
            try std.testing.expect(!ended);
            // Nothing is drawn wider than the shader searches.
            try std.testing.expect(s[2] + Culture.margin(culture.r0) <= culture.bin);
            seen[@intFromFloat(s[3])] += 1;
        }
    }
    for (culture.cells, 0..) |cell, i| {
        // A spore just landed has no size yet and is not drawn.
        const drawn = cell.alive and cell.reach() >= 0.5;
        if (drawn) try std.testing.expectEqual(@as(u8, 1), seen[i]);
        if (!cell.alive) try std.testing.expectEqual(@as(u8, 0), seen[i]);
    }
}

test "a window dragged through the culture never packs a bin past what the shader reads" {
    var culture = try Culture.init(std.testing.allocator, 2560, 1440, 1.0, 1.0);
    defer culture.deinit();
    var worst: usize = 0;
    // Back and forth across the screen, about as fast as a hand drags.
    for (0..60 * 40) |i| {
        const t = @as(f32, @floatFromInt(i)) / 60.0;
        const win = [_]WindowRect{.{ .x = 900 + 800 * @sin(t * 0.9), .y = 300 + 200 * @sin(t * 0.37), .w = 700, .h = 500 }};
        culture.step(1.0 / 60.0, &quiet, false, nowhere, &win);
        worst = @max(worst, culture.crowded);
    }
    try std.testing.expectEqual(@as(usize, 0), worst);
}

test "in music a beat sets off some of the waiting cells, a moment later and not together" {
    var culture = try Culture.init(std.testing.allocator, 3840, 2160, 1.0, 0.0);
    defer culture.deinit();
    for (culture.cells) |*cell| cell.alive = false;
    @memset(culture.food, 1.0);
    culture.spore_due = 1e9;
    // Forty full-grown bass cells, well apart.
    const n = 40;
    for (0..n) |k| {
        culture.cells[k] = .{
            .alive = true,
            .pos = .{ 300 + @as(f32, @floatFromInt(k % 10)) * 340, 300 + @as(f32, @floatFromInt(k / 10)) * 480 },
            .r = culture.r0,
            .span = 1e6,
            .seed = @as(f32, @floatFromInt(k)) / n,
        };
    }
    culture.speed = 1.0;

    // A held chord that has been sounding a while: loud, but nothing
    // strikes. They all wait.
    const chord: [6]f32 = @splat(0.5);
    culture.lately = chord;
    const dt: f32 = 1.0 / 120.0;
    for (0..120 * 2) |_| culture.step(dt, &chord, false, nowhere, &.{});
    for (culture.cells[0..n]) |cell| try std.testing.expect(!cell.dividing() and cell.ripe > 0.9);

    // One kick. Over the next half second some of them divide, each in
    // its own moment; the rest are still waiting.
    var began: [n]?usize = @splat(null);
    for (0..60) |i| {
        culture.step(dt, &chord, i == 0, nowhere, &.{});
        for (culture.cells[0..n], &began) |cell, *at| {
            if (at.* == null and cell.dividing()) at.* = i;
        }
    }
    var count: usize = 0;
    var moments: u64 = 0;
    for (began) |at| if (at) |i| {
        count += 1;
        moments |= @as(u64, 1) << @intCast(i);
        try std.testing.expect(i <= 40);
    };
    try std.testing.expect(count >= n / 4 and count <= 3 * n / 4);
    try std.testing.expect(@popCount(moments) >= 6);
}
