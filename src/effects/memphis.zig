const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");
const lamps_mod = @import("lamps.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");
const Lamps = lamps_mod.Lamps;
const max_lamps = lamps_mod.max_lamps;

// A Memphis print in two flat colors: discs, triangles, squares, zigzag
// strokes and fields of halftone dots, and wherever two of them overlap
// the color flips, so a zigzag is dark where it crosses a disc and dots
// are dark inside a triangle and light outside it.
//
// Each kind of shape lives on its own sheet. A sheet is a torus a little
// larger than the screen that slides across it at its own slow pace, with
// its shapes set on it so that no two of them touch. So shapes of a kind
// never overlap, the screen stays evenly filled for good, and all the
// overlapping is between sheets, which is what keeps changing. A shape
// leaves one edge of the screen and comes back on the opposite one, out
// of sight both times.
//
// The shader takes the shapes on screen and, per pixel, flips the color
// once for each one the pixel is inside (shaders/memphis.frag). So that a
// pixel need not look at every shape, the screen is cut into tiles and
// each tile lists the shapes that can show in it.
//
//   - the dots of a halftone field grow toward the focused window; when
//     focus moves they swing round to the new one (lamps.zig);
//   - the cursor pushes shapes aside, and they spring back;
//   - in music each dot field swells and each zigzag stretches with its
//     own band, and a loud passage quickens the sheets a little.
//
// Lengths are screen heights, from the bottom left corner.

/// Shapes sent to the shader at once. Must match SHAPES in the shader.
pub const max_shapes = 80;
/// How far outside its radius the shader may still draw a shape, as a
/// part of the radius (a zigzag's mitered corners, a field's last dots).
/// Must match SLACK in the shader.
const slack = 0.2;
/// Shapes a tile can list, and the texels a tile takes: how many, then
/// which. Must match TILE_STRIDE in the shader.
const tile_slots = 15;
const tile_stride = tile_slots + 1;
/// Least room between two shapes on a sheet.
const gap = 0.03;
/// How far a shape strays from its place on its sheet, less than half
/// the gap so two can never meet.
const stray = 0.012;
/// How far off the cursor starts to push, beyond a shape's radius, how
/// hard, and the spring that brings a shape back.
const push_reach = 0.07;
const push_force = 2.2;
const spring = 9.0;
/// A sheet's pace at speed 1.
const drift = 0.011;
/// The loose dots between the shapes: their lattice's pitch, and how many
/// cells before it repeats. Must match the shader.
const sprinkle_pitch = 0.085;
const sprinkle_cells = 64.0;

pub const Kind = enum(u8) { disc, triangle, square, zigzag, grid, scatter };

/// How a sheet is stocked: shapes of this kind per unit of area, between
/// these radii.
const Stock = struct { kind: Kind, density: f32, small: f32, large: f32 };

const stocks = [_][]const Stock{
    &.{.{ .kind = .disc, .density = 4.3, .small = 0.085, .large = 0.14 }},
    &.{
        .{ .kind = .triangle, .density = 2.5, .small = 0.11, .large = 0.22 },
        .{ .kind = .square, .density = 1.5, .small = 0.065, .large = 0.095 },
    },
    &.{.{ .kind = .zigzag, .density = 4.8, .small = 0.095, .large = 0.165 }},
    &.{.{ .kind = .grid, .density = 4.2, .small = 0.085, .large = 0.19 }},
    &.{.{ .kind = .scatter, .density = 3.0, .small = 0.12, .large = 0.21 }},
};
const n_sheets = stocks.len;

const tau = 2.0 * std.math.pi;

fn wrap(x: f32, size: f32) f32 {
    return x - size * @floor(x / size);
}

