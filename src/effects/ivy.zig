const std = @import("std");
const clock = @import("clock.zig");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");
const bands_mod = @import("bands.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

const WindowRect = shader_mod.ShaderProgram.WindowRect;

const max_windows = 32;

// Bioluminescent ivy: glowing vines take root on window frames (windows are
// trellises) and climb them, sprouting leaves as they grow. Vine geometry is
// recomputed from the *current* window rect every frame (perimeter-
// parameterized, voltaic crawl pattern), so vines ride their window.
//
// A plant lives exactly as long as its window. Growth is limited by space,
// not by length (competition for space, as in Runions et al. 2007): trunks
// creep around the frame until they meet another trunk's claim, shoots
// reach out until they meet occupied space or their unsupported length,
// and forking continues wherever there is room. Once the frame is clad the
// plant matures in place — stems thicken by the pipe model (Shinozaki
// 1964), leaves turn over one at a time — and only `closewindow` kills it.
// A window that merely leaves the screen (another workspace, a scratchpad)
// keeps its plant dormant until it returns.

/// Windows remembered at once, including dormant ones on other workspaces.
const max_known = 96;
const max_vines = 768;
const seg_step: f32 = 16.0; // arc length per stem segment
const leaf_spacing: f32 = 26.0;
const max_fall = 40;

// Render budget. Stems and leaves are "prims" of two RGBA32F texels in a
// data texture; the CPU bins them into screen tiles so each pixel only
// visits the prims that can reach it, however large the garden grows.
const max_prims = 16384;
const prim_tex_w = 1024;
const prim_rows = max_prims * 2 / prim_tex_w;
const max_refs = 1 << 17;
const ref_tex_w = 1024;
const ref_rows = max_refs / ref_tex_w;
const tile_px = 64;
/// Stem glow reach; the shader subtracts the glow's value here so the
/// cutoff never shows as an edge.
const stem_pad: f32 = 40.0;

// Space competition. The occupancy grid is rebuilt from the stems every
// frame; window interiors count as occupied (nothing grows under glass).
const cell_px: f32 = 8.0;
const cell_blocked: u16 = 0xFFFF;
/// Trunks stop this far (arc length) short of another trunk's claim.
const trunk_gap: f32 = 28.0;
/// A new trunk only roots in a stretch of bare frame at least this long.
const min_root_gap: f32 = 160.0;
/// Mean arc length between side shoots along a trunk.
const fork_spacing: f32 = 110.0;

// Dieback timing: a necrosis front sweeps from the tip toward the root
// over die_front_secs — the stem's glow drains and leaves let go as it
// passes — then the last residual glow fades by vine_die_secs. Stems
// hold their shape throughout; only the leaves move.
const vine_die_secs: f32 = 1.3;
const die_front_secs: f32 = 0.9;
/// Half-width of the necrosis front's soft edge, in arc length.
const front_soft: f32 = 30.0;

// Presence: a window that drops out of the snapshot is held in place for
// absent_hold (its closewindow usually lands inside that), then fades out
// and goes dormant. A returning window fades back in.
const absent_hold: f32 = 0.25;
const absent_fade: f32 = 0.4;
const return_fade: f32 = 0.5;

// Leaf turnover on mature nodes: each leaf lives a seeded 10-20 minutes
// (at growth 1), yellows, drops, and a new one grows at the node.
const leaf_cycle_min: f32 = 600.0;
const leaf_cycle_span: f32 = 600.0;

const Vine = struct {
    active: bool = false,
    /// Seconds spent dying (window closed/moved); fades out, then frees the slot.
    dying: f32 = 0,
    /// 1 = the screen border itself; anything else is a window address.
    addr: u64 = 0,
    /// Dying vines wilt IN PLACE: their anchor freezes where the plant
    /// stood, unaffected by where the window went (or that it's gone).
    /// Branches also freeze their attach frame, since the parent's slot
    /// may be recycled before they finish dying.
    frozen: bool = false,
    frozen_rect: WindowRect = undefined,
    frozen_attach: [2]f32 = .{ 0, 0 },
    frozen_ang: f32 = 0,
    frozen_presence: f32 = 1,
    t0: f32 = 0,
    dir: f32 = 1,
    dl: f32 = 0,
    /// Branches: the longest a shoot can reach without support. Trunks
    /// have no length limit (0) — only space stops them.
    reach: f32 = 0,
    /// Out of room: growth has stopped for good.
    halted: bool = false,
    seed: f32 = 0,
    /// Screen-border vines grow lifted toward the workspace interior
    /// (the outward perimeter normal would point off-screen).
    inward: bool = false,
    /// Branches: index of the vine this tendril forked from (-1 for
    /// trunks), the parent arc offset it roots at, and the parent's seed so
    /// a recycled slot can't silently become a different parent. For
    /// branches, `dir` is repurposed as the departure side (±1) and
    /// `inward` is inherited as the "prefer growing toward screen center"
    /// hint (set for border creepers).
    parent: i16 = -1,
    ps: f32 = 0,
    parent_seed: f32 = 0,
    /// 0 = trunk, 1 = branch, 2 = sub-branch (forking stops at 2).
    depth: u8 = 0,
    /// Sub-branches forked so far (branches fork at most twice).
    branches: u8 = 0,
    /// Trunks: arc length at which the next side shoot is tried.
    next_fork: f32 = 0,
    /// Seconds lived while its window was present (the leaf clock).
    age: f32 = 0,
};

/// A leaf shaken loose, tumbling down on the breeze.
const FallingLeaf = struct {
    active: bool = false,
    pos: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    angle: f32 = 0,
    spin: f32 = 0,
    age: f32 = 0,
    life: f32 = 1,
    size: f32 = 6,
};

/// Per-window state, persisted across frames and keyed by address. Holds
/// the last seen rect (dormant plants stay anchored to it), motion
/// detection, and the presence fade.
const KnownWin = struct {
    active: bool = false,
    addr: u64 = 0,
    rect: WindowRect = undefined,
    raw_prev: WindowRect = undefined,
    /// Settle countdown after a move/resize; nothing roots meanwhile.
    moving: f32 = 0,
    /// In this frame's snapshot.
    present: bool = false,
    /// Seconds since last in the snapshot.
    absent: f32 = 0,
    /// Render alpha, 0..1.
    presence: f32 = 1,
    /// closewindow arrived. Kept as a tombstone until the window leaves
    /// the snapshot, so a lagging snapshot can't replant it.
    closed: bool = false,
    /// Effect clock when last present, for evicting stale dormant entries
    /// (a close missed while the event socket was down).
    last_seen: f64 = 0,
};

/// Cheap deterministic per-node hash — stable across frames so jittered
/// leaves don't crawl.
fn fhash(a: f32, b: f32) f32 {
    const x = @sin(a * 12.9898 + b * 78.233) * 43758.5453;
    return x - @floor(x);
}

const smoothstep = bands_mod.smoothstep;

/// Arc position of the necrosis front for a vine `d` seconds into
/// dieback: starts at the tip (dl) and sweeps to the root (0), eased so
/// it lingers at both ends.
fn wiltFront(dl: f32, d: f32) f32 {
    return dl * (1.0 - smoothstep(0.0, die_front_secs, d));
}

/// How dead the vine is locally at arc offset `s` (0 alive, 1 past the
/// front), for a vine `d` seconds into dieback.
fn localWilt(v: *const Vine, s: f32, d: f32) f32 {
    if (d <= 0) return 0;
    const front = wiltFront(v.dl, d);
    return smoothstep(front - front_soft, front + front_soft, s);
}

fn perimeterOf(rect: WindowRect) f32 {
    return 2.0 * (@max(rect.w, 1.0) + @max(rect.h, 1.0));
}

/// Circular distance from arc point `t` to the arc interval starting at
/// `lo` with length `len`, on a loop of length `per` (0 inside it).
fn arcDistToInterval(t: f32, lo: f32, len: f32, per: f32) f32 {
    const into = @mod(t - lo, per);
    if (into <= len) return 0;
    return @min(into - len, per - into);
}

/// Point on a rect's border at perimeter offset `t` (wraps), walking
/// bottom -> right -> top -> left (voltaic pattern), plus the outward
/// normal of the edge it lands on. Coordinates are y-up (frag space).
const PerimHit = struct { pos: [2]f32, normal: [2]f32 };

/// Distance from a point to a rect's border line (0 on the frame).
fn rectBorderDist(rect: WindowRect, p: [2]f32) f32 {
    const qx = @max(rect.x - p[0], p[0] - (rect.x + rect.w));
    const qy = @max(rect.y - p[1], p[1] - (rect.y + rect.h));
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    const outside = @sqrt(ox * ox + oy * oy);
    const inside = @min(@max(qx, qy), 0.0);
    return @abs(outside + inside);
}

/// Inverse of perimeterAt: the arc offset of the border point nearest
/// `p`, in the same bottom -> right -> top -> left walk.
fn arcOffsetOf(rect: WindowRect, p: [2]f32) f32 {
    const w = @max(rect.w, 1.0);
    const h = @max(rect.h, 1.0);
    const px = std.math.clamp(p[0] - rect.x, 0.0, w);
    const py = std.math.clamp(p[1] - rect.y, 0.0, h);
    const d_bot = py;
    const d_top = h - py;
    const d_left = px;
    const d_right = w - px;
    const m = @min(@min(d_bot, d_top), @min(d_left, d_right));
    if (m == d_bot) return px;
    if (m == d_right) return w + py;
    if (m == d_top) return w + h + (w - px);
    return 2.0 * w + h + (h - py);
}

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
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    now: f64 = 0,

    vines: []Vine,
    spawn_timer: f32 = 0,

    fall: [max_fall]FallingLeaf = @splat(.{}),
    next_fall: u8 = 0,

    known: [max_known]KnownWin = @splat(.{}),
    last_ws_switches: u32 = 0,
    last_slide: f32 = 1.0,

    // Per-vine frame caches, rebuilt by resolveFrames: anchor rect (null
    // once its window is forgotten), presence alpha, and for branches the
    // attach point + departure angle on the parent.
    vr: []?WindowRect,
    vp: []f32,
    att_pos: [][2]f32,
    att_ang: []f32,
    // Pipe model: total stem length carried by each vine (itself plus
    // everything forked off it), and child lists to sum it by attach point.
    sub_len: []f32,
    first_child: []i16,
    next_sib: []i16,

    // Occupancy grid (vine index + 1, cell_blocked, or 0 = free).
    occ: []u16,
    gw: usize,
    gh: usize,

    // Frame geometry: prims, then per-tile ref lists.
    prims: [][8]f32,
    prim_count: u32 = 0,
    tiles_x: usize,
    tiles_y: usize,
    tile_hdr: [][2]u32,
    tile_fill: []u32,
    refs: []u32,
    ref_count: u32 = 0,

    // Window rects cached this frame.
    win_cache: [max_windows]WindowRect = undefined,
    win_cache_count: usize = 0,
    focused_center: [2]f32 = .{ -1e9, -1e9 },

    // Audio analysis: shared spectral front-end (real FFT bands + AGC).
    // Only the SLOW envelopes drive the garden — it breathes, never twitches.
    music: spectral.Analyzer = .{},

    growth: f32 = 1.0,
    brightness: f32 = 1.0,

    tex_prims: c.GLuint = 0,
    tex_tiles: c.GLuint = 0,
    tex_refs: c.GLuint = 0,

    u: Uniforms(.{
        .prims = "iPrims",
        .tiles = "iTiles",
        .refs = "iRefs",
        .tile_px = "iTilePx",
        .fall = "iFall[0]",
        .time = "iIvyTime",
        .bass = "iBass",
        .treble = "iTreble",
        .beat = "iBeat",
        .bright = "iBright",
    }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        var music = try spectral.Analyzer.init(allocator, params);
        errdefer music.deinit(allocator);

        const gw: usize = @intFromFloat(@ceil(@max(width, 1.0) / cell_px));
        const gh: usize = @intFromFloat(@ceil(@max(height, 1.0) / cell_px));
        const tiles_x: usize = @intFromFloat(@ceil(@max(width, 1.0) / tile_px));
        const tiles_y: usize = @intFromFloat(@ceil(@max(height, 1.0) / tile_px));

        const vines = try allocator.alloc(Vine, max_vines);
        errdefer allocator.free(vines);
        @memset(vines, .{});
        const vr = try allocator.alloc(?WindowRect, max_vines);
        errdefer allocator.free(vr);
        @memset(vr, null);
        const vp = try allocator.alloc(f32, max_vines);
        errdefer allocator.free(vp);
        const att_pos = try allocator.alloc([2]f32, max_vines);
        errdefer allocator.free(att_pos);
        @memset(att_pos, .{ 0, 0 });
        const att_ang = try allocator.alloc(f32, max_vines);
        errdefer allocator.free(att_ang);
        @memset(att_ang, 0);
        const sub_len = try allocator.alloc(f32, max_vines);
        errdefer allocator.free(sub_len);
        const first_child = try allocator.alloc(i16, max_vines);
        errdefer allocator.free(first_child);
        const next_sib = try allocator.alloc(i16, max_vines);
        errdefer allocator.free(next_sib);
        const occ = try allocator.alloc(u16, gw * gh);
        errdefer allocator.free(occ);
        @memset(occ, 0);
        const prims = try allocator.alloc([8]f32, max_prims);
        errdefer allocator.free(prims);
        const tile_hdr = try allocator.alloc([2]u32, tiles_x * tiles_y);
        errdefer allocator.free(tile_hdr);
        @memset(tile_hdr, .{ 0, 0 });
        const tile_fill = try allocator.alloc(u32, tiles_x * tiles_y);
        errdefer allocator.free(tile_fill);
        const refs = try allocator.alloc(u32, max_refs);
        errdefer allocator.free(refs);

        return .{
            .allocator = allocator,
            .music = music,
            .rng = std.Random.DefaultPrng.init(0x697679), // "ivy"
            .width = width,
            .height = height,
            .vines = vines,
            .vr = vr,
            .vp = vp,
            .att_pos = att_pos,
            .att_ang = att_ang,
            .sub_len = sub_len,
            .first_child = first_child,
            .next_sib = next_sib,
            .occ = occ,
            .gw = gw,
            .gh = gh,
            .prims = prims,
            .tiles_x = tiles_x,
            .tiles_y = tiles_y,
            .tile_hdr = tile_hdr,
            .tile_fill = tile_fill,
            .refs = refs,
            .growth = params.getFloat("growth", 1.0),
            .brightness = params.getFloat("brightness", 1.0),
        };
    }

    /// The desktop border as a trellis for addr == 1 vines.
    fn screenRect(self: *const Context) WindowRect {
        return .{ .x = 2.0, .y = 2.0, .w = self.width - 4.0, .h = self.height - 4.0, .address = 1 };
    }

    fn knownFor(self: *Context, addr: u64) ?*KnownWin {
        for (&self.known) |*k| {
            if (k.active and k.addr == addr) return k;
        }
        return null;
    }

    /// The rect a vine is rooted on: frozen where it wilted, the screen
    /// border (addr 1), or its window's last seen rect — which, for a
    /// dormant window, is where it stood when it left. Null once the
    /// window is forgotten.
    fn vineRect(self: *Context, v: *const Vine) ?WindowRect {
        if (v.frozen) return v.frozen_rect;
        if (v.addr == 1) return self.screenRect();
        const k = self.knownFor(v.addr) orelse return null;
        if (k.closed) return null;
        return k.rect;
    }

    fn vinePresence(self: *Context, v: *const Vine) f32 {
        if (v.frozen) return v.frozen_presence;
        if (v.addr == 1) return 1.0;
        const k = self.knownFor(v.addr) orelse return 0.0;
        return k.presence;
    }

    /// Whether plants on `addr` may grow or root now: the window is on
    /// screen, open, and has settled after any move.
    fn canGrow(self: *Context, addr: u64) bool {
        if (addr == 1) return true;
        const k = self.knownFor(addr) orelse return false;
        if (!k.present or k.closed or k.moving > 0) return false;
        const cx = k.rect.x + k.rect.w * 0.5;
        const cy = k.rect.y + k.rect.h * 0.5;
        return cx >= 0 and cx <= self.width and cy >= 0 and cy <= self.height;
    }

    /// Stop vine `i` in place for dieback, capturing everything it needs
    /// to keep rendering after its window and parent are gone.
    fn freeze(self: *Context, i: usize, rect: WindowRect) void {
        const v = &self.vines[i];
        v.frozen_presence = self.vp[i];
        v.frozen_attach = self.att_pos[i];
        v.frozen_ang = self.att_ang[i];
        v.frozen_rect = rect;
        v.frozen = true;
        v.dying = 0.0001;
    }

    /// Wilt every live vine on `addr` in place at `rect` — where the
    /// plant stood. Leaves are not shed here: they let go one by one as
    /// the necrosis front passes their node.
    fn wiltVines(self: *Context, addr: u64, rect: WindowRect) void {
        for (self.vines, 0..) |*v, i| {
            if (!v.active or v.dying > 0 or v.addr != addr) continue;
            self.freeze(i, rect);
        }
    }

    /// Drop every vine on `addr` without a dieback — for plants that are
    /// not on screen to be seen dying.
    fn dropVines(self: *Context, addr: u64) void {
        for (self.vines) |*v| {
            if (v.active and v.addr == addr and !v.frozen) v.active = false;
        }
    }

    /// A free vine slot, evicting the longest-dormant window's plant when
    /// the pool is full. Dormant plants are the only ones nobody can see.
    fn freeSlot(self: *Context) ?usize {
        for (self.vines, 0..) |v, i| {
            if (!v.active) return i;
        }
        var oldest: ?*KnownWin = null;
        for (&self.known) |*k| {
            if (!k.active or k.present) continue;
            if (oldest == null or k.last_seen < oldest.?.last_seen) oldest = k;
        }
        const k = oldest orelse return null;
        self.dropVines(k.addr);
        k.active = false;
        for (self.vines, 0..) |v, i| {
            if (!v.active) return i;
        }
        return null;
    }

    fn freeVineCount(self: *const Context) usize {
        var n: usize = 0;
        for (self.vines) |v| {
            if (!v.active) n += 1;
        }
        return n;
    }

    /// Resolve every vine's anchor rect, presence, and (for branches)
    /// attach frame. Parents resolve before children.
    fn resolveFrames(self: *Context) void {
        for (self.vines, 0..) |*v, i| {
            if (!v.active) {
                self.vr[i] = null;
                continue;
            }
            self.vr[i] = self.vineRect(v);
            self.vp[i] = self.vinePresence(v);
        }
        for ([_]u8{ 1, 2 }) |depth| {
            for (self.vines, 0..) |*v, i| {
                if (!v.active or v.depth != depth) continue;
                if (v.frozen) {
                    self.att_pos[i] = v.frozen_attach;
                    self.att_ang[i] = v.frozen_ang;
                    continue;
                }
                const pi: usize = @intCast(v.parent);
                if (!self.vines[pi].active or self.vr[pi] == null) continue;
                self.attachFrame(pi, v.ps, v.dir, v.seed, &self.att_pos[i], &self.att_ang[i]);
            }
        }
    }

    /// Where a shoot forking off vine `pi` at arc `ps` roots, and the
    /// angle it departs at: a seeded angle off the parent's local
    /// tangent, on `side` (away from the frame, like a shoot reaching for
    /// light).
    fn attachFrame(self: *Context, pi: usize, ps: f32, side: f32, seed: f32, pos: *[2]f32, ang: *f32) void {
        pos.* = self.vinePoint(pi, ps);
        const a = self.vinePoint(pi, @max(ps - 5.0, 0.0));
        const b = self.vinePoint(pi, ps + 5.0);
        ang.* = std.math.atan2(b[1] - a[1], b[0] - a[0]) + side * (0.55 + @mod(seed * 0.61, 1.0) * 0.6);
    }

    /// A trunk node at arc offset `s`: perimeter point lifted off the frame
    /// by an organic meander, swaying more toward the free tip.
    fn trunkPoint(self: *const Context, rect: WindowRect, v: *const Vine, s: f32) [2]f32 {
        const hit = perimeterAt(rect, v.t0 + v.dir * s);
        const sway_amp = (1.5 + self.music.bands.energy_ema * 3.0) * @min(s / 140.0, 1.0);
        // Three incommensurate meander frequencies with a per-vine
        // amplitude so no two vines wander with the same rhythm.
        const amp_v = 0.8 + fhash(v.seed, 0.29) * 0.5;
        const lift = 4.0 +
            (@sin(s * 0.11 + v.seed) * 4.0 +
                @sin(s * 0.045 + v.seed * 1.7) * 7.0 +
                @sin(s * 0.021 + v.seed * 3.1) * 3.5) * amp_v +
            @sin(clock.phase(self.now, 1.2) + s * 0.05 + v.seed) * sway_amp;
        const l = if (v.inward) -@max(lift, 1.5) else @max(lift, 1.5);
        return .{ hit.pos[0] + hit.normal[0] * l, hit.pos[1] + hit.normal[1] * l };
    }

    /// A branch node at arc offset `s`: leaves the parent at `attach`
    /// heading `ang`, arcing into free space with a seeded bend and
    /// meander. Closed-form relative to the attach frame, so branches ride
    /// their trunk exactly.
    fn branchPoint(self: *const Context, v: *const Vine, attach: [2]f32, ang: f32, s: f32) [2]f32 {
        const ux = @cos(ang);
        const uy = @sin(ang);
        const px = -uy;
        const py = ux;
        const bend = (@mod(v.seed * 0.37, 1.0) - 0.5) * 2.0 * 0.0032;
        const sway_amp = (1.5 + self.music.bands.energy_ema * 3.0) * @min(s / 90.0, 1.0);
        const off = @sin(s * 0.05 + v.seed * 3.0) * 7.0 +
            @sin(s * 0.013 + v.seed * 1.3) * 16.0 * (s / @max(v.reach, 1.0)) +
            bend * s * s +
            @sin(clock.phase(self.now, 1.4) + s * 0.06 + v.seed) * sway_amp;
        return .{ attach[0] + ux * s + px * off, attach[1] + uy * s + py * off };
    }

    fn vinePoint(self: *const Context, i: usize, s: f32) [2]f32 {
        const v = &self.vines[i];
        if (v.parent < 0) return self.trunkPoint(self.vr[i].?, v, s);
        return self.branchPoint(v, self.att_pos[i], self.att_ang[i], s);
    }

    // ---- space competition ----

    fn cellAt(self: *const Context, p: [2]f32) ?usize {
        if (p[0] < 0 or p[1] < 0 or p[0] >= self.width or p[1] >= self.height) return null;
        const cx: usize = @intFromFloat(p[0] / cell_px);
        const cy: usize = @intFromFloat(p[1] / cell_px);
        if (cx >= self.gw or cy >= self.gh) return null;
        return cy * self.gw + cx;
    }

    /// Is `owner` (a vine index) `i` itself or one of its ancestors?
    /// Kin never crowd each other out: a shoot starts on its parent.
    fn isKin(self: *const Context, i: usize, owner: usize) bool {
        var j: i32 = @intCast(i);
        while (j >= 0) {
            if (@as(usize, @intCast(j)) == owner) return true;
            j = self.vines[@intCast(j)].parent;
        }
        return false;
    }

    /// Free for a stem of vine `kin_of` (or a shoot about to fork off it):
    /// on screen, not under a window, and not claimed by an unrelated stem.
    fn spaceFree(self: *const Context, p: [2]f32, kin_of: usize) bool {
        const ci = self.cellAt(p) orelse return false;
        const o = self.occ[ci];
        if (o == 0) return true;
        if (o == cell_blocked) return false;
        return self.isKin(kin_of, o - 1);
    }

    fn stamp(self: *Context, p: [2]f32, owner: u16) void {
        const ci = self.cellAt(p) orelse return;
        const cx = ci % self.gw;
        const cy = ci / self.gw;
        const x0 = if (cx > 0) cx - 1 else cx;
        const y0 = if (cy > 0) cy - 1 else cy;
        const x1 = @min(cx + 1, self.gw - 1);
        const y1 = @min(cy + 1, self.gh - 1);
        for (y0..y1 + 1) |y| {
            for (x0..x1 + 1) |x| {
                const cell = &self.occ[y * self.gw + x];
                if (cell.* != cell_blocked) cell.* = owner;
            }
        }
    }

    fn blockRect(self: *Context, r: WindowRect) void {
        const x0f = std.math.clamp((r.x + 2.0) / cell_px, 0.0, @as(f32, @floatFromInt(self.gw)));
        const x1f = std.math.clamp((r.x + r.w - 2.0) / cell_px, 0.0, @as(f32, @floatFromInt(self.gw)));
        const y0f = std.math.clamp((r.y + 2.0) / cell_px, 0.0, @as(f32, @floatFromInt(self.gh)));
        const y1f = std.math.clamp((r.y + r.h - 2.0) / cell_px, 0.0, @as(f32, @floatFromInt(self.gh)));
        const x0: usize = @intFromFloat(@ceil(x0f));
        const x1: usize = @intFromFloat(@floor(x1f));
        const y0: usize = @intFromFloat(@ceil(y0f));
        const y1: usize = @intFromFloat(@floor(y1f));
        if (x1 <= x0 or y1 <= y0) return;
        for (y0..y1) |y| @memset(self.occ[y * self.gw + x0 .. y * self.gw + x1], cell_blocked);
    }

    /// Circular arc distance from `t` to the nearest stretch of frame
    /// claimed by a live trunk on `addr` (other than `exclude`).
    fn claimDist(self: *const Context, addr: u64, per: f32, t: f32, exclude: ?usize) f32 {
        var best: f32 = std.math.floatMax(f32);
        for (self.vines, 0..) |u, j| {
            if (!u.active or u.dying > 0 or u.parent >= 0 or u.addr != addr) continue;
            if (exclude != null and exclude.? == j) continue;
            const lo = if (u.dir > 0) u.t0 else u.t0 - u.dl;
            best = @min(best, arcDistToInterval(t, lo, u.dl, per));
        }
        return best;
    }

    const Gap = struct { mid: f32, len: f32 };

    /// The longest bare stretch of `rect`'s frame, with its midpoint.
    fn largestGap(self: *Context, addr: u64, rect: WindowRect) Gap {
        const per = perimeterOf(rect);
        const bin: f32 = 8.0;
        var claimed: [4096]bool = undefined;
        const n: usize = @min(@as(usize, @intFromFloat(@ceil(per / bin))), claimed.len);
        @memset(claimed[0..n], false);
        var any = false;
        for (self.vines) |u| {
            if (!u.active or u.dying > 0 or u.parent >= 0 or u.addr != addr) continue;
            any = true;
            const lo = if (u.dir > 0) u.t0 else u.t0 - u.dl;
            var s: f32 = -trunk_gap;
            while (s <= u.dl + trunk_gap) : (s += bin) {
                const b: usize = @intFromFloat(@mod(lo + s, per) / bin);
                claimed[@min(b, n - 1)] = true;
            }
        }
        if (!any) return .{ .mid = self.rng.random().float(f32) * per, .len = per };
        // Longest circular run of unclaimed bins: start the scan just past
        // a claimed bin so no run straddles the wrap.
        var start: usize = 0;
        while (start < n and !claimed[start]) start += 1;
        var best = Gap{ .mid = 0, .len = 0 };
        var run: usize = 0;
        var run_start: usize = 0;
        for (1..n + 1) |k| {
            const b = (start + k) % n;
            if (!claimed[b]) {
                if (run == 0) run_start = b;
                run += 1;
                const len = @as(f32, @floatFromInt(run)) * bin;
                if (len > best.len) best = .{ .mid = (@as(f32, @floatFromInt(run_start)) + @as(f32, @floatFromInt(run)) * 0.5) * bin, .len = len };
            } else run = 0;
        }
        return best;
    }

    // ---- spawning ----

    fn spawnTrunk(self: *Context, addr: u64, t0: f32, inward: bool) void {
        const r = self.rng.random();
        const i = self.freeSlot() orelse return;
        const seed = r.float(f32) * 100.0;
        self.vines[i] = .{
            .active = true,
            .addr = addr,
            .t0 = t0,
            .dir = if (r.boolean()) 1.0 else -1.0,
            .seed = seed,
            .inward = inward,
            .next_fork = 80.0 + fhash(seed, 0.83) * 60.0,
        };
        self.vr[i] = self.vineRect(&self.vines[i]);
        self.vp[i] = self.vinePresence(&self.vines[i]);
    }

    /// Fork a shoot off vine `pi` at arc `ps` — if the space it would
    /// grow into is free. Crowded forks simply don't happen.
    fn spawnBranch(self: *Context, pi: usize, ps: f32) void {
        const r = self.rng.random();
        // Keep slots in reserve so windows and the border can always root.
        if (self.freeVineCount() < 8) return;
        const parent = &self.vines[pi];
        const rect = self.vr[pi] orelse return;

        var reach = 70.0 + r.float(f32) * 110.0;
        if (parent.depth > 0) reach *= 0.6; // sub-branches stay short

        // Phototropism: depart on the side that reaches away from the
        // frame — or toward screen center for border creepers (inward).
        const attach = self.vinePoint(pi, ps);
        const a = self.vinePoint(pi, @max(ps - 5.0, 0.0));
        const b = self.vinePoint(pi, ps + 5.0);
        const tang = std.math.atan2(b[1] - a[1], b[0] - a[0]);
        var out_x = attach[0] - (rect.x + rect.w * 0.5);
        var out_y = attach[1] - (rect.y + rect.h * 0.5);
        if (parent.inward) {
            out_x = -out_x;
            out_y = -out_y;
        }
        const dot_p = @cos(tang + 0.85) * out_x + @sin(tang + 0.85) * out_y;
        const dot_m = @cos(tang - 0.85) * out_x + @sin(tang - 0.85) * out_y;
        const side: f32 = if (dot_p >= dot_m) 1.0 else -1.0;

        var nv = Vine{
            .active = true,
            .addr = parent.addr,
            .dir = side,
            .reach = reach,
            .seed = r.float(f32) * 100.0,
            .inward = parent.inward,
            .parent = @intCast(pi),
            .ps = ps,
            .parent_seed = parent.seed,
            .depth = parent.depth + 1,
        };
        var pos: [2]f32 = undefined;
        var ang: f32 = undefined;
        self.attachFrame(pi, ps, side, nv.seed, &pos, &ang);
        var s: f32 = 12.0;
        while (s <= @min(reach, 48.0)) : (s += 12.0) {
            if (!self.spaceFree(self.branchPoint(&nv, pos, ang, s), pi)) return;
        }

        const i = self.freeSlot() orelse return;
        self.vines[i] = nv;
        self.vr[i] = rect;
        self.vp[i] = self.vp[pi];
        self.att_pos[i] = pos;
        self.att_ang[i] = ang;
        if (parent.depth > 0) parent.branches += 1;
    }

    fn shedLeaves(self: *Context, pos: [2]f32, n: u32) void {
        const r = self.rng.random();
        for (0..n) |_| {
            const slot = self.next_fall;
            self.next_fall = (self.next_fall + 1) % max_fall;
            self.fall[slot] = .{
                .active = true,
                .pos = pos,
                .vel = .{ (r.float(f32) * 2.0 - 1.0) * 40.0, 5.0 + r.float(f32) * 20.0 },
                .angle = r.float(f32) * std.math.tau,
                .spin = (r.float(f32) * 2.0 - 1.0) * 3.0,
                .age = 0,
                .life = 2.5 + r.float(f32) * 2.0,
                .size = 5.0 + r.float(f32) * 4.0,
            };
        }
    }

    /// A leaf released by dieback or turnover: it detaches with its
    /// rendered pose and only a gentle push, so the hand-off from stem to
    /// air is seamless — then gravity, breeze, and tumble take over.
    fn dropLeaf(self: *Context, pos: [2]f32, angle: f32, size: f32) void {
        const r = self.rng.random();
        const slot = self.next_fall;
        self.next_fall = (self.next_fall + 1) % max_fall;
        self.fall[slot] = .{
            .active = true,
            .pos = pos,
            .vel = .{ (r.float(f32) * 2.0 - 1.0) * 18.0, -6.0 - r.float(f32) * 14.0 },
            .angle = angle,
            .spin = (r.float(f32) * 2.0 - 1.0) * 2.2,
            .age = 0,
            .life = 2.8 + r.float(f32) * 1.8,
            .size = size,
        };
    }

    // ---- per-frame update ----

    /// Track which windows are here, gone, closed, or moved. Plants die
    /// only on closewindow or a move/resize (they don't like being
    /// moved); a window merely out of view keeps its plant dormant.
    fn trackWindows(self: *Context, state: effects.FrameState, dt: f32) void {
        for (state.closed_windows) |addr| {
            const k = self.knownFor(addr) orelse continue;
            if (k.closed) continue;
            k.closed = true;
            // Wilt where it stood if anyone can see it; otherwise the
            // plant just goes with the window.
            if (k.presence > 0.01) self.wiltVines(addr, k.rect) else self.dropVines(addr);
        }

        // Rects jump across a workspace switch (the slide's camera, or a
        // snap) without the windows themselves moving: only a size change
        // counts as a resize then. The displacement since last frame is
        // the camera's if the slide was running on either frame — its
        // final step lands on the frame it reports settled.
        const camera_moving = state.workspace_switches != self.last_ws_switches or
            state.workspace_slide < 1.0 or self.last_slide < 1.0;
        self.last_ws_switches = state.workspace_switches;
        self.last_slide = state.workspace_slide;

        for (&self.known) |*k| k.present = false;
        for (self.win_cache[0..self.win_cache_count]) |w| {
            var entry: ?*KnownWin = self.knownFor(w.address);
            if (entry == null) {
                for (&self.known) |*k| {
                    if (!k.active) {
                        entry = k;
                        break;
                    }
                }
                if (entry == null) {
                    // Table full: forget the longest-dormant window.
                    var oldest: ?*KnownWin = null;
                    for (&self.known) |*k| {
                        if (!k.active or k.present) continue;
                        if (oldest == null or k.last_seen < oldest.?.last_seen) oldest = k;
                    }
                    if (oldest) |k| self.dropVines(k.addr);
                    entry = oldest;
                }
                const k = entry orelse continue;
                k.* = .{ .active = true, .addr = w.address, .rect = w, .raw_prev = w, .last_seen = self.now };
            }
            const k = entry.?;
            const returning = !k.present and k.absent > 0;
            k.present = true;
            k.absent = 0;
            k.last_seen = self.now;
            if (k.closed) {
                k.rect = w;
                k.raw_prev = w;
                continue;
            }

            const msz = @abs(w.w - k.raw_prev.w) + @abs(w.h - k.raw_prev.h);
            if (returning) {
                // Resized while out of view: the plant didn't survive it,
                // and nobody watched it die.
                if (msz > 6.0) self.dropVines(w.address);
            } else {
                const mdx = (w.x + w.w * 0.5) - (k.raw_prev.x + k.raw_prev.w * 0.5);
                const mdy = (w.y + w.h * 0.5) - (k.raw_prev.y + k.raw_prev.h * 0.5);
                const moved = !camera_moving and mdx * mdx + mdy * mdy > 6.0 * 6.0;
                if (moved or msz > 6.0) {
                    const was_still = k.moving <= 0;
                    k.moving = 0.4;
                    // Wilt at the last resting rect, not mid-motion.
                    if (was_still) self.wiltVines(w.address, k.rect);
                } else {
                    k.moving = @max(k.moving - dt, 0);
                }
            }
            k.raw_prev = w;
            k.rect = w;
            k.presence = @min(k.presence + dt / return_fade, 1.0);
        }
        for (&self.known) |*k| {
            if (!k.active or k.present) continue;
            k.absent += dt;
            if (k.closed) {
                k.active = false; // tombstone served its purpose
                continue;
            }
            k.presence = @min(k.presence, 1.0 - smoothstep(absent_hold, absent_hold + absent_fade, k.absent));
        }
    }

    fn spawnTick(self: *Context) void {
        // The desktop border always hosts creepers — and on an empty
        // workspace it carries the whole garden.
        {
            const want: u32 = if (self.win_cache_count == 0) 6 else 3;
            _ = self.rootOn(1, self.screenRect(), want, true);
        }
        // Windows: bigger frames seed more trunks. Once the seeded trunks
        // have all run out of room, any bare stretch left gets a new one,
        // until the whole frame is clad. One window per tick.
        for (self.win_cache[0..self.win_cache_count]) |w| {
            if (!self.canGrow(w.address)) continue;
            const per = perimeterOf(w);
            var want: u32 = 1;
            if (per > 2200.0) want += 1;
            if (per > 3800.0) want += 1;
            if (self.rootOn(w.address, w, want, false)) break;
        }

        // Propagation: a trunk tip that has grown within reach of another
        // (settled) frame steps onto it, rooting exactly at the contact
        // point — if that stretch of frame is still bare. One hop per tick.
        prop: for (self.vines, 0..) |v, i| {
            if (!v.active or v.dying > 0 or v.parent >= 0 or v.halted) continue;
            if (v.dl < 60.0) continue;
            if (!self.canGrow(v.addr)) continue;
            const tip = self.vinePoint(i, v.dl);
            for (self.win_cache[0..self.win_cache_count]) |w| {
                if (w.address == v.addr) continue;
                if (!self.canGrow(w.address)) continue;
                if (rectBorderDist(w, tip) > 16.0) continue;
                const t = arcOffsetOf(w, tip);
                if (self.claimDist(w.address, perimeterOf(w), t, null) < trunk_gap * 2.0) continue;
                self.spawnTrunk(w.address, t, false);
                break :prop;
            }
        }
    }

    /// Root a trunk on `addr` if it wants one and has bare frame for it.
    fn rootOn(self: *Context, addr: u64, rect: WindowRect, want: u32, inward: bool) bool {
        var have: u32 = 0;
        var growing: u32 = 0;
        for (self.vines) |v| {
            if (!v.active or v.dying > 0 or v.parent >= 0 or v.addr != addr) continue;
            have += 1;
            if (!v.halted) growing += 1;
        }
        if (have >= want and growing > 0) return false;
        const gap = self.largestGap(addr, rect);
        if (gap.len < min_root_gap) return false;
        self.spawnTrunk(addr, gap.mid, inward);
        return true;
    }

    fn growVines(self: *Context, dt: f32) void {
        for (self.vines, 0..) |*v, i| {
            if (!v.active) continue;

            const rect_opt = self.vr[i];
            var orphaned = rect_opt == null;
            // Branches die with their trunk. The seed check guards against a
            // recycled slot silently becoming a different parent.
            if (v.parent >= 0 and !v.frozen) {
                const p = &self.vines[@intCast(v.parent)];
                if (!p.active or p.dying > 0 or p.seed != v.parent_seed) orphaned = true;
            }
            if (orphaned and v.dying == 0) {
                // The trellis fell: freeze in place; the dieback front
                // sheds the leaves as it sweeps.
                const rect = rect_opt orelse {
                    v.active = false;
                    continue;
                };
                self.freeze(i, rect);
            }
            if (v.dying > 0) {
                v.dying += dt;
                if (v.dying >= vine_die_secs) v.active = false;
                continue;
            }

            if (v.addr != 1) {
                const k = self.knownFor(v.addr) orelse continue;
                if (!k.present) continue; // dormant
            }
            v.age += dt;
            if (v.halted or !self.canGrow(v.addr)) continue;

            const rect = rect_opt.?;
            // The focused window is the tended plant: it grows faster.
            const cx = rect.x + rect.w * 0.5;
            const cy = rect.y + rect.h * 0.5;
            const is_focused = @abs(cx - self.focused_center[0]) < 40.0 and @abs(cy - self.focused_center[1]) < 40.0;
            const tend: f32 = if (is_focused) 1.8 else 1.0;
            // Silence -> a slow creep; music feeds the garden. Each vine has
            // its own vigor so the canopy fills in unevenly, like a plant.
            const vigor = 0.75 + fhash(v.seed, 0.53) * 0.5;
            self.extend(i, dt * self.growth * tend * vigor * (16.0 + self.music.bands.energy_ema * 40.0));
            if (v.halted) continue;

            // Forking: trunks put out a shoot behind the tip every
            // fork_spacing or so, for as long as they grow; branches fork
            // up to 2 short sub-branches.
            if (v.depth == 0) {
                if (v.dl > v.next_fork) {
                    self.spawnBranch(i, v.next_fork - 30.0 - fhash(v.seed, v.next_fork) * 30.0);
                    v.next_fork += fork_spacing * (0.7 + 0.6 * fhash(v.seed * 1.9, v.next_fork));
                }
            } else if (v.depth == 1 and v.branches < 2) {
                const next = 45.0 + @as(f32, @floatFromInt(v.branches)) * 75.0 + @mod(v.seed * 0.83, 1.0) * 30.0;
                if (v.dl > next) {
                    if (next < v.reach) self.spawnBranch(i, next - 15.0);
                    v.branches += 1;
                }
            }
        }
    }

    /// Lengthen vine `i` by `amount`, halting it for good where it runs
    /// out of room: trunks at another trunk's claim on the frame (or their
    /// own root, fully wrapped), shoots at occupied space or their reach.
    fn extend(self: *Context, i: usize, amount: f32) void {
        const v = &self.vines[i];
        if (v.halted) return;
        const next = v.dl + amount;
        if (v.parent < 0) {
            const rect = self.vr[i].?;
            const per = perimeterOf(rect);
            const tip = v.t0 + v.dir * next;
            if (next >= per - trunk_gap or self.claimDist(v.addr, per, tip, i) < trunk_gap) {
                v.halted = true;
                return;
            }
        } else {
            if (next >= v.reach) {
                v.dl = v.reach;
                v.halted = true;
                return;
            }
            if (!self.spaceFree(self.vinePoint(i, next + 8.0), i)) {
                v.halted = true;
                return;
            }
        }
        v.dl = next;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;
        const r = self.rng.random();

        // ---- audio analysis: real FFT bands, adaptive onset ----
        const beat_hit = self.music.update(dt);

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

        self.resolveFrames();
        self.trackWindows(state, dt);
        self.resolveFrames();

        // ---- vine lifecycle ----
        // Staggered so a new workspace plants over a second or two, not
        // all at once.
        self.spawn_timer -= dt;
        if (self.spawn_timer <= 0) {
            self.spawn_timer = 0.45;
            self.spawnTick();
        }
        self.growVines(dt);

        // ---- beats: a gentle growth nudge, and sometimes a leaf ----
        if (beat_hit) {
            var nudged: u8 = 0;
            var tries: u8 = 0;
            while (nudged < 2 and tries < 16) : (tries += 1) {
                const vi = r.intRangeLessThan(usize, 0, max_vines);
                const v = &self.vines[vi];
                if (!v.active or v.dying > 0 or !self.canGrow(v.addr)) continue;
                self.extend(vi, 4.0);
                nudged += 1;
            }
            if (r.float(f32) < 0.3) {
                tries = 0;
                while (tries < 16) : (tries += 1) {
                    const vi = r.intRangeLessThan(usize, 0, max_vines);
                    const v = &self.vines[vi];
                    if (!v.active or v.dying > 0 or v.dl < 60.0 or self.vr[vi] == null or self.vp[vi] < 0.5) continue;
                    self.shedLeaves(self.vinePoint(vi, (0.3 + r.float(f32) * 0.6) * v.dl), 1);
                    break;
                }
            }
        }

        // ---- falling leaves ----
        for (&self.fall) |*p| {
            if (!p.active) continue;
            p.age += dt;
            if (p.age >= p.life or p.pos[1] < -30.0) {
                p.active = false;
                continue;
            }
            const damp = @exp(-0.8 * dt);
            p.vel[0] *= damp;
            p.vel[1] *= damp;
            p.vel[1] -= 42.0 * dt; // y-up: leaves fall
            p.vel[0] += @sin(clock.phase(self.now, 0.9) + p.pos[1] * 0.012) * 45.0 * dt; // breeze
            // Seesaw: a falling leaf rocks on its air cushion, gliding
            // sideways and briefly catching lift at each swing.
            const rock = @sin(clock.phase(self.now, 2.4) + p.spin * 7.0 + p.pos[0] * 0.01);
            p.vel[0] += rock * 30.0 * dt;
            p.vel[1] += @abs(rock) * 14.0 * dt;
            p.pos[0] += p.vel[0] * dt;
            p.pos[1] += p.vel[1] * dt;
            p.angle += p.spin * dt + rock * 0.8 * dt;
        }

        self.resolveFrames();
        self.buildGeometry(dt);
        self.binPrims();
    }

    fn pushPrim(self: *Context, p: [8]f32) bool {
        if (self.prim_count >= max_prims) return false;
        self.prims[self.prim_count] = p;
        self.prim_count += 1;
        return true;
    }

    /// Emit stems + leaves as prims and rebuild the occupancy grid.
    fn buildGeometry(self: *Context, dt: f32) void {
        // Pipe model inputs: child lists and the stem length each vine
        // carries (its own plus all its descendants').
        @memset(self.first_child, -1);
        for (self.vines, 0..) |v, i| {
            self.sub_len[i] = if (v.active) v.dl else 0;
            if (!v.active or v.parent < 0) continue;
            const pi: usize = @intCast(v.parent);
            self.next_sib[i] = self.first_child[pi];
            self.first_child[pi] = @intCast(i);
        }
        for ([_]u8{ 2, 1 }) |depth| {
            for (self.vines, 0..) |v, i| {
                if (!v.active or v.depth != depth) continue;
                self.sub_len[@intCast(v.parent)] += self.sub_len[i];
            }
        }

        @memset(self.occ, 0);
        for (self.win_cache[0..self.win_cache_count]) |w| self.blockRect(w);

        self.prim_count = 0;
        for (self.vines, 0..) |*v, vi| {
            if (!v.active) continue;
            const pres = self.vp[vi];
            if (pres <= 0.005 or self.vr[vi] == null) continue;
            // Dead spans fade out as the front passes; any residual glow
            // drains at the very end of dieback.
            const end_fade = 1.0 - smoothstep(vine_die_secs - 0.4, vine_die_secs, v.dying);
            if (end_fade <= 0) continue;
            const owner: u16 = @intCast(vi + 1);

            // Stem segments at fixed arc steps; the growing tip glows.
            var s: f32 = 0;
            var a = self.vinePoint(vi, 0);
            while (s < v.dl) : (s += seg_step) {
                const s1 = @min(s + seg_step, v.dl);
                if (s1 - s < 2.0) break;
                const b = self.vinePoint(vi, s1);
                const tip = if (v.halted) 0.0 else smoothstep(v.dl - 70.0, v.dl, s1);
                // Child stems render dimmer, so shoots read as offshoots.
                const gen = 1.0 - 0.16 * @as(f32, @floatFromInt(v.depth));
                const lam = localWilt(v, (s + s1) * 0.5, v.dying);
                // Pipe model: the stem at s carries everything beyond it —
                // its own run to the tip plus every shoot forked past s.
                var load = v.dl - s;
                var ch = self.first_child[vi];
                while (ch >= 0) : (ch = self.next_sib[@intCast(ch)]) {
                    const cv = &self.vines[@intCast(ch)];
                    if (cv.ps >= s) load += self.sub_len[@intCast(ch)];
                }
                const width = @min(0.55 + 0.022 * @sqrt(load), 3.0) + 0.3 * tip;
                const bright = (0.4 + tip * 0.6) * gen * end_fade * (1.0 - lam) * pres;
                _ = self.pushPrim(.{ a[0], a[1], b[0], b[1], bright, width, 0, 0 });
                if (v.dying == 0) {
                    self.stamp(a, owner);
                    self.stamp(.{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 }, owner);
                }
                a = b;
            }
            if (v.dying == 0) self.stamp(a, owner);

            self.emitLeaves(v, vi, pres, end_fade, dt);
        }
    }

    /// Leaf nodes: nominally alternate, but with seeded jitter in spacing,
    /// angle, and size — and the occasional bare node — so the canopy
    /// fills in like a plant, not a rivet line.
    fn emitLeaves(self: *Context, v: *const Vine, vi: usize, pres: f32, end_fade: f32, dt: f32) void {
        var li: u32 = 0;
        var ls: f32 = 22.0;
        while (ls < v.dl) : (ls += leaf_spacing) {
            const fi = @as(f32, @floatFromInt(li));
            li += 1;
            if (fhash(v.seed * 1.7, fi) < 0.16) continue; // bare patch
            const jit = fhash(v.seed, fi);
            const ls_e = std.math.clamp(ls + (jit * 2.0 - 1.0) * 9.0, 2.0, v.dl);
            const p0 = self.vinePoint(vi, ls_e);
            const pa = self.vinePoint(vi, @max(ls_e - 5.0, 0.0));
            const pb = self.vinePoint(vi, ls_e + 5.0);
            const tang = std.math.atan2(pb[1] - pa[1], pb[0] - pa[0]);
            const side: f32 = if (li % 2 == 0) 1.0 else -1.0;
            const lam = localWilt(v, ls_e, v.dying);

            // Turnover: a mature node's leaf lives one seeded cycle, yellows,
            // lets go, and a fresh one grows in its place. Each node's
            // clock starts half a cycle after the tip passed it (estimated
            // at the slowest growth rate, so never early), with a phase
            // offset that can't open mid-senescence.
            var tint: f32 = 0;
            var regrow: f32 = 1;
            var gen_n: f32 = 0;
            var turn_droop: f32 = 0;
            var drop_now = false;
            // `growth` sets the plant's whole pace, leaf lives included.
            const pace = @max(self.growth, 0.05);
            const period = (leaf_cycle_min + fhash(v.seed * 3.1, fi) * leaf_cycle_span) / pace;
            const born = ls_e / (16.0 * 0.75 * pace);
            const lt = v.age - born - period * 0.5;
            if (lt > 0 and v.dying == 0) {
                const off = fhash(v.seed * 5.3, fi) * 0.9;
                const ph = lt / period + off;
                gen_n = @floor(ph);
                const u = ph - gen_n;
                if (u >= 0.985) {
                    // Fallen, and the new bud hasn't broken yet. The frame
                    // it crosses over, the leaf is released into the air.
                    const ph_prev = (lt - dt) / period + off;
                    if (@floor(ph_prev) != gen_n or ph_prev - gen_n >= 0.985) continue;
                    drop_now = true;
                }
                regrow = if (gen_n >= 1) smoothstep(0.0, 0.04, u) else 1.0;
                tint = smoothstep(0.92, 0.975, u);
                turn_droop = tint;
            }

            // A dying (or senescent) leaf stops fluttering with the music.
            const still = @max(lam, turn_droop);
            const flutter = @sin(clock.phase(self.now, 1.6) + ls_e * 0.3 + v.seed) *
                (0.08 + self.music.treble() * 0.12) * (1.0 - still);
            // Each regrown leaf sits a little differently from the last.
            const gen_jit = if (gen_n >= 1) (fhash(v.seed + gen_n * 7.1, fi) - 0.5) * 0.4 else 0.0;
            var angle = tang + side * (0.75 + fhash(v.seed + 3.0, fi) * 0.55) + (jit - 0.5) * 0.5 + flutter + gen_jit;
            const grow_in = smoothstep(0.0, 35.0, v.dl - ls_e);
            // Real ivy: young leaves near the growing tip stay small,
            // older nodes carry big mature leaves.
            const mature = 0.5 + 0.5 * smoothstep(0.0, 140.0, v.dl - ls_e);
            const vary = 0.75 + fhash(v.seed + 7.0 + gen_n, fi) * 0.5;
            const band = self.music.bands.smooth[@as(usize, @intFromFloat(ls_e)) % 6];
            var size = (11.5 + @sin(v.seed * 3.0 + ls_e * 0.7) * 3.5) * vary * mature * grow_in * regrow * (1.0 + band * 0.08) * end_fade;
            if (still > 0) {
                // Wilting: the petiole loses grip, so the blade droops
                // toward hanging and shrivels a little before it lets go.
                const dd = @mod(-std.math.pi * 0.5 - angle + std.math.pi, std.math.tau) - std.math.pi;
                angle += dd * still * 0.7;
                size *= 1.0 - 0.3 * still;
            }
            if (size <= 0.5) continue;
            if (drop_now) {
                if (pres > 0.5) self.dropLeaf(p0, angle, size);
                continue;
            }
            // Dieback: each node lets go once, at its own point in the
            // front's passage — detected as the wilt crossing a per-node
            // threshold between last frame and this one.
            const thr = 0.25 + 0.55 * fhash(v.seed * 2.3, fi);
            if (lam >= thr) {
                const d_prev = v.dying - dt;
                const lam_prev: f32 = if (d_prev <= 0) 0.0 else localWilt(v, ls_e, d_prev);
                if (lam_prev < thr and size > 2.0 and pres > 0.5) self.dropLeaf(p0, angle, size);
                continue;
            }
            const lhash = fhash(v.seed * 0.37 + gen_n, fi * 1.31);
            if (!self.pushPrim(.{ p0[0], p0[1], @mod(angle, std.math.tau), size, pres, tint, lhash, 1 })) return;
        }
    }

    /// Bin prims into screen tiles: count, prefix-sum, fill. A prim that
    /// would overflow the ref budget is dropped whole, never half-binned.
    fn binPrims(self: *Context) void {
        @memset(self.tile_fill, 0);
        const tx_max: i32 = @intCast(self.tiles_x - 1);
        const ty_max: i32 = @intCast(self.tiles_y - 1);
        var total: u32 = 0;
        var usable: u32 = 0;
        for (self.prims[0..self.prim_count]) |p| {
            const box = primTiles(p, tx_max, ty_max) orelse {
                usable += 1;
                continue;
            };
            const n: u32 = @intCast((box[2] - box[0] + 1) * (box[3] - box[1] + 1));
            if (total + n > max_refs) break;
            total += n;
            usable += 1;
            var ty = box[1];
            while (ty <= box[3]) : (ty += 1) {
                var tx = box[0];
                while (tx <= box[2]) : (tx += 1) self.tile_fill[@as(usize, @intCast(ty)) * self.tiles_x + @as(usize, @intCast(tx))] += 1;
            }
        }
        var off: u32 = 0;
        for (self.tile_hdr, self.tile_fill) |*h, *f| {
            h.* = .{ off, 0 };
            off += f.*;
        }
        for (self.prims[0..usable], 0..) |p, pi| {
            const box = primTiles(p, tx_max, ty_max) orelse continue;
            var ty = box[1];
            while (ty <= box[3]) : (ty += 1) {
                var tx = box[0];
                while (tx <= box[2]) : (tx += 1) {
                    const h = &self.tile_hdr[@as(usize, @intCast(ty)) * self.tiles_x + @as(usize, @intCast(tx))];
                    self.refs[h[0] + h[1]] = @intCast(pi);
                    h[1] += 1;
                }
            }
        }
        self.ref_count = total;
    }

    /// Inclusive tile range a prim can light, or null if it's off screen.
    fn primTiles(p: [8]f32, tx_max: i32, ty_max: i32) ?[4]i32 {
        var lo: [2]f32 = undefined;
        var hi: [2]f32 = undefined;
        if (p[7] < 0.5) {
            if (p[4] < 0.01) return null; // dark stem
            lo = .{ @min(p[0], p[2]) - stem_pad, @min(p[1], p[3]) - stem_pad };
            hi = .{ @max(p[0], p[2]) + stem_pad, @max(p[1], p[3]) + stem_pad };
        } else {
            const rr = p[3] * 3.4;
            lo = .{ p[0] - rr, p[1] - rr };
            hi = .{ p[0] + rr, p[1] + rr };
        }
        const x0: i32 = @intFromFloat(@max(@floor(lo[0] / tile_px), -1.0));
        const y0: i32 = @intFromFloat(@max(@floor(lo[1] / tile_px), -1.0));
        const x1: i32 = @intFromFloat(@min(@floor(hi[0] / tile_px), @as(f32, @floatFromInt(tx_max + 1))));
        const y1: i32 = @intFromFloat(@min(@floor(hi[1] / tile_px), @as(f32, @floatFromInt(ty_max + 1))));
        const box = [4]i32{ @max(x0, 0), @max(y0, 0), @min(x1, tx_max), @min(y1, ty_max) };
        if (box[2] < box[0] or box[3] < box[1]) return null;
        return box;
    }

    fn makeTex(tex: *c.GLuint, internal: c.GLint, w: c.GLsizei, h: c.GLsizei, format: c.GLenum, ty: c.GLenum) void {
        c.glGenTextures(1, tex);
        c.glBindTexture(c.GL_TEXTURE_2D, tex.*);
        // Integer and float data textures must be NEAREST to be complete.
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, internal, w, h, 0, format, ty, null);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        if (self.tex_prims == 0) {
            makeTex(&self.tex_prims, c.GL_RGBA32F, prim_tex_w, prim_rows, c.GL_RGBA, c.GL_FLOAT);
            makeTex(&self.tex_tiles, c.GL_RG32UI, @intCast(self.tiles_x), @intCast(self.tiles_y), c.GL_RG_INTEGER, c.GL_UNSIGNED_INT);
            makeTex(&self.tex_refs, c.GL_R32UI, ref_tex_w, ref_rows, c.GL_RED_INTEGER, c.GL_UNSIGNED_INT);
        }

        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex_prims);
        const prow = (self.prim_count * 2 + prim_tex_w - 1) / prim_tex_w;
        if (prow > 0) c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, prim_tex_w, @intCast(prow), c.GL_RGBA, c.GL_FLOAT, @ptrCast(self.prims.ptr));

        c.glActiveTexture(c.GL_TEXTURE1);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex_tiles);
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, @intCast(self.tiles_x), @intCast(self.tiles_y), c.GL_RG_INTEGER, c.GL_UNSIGNED_INT, @ptrCast(self.tile_hdr.ptr));

        c.glActiveTexture(c.GL_TEXTURE2);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex_refs);
        const rrow = (self.ref_count + ref_tex_w - 1) / ref_tex_w;
        if (rrow > 0) c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, ref_tex_w, @intCast(rrow), c.GL_RED_INTEGER, c.GL_UNSIGNED_INT, @ptrCast(self.refs.ptr));
        c.glActiveTexture(c.GL_TEXTURE0);

        self.u.use(prog.program);

        self.u.int(.prims, 0);
        self.u.int(.tiles, 1);
        self.u.int(.refs, 2);
        self.u.int(.tile_px, tile_px);

        if (self.u.loc(.fall) >= 0) {
            // (x, y, angle, size) — a fast attack so a released leaf
            // appears the instant its stem copy vanishes (no blink), then a
            // fade over the last third of its fall.
            var pv: [max_fall][4]f32 = @splat(.{ 0, 0, 0, 0 });
            for (self.fall, 0..) |p, i| {
                if (!p.active) continue;
                const env = @min(p.age * 10.0, 1.0) * (1.0 - smoothstep(p.life * 0.65, p.life, p.age));
                pv[i] = .{ p.pos[0], p.pos[1], @mod(p.angle, std.math.tau), p.size * env };
            }
            self.u.f4v(.fall, max_fall, &pv[0]);
        }

        // Effect-local time (fire.zig pattern) — keeps shader noise
        // coordinates small so f32 precision holds over long sessions.
        self.u.f1(.time, @floatCast(self.now));
        self.u.f1(.bass, self.music.bass());
        self.u.f1(.treble, self.music.treble());
        self.u.f1(.beat, self.music.onset.beat);
        self.u.f1(.bright, self.brightness);
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
        if (self.tex_prims != 0) {
            c.glDeleteTextures(1, &self.tex_prims);
            c.glDeleteTextures(1, &self.tex_tiles);
            c.glDeleteTextures(1, &self.tex_refs);
        }
        self.allocator.free(self.vines);
        self.allocator.free(self.vr);
        self.allocator.free(self.vp);
        self.allocator.free(self.att_pos);
        self.allocator.free(self.att_ang);
        self.allocator.free(self.sub_len);
        self.allocator.free(self.first_child);
        self.allocator.free(self.next_sib);
        self.allocator.free(self.occ);
        self.allocator.free(self.prims);
        self.allocator.free(self.tile_hdr);
        self.allocator.free(self.tile_fill);
        self.allocator.free(self.refs);
    }
};
