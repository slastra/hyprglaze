//! fire: flames rising from the top edges of windows, as a fluid.
//!
//! Two things are simulated on a coarse grid on the GPU. The air is a 2D
//! incompressible flow, Stam's stable fluids (1999): its velocity is
//! carried along itself, stirred where it is hot, and a pressure solve
//! keeps it divergence-free. The fire is temperature carried by that air
//! and, on top of it, rising under its own heat as it cools.
//!
//! The rise is kept out of the pressure solve on purpose. In two
//! dimensions a sheet of hot gas along an edge cannot rise as a sheet,
//! because air would have to come in underneath it and there is only the
//! window there; it sits on the edge and leaks away in a few thin curls.
//! Real flames draw that air from the third dimension.
//!
//! Windows are solid bodies in the air, moving at their own velocity, and
//! each one feeds heat in along its top edge. Nothing about a moving
//! window is scripted. Drag one and its flame is left behind in the air it
//! was burning in and streams back over the window; the air the window
//! shoves aside bends its neighbors' flames; stop, and the trail it drew
//! burns out while the flame stands back up.
//!
//! The light the fire throws is its heat blurred at several widths at
//! once (a dual-filter pyramid, Bjorge 2015), so one flame has both a
//! close halo and a wide, faint reach.

const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const geometry = @import("geometry.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

const log = std.log.scoped(.fire);

const max_windows = 32;

/// Screen px per grid cell.
const cell_px: f32 = 4.0;

/// Pressure relaxation sweeps a step. The solve starts from last frame's
/// pressure, so a few are enough.
const jacobi_sweeps = 18;

/// Levels in the light pyramid. Each is half the size of the one before,
/// the first half the grid: the last, at 256 px a cell, is the reach.
const glow_levels = 6;
/// How much of each level is in the light, tightest first. The wide ones
/// are dilute and need the weight to show at all.
const glow_mix = [glow_levels]f32{ 0.10, 0.35, 0.60, 0.90, 1.20, 1.50 };

/// The longest step the flow takes, and the most steps one frame runs.
const max_step: f32 = 1.0 / 45.0;
const max_steps = 3;

/// A window faster than this is a jump (a workspace switch, a warp), not a
/// move, and stirs nothing.
const jump_speed: f32 = 9000.0;

// How quickly the tracked velocity follows the window (seconds). The
// geometry arrives in step with the compositor, so this is only enough to
// take the stairs out of a frame-to-frame difference.
const tau_vel: f32 = 0.025;
// How quickly a window's flame grows or shrinks as it gains or loses focus.
const tau_burn: f32 = 0.35;

const vert_src: [*:0]const u8 =
    \\#version 300 es
    \\void main() {
    \\    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    \\    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

// State texture: rg = velocity (px/s), b = temperature, a = smoke, or -1
// inside a window. Pressure texture: r = pressure, g = divergence,
// b = solid.

/// Carry the state along the flow, then apply this step's forces, cooling
/// and sources.
const advect_src: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uState;
    \\uniform vec2 uGrid;
    \\uniform float uCell;
    \\uniform float uDt;
    \\uniform float uTime;
    \\uniform vec4 uWin[32];
    \\uniform vec4 uWinMove[32];   // velocity px/s, burn 0..1, seed
    \\uniform int uWinCount;
    \\uniform vec4 uGas;           // updraft, drag, stir, rise px/s
    \\uniform vec2 uCool;          // constant and proportional cooling
    \\uniform vec2 uSmoke;         // smoke per unit of heat lost, thinning per second
    \\uniform float uFloor;        // how hard the bottom of the screen burns
    \\out vec4 o;
    \\
    \\float hash(ivec2 p) {
    \\    uint h = uint(p.x) * 0x8da6b343u + uint(p.y) * 0xd8163841u;
    \\    h ^= h >> 15; h *= 0x2c1b3c6du;
    \\    h ^= h >> 12; h *= 0x297a2d39u;
    \\    h ^= h >> 15;
    \\    return float(h >> 8) / 16777216.0;
    \\}
    \\float noise(vec2 p) {
    \\    ivec2 i = ivec2(floor(p));
    \\    vec2 f = fract(p);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    return mix(mix(hash(i), hash(i + ivec2(1, 0)), f.x),
    \\               mix(hash(i + ivec2(0, 1)), hash(i + ivec2(1, 1)), f.x), f.y);
    \\}
    \\
    \\void main() {
    \\    vec2 x = gl_FragCoord.xy * uCell;
    \\
    \\    // Inside a window: solid, moving as the window moves.
    \\    for (int i = 0; i < uWinCount && i < 32; i++) {
    \\        vec4 w = uWin[i];
    \\        if (x.x > w.x && x.x < w.x + w.z && x.y > w.y && x.y < w.y + w.w) {
    \\            o = vec4(uWinMove[i].xy, 0.0, -1.0);
    \\            return;
    \\        }
    \\    }
    \\
    \\    // Where this cell's gas was a step ago: brought by the air, and
    \\    // by its own rise, fast where it burns and slow where only smoke
    \\    // is left. Clear, cold air does not rise at all.
    \\    vec2 span = uGrid * uCell;
    \\    vec4 here = texture(uState, x / span);
    \\    // The rise is read a little below as well as here: a cold cell
    \\    // just above the flame has to be reached by what is coming up.
    \\    vec4 under = texture(uState, (x - vec2(0.0, 2.0 * uCell)) / span);
    \\    float hot = min(max(here.b, under.b), 1.0);
    \\    float warm = min(hot * 4.0 + max(max(here.a, under.a), 0.0) * 1.5, 1.0);
    \\    vec2 carry = here.xy + vec2(0.0, uGas.w * (0.3 * warm + 0.7 * hot));
    \\    vec4 s = texture(uState, (x - carry * uDt) / span);
    \\    vec2 v = s.xy;
    \\    float T = s.b;
    \\    // Next to a window the sample is part wall (-1): no smoke there.
    \\    float smoke = max(s.a, 0.0);
    \\    float lift = T + 0.25 * smoke;
    \\
    \\    // Still air comes to rest.
    \\    v *= exp(-uGas.y * uDt);
    \\    // The rising gas drags a little of the air up with it, enough to
    \\    // draw neighboring flames toward each other.
    \\    v.y += uGas.x * lift * uDt;
    \\    // And it churns: a divergence-free stir (the curl of a drifting
    \\    // noise field), only where there is something to churn.
    \\    vec2 q = x * 0.011 + vec2(0.0, -uTime * 0.7);
    \\    float e = 0.35;
    \\    vec2 curl = vec2(noise(q + vec2(0.0, e)) - noise(q - vec2(0.0, e)),
    \\                     noise(q - vec2(e, 0.0)) - noise(q + vec2(e, 0.0))) / (2.0 * e);
    \\    v += curl * uGas.z * lift * uDt;
    \\    // It cools, the last of it quickly, so a flame ends in a tip
    \\    // rather than a haze. What burns out becomes smoke, which thins.
    \\    float cooled = max(T - uDt * (uCool.x + uCool.y * T), 0.0);
    \\    smoke = min(smoke + uSmoke.x * (T - cooled), 2.0) * exp(-uSmoke.y * uDt);
    \\    T = cooled;
    \\
    \\    // Each window burns along its top edge, in jets that wander and
    \\    // gutter, which is what breaks the flame into tongues.
    \\    for (int i = 0; i < uWinCount && i < 32; i++) {
    \\        vec4 w = uWin[i];
    \\        float along = x.x - w.x;
    \\        float above = x.y - (w.y + w.w);
    \\        if (along < 0.0 || along > w.z || above < 0.0 || above > 2.5 * uCell) continue;
    \\        float ends = smoothstep(0.0, 36.0, along) * smoothstep(0.0, 36.0, w.z - along);
    \\        float seed = uWinMove[i].w;
    \\        float jets = 0.65 * noise(vec2(along * 0.016 + seed, uTime * 0.9))
    \\                   + 0.35 * noise(vec2(along * 0.045 - seed, uTime * 1.7 + 7.0));
    \\        float burn = ends * smoothstep(0.22, 0.6, jets) * (0.8 + 0.7 * uWinMove[i].z);
    \\        if (burn <= 0.0) continue;
    \\        T = max(T, burn);
    \\        // Fresh gas leaves the edge with the window's own motion.
    \\        v = mix(v, uWinMove[i].xy, 0.5);
    \\    }
    \\
    \\    // And so does the bottom of the screen, edge to edge.
    \\    if (uFloor > 0.0 && x.y < 2.5 * uCell) {
    \\        float jets = 0.65 * noise(vec2(x.x * 0.011, uTime * 0.8 + 31.0))
    \\                   + 0.35 * noise(vec2(x.x * 0.034 + 9.0, uTime * 1.5));
    \\        float burn = smoothstep(0.24, 0.62, jets) * uFloor;
    \\        if (burn > 0.0) T = max(T, burn);
    \\    }
    \\
    \\    o = vec4(v, T, smoke);
    \\}
;

/// Divergence of the carried velocity, beside last frame's pressure.
const diverge_src: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uState;
    \\uniform sampler2D uPres;
    \\uniform float uCell;
    \\out vec4 o;
    \\void main() {
    \\    ivec2 p = ivec2(gl_FragCoord.xy);
    \\    ivec2 hi = textureSize(uState, 0) - 1;
    \\    vec4 sc = texelFetch(uState, p, 0);
    \\    float l = texelFetch(uState, clamp(p + ivec2(-1, 0), ivec2(0), hi), 0).x;
    \\    float r = texelFetch(uState, clamp(p + ivec2(1, 0), ivec2(0), hi), 0).x;
    \\    float b = texelFetch(uState, clamp(p + ivec2(0, -1), ivec2(0), hi), 0).y;
    \\    float t = texelFetch(uState, clamp(p + ivec2(0, 1), ivec2(0), hi), 0).y;
    \\    float div = ((r - l) + (t - b)) / (2.0 * uCell);
    \\    o = vec4(texelFetch(uPres, p, 0).r, div, sc.a < -0.5 ? 1.0 : 0.0, 0.0);
    \\}
;

/// One Jacobi sweep of the pressure Poisson equation. A solid neighbor
/// mirrors the cell's own pressure: no flow through a wall.
const jacobi_src: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uPres;
    \\uniform float uCell;
    \\out vec4 o;
    \\void main() {
    \\    ivec2 p = ivec2(gl_FragCoord.xy);
    \\    ivec2 hi = textureSize(uPres, 0) - 1;
    \\    vec4 pc = texelFetch(uPres, p, 0);
    \\    // Past the grid's edge is open air at pressure 0.
    \\    vec4 l = p.x > 0 ? texelFetch(uPres, p + ivec2(-1, 0), 0) : vec4(0.0);
    \\    vec4 r = p.x < hi.x ? texelFetch(uPres, p + ivec2(1, 0), 0) : vec4(0.0);
    \\    vec4 b = p.y > 0 ? texelFetch(uPres, p + ivec2(0, -1), 0) : vec4(0.0);
    \\    vec4 t = p.y < hi.y ? texelFetch(uPres, p + ivec2(0, 1), 0) : vec4(0.0);
    \\    float sum = (l.b > 0.5 ? pc.r : l.r) + (r.b > 0.5 ? pc.r : r.r)
    \\              + (b.b > 0.5 ? pc.r : b.r) + (t.b > 0.5 ? pc.r : t.r);
    \\    o = vec4((sum - pc.g * uCell * uCell) * 0.25, pc.g, pc.b, 0.0);
    \\}
;

/// Take the pressure gradient out of the velocity, leaving it
/// divergence-free, and hold the gas against a wall to the wall's motion.
const project_src: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uState;
    \\uniform sampler2D uPres;
    \\uniform float uCell;
    \\out vec4 o;
    \\void main() {
    \\    ivec2 p = ivec2(gl_FragCoord.xy);
    \\    ivec2 hi = textureSize(uState, 0) - 1;
    \\    vec4 s = texelFetch(uState, p, 0);
    \\    if (s.a < -0.5) { o = s; return; }
    \\    ivec2 pl = clamp(p + ivec2(-1, 0), ivec2(0), hi);
    \\    ivec2 pr = clamp(p + ivec2(1, 0), ivec2(0), hi);
    \\    ivec2 pb = clamp(p + ivec2(0, -1), ivec2(0), hi);
    \\    ivec2 pt = clamp(p + ivec2(0, 1), ivec2(0), hi);
    \\    vec4 c0 = texelFetch(uPres, p, 0);
    \\    vec4 l = p.x > 0 ? texelFetch(uPres, pl, 0) : vec4(0.0);
    \\    vec4 r = p.x < hi.x ? texelFetch(uPres, pr, 0) : vec4(0.0);
    \\    vec4 b = p.y > 0 ? texelFetch(uPres, pb, 0) : vec4(0.0);
    \\    vec4 t = p.y < hi.y ? texelFetch(uPres, pt, 0) : vec4(0.0);
    \\    vec2 grad = vec2((r.b > 0.5 ? c0.r : r.r) - (l.b > 0.5 ? c0.r : l.r),
    \\                     (t.b > 0.5 ? c0.r : t.r) - (b.b > 0.5 ? c0.r : b.r)) / (2.0 * uCell);
    \\    vec2 v = s.xy - grad;
    \\    if (l.b > 0.5) v.x = texelFetch(uState, pl, 0).x;
    \\    if (r.b > 0.5) v.x = texelFetch(uState, pr, 0).x;
    \\    if (b.b > 0.5) v.y = texelFetch(uState, pb, 0).y;
    \\    if (t.b > 0.5) v.y = texelFetch(uState, pt, 0).y;
    \\    o = vec4(v, s.b, max(s.a, 0.0));
    \\}
;

/// Halve the light into the next level down: the center and four
/// diagonals, each a bilinear tap. The first level reads the fire's state
/// and takes what it gives off, which climbs steeply with heat.
const dim_src: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uSrc;
    \\uniform vec2 uInv;      // 1 / this target's size
    \\uniform vec2 uTexel;    // one texel of the source
    \\uniform float uEmit;    // 1 when the source is the fire's state
    \\out vec4 o;
    \\float light(vec2 uv) {
    \\    vec4 s = texture(uSrc, uv);
    \\    if (uEmit < 0.5) return s.r;
    \\    float T = min(s.b, 1.3);
    \\    return T * T;
    \\}
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy * uInv;
    \\    vec2 d = vec2(uTexel.x, -uTexel.y);
    \\    float sum = light(uv) * 4.0 + light(uv + uTexel) + light(uv - uTexel)
    \\              + light(uv + d) + light(uv - d);
    \\    o = vec4(sum / 8.0);
    \\}
;

/// Spread a coarse level back up with a tent and add this level's own
/// share, so the finest ends up holding every width at once.
const spread_src: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uCoarse;
    \\uniform sampler2D uSame;
    \\uniform vec2 uInv;      // 1 / this target's size
    \\uniform vec2 uTexel;    // half a texel of the coarse level
    \\uniform vec2 uGain;     // of the coarse level, of this one
    \\out vec4 o;
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy * uInv;
    \\    vec2 h = uTexel;
    \\    float sum = texture(uCoarse, uv + vec2(-2.0 * h.x, 0.0)).r
    \\              + texture(uCoarse, uv + vec2(2.0 * h.x, 0.0)).r
    \\              + texture(uCoarse, uv + vec2(0.0, -2.0 * h.y)).r
    \\              + texture(uCoarse, uv + vec2(0.0, 2.0 * h.y)).r
    \\              + 2.0 * (texture(uCoarse, uv + vec2(-h.x, h.y)).r
    \\                     + texture(uCoarse, uv + vec2(h.x, h.y)).r
    \\                     + texture(uCoarse, uv + vec2(-h.x, -h.y)).r
    \\                     + texture(uCoarse, uv + vec2(h.x, -h.y)).r);
    \\    o = vec4(uGain.x * sum / 12.0 + uGain.y * texture(uSame, uv).r);
    \\}