pub const Shape = struct {
    kind: Kind,
    sheet: u8,
    /// Where it sits on its sheet.
    home: [2]f32,
    /// The circle its outline fits in.
    r: f32,
    /// How it is turned, and how fast it turns.
    turn: f32 = 0,
    spin: f32 = 0,
    seed: f32,
    /// What these two mean is up to the kind (see `Pattern.init`).
    a: f32 = 0,
    b: f32 = 0,
    band: u8 = 0,
    level: f32 = 0,
    /// Where it is in its stroll round its place, and its pace.
    phase: [2]f32 = .{ 0, 0 },
    rate: [2]f32 = .{ 0, 0 },
    /// How far the cursor has pushed it, and how fast that is changing.
    off: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    /// The way a halftone field's dots grow.
    lean: [2]f32 = .{ 0.7, 0.7 },
};

pub const Sheet = struct {
    /// The torus, and how far it reaches past the screen on every side.
    size: [2]f32,
    margin: f32,
    vel: [2]f32,
    at: [2]f32 = .{ 0, 0 },

    /// From one point on it to another, the short way round.
    fn between(self: Sheet, a: [2]f32, b: [2]f32) [2]f32 {
        var d: [2]f32 = undefined;
        for (0..2) |k| {
            d[k] = wrap(a[k] - b[k] + 0.5 * self.size[k], self.size[k]) - 0.5 * self.size[k];
        }
        return d;
    }
};

/// A lamp, for the pattern's purposes: where it is and how bright.
pub const Light = struct { pos: [2]f32, strength: f32 };

