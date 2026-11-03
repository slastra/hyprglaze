const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");
const smoothstep = @import("bands.zig").smoothstep;
const clock = @import("clock.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

// The Voronoi tissue is shader-side; this context drives its ambient
// cells and turns it into a dancefloor. Each ambient cell drifts and
// slowly divides into two daughters and fuses back (mitosis), on its own
// staggered cycle. Every cell is assigned a spectral band and its fill
// lights with it, bass heaves the drift and swells the membranes, energy
// quickens the drift clock (accumulated here so the rate change never
// snaps phase), and kicks flash the membranes. All zero in silence — or
// music = false, which skips capture — collapsing to a quiet tissue.

/// Ambient mother cells; each is two coincident seeds until it divides.
pub const n_cells = 24;
pub const n_seeds = n_cells * 2;

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    /// Music-paced drift clock (replaces the shader's iTime * 0.15).
    flow: f64 = 0,
    width: f32,
    height: f32,
    /// Per daughter (mother = i / 2, sister = i ^ 1): position in surface
    /// pixels, window weight, and the mother's split 0..1. Frame-constant,
    /// so it is built here once rather than in every pixel.
    seeds: [n_seeds][4]f32 = @splat(.{ 0, 0, 0, 0 }),

    u: Uniforms(.{
        .flow = "iBloomFlow",
        .bands = "iBloomBands[0]",
        .bass = "iBloomBass",
        .beat = "iBloomBeat",
        .seeds = "iBloomSeeds[0]",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const music = try spectral.Analyzer.init(allocator, params);
        return .{ .allocator = allocator, .music = music, .width = width, .height = height };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        _ = self.music.update(dt);
        self.flow += dt * (0.15 + self.music.bands.energy_ema * 0.45);

        const t = self.flow;
        const bass = self.music.bass();
        const wander = 0.1 * (1.0 + @min(bass, 1.2) * 0.6);
        const reach = 0.055 * @min(self.width, self.height);
        for (0..n_cells) |i| {
            const fi: f32 = @floatFromInt(i);
            // Orbit rates stay within ~3x of each other: crisp membranes
            // make a fast seed read as frantic.
            const px = fract(fi * 0.381966) + wander * @sin(clock.phase(t, 0.35 + fract(fi * 0.618034) * 0.6));
            const py = fract(fi * 0.618034) + wander * @cos(clock.phase(t, 0.3 + fract(fi * 0.381966) * 0.6));
            const axis = fi * 2.39996 + clock.phase(t, 0.15 + fract(fi * 0.7548) * 0.2);
            // Life cycle: whole, divide, two daughters, fuse. Staggered
            // phases and rates so divisions trickle across the screen.
            const u = fract(clock.cycles(t, 0.25 + fract(fi * 0.5698) * 0.15) + fi * 0.618034);
            const split = smoothstep(0.30, 0.55, u) * (1.0 - smoothstep(0.80, 1.0, u));

            // Additive weight that grows as the mother nears a window, so a
            // cell crowding a window shrinks away instead of thinning to a
            // dart (an additively weighted Voronoi).
            const cx = px * self.width;
            const cy = py * self.height;
            var sw: f32 = 1e9;
            for (state.windows) |w| {
                if (w.w < 1.0 or w.h < 1.0) continue;
                sw = @min(sw, sdRoundBox(cx - (w.x + w.w * 0.5), cy - (w.y + w.h * 0.5), w.w * 0.5, w.h * 0.5, 12.0));
            }
            const weight = 140.0 * (1.0 - smoothstep(0.0, 110.0, sw));

            const ox = @cos(axis) * split * reach;
            const oy = @sin(axis) * split * reach;
            self.seeds[i * 2] = .{ cx - ox, cy - oy, weight, split };
            self.seeds[i * 2 + 1] = .{ cx + ox, cy + oy, weight, split };
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        self.u.use(prog.program);
        self.u.f1(.flow, @floatCast(self.flow));
        self.u.f1v(.bands, 6, &self.music.bands.smooth[0]);
        self.u.f1(.bass, self.music.bass());
        self.u.f1(.beat, self.music.onset.beat);
        self.u.f4v(.seeds, n_seeds, &self.seeds[0]);
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
    }
};

fn fract(x: f32) f32 {
    return x - @floor(x);
}

/// Signed distance from (px, py), relative to the box center, to a
/// rounded box: the shader's window shape.
fn sdRoundBox(px: f32, py: f32, hx: f32, hy: f32, r: f32) f32 {
    const qx = @abs(px) - hx + r;
    const qy = @abs(py) - hy + r;
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - r;
}
