const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");
const clock = @import("clock.zig");
const geometry = @import("geometry.zig");
const smoothstep = @import("bands.zig").smoothstep;

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

const log = std.log.scoped(.coral);

// Brain coral grown by Gray-Scott reaction-diffusion. Two chemicals live on
// a coarse grid: U, the food, fed everywhere at rate f, and V, the coral,
// which eats U to make more of itself and dies at rate f + k:
//
//     U' = U + Du lap(U) - U V^2 + f (1 - U)
//     V' = V + Dv lap(V) + U V^2 - (f + k) V
//
// The grid is a pair of half-float textures stepped on the GPU: U and V in
// R and G, with B and A carrying two fields the desktop needs (below).
// The display shader thresholds V into flat folds. Everything the desktop
// does to the coral is a term in that system:
//
//   - a window is bare rock: the longer it covers a cell (the fourth
//     channel keeps count) the higher k climbs there, so coral it lands
//     on slowly thins, breaks into spots and dies, and a thin band just
//     outside its edge leaks V, so coral starts at the frames and grows
//     back when a window moves on;
//   - the cursor is a pen, laying V in proportion to the distance it
//     travels, so a stroke buckles into folds and a resting cursor adds
//     nothing;
//   - a spore lands at a random spot every few seconds, which is what
//     starts an empty desktop;
//   - music quickens the steps, and a kick now and then drops a spore.
//     The reaction is far too slow to follow a beat, so the rest of the
//     music rides on the reef's own shape: a third channel holds each
//     cell's `reach`, its distance from the nearest window edge or the
//     cursor measured through the coral, and the display shader sends
//     pulses of light out along it. They run down the folds, split at
//     the forks, and hop the gaps late, brighter and faster with the
//     music;
//   - f and k are read from a smooth field that drifts across the screen,
//     so each region slowly passes between growth habits (see `regime`
//     in the shaders), tight mazes at one end and loose worms at the other;
//   - a few broad patches of raised k wander over the screen (`ebb`).
//     Inside one the folds shrink to spots and die, and behind it the
//     surrounding reef grows back into the clearing. A full labyrinth on
//     its own freezes; the ebb is what keeps it moving for good.
//
// A workspace switch slides the whole window strip across the screen;
// the window terms are gated off while it does, so the passing rects
// leave no trace on the reef.

/// Cells across one fold-and-gap period of the pattern at the diffusion
/// rates below (measured in the harness); turns `scale` into a cell size.
const cells_per_fold = 22.0;

/// Sim steps per second, per cell of grid width, at speed 1. A front
/// advances a fixed fraction of a cell per step, so tying the rate to the
/// grid makes the reef cross the screen in the same time at any size.
const steps_per_cell = 0.4;
/// Most steps one frame may run; a longer stall drops its backlog.
const max_steps = 24;

/// k added on fully barren rock: enough to carry any point of the path
/// well past the spot regime, so nothing is left under a window.
const rock_kill = 0.012;
/// Seconds under a window for rock to turn fully barren, and uncovered
/// for it to recover. The reef starts to thin about a third of the way
/// in, so a window has to stay put for a while before anything dies.
const barren_after = 24.0;
const recover_after = 6.0;
/// Step barrenness changes in; exact in a half float anywhere in 0..1.
const cover_quantum = 1.0 / 64.0;
/// V added per step in a window's edge band, before saturation. Per step,
/// not per second: it has to outpace the reaction's own decay to light.
const edge_seed = 0.012;
/// V laid per cell of cursor travel.
const ink_per_cell = 0.5;
/// k added at the heart of an ebb: enough to carry any point of the path
/// past the spot regime to where nothing survives.
const ebb_kill = 0.0095;
/// Reach cost of crossing a cell of bare rock, against 1 for coral.
const gap_cost = 5.0;
/// Seconds for the pulses to fade out when a window starts moving, and to
/// come back once every window has been still for `hush_hold`. The reach
/// is measured from the window edges, so a moving window re-times every
/// pulse on screen at once; they sit that out and return on the new field.
const hush_out = 0.25;
const hush_hold = 0.6;
const hush_in = 1.8;
/// Cells between one pulse and the next along a fold.
const pulse_cells = 44.0;
/// Mean seconds between spores.
const spore_every = 5.0;