pub const Pattern = struct {
    aspect: f32,
    speed: f32,
    shapes: [max_shapes]Shape = undefined,
    n: usize = 0,
    sheets: [n_sheets]Sheet,
    /// How far the loose dots have slid.
    sprinkle: [2]f32 = .{ 0, 0 },
    energy: f32 = 0,

    pub fn init(aspect: f32, size: f32, speed: f32, seed: u64) Pattern {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        var self = Pattern{ .aspect = aspect, .speed = speed, .sheets = undefined };

        // The sheets head off in directions spread evenly round the
        // compass, each at its own pace.
        const heading = r.float(f32) * tau;
        var total: f32 = 0;
        var wanted: [n_sheets]f32 = undefined;
        for (&self.sheets, stocks, 0..) |*sheet, stock, s| {
            var largest: f32 = 0;
            for (stock) |st| largest = @max(largest, st.large * size);
            const margin = largest * (1.0 + slack) + stray + 0.03;
            const angle = heading + tau * (@as(f32, @floatFromInt(s)) * 2.0 / @as(f32, @floatFromInt(n_sheets)) + 0.12 * (r.float(f32) - 0.5));
            const pace = drift * (0.55 + 0.9 * r.float(f32));
            sheet.* = .{
                .size = .{ aspect + 2.0 * margin, 1.0 + 2.0 * margin },
                .margin = margin,
                .vel = .{ @cos(angle) * pace, @sin(angle) * pace },
            };
            wanted[s] = 0;
            for (stock) |st| wanted[s] += st.density * sheet.size[0] * sheet.size[1] / (size * size);
            total += wanted[s];
        }
        const share = @min(1.0, @as(f32, max_shapes) / total);

        for (stocks, 0..) |stock, s| {
            const sheet = self.sheets[s];
            // Its shapes, largest first, each thrown at the sheet until
            // it lands clear of the others.
            const first = self.n;
            var sizes: [max_shapes]struct { r: f32, kind: Kind } = undefined;
            var count: usize = 0;
            for (stock) |st| {
                const many: usize = @intFromFloat(@round(st.density * sheet.size[0] * sheet.size[1] / (size * size) * share));
                for (0..many) |_| {
                    if (count == max_shapes) break;
                    const u = r.float(f32);
                    sizes[count] = .{ .r = size * (st.small + (st.large - st.small) * u), .kind = st.kind };
                    count += 1;
                }
            }
            std.mem.sort(@TypeOf(sizes[0]), sizes[0..count], {}, struct {
                fn before(_: void, x: @TypeOf(sizes[0]), y: @TypeOf(sizes[0])) bool {
                    return x.r > y.r;
                }
            }.before);
            for (sizes[0..count]) |want| {
                if (self.n == max_shapes) break;
                var tries: usize = 0;
                place: while (tries < 600) : (tries += 1) {
                    const at = [2]f32{ r.float(f32) * sheet.size[0], r.float(f32) * sheet.size[1] };
                    for (self.shapes[first..self.n]) |other| {
                        const d = sheet.between(at, other.home);
                        const least = want.r + other.r + gap;
                        if (d[0] * d[0] + d[1] * d[1] < least * least) continue :place;
                    }
                    self.shapes[self.n] = make(r, want.kind, @intCast(s), at, want.r, size);
                    self.n += 1;
                    break;
                }
            }
        }
        return self;
    }

    fn make(r: std.Random, kind: Kind, sheet: u8, at: [2]f32, radius: f32, size: f32) Shape {
        var shape = Shape{
            .kind = kind,
            .sheet = sheet,
            .home = at,
            .r = radius,
            .seed = r.float(f32),
            .turn = r.float(f32) * tau,
            .band = r.uintLessThan(u8, 6),
            .phase = .{ r.float(f32) * tau, r.float(f32) * tau },
            .rate = .{ 0.12 + 0.14 * r.float(f32), 0.12 + 0.14 * r.float(f32) },
        };
        const either: f32 = if (r.boolean()) 1.0 else -1.0;
        switch (kind) {
            .disc => {},
            // The two lower corners, each moved round the circle a way.
            .triangle => {
                shape.a = (r.float(f32) - 0.5) * 1.2;
                shape.b = (r.float(f32) - 0.5) * 1.2;
                shape.spin = either * (0.012 + 0.03 * r.float(f32));
            },
            .square => shape.spin = either * (0.02 + 0.04 * r.float(f32)),
            // How many strokes, and how thick.
            .zigzag => {
                const u = r.float(f32);
                shape.a = if (u < 0.28) 2.0 else if (u < 0.6) 3.0 else 4.0;
                shape.b = size * (0.013 + 0.006 * r.float(f32));
                shape.spin = either * (0.01 + 0.03 * r.float(f32));
            },
            // The lattice's pitch, and which of four fields it is:
            // round or square, the dots growing across it, out from
            // its middle, or all one size.
            .grid => {
                const fine = r.float(f32) < 0.45;
                shape.a = radius / (if (fine) 9.0 + 4.0 * r.float(f32) else 4.6 + 2.4 * r.float(f32));
                shape.b = @floatFromInt(r.uintLessThan(u8, 4));
            },
            // The lattice's pitch, and its largest dot as a part of
            // that: big polka dots, or fine dust.
            .scatter => {
                const dust = r.float(f32) < 0.4;
                shape.a = if (dust) size * (0.017 + 0.008 * r.float(f32)) else size * (0.05 + 0.02 * r.float(f32));
                shape.b = if (dust) 0.2 else 0.27;
                shape.spin = either * (0.008 + 0.02 * r.float(f32));
            },
        }
        return shape;
    }

    /// Where its place on its sheet is on screen now.
    fn anchor(self: *const Pattern, shape: Shape) [2]f32 {
        const sheet = self.sheets[shape.sheet];
        return .{
            wrap(shape.home[0] + sheet.at[0], sheet.size[0]) - sheet.margin,
            wrap(shape.home[1] + sheet.at[1], sheet.size[1]) - sheet.margin,
        };
    }

    /// Where its middle is on screen now.
    pub fn where(self: *const Pattern, i: usize) [2]f32 {
        const shape = self.shapes[i];
        const at = self.anchor(shape);
        return .{
            at[0] + stray * @sin(shape.phase[0]) + shape.off[0],
            at[1] + stray * @sin(shape.phase[1]) + shape.off[1],
        };
    }

    pub fn step(self: *Pattern, dt_in: f32, bands: *const [6]f32, cursor: [2]f32, lights: []const Light) void {
        const dt = std.math.clamp(dt_in, 0.0, 0.05);
        var loud: f32 = 0;
        for (bands) |b| loud += b / 6.0;
        self.energy += (std.math.clamp(loud * 1.6, 0.0, 1.0) - self.energy) * @min(1.0, 0.5 * dt);

        const pace = self.speed * (1.0 + 0.6 * self.energy) * dt;
        for (&self.sheets) |*sheet| {
            for (0..2) |k| sheet.at[k] = wrap(sheet.at[k] + sheet.vel[k] * pace, sheet.size[k]);
        }
        const round = sprinkle_pitch * sprinkle_cells;
        self.sprinkle[0] = wrap(self.sprinkle[0] + 0.6 * drift * pace, round);
        self.sprinkle[1] = wrap(self.sprinkle[1] + 0.35 * drift * pace, round);

        for (self.shapes[0..self.n], 0..) |*shape, i| {
            shape.turn = wrap(shape.turn + shape.spin * pace, tau);
            for (0..2) |k| shape.phase[k] = wrap(shape.phase[k] + shape.rate[k] * pace, tau);

            // Each follows its band at its own pace.
            const heard = std.math.clamp(bands[shape.band] * 1.4, 0.0, 1.0);
            shape.level += (heard - shape.level) * @min(1.0, (2.0 + 3.0 * shape.seed) * dt);

            // The cursor pushes it off, and a spring brings it back.
            const at = self.where(i);
            const dx = at[0] - cursor[0];
            const dy = at[1] - cursor[1];
            const d = @sqrt(dx * dx + dy * dy);
            const reach = shape.r + push_reach;
            var acc = [2]f32{ -spring * shape.off[0], -spring * shape.off[1] };
            if (d < reach and d > 1e-5) {
                const push = push_force * (1.0 - d / reach) / d;
                acc[0] += dx * push;
                acc[1] += dy * push;
            }
            const damp = 2.0 * @sqrt(spring);
            for (0..2) |k| {
                shape.vel[k] += (acc[k] - damp * shape.vel[k]) * dt;
                shape.off[k] += shape.vel[k] * dt;
            }

            // A halftone field's dots grow toward the light.
            if (shape.kind == .grid) {
                var want = [2]f32{ 0, 0 };
                for (lights) |light| {
                    const lx = light.pos[0] - at[0];
                    const ly = light.pos[1] - at[1];
                    const l = @sqrt(lx * lx + ly * ly);
                    if (l < 1e-4) continue;
                    want[0] += light.strength * lx / l;
                    want[1] += light.strength * ly / l;
                }
                const ease = @min(1.0, 2.5 * dt);
                for (0..2) |k| shape.lean[k] += (want[k] - shape.lean[k]) * ease;
            }
        }
    }

    /// Whether any of it can show.
    fn shows(self: *const Pattern, at: [2]f32, shape: Shape) bool {
        const reach = shape.r * (1.0 + slack) + 0.002;
        return at[0] > -reach and at[0] < self.aspect + reach and at[1] > -reach and at[1] < 1.0 + reach;
    }

    /// The shapes on screen, as the shader takes them: x, y, radius and
    /// kind (with the seed as its fraction), then how it is turned, its
    /// two numbers, and how loud its band is.
    pub fn pack(self: *const Pattern, body: *[max_shapes][4]f32, how: *[max_shapes][4]f32) usize {
        var count: usize = 0;
        for (self.shapes[0..self.n], 0..) |shape, i| {
            const at = self.where(i);
            if (!self.shows(at, shape)) continue;
            const turned = if (shape.kind == .grid) std.math.atan2(shape.lean[1], shape.lean[0]) else shape.turn;
            body[count] = .{ at[0], at[1], shape.r, @as(f32, @floatFromInt(@intFromEnum(shape.kind))) + 0.999 * shape.seed };
            how[count] = .{ turned, shape.a, shape.b, shape.level };
            count += 1;
        }
        return count;
    }
};