;

/// What the simulation remembers about one window, by address.
const Track = struct {
    addr: u64 = 0,
    pos: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    burn: f32 = 0,
    seen: bool = false,
};

/// A window's velocity from where it was a frame ago, eased. A step that
/// would mean more than `jump_speed` is a jump and counts as standing
/// still.
fn follow(track: *Track, x: f32, y: f32, dt: f32) void {
    if (dt <= 0) return;
    var vx = (x - track.pos[0]) / dt;
    var vy = (y - track.pos[1]) / dt;
    if (vx * vx + vy * vy > jump_speed * jump_speed) {
        vx = 0;
        vy = 0;
        track.vel = .{ 0, 0 };
    }
    const k = 1.0 - @exp(-dt / tau_vel);
    track.vel[0] += (vx - track.vel[0]) * k;
    track.vel[1] += (vy - track.vel[1]) * k;
    track.pos = .{ x, y };
}

pub const Context = struct {
    width: f32,
    height: f32,
    gw: c.GLsizei,
    gh: c.GLsizei,
    now: f64 = 0,
    /// This frame's time to advance, 0 when there is none.
    dt: f32 = 0,

    /// Flame size and how much smoke to show, from the config.
    height_scale: f32,
    smoke: f32,
    /// How hard the bottom of the screen burns, 0 for not at all.
    floor: f32,
    /// How much light the fire throws on what is around it, 0 for none.
    glow: f32,

    tracks: [max_windows]Track = @splat(.{}),
    switches: u32 = 0,

    // This frame's windows for the simulation: rect, then velocity, burn
    // and a seed for its jets.
    wins: [max_windows][4]f32 = undefined,
    moves: [max_windows][4]f32 = undefined,
    /// How far each window came since the last frame, so a frame made up
    /// in several steps sweeps it across instead of jumping it.
    came: [max_windows][2]f32 = undefined,
    win_count: u32 = 0,

    // GL, created on the first upload.
    gl_ready: bool = false,
    gl_failed: bool = false,
    vao: c.GLuint = 0,
    fbo: c.GLuint = 0,
    state: [2]c.GLuint = .{ 0, 0 },
    pres: [2]c.GLuint = .{ 0, 0 },
    cur: u8 = 0,
    pcur: u8 = 0,
    advect: c.GLuint = 0,
    diverge: c.GLuint = 0,
    jacobi: c.GLuint = 0,
    project: c.GLuint = 0,
    // The light pyramid: halved on the way down, summed on the way up.
    // lit[0] is what gets drawn.
    dim: c.GLuint = 0,
    spread: c.GLuint = 0,
    dimmed: [glow_levels]c.GLuint = @splat(0),
    lit: [glow_levels - 1]c.GLuint = @splat(0),
    glow_size: [glow_levels][2]c.GLsizei = undefined,

    au: Uniforms(.{
        .state = "uState",
        .grid = "uGrid",
        .cell = "uCell",
        .dt = "uDt",
        .time = "uTime",
        .win = "uWin[0]",
        .move = "uWinMove[0]",
        .count = "uWinCount",
        .gas = "uGas",
        .cool = "uCool",
        .smoke = "uSmoke",
        .floor = "uFloor",
    }) = .{},
    du: Uniforms(.{ .state = "uState", .pres = "uPres", .cell = "uCell" }) = .{},
    ju: Uniforms(.{ .pres = "uPres", .cell = "uCell" }) = .{},
    pu: Uniforms(.{ .state = "uState", .pres = "uPres", .cell = "uCell" }) = .{},
    mu: Uniforms(.{ .src = "uSrc", .inv = "uInv", .texel = "uTexel", .emit = "uEmit" }) = .{},
    su: Uniforms(.{
        .coarse = "uCoarse",
        .same = "uSame",
        .inv = "uInv",
        .texel = "uTexel",
        .gain = "uGain",
    }) = .{},

    /// On the main (drawing) program.
    u: Uniforms(.{
        .fire = "iFire",
        .span = "iFireSpan",
        .time = "iFireTime",
        .smoke = "iSmoke",
        .light = "iFireLight",
        .glow = "iGlow",
    }) = .{},

    pub fn init(_: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        return .{
            .width = width,
            .height = height,
            .gw = @intFromFloat(@ceil(@max(width, 1.0) / cell_px)),
            .gh = @intFromFloat(@ceil(@max(height, 1.0) / cell_px)),
            .height_scale = std.math.clamp(params.getFloat("height", 1.0), 0.3, 3.0),
            .smoke = std.math.clamp(params.getFloat("smoke", 1.0), 0.0, 3.0),
            .floor = std.math.clamp(params.getFloat("floor", 1.0), 0.0, 1.5),
            .glow = std.math.clamp(params.getFloat("glow", 1.0), 0.0, 3.0),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        // The windows move in real time, so the fire has to as well: a slow
        // frame is made up in more steps, not a shorter one.
        const dt = std.math.clamp(state.dt, 0.0, max_step * max_steps);
        self.now += dt;
        self.dt = dt;

        // A workspace switch puts different windows at the same places:
        // nothing moved, so nobody has a velocity.
        const switched = state.workspace_switches != self.switches;
        self.switches = state.workspace_switches;

        for (&self.tracks) |*t| t.seen = false;
        const count = @min(state.windows.len, max_windows);
        const k_burn = 1.0 - @exp(-dt / tau_burn);
        const f = state.focused_win;
        for (state.windows[0..count], 0..) |w, i| {
            const track = self.trackFor(w.address, w.x, w.y);
            const was = track.pos;
            if (switched) {
                track.pos = .{ w.x, w.y };
                track.vel = .{ 0, 0 };
            } else follow(track, w.x, w.y, dt);
            // A jump leaves the velocity at rest, and then nothing came
            // from anywhere.
            const moved = track.vel[0] != 0 or track.vel[1] != 0;
            self.came[i] = if (moved and !switched) .{ w.x - was[0], w.y - was[1] } else .{ 0, 0 };

            // The focused window burns higher.
            const focused = f.hasArea() and @abs(f.x - w.x) < 3 and @abs(f.y - w.y) < 3 and
                @abs(f.w - w.w) < 3 and @abs(f.h - w.h) < 3;
            track.burn += ((if (focused) @as(f32, 1.0) else 0.0) - track.burn) * k_burn;

            self.wins[i] = .{ w.x, w.y, w.w, w.h };
            self.moves[i] = .{
                track.vel[0],
                track.vel[1],
                track.burn,
                @as(f32, @floatFromInt(w.address % 977)) * 0.37,
            };
        }
        self.win_count = @intCast(count);
        for (&self.tracks) |*t| {
            if (!t.seen) t.* = .{};
        }
    }

    /// The window's track, or a fresh one that starts at rest where the
    /// window is now.
    fn trackFor(self: *Context, addr: u64, x: f32, y: f32) *Track {
        var free: ?*Track = null;
        for (&self.tracks) |*t| {
            if (t.addr == addr and addr != 0) {
                t.seen = true;
                return t;
            }
            if (free == null and t.addr == 0 and !t.seen) free = t;
        }
        const t = free orelse &self.tracks[0];
        t.* = .{ .addr = addr, .pos = .{ x, y }, .seen = true };
        return t;
    }

    fn makeTex(tex: c.GLuint, w: c.GLsizei, h: c.GLsizei) bool {
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, w, h, 0, c.GL_RGBA, c.GL_HALF_FLOAT, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, tex, 0);
        if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) return false;
        c.glClearColor(0, 0, 0, 0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        return true;
    }

    fn ensureGl(self: *Context) bool {
        if (self.gl_ready) return true;
        if (self.gl_failed) return false;
        self.gl_failed = true;

        self.advect = geometry.compileProgram(vert_src, advect_src);
        self.diverge = geometry.compileProgram(vert_src, diverge_src);
        self.jacobi = geometry.compileProgram(vert_src, jacobi_src);
        self.project = geometry.compileProgram(vert_src, project_src);
        self.dim = geometry.compileProgram(vert_src, dim_src);
        self.spread = geometry.compileProgram(vert_src, spread_src);
        if (self.advect == 0 or self.diverge == 0 or self.jacobi == 0 or self.project == 0 or
            self.dim == 0 or self.spread == 0)
        {
            log.err("a simulation shader failed to compile", .{});
            return false;
        }

        c.glGenTextures(2, &self.state);
        c.glGenTextures(2, &self.pres);
        c.glGenFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        var complete = true;
        for (self.state) |t| complete = complete and makeTex(t, self.gw, self.gh);
        for (self.pres) |t| complete = complete and makeTex(t, self.gw, self.gh);
        c.glGenTextures(glow_levels, &self.dimmed);
        c.glGenTextures(glow_levels - 1, &self.lit);
        var size = [2]c.GLsizei{ self.gw, self.gh };
        for (0..glow_levels) |i| {
            size = .{ @max(@divTrunc(size[0] + 1, 2), 1), @max(@divTrunc(size[1] + 1, 2), 1) };
            self.glow_size[i] = size;
            complete = complete and makeTex(self.dimmed[i], size[0], size[1]);
            if (i < glow_levels - 1) complete = complete and makeTex(self.lit[i], size[0], size[1]);
        }
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (!complete) {
            // The flow lives on small per-step changes that 8 bits lose.
            log.err("no half-float render target; fire cannot burn here", .{});
            return false;
        }
        c.glGenVertexArrays(1, &self.vao);

        self.gl_failed = false;
        self.gl_ready = true;
        return true;
    }

    fn pass(target: c.GLuint) void {
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, target, 0);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    }

    fn bind(unit: c.GLenum, tex: c.GLuint) void {
        c.glActiveTexture(unit);
        c.glBindTexture(c.GL_TEXTURE_2D, tex);
    }

    /// One step of the flow, with the framebuffer and vertex array bound.
    fn step(self: *Context, dt: f32, wins: *const [max_windows][4]f32) void {
        const next = 1 - self.cur;

        // Carry, force, cool, feed: state[cur] -> state[next].
        self.au.use(self.advect);
        bind(c.GL_TEXTURE0, self.state[self.cur]);
        self.au.int(.state, 0);
        self.au.f2(.grid, @floatFromInt(self.gw), @floatFromInt(self.gh));
        self.au.f1(.cell, cell_px);
        self.au.f1(.dt, dt);
        self.au.f1(.time, @floatCast(@mod(self.now, 4096.0)));
        self.au.f4v(.win, @intCast(self.win_count), &wins[0]);
        self.au.f4v(.move, @intCast(self.win_count), &self.moves[0]);
        self.au.int(.count, @intCast(self.win_count));
        // A taller flame is gas that rises faster and cools slower.
        const lift = @sqrt(self.height_scale);
        self.au.f4(.gas, 350.0, 2.2, 2200.0, 290.0 * lift);
        self.au.f2(.cool, 0.8 / lift, 1.3 / lift);
        self.au.f2(.smoke, 0.5, 0.7);
        self.au.f1(.floor, self.floor * 0.7);
        pass(self.state[next]);

        // Its divergence, beside last frame's pressure.
        self.du.use(self.diverge);
        bind(c.GL_TEXTURE0, self.state[next]);
        bind(c.GL_TEXTURE1, self.pres[self.pcur]);
        self.du.int(.state, 0);
        self.du.int(.pres, 1);
        self.du.f1(.cell, cell_px);
        pass(self.pres[1 - self.pcur]);
        self.pcur = 1 - self.pcur;

        // Relax the pressure.
        self.ju.use(self.jacobi);
        self.ju.int(.pres, 0);
        self.ju.f1(.cell, cell_px);
        c.glActiveTexture(c.GL_TEXTURE0);
        for (0..jacobi_sweeps) |_| {
            c.glBindTexture(c.GL_TEXTURE_2D, self.pres[self.pcur]);
            pass(self.pres[1 - self.pcur]);
            self.pcur = 1 - self.pcur;
        }

        // Project: state[next] and the pressure -> state[cur], which this
        // step no longer needs and so becomes the new state.
        self.pu.use(self.project);
        bind(c.GL_TEXTURE0, self.state[next]);
        bind(c.GL_TEXTURE1, self.pres[self.pcur]);
        self.pu.int(.state, 0);
        self.pu.int(.pres, 1);
        self.pu.f1(.cell, cell_px);
        pass(self.state[self.cur]);
    }

    /// The light of the fire as it is now, into lit[0]. Framebuffer and
    /// vertex array bound.
    fn light(self: *Context) void {
        self.mu.use(self.dim);
        self.mu.int(.src, 0);
        c.glActiveTexture(c.GL_TEXTURE0);
        var from = [2]c.GLsizei{ self.gw, self.gh };
        for (0..glow_levels) |i| {
            const to = self.glow_size[i];
            c.glViewport(0, 0, to[0], to[1]);
            c.glBindTexture(c.GL_TEXTURE_2D, if (i == 0) self.state[self.cur] else self.dimmed[i - 1]);
            self.mu.f2(.inv, 1.0 / @as(f32, @floatFromInt(to[0])), 1.0 / @as(f32, @floatFromInt(to[1])));
            self.mu.f2(.texel, 1.0 / @as(f32, @floatFromInt(from[0])), 1.0 / @as(f32, @floatFromInt(from[1])));
            self.mu.f1(.emit, if (i == 0) 1.0 else 0.0);
            pass(self.dimmed[i]);
            from = to;
        }

        self.su.use(self.spread);
        self.su.int(.coarse, 0);
        self.su.int(.same, 1);
        var i: usize = glow_levels - 1;
        while (i > 0) {
            i -= 1;
            const to = self.glow_size[i];
            const coarse = self.glow_size[i + 1];
            const top = i == glow_levels - 2;
            c.glViewport(0, 0, to[0], to[1]);
            bind(c.GL_TEXTURE0, if (top) self.dimmed[i + 1] else self.lit[i + 1]);
            bind(c.GL_TEXTURE1, self.dimmed[i]);
            self.su.f2(.inv, 1.0 / @as(f32, @floatFromInt(to[0])), 1.0 / @as(f32, @floatFromInt(to[1])));
            self.su.f2(.texel, 0.5 / @as(f32, @floatFromInt(coarse[0])), 0.5 / @as(f32, @floatFromInt(coarse[1])));
            self.su.f2(.gain, if (top) glow_mix[i + 1] else 1.0, glow_mix[i]);
            pass(self.lit[i]);
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        if (!self.ensureGl()) return;

        if (self.dt > 0) {
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
            c.glViewport(0, 0, self.gw, self.gh);
            c.glBindVertexArray(self.vao);
            const steps: u32 = @intFromFloat(@ceil(self.dt / max_step));
            const dt = self.dt / @as(f32, @floatFromInt(steps));
            for (0..steps) |k| {
                // Where the windows had got to by the end of this step.
                const back = 1.0 - @as(f32, @floatFromInt(k + 1)) / @as(f32, @floatFromInt(steps));
                var at: [max_windows][4]f32 = undefined;
                for (0..self.win_count) |i| {
                    at[i] = self.wins[i];
                    at[i][0] -= self.came[i][0] * back;
                    at[i][1] -= self.came[i][1] * back;
                }
                self.step(dt, &at);
            }
            if (self.glow > 0) self.light();
            c.glActiveTexture(c.GL_TEXTURE0);
            c.glBindVertexArray(0);
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
            self.dt = 0;
        }

        self.u.use(prog.program);
        bind(c.GL_TEXTURE0, self.state[self.cur]);
        self.u.int(.fire, 0);
        bind(c.GL_TEXTURE1, self.lit[0]);
        self.u.int(.light, 1);
        self.u.f1(.glow, self.glow);
        c.glActiveTexture(c.GL_TEXTURE0);
        self.u.f2(.span, @as(f32, @floatFromInt(self.gw)) * cell_px, @as(f32, @floatFromInt(self.gh)) * cell_px);
        // Fire-local time keeps the noise coordinates small, so the detail
        // noise holds its f32 precision over a long session.
        self.u.f1(.time, @floatCast(@mod(self.now, 4096.0)));
        self.u.f1(.smoke, self.smoke);
    }

    pub fn deinit(self: *Context) void {
        if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
        if (self.state[0] != 0) c.glDeleteTextures(2, &self.state);
        if (self.pres[0] != 0) c.glDeleteTextures(2, &self.pres);
        if (self.dimmed[0] != 0) c.glDeleteTextures(glow_levels, &self.dimmed);
        if (self.lit[0] != 0) c.glDeleteTextures(glow_levels - 1, &self.lit);
        if (self.vao != 0) c.glDeleteVertexArrays(1, &self.vao);
        inline for (.{ "advect", "diverge", "jacobi", "project", "dim", "spread" }) |name| {
            if (@field(self, name) != 0) c.glDeleteProgram(@field(self, name));
        }
    }
};

test "a window's velocity follows its motion and ignores a jump" {
    var track = Track{ .pos = .{ 100, 100 } };
    // 600 px/s to the right for a tenth of a second.
    for (1..13) |i| follow(&track, 100 + @as(f32, @floatFromInt(i)) * 5.0, 100, 1.0 / 120.0);
    try std.testing.expectApproxEqAbs(@as(f32, 600), track.vel[0], 30);
    try std.testing.expectApproxEqAbs(@as(f32, 0), track.vel[1], 1e-3);

    // A warp across the screen in one frame is not a move.
    follow(&track, 2400, 900, 1.0 / 120.0);
    try std.testing.expectEqual([2]f32{ 0, 0 }, track.vel);
    try std.testing.expectEqual([2]f32{ 2400, 900 }, track.pos);

    // Then at rest it stays at rest.
    follow(&track, 2400, 900, 1.0 / 120.0);
    try std.testing.expectEqual([2]f32{ 0, 0 }, track.vel);
}