const max_windows = shader_mod.max_windows;

const vert_src: [*:0]const u8 =
    \\#version 300 es
    \\void main() {
    \\    vec2 p = vec2(gl_VertexID & 1, (gl_VertexID >> 1) & 1) * 2.0 - 1.0;
    \\    gl_Position = vec4(p, 0.0, 1.0);
    \\}
;

/// The regime field and the (f, k) path it indexes, shared with
/// shaders/coral.frag (keep the two copies of `regime` identical).
const sim_frag_src: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uPrev;
    \\uniform vec2 uSize;       // grid cells
    \\uniform vec2 uCell;       // px per cell
    \\uniform vec4 uWindows[32];
    \\uniform int uWinCount;
    \\uniform float uKill;      // k added on fully barren rock
    \\uniform vec2 uCover;      // barrenness gained per step covered, lost uncovered
    \\uniform float uSeed;      // V added per step in a window's edge band
    \\uniform vec4 uStroke;     // cursor path this frame: from.xy, to.xy (px)
    \\uniform float uInk;       // V added per step inside the stroke
    \\uniform vec3 uSpore;      // x, y (px), V added
    \\uniform vec3 uPhase;      // regime drift
    \\uniform float uMap;       // 1: lay f along x and k along y instead
    \\uniform float uGap;       // reach cost of a cell of bare rock
    \\uniform vec4 uPath;       // f, k at regime 0, then f, k at regime 1
    \\uniform float uBow;       // k added at the middle of the path
    \\uniform vec3 uEbbPhase;   // the ebb's drift
    \\uniform float uEbb;       // k added at the heart of an ebb
    \\out vec4 o;
    \\
    \\float regime(vec2 p, vec3 ph, float h) {
    \\    vec2 q = p / h;
    \\    float a = sin(dot(q, vec2(2.1, 1.3)) + ph.x);
    \\    float b = sin(dot(q, vec2(-1.7, 2.9)) + ph.y);
    \\    float d = sin(dot(q, vec2(3.4, -2.2)) + ph.z + a * 0.8);
    \\    return smoothstep(-0.55, 0.55, (a + b + d) / 3.0);
    \\}
    \\
    \\// Where the reef is dying back: a few broad patches that wander.
    \\float ebb(vec2 p, vec3 ph, float h) {
    \\    vec2 q = p / h;
    \\    float a = sin(dot(q, vec2(4.6, 2.3)) + ph.x);
    \\    float b = sin(dot(q, vec2(-2.9, 4.4)) + ph.y);
    \\    float d = sin(dot(q, vec2(1.2, -5.3)) + ph.z);
    \\    return smoothstep(0.30, 0.62, (a + b + d) / 3.0);
    \\}
    \\
    \\float sdBox(vec2 p, vec2 b) {
    \\    vec2 d = abs(p) - b;
    \\    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
    \\}
    \\
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy / uSize;
    \\    vec2 t = 1.0 / uSize;
    \\    vec4 s = texture(uPrev, uv);
    \\    vec3 e0 = texture(uPrev, uv + vec2(t.x, 0.0)).rgb, e1 = texture(uPrev, uv - vec2(t.x, 0.0)).rgb;
    \\    vec3 e2 = texture(uPrev, uv + vec2(0.0, t.y)).rgb, e3 = texture(uPrev, uv - vec2(0.0, t.y)).rgb;
    \\    vec3 c0 = texture(uPrev, uv + t).rgb, c1 = texture(uPrev, uv - t).rgb;
    \\    vec3 c2 = texture(uPrev, uv + vec2(t.x, -t.y)).rgb, c3 = texture(uPrev, uv + vec2(-t.x, t.y)).rgb;
    \\    vec2 lap = -s.rg + 0.2 * (e0.rg + e1.rg + e2.rg + e3.rg) + 0.05 * (c0.rg + c1.rg + c2.rg + c3.rg);
    \\
    \\    vec2 p = gl_FragCoord.xy * uCell;
    \\    float cell = uCell.x;
    \\    float f, k;
    \\    if (uMap > 0.5) {
    \\        f = mix(0.020, 0.070, uv.x);
    \\        k = mix(0.054, 0.068, uv.y);
    \\    } else {
    \\        float r = regime(p, uPhase, uSize.y * uCell.y);
    \\        f = mix(uPath.x, uPath.z, r);
    \\        k = mix(uPath.y, uPath.w, r) + uBow * 4.0 * r * (1.0 - r);
    \\        k += uEbb * ebb(p, uEbbPhase, uSize.y * uCell.y);
    \\    }
    \\
    \\    float rock = 0.0, edge = 0.0;
    \\    for (int i = 0; i < uWinCount && i < 32; i++) {
    \\        vec4 w = uWindows[i];
    \\        float d = sdBox(p - (w.xy + w.zw * 0.5), w.zw * 0.5);
    \\        rock = max(rock, 1.0 - smoothstep(-2.0 * cell, 0.0, d));
    \\        edge = max(edge, smoothstep(0.0, cell, d) * (1.0 - smoothstep(cell, 3.0 * cell, d)));
    \\    }
    \\    // Rock a window sits on turns barren over time, and recovers once
    \\    // it is uncovered. Barren rock kills the way an ebb does, by a
    \\    // raised kill rate, so the reef under a window thins, breaks into
    \\    // spots and goes out, and a window passing over does it no harm.
    \\    float barren = clamp(s.a + mix(-uCover.y, uCover.x, rock), 0.0, 1.0);
    \\    k += uKill * smoothstep(0.0, 1.0, barren);
    \\
    \\    float u = s.r, v = s.g;
    \\    float uvv = u * v * v;
    \\    u += 1.0 * lap.r - uvv + f * (1.0 - u);
    \\    v += 0.5 * lap.g + uvv - (f + k) * v;
    \\    // A neighbour's edge band never seeds under a window.
    \\    v += uSeed * edge * (1.0 - rock) * max(0.0, 1.0 - v / 0.3);
    \\
    \\    vec2 ab = uStroke.zw - uStroke.xy;
    \\    float h = clamp(dot(p - uStroke.xy, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    \\    float sd = length(p - uStroke.xy - ab * h);
    \\    v += uInk * (1.0 - smoothstep(cell, 2.5 * cell, sd));
    \\    v += uSpore.z * (1.0 - smoothstep(0.0, 3.0 * cell, length(p - uSpore.xy)));
    \\
    \\    v = clamp(v, 0.0, 1.0);
    \\
    \\    // Reach: how far this cell is from a window's edge or the cursor
    \\    // going through the reef, one relaxation step of a shortest-path
    \\    // field. A cell of coral costs 1 to cross and a cell of bare rock
    \\    // several, so the field runs along the folds and only then hops
    \\    // the gaps between them.
    \\    float cost = mix(uGap, 1.0, smoothstep(0.10, 0.22, v));
    \\    float near = min(min(e0.b, e1.b), min(e2.b, e3.b)) + cost;
    \\    float diag = min(min(c0.b, c1.b), min(c2.b, c3.b)) + cost * 1.41421;
    \\    float reach = min(min(near, diag), 4000.0);
    \\    float src = max(edge, 1.0 - smoothstep(cell, 3.0 * cell, length(p - uStroke.zw)));
    \\    if (src > 0.5) reach = 0.0;
    \\
    \\    o = vec4(clamp(u, 0.0, 1.0), v, reach, barren);
    \\}
;

/// The (f, k) path the regime field moves each region along. It follows
/// the crescent of Pearson's parameter map where stripes grow and branch
/// (mapped with `map = true`): tight mazes at the low end, long loose
/// worms at the high end, and coral that fills the rock all the way
/// along. Off the crescent to one side the reef floods solid, to the
/// other it breaks into spots and stops spreading. The crescent curves,
/// so the path bows toward higher k in the middle to stay on it.
pub const Path = struct {
    f_lo: f32,
    k_lo: f32,
    f_hi: f32,
    k_hi: f32,
    bow: f32,

    pub fn at(self: Path, r: f32) [2]f32 {
        return .{
            self.f_lo + (self.f_hi - self.f_lo) * r,
            self.k_lo + (self.k_hi - self.k_lo) * r + self.bow * 4.0 * r * (1.0 - r),
        };
    }
};
pub const path: Path = .{ .f_lo = 0.034, .k_lo = 0.0580, .f_hi = 0.054, .k_hi = 0.0625, .bow = 0.0008 };

/// Whole sim steps owed for `dt` seconds at `rate` steps per second,
/// carrying the fraction in `acc`. A backlog past `max_steps` is dropped,
/// so a stall slows the reef for a frame instead of bursting afterwards.
pub fn stepsFor(acc: *f32, dt: f32, rate: f32) u32 {
    acc.* += dt * rate;
    const whole = @floor(acc.*);
    if (whole > max_steps) {
        acc.* = 0;
        return max_steps;
    }
    acc.* -= whole;
    return @intFromFloat(whole);
}

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    /// Grid size in cells, and one cell's size in px.
    gw: i32,
    gh: i32,
    cell: [2]f32,

    speed: f32,
    drift_rate: f32,
    pen: bool,
    map: bool,

    /// Regime drift clock, f64 so it keeps its step over a long session.
    drift: f64 = 0,
    acc: f32 = 0,
    /// Steps the next `upload` runs.
    pending: u32 = 0,
    rate: f32 = 90.0,
    /// Window terms' gate: 0 through a workspace slide, easing back to 1.
    gate: f32 = 0,
    spore_in: f32 = 0.3,
    spore: [3]f32 = .{ 0, 0, 0 },
    /// Pulse clock in cycles, quickening with music energy (accumulated
    /// so a rate change never snaps phase).
    pulse: f64 = 0,
    /// Barrenness gain and loss not yet handed to the sim.
    cover_owed: [2]f32 = .{ 0, 0 },
    /// Last frame's window rects by address, to see one move.
    seen: [max_windows]shader_mod.ShaderProgram.WindowRect = undefined,
    seen_count: u32 = 0,
    windows_next: [max_windows]shader_mod.ShaderProgram.WindowRect = undefined,
    /// Seconds since a window last moved, and the pulses' level (0..1).
    still_for: f32 = 10.0,
    voice: f32 = 1.0,
    /// A kick's spore waiting for a frame that steps.
    kick_at: ?[2]f32 = null,
    kick_spore_in: f32 = 0,
    /// Where the pen was when its ink was last laid.
    pen_from: [2]f32 = .{ 0, 0 },
    pen_to: [2]f32 = .{ 0, 0 },
    pen_seeded: bool = false,
    ink: f32 = 0,

    windows: [max_windows][4]f32 = undefined,
    window_count: u32 = 0,

    gl_ready: bool = false,
    gl_failed: bool = false,
    sim_prog: c.GLuint = 0,
    tex: [2]c.GLuint = .{ 0, 0 },
    fbo: c.GLuint = 0,
    vao: c.GLuint = 0,
    current: u1 = 0,

    su: Uniforms(.{
        .prev = "uPrev",
        .size = "uSize",
        .cell = "uCell",
        .windows = "uWindows[0]",
        .win_count = "uWinCount",
        .kill = "uKill",
        .cover = "uCover",
        .seed = "uSeed",
        .stroke = "uStroke",
        .ink = "uInk",
        .spore = "uSpore",
        .phase = "uPhase",
        .map = "uMap",
        .gap = "uGap",
        .path = "uPath",
        .bow = "uBow",
        .ebb_phase = "uEbbPhase",
        .ebb = "uEbb",
    }) = .{},

    u: Uniforms(.{
        .field = "iCoral",
        .size = "iCoralSize",
        .phase = "iCoralPhase",
        .beat = "iCoralBeat",
        .bass = "iCoralBass",
        .energy = "iCoralEnergy",
        .pulse = "iCoralPulse",
        .pulse_cells = "iCoralPulseCells",
        .voice = "iCoralVoice",
        .map = "iCoralMap",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const music = try spectral.Analyzer.init(allocator, params);
        const scale = std.math.clamp(params.getFloat("scale", 70.0), 24.0, 400.0);
        const gw: i32 = @intFromFloat(@max(16.0, @ceil(width * cells_per_fold / scale)));
        const gh: i32 = @intFromFloat(@max(16.0, @ceil(height * cells_per_fold / scale)));
        return .{
            .allocator = allocator,
            .music = music,
            .rng = std.Random.DefaultPrng.init(0xC02A1),
            .width = width,
            .height = height,
            .gw = gw,
            .gh = gh,
            .cell = .{ width / @as(f32, @floatFromInt(gw)), height / @as(f32, @floatFromInt(gh)) },
            .speed = std.math.clamp(params.getFloat("speed", 1.0), 0.1, 8.0),
            .drift_rate = std.math.clamp(params.getFloat("drift", 1.0), 0.0, 10.0),
            .pen = params.getBool("cursor", true),
            .map = params.getBool("map", false),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.1);
        const kick = self.music.update(dt);
        self.pulse += dt * (0.22 + @min(self.music.bands.energy_ema, 1.5) * 0.9);
        if (kick) {
            const r = self.rng.random();
            const at = [2]f32{ r.float(f32) * self.width, r.float(f32) * self.height };
            // Only one kick in a while seeds: a spore
            // on every beat would churn the reef faster than it grows.
            if (self.kick_spore_in <= 0) {
                self.kick_at = at;
                self.kick_spore_in = 2.5;
            }
        }
        self.kick_spore_in -= dt;
        const energy = self.music.bands.energy_ema;
        self.drift += dt * self.drift_rate;
        self.rate = steps_per_cell * @as(f32, @floatFromInt(self.gw)) * self.speed * (1.0 + @min(energy, 1.5) * 0.3);
        self.pending = stepsFor(&self.acc, dt, self.rate);

        // Off for the whole slide, then back over about half a second.
        const settled: f32 = if (state.workspace_slide >= 0.999) 1.0 else 0.0;
        self.gate = if (settled == 0.0) 0.0 else @min(1.0, self.gate + dt * 2.0);

        self.window_count = 0;
        var moved = false;
        var kept: u32 = 0;
        for (state.windows) |w| {
            if (self.window_count == max_windows) break;
            if (w.w < 1.0 or w.h < 1.0) continue;
            self.windows[self.window_count] = .{ w.x, w.y, w.w, w.h };
            self.window_count += 1;
            // New, or not where it was by more than a pixel of jitter.
            var same = false;
            for (self.seen[0..self.seen_count]) |o| {
                if (o.address != w.address) continue;
                same = @abs(o.x - w.x) < 1.0 and @abs(o.y - w.y) < 1.0 and
                    @abs(o.w - w.w) < 1.0 and @abs(o.h - w.h) < 1.0;
                break;
            }
            if (!same) moved = true;
            self.windows_next[kept] = w;
            kept += 1;
        }
        if (kept != self.seen_count) moved = true;
        @memcpy(self.seen[0..kept], self.windows_next[0..kept]);
        self.seen_count = kept;
        self.still_for = if (moved) 0.0 else self.still_for + dt;
        const want: f32 = if (self.still_for >= hush_hold) 1.0 else 0.0;
        const rate: f32 = if (want > self.voice) 1.0 / hush_in else 1.0 / hush_out;
        self.voice = std.math.clamp(self.voice + std.math.sign(want - self.voice) * rate * dt, 0.0, 1.0);

        // The stroke runs from where ink was last laid to the cursor, and
        // only advances on a frame that steps, so no travel is skipped.
        if (!self.pen_seeded) {
            self.pen_from = state.cursor;
            self.pen_seeded = true;
        }
        self.pen_to = state.cursor;
        self.ink = 0;
        if (self.pen and self.pending > 0) {
            const dx = self.pen_to[0] - self.pen_from[0];
            const dy = self.pen_to[1] - self.pen_from[1];
            const cells = @sqrt(dx * dx + dy * dy) / self.cell[0];
            // A jump (a workspace switch, a warp) is not a stroke.
            if (cells < 60.0) {
                // Each cell of the stroke is inked once however many
                // steps the frame runs, and a slow pass still leaves a
                // line: the per-step dose is capped, not the total.
                const per_step = ink_per_cell * @min(cells, 1.0) / @as(f32, @floatFromInt(self.pending));
                self.ink = @min(per_step, 0.2);
            } else {
                self.pen_from = self.pen_to;
            }
        }

        self.spore[2] = 0;
        self.spore_in -= dt * self.speed;
        if (self.kick_at != null and self.pending > 0) {
            self.spore = .{ self.kick_at.?[0], self.kick_at.?[1], 0.5 };
            self.kick_at = null;
        } else if (self.spore_in <= 0 and self.pending > 0) {
            const r = self.rng.random();
            self.spore = .{ r.float(f32) * self.width, r.float(f32) * self.height, 0.5 };
            self.spore_in = if (self.map) 0.05 else spore_every * (0.5 + r.float(f32));
        }
    }

    fn ensureGl(self: *Context) bool {
        if (self.gl_ready) return true;
        if (self.gl_failed) return false;
        self.gl_failed = true;

        self.sim_prog = geometry.compileProgram(vert_src, sim_frag_src);
        if (self.sim_prog == 0) {
            log.err("sim shader failed to compile", .{});
            return false;
        }

        c.glGenTextures(2, &self.tex);
        c.glGenFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        var complete = true;
        for (self.tex) |t| {
            c.glBindTexture(c.GL_TEXTURE_2D, t);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, self.gw, self.gh, 0, c.GL_RGBA, c.GL_HALF_FLOAT, null);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, t, 0);
            if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
                complete = false;
                break;
            }
            // All food, no coral.
            c.glClearColor(1, 0, 0, 0);
            c.glClear(c.GL_COLOR_BUFFER_BIT);
        }
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (!complete) {
            // 8-bit would lose the small per-step changes the reaction
            // lives on, so there is no fallback format.
            log.err("no half-float render target; coral cannot grow here", .{});
            return false;
        }
        c.glGenVertexArrays(1, &self.vao);

        self.gl_failed = false;
        self.gl_ready = true;
        return true;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        if (self.ensureGl() and self.pending > 0) {
            const steps = self.pending;
            self.pending = 0;

            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
            c.glViewport(0, 0, self.gw, self.gh);
            c.glBindVertexArray(self.vao);
            c.glActiveTexture(c.GL_TEXTURE0);

            self.su.use(self.sim_prog);
            self.su.int(.prev, 0);
            self.su.f2(.size, @floatFromInt(self.gw), @floatFromInt(self.gh));
            self.su.f2(.cell, self.cell[0], self.cell[1]);
            self.su.f4v(.windows, @intCast(self.window_count), &self.windows[0]);
            self.su.int(.win_count, @intCast(self.window_count));
            self.su.f1(.kill, rock_kill);
            self.su.f1(.seed, self.gate * edge_seed);
            self.su.f4(.stroke, self.pen_from[0], self.pen_from[1], self.pen_to[0], self.pen_to[1]);
            self.su.f1(.ink, self.ink);
            const ph = self.phases();
            self.su.f3(.phase, ph[0], ph[1], ph[2]);
            self.su.f1(.map, if (self.map) 1.0 else 0.0);
            self.su.f1(.gap, gap_cost);
            self.su.f4(.path, path.f_lo, path.k_lo, path.f_hi, path.k_hi);
            self.su.f1(.bow, path.bow);
            self.su.f3(.ebb_phase, clock.phase(self.drift, 0.031), clock.phase(self.drift, 0.023), clock.phase(self.drift, 0.027));
            self.su.f1(.ebb, ebb_kill);

            // Barrenness moves in whole quanta on a frame's first step. A
            // per-step share would be smaller than a half float can add
            // to a value near 1, and the count would stall partway.
            const seconds = @as(f32, @floatFromInt(steps)) / self.rate;
            self.cover_owed[0] += self.gate * seconds / barren_after;
            self.cover_owed[1] += seconds / recover_after;
            var cover = [2]f32{ 0, 0 };
            for (&self.cover_owed, &cover) |*owed, *out| {
                out.* = @floor(owed.* / cover_quantum) * cover_quantum;
                owed.* -= out.*;
            }

            for (0..steps) |i| {
                if (i == 0) self.su.f2(.cover, cover[0], cover[1]) else self.su.f2(.cover, 0, 0);
                const next = 1 - self.current;
                // The spore lands once; later steps only spread it.
                const amount: f32 = if (i == 0) self.spore[2] else 0.0;
                self.su.f3(.spore, self.spore[0], self.spore[1], amount);
                c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex[next], 0);
                c.glBindTexture(c.GL_TEXTURE_2D, self.tex[self.current]);
                c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
                self.current = next;
            }
            self.pen_from = self.pen_to;

            c.glBindVertexArray(0);
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        }

        self.u.use(prog.program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[self.current]);
        self.u.int(.field, 0);
        self.u.f2(.size, @floatFromInt(self.gw), @floatFromInt(self.gh));
        const ph = self.phases();
        self.u.f3(.phase, ph[0], ph[1], ph[2]);
        self.u.f1(.beat, self.music.beat());
        self.u.f1(.bass, self.music.bass());
        self.u.f1(.energy, self.music.bands.energy_ema);
        self.u.f1(.pulse, clock.cycles(self.pulse, 1.0));
        self.u.f1(.pulse_cells, pulse_cells);
        self.u.f1(.voice, smoothstep(0.0, 1.0, self.voice));
        self.u.f1(.map, if (self.map) 1.0 else 0.0);
    }

    /// Three slow incommensurate turns; a region crosses the regimes over
    /// a few minutes at drift 1.
    fn phases(self: *const Context) [3]f32 {
        return .{
            clock.phase(self.drift, 0.021),
            clock.phase(self.drift, 0.013),
            clock.phase(self.drift, 0.017),
        };
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
        if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
        if (self.tex[0] != 0) c.glDeleteTextures(2, &self.tex);
        if (self.sim_prog != 0) c.glDeleteProgram(self.sim_prog);
        if (self.vao != 0) c.glDeleteVertexArrays(1, &self.vao);
    }
};