/// For each tile of the screen, the shapes that can show in it, as rows
/// of bytes the shader reads from a texture.
pub const Tiles = struct {
    allocator: std.mem.Allocator,
    /// A tile's side in px, and in screen heights.
    px: f32,
    side: f32,
    tw: usize,
    th: usize,
    cells: []u8,
    /// Shapes left out of a tile for want of room, in the last build.
    dropped: usize = 0,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32) !Tiles {
        const px = std.math.clamp(@round(height / 24.0), 24.0, 160.0);
        const tw: usize = @intFromFloat(@ceil(width / px));
        const th: usize = @intFromFloat(@ceil(height / px));
        const cells = try allocator.alloc(u8, tw * th * tile_stride);
        @memset(cells, 0);
        return .{ .allocator = allocator, .px = px, .side = px / height, .tw = tw, .th = th, .cells = cells };
    }

    pub fn deinit(self: *Tiles) void {
        self.allocator.free(self.cells);
    }

    /// `body` as `Pattern.pack` makes it. A shape is listed in every
    /// tile its circle, with the slack the shader allows it, touches.
    pub fn build(self: *Tiles, body: []const [4]f32) void {
        @memset(self.cells, 0);
        self.dropped = 0;
        const side = self.side;
        for (body, 0..) |b, j| {
            // A pixel of room on top, as the shader has.
            const reach = b[2] * (1.0 + slack) + 2.0 * side / self.px;
            const x0 = self.clampTile((b[0] - reach) / side, self.tw);
            const x1 = self.clampTile((b[0] + reach) / side, self.tw);
            const y0 = self.clampTile((b[1] - reach) / side, self.th);
            const y1 = self.clampTile((b[1] + reach) / side, self.th);
            var ty = y0;
            while (ty <= y1) : (ty += 1) {
                var tx = x0;
                while (tx <= x1) : (tx += 1) {
                    // The tile's nearest point to the shape's middle.
                    const lx = @as(f32, @floatFromInt(tx)) * side;
                    const ly = @as(f32, @floatFromInt(ty)) * side;
                    const dx = b[0] - std.math.clamp(b[0], lx, lx + side);
                    const dy = b[1] - std.math.clamp(b[1], ly, ly + side);
                    if (dx * dx + dy * dy > reach * reach) continue;
                    const cell = self.cells[(ty * self.tw + tx) * tile_stride ..][0..tile_stride];
                    if (cell[0] == tile_slots) {
                        self.dropped += 1;
                        continue;
                    }
                    cell[0] += 1;
                    cell[cell[0]] = @intCast(j);
                }
            }
        }
    }

    fn clampTile(_: *const Tiles, at: f32, count: usize) usize {
        return @intFromFloat(std.math.clamp(@floor(at), 0.0, @as(f32, @floatFromInt(count - 1))));
    }

    /// The shapes listed for the tile a point (screen heights) is in.
    pub fn list(self: *const Tiles, at: [2]f32) []const u8 {
        const tx = self.clampTile(at[0] / self.side, self.tw);
        const ty = self.clampTile(at[1] / self.side, self.th);
        const cell = self.cells[(ty * self.tw + tx) * tile_stride ..][0..tile_stride];
        return cell[1 .. 1 + cell[0]];
    }

    /// The longest list, and the mean length.
    pub fn fullest(self: *const Tiles) struct { most: usize, mean: f32 } {
        var most: usize = 0;
        var sum: usize = 0;
        for (0..self.tw * self.th) |t| {
            most = @max(most, self.cells[t * tile_stride]);
            sum += self.cells[t * tile_stride];
        }
        return .{ .most = most, .mean = @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(self.tw * self.th)) };
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    width: f32,
    height: f32,
    pattern: Pattern,
    lamps: Lamps = .{},
    /// Palette slots of the ink and the paper (-1 = the background), and
    /// how much of the ink is mixed into the paper.
    ink: f32,
    paper: f32,
    tint: f32,
    size: f32,
    body: [max_shapes][4]f32 = @splat(.{ 0, 0, 0, 0 }),
    how: [max_shapes][4]f32 = @splat(.{ 0, 0, 0, 0 }),
    tiles: Tiles,
    tex: c.GLuint = 0,

    u: Uniforms(.{
        .tiles = "iShapeTiles",
        .tile = "iShapeTile",
        .body = "iShape[0]",
        .how = "iShapeHow[0]",
        .count = "iShapeCount",
        .sprinkle = "iSprinkle",
        .look = "iMemphisLook",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const w = @max(width, 64.0);
        const h = @max(height, 64.0);
        const size = std.math.clamp(params.getFloat("size", 1.0), 0.6, 1.6);
        var music = try spectral.Analyzer.init(allocator, params);
        errdefer music.deinit(allocator);
        return .{
            .allocator = allocator,
            .music = music,
            .tiles = try Tiles.init(allocator, w, h),
            .width = w,
            .height = h,
            .size = size,
            .pattern = Pattern.init(
                w / h,
                size,
                std.math.clamp(params.getFloat("speed", 1.0), 0.0, 6.0),
                0x3e3f15,
            ),
            .ink = @floatFromInt(std.math.clamp(params.getInt("ink", 5), -1, 15)),
            .paper = @floatFromInt(std.math.clamp(params.getInt("paper", -1), -1, 15)),
            .tint = std.math.clamp(params.getFloat("tint", 0.24), 0.0, 1.0),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        _ = self.music.update(dt);

        // The light is behind the focused window, and with nothing
        // focused off beyond the upper right corner.
        var id: u64 = lamps_mod.home_id;
        var pos = [2]f32{ 1.3 * self.width, 1.4 * self.height };
        if (state.focused_address > lamps_mod.cursor_id) {
            for (state.windows) |w| {
                if (w.address != state.focused_address or w.w < 1.0 or w.h < 1.0) continue;
                id = w.address;
                pos = .{ w.x + w.w * 0.5, w.y + w.h * 0.5 };
                break;
            }
        }
        self.lamps.step(dt, id, pos, state.windows);
        var lights: [max_lamps]Light = undefined;
        var lit: usize = 0;
        for (self.lamps.lamps) |lamp| {
            if (lamp.id == 0 or lamp.strength() <= 0) continue;
            lights[lit] = .{ .pos = .{ lamp.pos[0] / self.height, lamp.pos[1] / self.height }, .strength = lamp.strength() };
            lit += 1;
        }
        const cursor = [2]f32{ state.cursor[0] / self.height, state.cursor[1] / self.height };
        self.pattern.step(dt, &self.music.bands.bands, cursor, lights[0..lit]);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        const count = self.pattern.pack(&self.body, &self.how);
        const tiles = &self.tiles;
        tiles.build(self.body[0..count]);
        const tex_w: c.GLsizei = @intCast(tiles.tw * tile_stride);
        const tex_h: c.GLsizei = @intCast(tiles.th);
        c.glActiveTexture(c.GL_TEXTURE0);
        if (self.tex == 0) {
            c.glGenTextures(1, &self.tex);
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_R8UI, tex_w, tex_h, 0, c.GL_RED_INTEGER, c.GL_UNSIGNED_BYTE, null);
        }
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        // Rows of single bytes, of any length.
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 1);
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, tex_w, tex_h, c.GL_RED_INTEGER, c.GL_UNSIGNED_BYTE, tiles.cells.ptr);
        c.glPixelStorei(c.GL_UNPACK_ALIGNMENT, 4);

        self.u.use(prog.program);
        self.u.int(.tiles, 0);
        self.u.f1(.tile, tiles.px);
        self.u.f4v(.body, max_shapes, &self.body[0]);
        self.u.f4v(.how, max_shapes, &self.how[0]);
        self.u.f2(.count, @floatFromInt(count), self.pattern.energy);
        self.u.f2(.sprinkle, self.pattern.sprinkle[0], self.pattern.sprinkle[1]);
        self.u.f4(.look, self.ink, self.paper, self.tint, self.size);
    }

    pub fn deinit(self: *Context) void {
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
        self.tiles.deinit();
        self.music.deinit(self.allocator);
    }
};

