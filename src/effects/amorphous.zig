const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const iohelp = @import("../core/io_helper.zig");
const palette_mod = @import("../core/palette.zig");
const audio_mod = @import("visualizer/audio.zig");
const spectral = @import("spectral.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

/// Amorphous: flat liquid blobs in two independent layers, one behind the
/// other. Each blob is a metaball cluster: a core circle plus satellites
/// that orbit it slowly. Bodies drift in straight lines, meet gentle
/// resistance at window rects, and wrap across the screen edges (the shader measures distance
/// on a torus, so a blob leaving one edge is already coming in the other).
/// The cluster geometry is animated here, once per frame, and uploaded as
/// a circle list; the shader only sums the field.
/// Layer colors are rolled once per start from the theme's usable accents,
/// so each launch gets a fresh pair.
///
/// Config:
///   [amorphous]
///   size     = 1.0       # blob radius multiplier
///   speed    = 1.0       # wobble / drift rate multiplier
///   opacity  = 0.55      # front layer over back: 1.0 is opaque, 0 fully tinted
///   music    = true      # loudness loosens surface tension, each lobe rides a band
///   sink     = "..."     # PulseAudio monitor source (auto-detected by default)
///   front    = 2         # fixed layer colors: a theme slot (1-16, the color_NN
///   back     = "#C4A7E7" # numbers in themes.json) or a hex; omit to roll
pub const layers = 2;
pub const blobs = 3;
pub const lobes = 7;
pub const balls_per_blob = 1 + lobes;
pub const balls_per_layer = blobs * balls_per_blob;
pub const total_balls = layers * balls_per_layer;

/// Screen-space units: the short screen edge is 1.0, origin at the center.
const Ball = extern struct { x: f32, y: f32, r2: f32, pad: f32 = 0 };

/// A drifting blob body.
const Body = struct { x: f32, y: f32, vx: f32, vy: f32 };


/// A window rect in blob units. Windows near a screen edge also get
/// wrapped images on the far side, since the screen is a torus: a blob at
/// the left edge is touching whatever tile sits at the right edge.
const Box = struct { x0: f32, y0: f32, x1: f32, y1: f32 };
const max_windows = 32;
const max_boxes = max_windows * 4;

/// Base drift speed in screen units per second (short edge = 1.0).
const drift_speed: f32 = 0.045;

pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: ?*audio_mod.AudioCapture,
    /// AGC'd six-band spectrum plus an energy envelope. Zero in silence or
    /// with music = false, so the blobs then behave exactly as unwired.
    an: spectral.Bands = .{},
    size: f32,
    speed: f32,
    opacity: f32,
    aspect: f32,
    width: f32,
    height: f32,
    bodies: [layers * blobs]Body = undefined,
    /// Each ball's offset from its blob's center and its radius, from the
    /// last layout, so collisions can use the blob's real outline.
    offsets: [total_balls][3]f32 = undefined,
    boxes: [max_boxes]Box = undefined,
    box_count: usize = 0,
    rng: std.Random.DefaultPrng,


    /// Layer colors, chosen from the theme on the first frame that carries
    /// a palette (and again if the theme changes). Until then, fallbacks.
    front: [3]f32 = .{ 0.55, 0.35, 0.75 },
    back: [3]f32 = .{ 0.35, 0.25, 0.55 },
    picked_theme: [128]u8 = undefined,
    picked_theme_len: u8 = 0,
    picked: bool = false,
    /// Colors fixed from config; a fixed one is never rolled. A slot is
    /// resolved against the palette when the first frame carries one.
    front_fixed: bool = false,
    back_fixed: bool = false,
    front_slot: ?u8 = null,
    back_slot: ?u8 = null,

    balls: [total_balls]Ball = undefined,

    cached_program: c.GLuint = 0,
    loc_size: c.GLint = -1,
    loc_front: c.GLint = -1,
    loc_back: c.GLint = -1,
    loc_opacity: c.GLint = -1,
    loc_balls: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const prng = std.Random.DefaultPrng.init(iohelp.nowNs());
        var audio: ?*audio_mod.AudioCapture = null;
        if (params.getBool("music", true)) audio = try audio_mod.spawn(allocator, params);
        var self = Context{
            .allocator = allocator,
            .audio = audio,
            .size = params.getFloat("size", 1.0),
            .speed = params.getFloat("speed", 1.0),
            .opacity = std.math.clamp(params.getFloat("opacity", 0.55), 0.0, 1.0),
            .aspect = width / @min(width, height),
            .width = width,
            .height = height,
            .rng = prng,
        };
        self.front_slot = fixedColor(params, "front", &self.front, &self.front_fixed);
        self.back_slot = fixedColor(params, "back", &self.back, &self.back_fixed);
        // Start each blob at its home, heading in a random direction.
        // Small blobs move faster, the way small drops skate.
        for (0..layers) |layer| {
            for (0..blobs) |i| {
                const hm = home(i, layer);
                const ang = self.rng.random().float(f32) * std.math.tau;
                const sp = drift_speed / @sqrt(blobSize(i));
                self.bodies[layer * blobs + i] = .{
                    .x = hm[0] * self.aspect,
                    .y = hm[1],
                    .vx = @cos(ang) * sp,
                    .vy = @sin(ang) * sp,
                };
            }
        }
        self.animate(0);
        return self;
    }

    fn blobSize(i: usize) f32 {
        return switch (i) {
            0 => 1.8,
            1 => 1.0,
            else => 0.45,
        };
    }


    /// Home positions: big one upper right, medium left, small lower middle.
    /// The back layer's homes are mirrored so the two sets do not stack.
    fn home(i: usize, layer: usize) [2]f32 {
        const h: [2]f32 = switch (i) {
            0 => .{ 0.25, -0.02 },
            1 => .{ -0.35, 0.05 },
            else => .{ 0.05, -0.32 },
        };
        return if (layer == 1) .{ -h[0], -h[1] } else h;
    }

    /// Move one body by `dt`: drift, resistance at windows, speed cap, and
    /// the wrap. `offsets` are the body's balls relative to its center (and
    /// their radii), which give its real reach toward a window.
    fn moveBody(self: *const Context, b: *Body, R: f32, offsets: []const [3]f32, sp_max: f32, dt: f32) void {
        const half_w = self.aspect * 0.5;
        const half_h: f32 = 0.5;
        b.x += b.vx * dt;
        b.y += b.vy * dt;

        // Contacts this frame. A blob's outline is lobed, so its
        // reach toward a window is measured from its balls, not a
        // fixed radius: the farthest ball edge along the contact
        // normal. Only the deepest contact is resolved, a blob whose
        // center is already under a window is left alone, and a
        // blob squeezed from opposing sides (no room to fit) gives
        // up and drifts through. Without those, tiled windows made
        // blobs ping-pong between rects every frame.
        var best_depth: f32 = 0;
        var best_nx: f32 = 0;
        var best_ny: f32 = 0;
        var first_nx: f32 = 0;
        var first_ny: f32 = 0;
        var contacts: u8 = 0;
        var covered = false;
        var squeezed = false;
        var exit_nx: f32 = 0;
        var exit_ny: f32 = 0;
        for (self.boxes[0..self.box_count]) |bx| {
            const x0 = bx.x0;
            const y0 = bx.y0;
            const x1 = bx.x1;
            const y1 = bx.y1;
            if (b.x > x0 and b.x < x1 and b.y > y0 and b.y < y1) {
                covered = true;
                // Nearest side whose far side is open space, for the
                // nudge below. Sides that lead straight under another
                // window (a neighboring tile, or the tile across the
                // wrap) are skipped: nudging into them just bounced
                // the blob back and forth across the screen edge.
                const sides = [_]struct { d: f32, nx: f32, ny: f32 }{
                    .{ .d = b.x - x0, .nx = -1, .ny = 0 },
                    .{ .d = x1 - b.x, .nx = 1, .ny = 0 },
                    .{ .d = b.y - y0, .nx = 0, .ny = -1 },
                    .{ .d = y1 - b.y, .nx = 0, .ny = 1 },
                };
                var best_d: f32 = 1e9;
                for (sides) |sd| {
                    if (sd.d >= best_d) continue;
                    // Probe just beyond the side.
                    var ex = b.x + sd.nx * (sd.d + 0.02);
                    var ey = b.y + sd.ny * (sd.d + 0.02);
                    if (ex < -half_w) ex += self.aspect;
                    if (ex >= half_w) ex -= self.aspect;
                    if (ey < -half_h) ey += 1.0;
                    if (ey >= half_h) ey -= 1.0;
                    var open = true;
                    for (self.boxes[0..self.box_count]) |ob| {
                        if (ex > ob.x0 and ex < ob.x1 and ey > ob.y0 and ey < ob.y1) {
                            open = false;
                            break;
                        }
                    }
                    if (!open) continue;
                    best_d = sd.d;
                    exit_nx = sd.nx;
                    exit_ny = sd.ny;
                }
                break;
            }
            const cx = std.math.clamp(b.x, x0, x1);
            const cy = std.math.clamp(b.y, y0, y1);
            const dx = b.x - cx;
            const dy = b.y - cy;
            const d2 = dx * dx + dy * dy;
            if (d2 >= R * R * 2.0 or d2 < 1e-9) continue;
            const d = @sqrt(d2);
            const nx = dx / d;
            const ny = dy / d;
            // Reach of the outline toward the window.
            var reach: f32 = 0;
            for (offsets) |o| {
                reach = @max(reach, -(o[0] * nx + o[1] * ny) + o[2]);
            }
            const depth = reach - d;
            if (depth <= 0) continue;
            if (contacts == 0) {
                first_nx = nx;
                first_ny = ny;
            } else if (nx * first_nx + ny * first_ny < -0.5) {
                squeezed = true;
            }
            contacts += 1;
            if (depth > best_depth) {
                best_depth = depth;
                best_nx = nx;
                best_ny = ny;
            }
        }
        if (!covered and !squeezed and best_depth > 0) {
            // Subtle resistance rather than a wall. The velocity
            // into the window bleeds off over ~0.4s and a weak spring
            // on the penetration nudges back, so a blob drifts a fair
            // way into a pane, slows, and wanders back out. No
            // position correction: nothing here ever snaps.
            const vn = b.vx * best_nx + b.vy * best_ny;
            if (vn < 0) {
                const damped = vn * @exp(-dt / 0.4);
                b.vx += (damped - vn) * best_nx;
                b.vy += (damped - vn) * best_ny;
            }
            const spring = best_depth * 0.6 * dt;
            b.vx += best_nx * spring;
            b.vy += best_ny * spring;
        } else if (covered) {
            // Under a window the blob would rather not be there: a
            // gentle, constant nudge toward the nearest edge. It is
            // a preference, not a rule, so it can still cross a
            // window and can sit under one for a while.
            b.vx += exit_nx * 0.02 * dt;
            b.vy += exit_ny * 0.02 * dt;
        }
        // Resistance and nudges add energy; cap the speed so a blob
        // never ends up racing.
        const sp2 = b.vx * b.vx + b.vy * b.vy;
        if (sp2 > sp_max * sp_max) {
            const f = sp_max / @sqrt(sp2);
            b.vx *= f;
            b.vy *= f;
        }

        // Wrap on the torus the shader draws.
        if (b.x < -half_w) b.x += self.aspect;
        if (b.x >= half_w) b.x -= self.aspect;
        if (b.y < -half_h) b.y += 1.0;
        if (b.y >= half_h) b.y -= 1.0;
    }

    /// Move the bodies by `dt` seconds: straight-line drift, a bounce off
    /// any window rect, and a wrap across the screen edges.
    fn step(self: *Context, dt: f32, windows: []const shader_mod.ShaderProgram.WindowRect) void {
        const unit = @min(self.width, self.height);
        const half_w = self.aspect * 0.5;
        const half_h: f32 = 0.5;
        self.box_count = 0;
        // Largest reach any blob has, to decide which images matter.
        const reach_max = 0.16 * blobSize(0) * self.size * 1.5;
        var wi: usize = 0;
        for (windows) |w| {
            if (wi == max_windows) break;
            if (w.w < 1 or w.h < 1) continue;
            wi += 1;
            const x0 = (w.x - self.width * 0.5) / unit;
            const y0 = (w.y - self.height * 0.5) / unit;
            const x1 = x0 + w.w / unit;
            const y1 = y0 + w.h / unit;
            // The rect itself plus any wrapped image that comes within
            // reach of the screen: shifted a screen width across if it
            // hugs a vertical edge, a screen height if a horizontal one.
            const sx: f32 = if (x0 < -half_w + reach_max) self.aspect else if (x1 > half_w - reach_max) -self.aspect else 0;
            const sy: f32 = if (y0 < -half_h + reach_max) 1.0 else if (y1 > half_h - reach_max) -1.0 else 0;
            const shifts = [_][2]f32{ .{ 0, 0 }, .{ sx, 0 }, .{ 0, sy }, .{ sx, sy } };
            for (shifts, 0..) |sh, n| {
                if (n > 0 and sh[0] == 0 and sh[1] == 0) continue;
                if (n == 3 and (sh[0] == 0 or sh[1] == 0)) continue;
                self.boxes[self.box_count] = .{ .x0 = x0 + sh[0], .y0 = y0 + sh[1], .x1 = x1 + sh[0], .y1 = y1 + sh[1] };
                self.box_count += 1;
            }
        }
        for (0..layers) |layer| {
            for (0..blobs) |i| {
                const b = &self.bodies[layer * blobs + i];
                const R = 0.16 * blobSize(i) * self.size;
                const bfirst = (layer * blobs + i) * balls_per_blob;
                self.moveBody(b, R, self.offsets[bfirst..][0..balls_per_blob], drift_speed / @sqrt(blobSize(i)) * 1.5, dt);
            }
        }
    }

    /// Lay out every circle for time `t` (already speed-scaled).
    fn animate(self: *Context, t: f32) void {
        var k: usize = 0;
        for (0..layers) |layer| {
            // Layers are independent: each has its own clock offset.
            const tl = t + @as(f32, @floatFromInt(layer)) * 41.0;
            for (0..blobs) |i| {
                const fi: f32 = @floatFromInt(i);
                const size = blobSize(i) * self.size;
                const R = 0.16 * size;
                // Surface tension: small blobs tuck their satellites into
                // the core (a droplet), large ones let them reach out. Music
                // loosens it: loud passages let even the droplets go lumpy,
                // silence relaxes everything back to its resting shape.
                const slack = @min(1.0, smoothstep(0.4, 2.0, size) + self.an.energy_ema * 0.9);
                const body = self.bodies[layer * blobs + i];
                const cx = body.x;
                const cy = body.y;
                const tb = tl + fi * 7.3;

                const core_r = R * 0.62;
                self.balls[k] = .{ .x = cx, .y = cy, .r2 = core_r * core_r };
                self.offsets[k] = .{ 0, 0, core_r };
                k += 1;
                for (0..lobes) |j| {
                    const fj: f32 = @floatFromInt(j);
                    const base = fj * std.math.tau / @as(f32, lobes);
                    const ang = base + 0.55 * @sin(tb * (0.23 + 0.07 * fj) + fj * 1.7);
                    // Each lobe rides one frequency band: the satellite
                    // reaches further out and swells as its band plays, so
                    // the outline is a slow radial equalizer.
                    const band = self.an.smooth[j % 6];
                    const off = R * (0.55 + 0.30 * @sin(tb * (0.31 + 0.05 * fj) + fj * 2.9)) * slack * (1.0 + band * 0.45);
                    const rad = R * (0.26 + 0.10 * @sin(tb * (0.27 + 0.06 * fj) + fj * 4.3)) * (0.5 + 0.5 * slack) * (1.0 + band * 0.35);
                    // No squashing against windows: snapping satellites to a
                    // pane edge flipped sides whenever one crossed a pane's
                    // midline, a visible jump. Everything that touches the
                    // geometry here is a smooth function of time; windows
                    // only ever act on the bodies' velocities.
                    const ox = off * @cos(ang);
                    const oy = off * @sin(ang);
                    self.balls[k] = .{ .x = cx + ox, .y = cy + oy, .r2 = rad * rad };
                    self.offsets[k] = .{ ox, oy, rad };
                    k += 1;
                }
            }
        }
    }

    /// Pick the two layer colors from the theme. Only colors that will read
    /// as a flat blob qualify: enough luminance contrast against the
    /// background so the silhouette is visible, and enough chroma that it
    /// is a color rather than a grey (the theme's greys are text shades).
    /// The second pick has to sit well away from the first so the layers
    /// never look like one.
    fn pickColors(self: *Context, pal: *const palette_mod.Palette) void {
        const bg = pal.background;
        var cands: [palette_mod.max_palette_colors]palette_mod.Color = undefined;
        var n: usize = 0;
        for (pal.colors[0..pal.color_count]) |col| {
            const lum_diff = @abs(luma(col) - luma(bg));
            const chroma = @max(col.r, @max(col.g, col.b)) - @min(col.r, @min(col.g, col.b));
            // Very pale colors (the theme's whites and near-whites) glare
            // as a big flat area, so they are out too.
            if (lum_diff < 0.18 or chroma < 0.12 or luma(col) > 0.82) continue;
            cands[n] = col;
            n += 1;
        }
        const r = self.rng.random();
        if (n == 0) {
            // A monochrome theme: foreground on background is all there is.
            if (!self.front_fixed) self.front = .{ pal.foreground.r, pal.foreground.g, pal.foreground.b };
            if (!self.back_fixed) self.back = .{
                (pal.foreground.r + bg.r) * 0.5,
                (pal.foreground.g + bg.g) * 0.5,
                (pal.foreground.b + bg.b) * 0.5,
            };
            return;
        }
        // A fixed front still anchors the back pick's spacing.
        const a: palette_mod.Color = if (self.front_fixed)
            .{ .r = self.front[0], .g = self.front[1], .b = self.front[2] }
        else
            cands[r.intRangeLessThan(usize, 0, n)];
        self.front = .{ a.r, a.g, a.b };
        if (self.back_fixed) return;
        // Second: random among those far enough from the first, else the
        // farthest one there is.
        var far: [palette_mod.max_palette_colors]palette_mod.Color = undefined;
        var nf: usize = 0;
        var best = a;
        var best_d: f32 = -1;
        for (cands[0..n]) |col| {
            const d = dist(col, a);
            if (d >= 0.35) {
                far[nf] = col;
                nf += 1;
            }
            if (d > best_d) {
                best_d = d;
                best = col;
            }
        }
        const b = if (nf > 0) far[r.intRangeLessThan(usize, 0, nf)] else best;
        self.back = .{ b.r, b.g, b.b };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        if (state.palette) |pal| {
            const name = pal.themeName();
            const same = self.picked and std.mem.eql(u8, name, self.picked_theme[0..self.picked_theme_len]);
            if (!same) {
                // Slots resolve against whatever theme is loaded now.
                if (self.front_slot) |sl| resolveSlot(pal, sl, &self.front, &self.front_fixed);
                if (self.back_slot) |sl| resolveSlot(pal, sl, &self.back, &self.back_fixed);
                self.pickColors(pal);
                const len: u8 = @intCast(@min(name.len, self.picked_theme.len));
                @memcpy(self.picked_theme[0..len], name[0..len]);
                self.picked_theme_len = len;
                self.picked = true;
            }
        }
        if (self.audio) |audio| {
            const wave = audio.getWaveform();
            const mags = spectral.magnitudes(&wave);
            self.an.update(&mags, std.math.clamp(state.dt, 0.0, 0.05));
        }
        const dt = std.math.clamp(state.dt, 0.0, 0.1) * self.speed;
        self.step(dt, state.windows);
        self.animate(state.time * self.speed);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_front = c.glGetUniformLocation(prog.program, "iBlobFront");
            self.loc_back = c.glGetUniformLocation(prog.program, "iBlobBack");
            self.loc_opacity = c.glGetUniformLocation(prog.program, "iBlobOpacity");
            self.loc_balls = c.glGetUniformLocation(prog.program, "iBalls[0]");
        }
        if (self.loc_front >= 0) c.glUniform3f(self.loc_front, self.front[0], self.front[1], self.front[2]);
        if (self.loc_back >= 0) c.glUniform3f(self.loc_back, self.back[0], self.back[1], self.back[2]);
        if (self.loc_opacity >= 0) c.glUniform1f(self.loc_opacity, self.opacity);
        if (self.loc_balls >= 0) c.glUniform4fv(self.loc_balls, total_balls, @ptrCast(&self.balls[0]));
    }

    pub fn deinit(self: *Context) void {
        if (self.audio) |audio| audio_mod.shutdown(audio, self.allocator);
    }
};