test "stepsFor carries the fraction and drops a stalled backlog" {
    var acc: f32 = 0;
    var total: u32 = 0;
    for (0..120) |_| total += stepsFor(&acc, 1.0 / 120.0, 90.0);
    try std.testing.expect(total == 89 or total == 90);
    try std.testing.expect(acc < 1.0);

    acc = 0;
    try std.testing.expectEqual(@as(u32, max_steps), stepsFor(&acc, 10.0, 90.0));
    try std.testing.expectEqual(@as(f32, 0), acc);
}

/// Linear interpolation through `pts`, sorted by x, held flat outside.
fn lerpTable(pts: []const [2]f32, x: f32) f32 {
    if (x <= pts[0][0]) return pts[0][1];
    for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
        if (x <= b[0]) return a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0]);
    }
    return pts[pts.len - 1][1];
}

test "the path stays on the growing crescent and the ebb clears it" {
    // Both edges of the crescent as (f, k), read off the parameter map
    // (`map = true`): below the first the reef floods solid, above the
    // second it only makes spots. Past about k = 0.067 nothing survives.
    const flood = [_][2]f32{ .{ 0.032, 0.0540 }, .{ 0.0375, 0.0568 }, .{ 0.045, 0.0587 }, .{ 0.0575, 0.0603 } };
    const spots = [_][2]f32{ .{ 0.034, 0.0615 }, .{ 0.045, 0.0635 }, .{ 0.0575, 0.0643 } };
    var i: u32 = 0;
    while (i <= 10) : (i += 1) {
        const fk = path.at(@as(f32, @floatFromInt(i)) / 10.0);
        try std.testing.expect(fk[1] > lerpTable(&flood, fk[0]) + 0.0005);
        try std.testing.expect(fk[1] < lerpTable(&spots, fk[0]) - 0.0005);
        try std.testing.expect(fk[1] + ebb_kill > 0.067);
    }
}