const quiet: [6]f32 = @splat(0);
const nowhere = [2]f32{ -1e6, -1e6 };
const no_light = [0]Light{};

test "a sheet is well stocked, and no two shapes on one ever touch" {
    var pattern = Pattern.init(16.0 / 9.0, 1.0, 1.0, 7);
    try std.testing.expect(pattern.n >= 44);
    var of_kind: [6]usize = @splat(0);
    for (pattern.shapes[0..pattern.n]) |shape| of_kind[@intFromEnum(shape.kind)] += 1;
    for (of_kind) |count| try std.testing.expect(count >= 3);

    // Ten minutes, looked at every few seconds.
    for (0..150) |_| {
        for (0..200) |_| pattern.step(0.02, &quiet, nowhere, &no_light);
        for (0..pattern.n) |i| {
            for (i + 1..pattern.n) |j| {
                const a = pattern.shapes[i];
                const b = pattern.shapes[j];
                if (a.sheet != b.sheet) continue;
                // The short way round the sheet between where the two
                // are now.
                const sheet = pattern.sheets[a.sheet];
                const pa = pattern.where(i);
                const pb = pattern.where(j);
                const d = sheet.between(pa, pb);
                try std.testing.expect(@sqrt(d[0] * d[0] + d[1] * d[1]) > a.r + b.r);
            }
        }
    }
}