/// Read a `front`/`back` key: an integer is a theme slot (returned, to be
/// resolved once a palette is available), a string is a hex color applied
/// now. Anything else leaves the color to be rolled.
fn fixedColor(params: config_mod.EffectParams, key: []const u8, out: *[3]f32, fixed: *bool) ?u8 {
    const slot = params.getInt(key, 0);
    if (slot >= 1 and slot <= palette_mod.max_palette_colors) return @intCast(slot);
    if (params.getString(key, null)) |hex| {
        if (palette_mod.Color.fromHex(hex)) |col| {
            out.* = .{ col.r, col.g, col.b };
            fixed.* = true;
        } else |_| std.log.warn("amorphous: bad {s} color '{s}', rolling from the theme", .{ key, hex });
    }
    return null;
}

fn resolveSlot(pal: *const palette_mod.Palette, slot: u8, out: *[3]f32, fixed: *bool) void {
    if (slot > pal.color_count) {
        std.log.warn("amorphous: theme '{s}' has no color slot {d}, rolling instead", .{ pal.themeName(), slot });
        fixed.* = false;
        return;
    }
    const col = pal.colors[slot - 1];
    out.* = .{ col.r, col.g, col.b };
    fixed.* = true;
}

fn luma(col: palette_mod.Color) f32 {
    return 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b;
}

fn dist(a: palette_mod.Color, b: palette_mod.Color) f32 {
    const dr = a.r - b.r;
    const dg = a.g - b.g;
    const db = a.b - b.b;
    return @sqrt(dr * dr + dg * dg + db * db);
}

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}