test "a shape that goes off one edge comes back on the opposite one, out of sight both times" {
    var pattern = Pattern.init(16.0 / 9.0, 1.0, 6.0, 11);
    var body: [max_shapes][4]f32 = undefined;
    var how: [max_shapes][4]f32 = undefined;
    var last: [max_shapes][2]f32 = undefined;
    for (0..pattern.n) |i| last[i] = pattern.where(i);
    var jumps: usize = 0;
    for (0..60000) |_| {
        pattern.step(0.02, &quiet, nowhere, &no_light);
        const sent = pattern.pack(&body, &how);
        try std.testing.expect(sent <= max_shapes);
        for (0..pattern.n) |i| {
            const now = pattern.where(i);
            const moved = @abs(now[0] - last[i][0]) + @abs(now[1] - last[i][1]);
            if (moved > 0.1) {
                jumps += 1;
                try std.testing.expect(!pattern.shows(last[i], pattern.shapes[i]));
                try std.testing.expect(!pattern.shows(now, pattern.shapes[i]));
            }
            last[i] = now;
        }
    }
    try std.testing.expect(jumps > 20);
}

test "the shader is given every shape that can show, and none that cannot" {
    var pattern = Pattern.init(21.0 / 9.0, 0.8, 1.0, 5);
    var body: [max_shapes][4]f32 = undefined;
    var how: [max_shapes][4]f32 = undefined;
    for (0..40) |_| {
        for (0..500) |_| pattern.step(0.02, &quiet, nowhere, &no_light);
        const sent = pattern.pack(&body, &how);
        var nearly: usize = 0;
        for (0..pattern.n) |i| {
            const shape = pattern.shapes[i];
            const at = pattern.where(i);
            const reach = shape.r * (1.0 + slack);
            const hair = reach + 0.003;
            if (at[0] > -hair and at[0] < pattern.aspect + hair and at[1] > -hair and at[1] < 1.0 + hair) nearly += 1;
            const out = at[0] < -reach or at[0] > pattern.aspect + reach or at[1] < -reach or at[1] > 1.0 + reach;
            if (out) continue;
            var found = false;
            for (body[0..sent]) |b| {
                if (b[0] == at[0] and b[1] == at[1] and b[2] == shape.r) found = true;
            }
            try std.testing.expect(found);
        }
        // Anything else sent is within a hair of showing.
        try std.testing.expect(sent <= nearly);
        try std.testing.expect(sent >= 20);
    }
}

test "the cursor pushes a shape aside, and it springs back when the cursor leaves" {
    var pattern = Pattern.init(16.0 / 9.0, 1.0, 0.0, 7);
    const i: usize = 0;
    const rest = pattern.where(i);
    const r = pattern.shapes[i].r;
    const cursor = [2]f32{ rest[0] - 0.6 * r, rest[1] };
    for (0..120) |_| pattern.step(1.0 / 120.0, &quiet, cursor, &no_light);
    const pushed = pattern.where(i);
    try std.testing.expect(pushed[0] > rest[0] + 0.01);
    try std.testing.expect(pushed[0] < rest[0] + 0.2);
    for (0..600) |_| pattern.step(1.0 / 120.0, &quiet, nowhere, &no_light);
    const back = pattern.where(i);
    try std.testing.expectApproxEqAbs(rest[0], back[0], 1e-3);
    try std.testing.expectApproxEqAbs(rest[1], back[1], 1e-3);
}

test "a halftone field's dots grow toward the light, and swing round when the light moves" {
    var pattern = Pattern.init(16.0 / 9.0, 1.0, 0.0, 7);
    var field: usize = 0;
    while (pattern.shapes[field].kind != .grid) field += 1;
    const at = pattern.where(field);
    const right = [_]Light{.{ .pos = .{ at[0] + 0.5, at[1] }, .strength = 1 }};
    const below = [_]Light{.{ .pos = .{ at[0], at[1] - 0.5 }, .strength = 1 }};
    for (0..600) |_| pattern.step(1.0 / 120.0, &quiet, nowhere, &right);
    try std.testing.expectApproxEqAbs(@as(f32, 1), pattern.shapes[field].lean[0], 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pattern.shapes[field].lean[1], 1e-2);
    for (0..600) |_| pattern.step(1.0 / 120.0, &quiet, nowhere, &below);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pattern.shapes[field].lean[0], 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, -1), pattern.shapes[field].lean[1], 1e-2);
}

test "each shape hears its own band, and a loud passage quickens the sheets" {
    var pattern = Pattern.init(16.0 / 9.0, 1.0, 1.0, 7);
    var bands: [6]f32 = @splat(0);
    bands[2] = 0.7;
    for (0..240) |_| pattern.step(1.0 / 120.0, &bands, nowhere, &no_light);
    for (pattern.shapes[0..pattern.n]) |shape| {
        if (shape.band == 2) {
            try std.testing.expect(shape.level > 0.8);
        } else {
            try std.testing.expectEqual(@as(f32, 0), shape.level);
        }
    }
    try std.testing.expect(pattern.energy > 0.05);
}

test "a tile lists every shape that can show in it, and none has more than it can hold" {
    const screens = [_][3]f32{ .{ 3840, 2160, 1.0 }, .{ 3440, 1440, 0.6 }, .{ 1920, 1080, 1.6 }, .{ 1080, 1920, 1.0 } };
    for (screens, 0..) |screen, seed| {
        var pattern = Pattern.init(screen[0] / screen[1], screen[2], 6.0, 20 + seed);
        var tiles = try Tiles.init(std.testing.allocator, screen[0], screen[1]);
        defer tiles.deinit();
        var body: [max_shapes][4]f32 = undefined;
        var how: [max_shapes][4]f32 = undefined;
        var prng = std.Random.DefaultPrng.init(3);
        const r = prng.random();
        var most: usize = 0;
        var mean: f32 = 0;
        for (0..60) |_| {
            for (0..300) |_| pattern.step(0.02, &quiet, nowhere, &no_light);
            const sent = pattern.pack(&body, &how);
            tiles.build(body[0..sent]);
            try std.testing.expectEqual(@as(usize, 0), tiles.dropped);
            const full = tiles.fullest();
            most = @max(most, full.most);
            mean += full.mean / 60.0;
            for (0..400) |_| {
                const at = [2]f32{ r.float(f32) * pattern.aspect, r.float(f32) };
                const listed = tiles.list(at);
                for (body[0..sent], 0..) |b, j| {
                    // As the shader reckons whether to draw it here.
                    const reach = b[2] * (1.0 + slack) + 1.0 / screen[1];
                    const dx = at[0] - b[0];
                    const dy = at[1] - b[1];
                    if (dx * dx + dy * dy > reach * reach) continue;
                    try std.testing.expect(std.mem.indexOfScalar(u8, listed, @intCast(j)) != null);
                }
            }
        }
        try std.testing.expect(most <= tile_slots - 3);
        try std.testing.expect(mean < 6.0);
    }
}
