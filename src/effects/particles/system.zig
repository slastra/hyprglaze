//! Ball physics: substepped XPBD (Macklin et al., "Small Steps in Physics
//! Simulation", 2019).
//!
//! Each frame is split into `substeps`. A substep integrates external
//! accelerations, projects every contact out of penetration (screen walls,
//! window rects, other balls), derives velocity from the corrected
//! positions, then runs a velocity pass for restitution and friction.
//! Small steps make contacts stable without iterations, and keep a ball
//! from ever moving farther than its radius in one step, so nothing tunnels.
//!
//! Windows are kinematic colliders: infinite mass, their rect interpolated
//! across the frame's substeps, and each point on a rect carrying the
//! velocity of the edges around it. A window moving into a ball pushes it
//! out, and the velocity pass bounces it relative to the window — a moving
//! window bats balls, a resting one is a wall. Contacts use the rect's
//! signed distance, so corners are rounded and glancing hits deflect
//! diagonally.

const std = @import("std");

/// Size of the shared `iParticles` uniform array (core/shader.zig).
pub const max_particles = 300;
pub const max_balls = 150;
pub const max_pops = 8;
pub const max_colliders = 32;

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Ball = struct {
    x: [2]f32,
    v: [2]f32,
    r: f32,
    inv_mass: f32,
    color: f32,
};

/// A burst, drawn as an expanding ring while `age` < 1.
pub const Pop = struct {
    x: [2]f32 = .{ 0, 0 },
    r: f32 = 0,
    color: f32 = 0,
    age: f32 = 1,
};

/// A window as the solver sees it: its rect at the start and end of the
/// frame. `moving` false means its displacement is not its own (a
/// workspace slide's camera, or the frame it appeared): it still blocks,
/// but imparts no velocity.
pub const Collider = struct {
    from: Rect,
    to: Rect,
    moving: bool,
};

pub const Params = struct {
    substeps: u32 = 8,
    /// Inverse-square pull toward the focused window's centre:
    /// a = well / (d^2 + softening^2).
    well: f32 = 9.0e7,
    well_softening: f32 = 80.0,
    /// Cursor push, same law, within `cursor_radius`.
    cursor: f32 = 6.0e7,
    cursor_radius: f32 = 400.0,
    /// Linear air drag, 1/s.
    drag: f32 = 0.03,
    restitution: f32 = 0.55,
    wall_restitution: f32 = 0.45,
    friction: f32 = 0.15,
    /// Approach speeds below this rest instead of bouncing, so balls
    /// settled against a frame don't buzz.
    rest_speed: f32 = 40.0,
    /// Ball-ball impacts faster than this (px/s) burst the smaller ball.
    pop_speed: f32 = 1500.0,
    /// Box2D's maxLinearCorrection: the most a contact may push a ball per
    /// substep. A window that opens on top of balls slides them out over a
    /// few frames instead of teleporting them.
    max_correction: f32 = 4.0,
    max_speed: f32 = 4000.0,
};

const Contact = struct {
    a: u16,
    /// Other ball, or none for a wall/window.
    b: ?u16,
    n: [2]f32, // unit, pointing toward `a`
    /// Obstacle velocity at the contact point (walls/windows).
    wall_v: [2]f32,
    /// The contact began this substep. Only a beginning contact bounces
    /// (or pops): a sustained one just transmits force, so a window
    /// pressing into a pile moves it instead of pumping energy into it.
    fresh: bool,
};

const max_contacts = 4096;

// Contact persistence, one bit per (ball, obstacle) and (ball, ball),
// double-buffered across substeps. Obstacles: the 4 screen walls, then
// colliders by index.
const pair_words = (max_balls + 63) / 64;
const Touching = struct {
    obstacle: [max_balls]u64 = @splat(0),
    pair: [max_balls][pair_words]u64 = @splat(@splat(0)),
};

pub const ParticleSystem = struct {
    balls: [max_balls]Ball = undefined,
    count: u32,
    width: f32,
    height: f32,
    params: Params = .{},
    pops: [max_pops]Pop = @splat(.{}),
    next_pop: u8 = 0,
    rng: std.Random.DefaultPrng,

    contacts: [max_contacts]Contact = undefined,
    contact_count: usize = 0,
    touch: [2]Touching = .{ .{}, .{} },
    touch_cur: u1 = 0,
    // Velocity before the position pass, per ball, for restitution.
    v_pre: [max_balls][2]f32 = undefined,

    pub fn init(count: u32, width: f32, height: f32) ParticleSystem {
        var sys = ParticleSystem{
            .count = @min(count, max_balls),
            .width = width,
            .height = height,
            .rng = std.Random.DefaultPrng.init(0xDEADBEEF),
        };
        const rand = sys.rng.random();
        for (0..sys.count) |i| {
            const r = 6.0 + rand.float(f32) * 8.0;
            sys.balls[i] = .{
                .x = .{ rand.float(f32) * width, rand.float(f32) * height },
                .v = .{ (rand.float(f32) - 0.5) * 120.0, (rand.float(f32) - 0.5) * 120.0 },
                .r = r,
                .inv_mass = 1.0 / (r * r),
                .color = rand.float(f32),
            };
        }
        return sys;
    }

    /// Advance one frame of `dt` seconds.
    pub fn step(
        self: *ParticleSystem,
        dt: f32,
        well_center: ?[2]f32,
        cursor: [2]f32,
        colliders: []const Collider,
    ) void {
        if (dt <= 0) return;
        const n: u32 = @max(self.params.substeps, 1);
        const h = dt / @as(f32, @floatFromInt(n));
        const ncol = @min(colliders.len, max_colliders);

        for (&self.pops) |*p| {
            if (p.age < 1) p.age = @min(p.age + dt / 0.35, 1);
        }

        for (0..n) |s| {
            const t1 = @as(f32, @floatFromInt(s + 1)) / @as(f32, @floatFromInt(n));

            // ---- integrate external accelerations ----
            const decay = @exp(-self.params.drag * h);
            var prev: [max_balls][2]f32 = undefined;
            for (self.balls[0..self.count], 0..) |*b, i| {
                const a = self.acceleration(b.x, well_center, cursor);
                b.v[0] = (b.v[0] + a[0] * h) * decay;
                b.v[1] = (b.v[1] + a[1] * h) * decay;
                self.v_pre[i] = b.v;
                prev[i] = b.x;
                b.x[0] += b.v[0] * h;
                b.x[1] += b.v[1] * h;
            }

            // ---- position pass: project contacts ----
            self.contact_count = 0;
            self.touch_cur ^= 1;
            self.touch[self.touch_cur] = .{};
            for (self.balls[0..self.count], 0..) |*b, i| {
                self.solveWalls(b, @intCast(i));
                for (colliders[0..ncol], 0..) |col, k| self.solveWindow(b, @intCast(i), @intCast(4 + k), col, t1, dt, h);
            }
            self.solvePairs();

            // ---- velocities from positions, then the velocity pass ----
            for (self.balls[0..self.count], 0..) |*b, i| {
                b.v = .{ (b.x[0] - prev[i][0]) / h, (b.x[1] - prev[i][1]) / h };
            }
            self.velocityPass(h);

            for (self.balls[0..self.count]) |*b| {
                const sp = @sqrt(b.v[0] * b.v[0] + b.v[1] * b.v[1]);
                if (sp > self.params.max_speed) {
                    const k = self.params.max_speed / sp;
                    b.v = .{ b.v[0] * k, b.v[1] * k };
                }
            }
        }
    }

    fn acceleration(self: *const ParticleSystem, x: [2]f32, well_center: ?[2]f32, cursor: [2]f32) [2]f32 {
        var a: [2]f32 = .{ 0, 0 };
        if (well_center) |c| {
            const dx = c[0] - x[0];
            const dy = c[1] - x[1];
            const d2 = dx * dx + dy * dy;
            const d = @sqrt(d2) + 1e-3;
            const s = self.params.well_softening;
            const mag = self.params.well / (d2 + s * s);
            a[0] += dx / d * mag;
            a[1] += dy / d * mag;
        }
        const cx = x[0] - cursor[0];
        const cy = x[1] - cursor[1];
        const c2 = cx * cx + cy * cy;
        if (c2 < self.params.cursor_radius * self.params.cursor_radius) {
            const d = @sqrt(c2) + 1e-3;
            const fade = 1.0 - d / self.params.cursor_radius;
            const mag = self.params.cursor / (c2 + 2500.0) * fade;
            a[0] += cx / d * mag;
            a[1] += cy / d * mag;
        }
        return a;
    }

    fn addContact(self: *ParticleSystem, c: Contact) void {
        if (self.contact_count >= max_contacts) return;
        self.contacts[self.contact_count] = c;
        self.contact_count += 1;
    }

    /// Mark ball `a` touching obstacle `ob` this substep; true if it was
    /// not touching it the substep before.
    fn touchObstacle(self: *ParticleSystem, a: u16, ob: u6) bool {
        const bit = @as(u64, 1) << ob;
        self.touch[self.touch_cur].obstacle[a] |= bit;
        return self.touch[self.touch_cur ^ 1].obstacle[a] & bit == 0;
    }

    fn touchPair(self: *ParticleSystem, a: u16, b: u16) bool {
        const w = b / 64;
        const bit = @as(u64, 1) << @intCast(b % 64);
        self.touch[self.touch_cur].pair[a][w] |= bit;
        return self.touch[self.touch_cur ^ 1].pair[a][w] & bit == 0;
    }

    fn wallContact(self: *ParticleSystem, i: u16, ob: u6, n: [2]f32) void {
        self.addContact(.{ .a = i, .b = null, .n = n, .wall_v = .{ 0, 0 }, .fresh = self.touchObstacle(i, ob) });
    }

    fn solveWalls(self: *ParticleSystem, b: *Ball, i: u16) void {
        const r = b.r;
        if (b.x[0] < r) {
            b.x[0] = r;
            self.wallContact(i, 0, .{ 1, 0 });
        } else if (b.x[0] > self.width - r) {
            b.x[0] = self.width - r;
            self.wallContact(i, 1, .{ -1, 0 });
        }
        if (b.x[1] < r) {
            b.x[1] = r;
            self.wallContact(i, 2, .{ 0, 1 });
        } else if (b.x[1] > self.height - r) {
            b.x[1] = self.height - r;
            self.wallContact(i, 3, .{ 0, -1 });
        }
    }

    /// Ball against a window's rect at substep fraction `t`: signed
    /// distance to the box, pushed out along its gradient.
    fn solveWindow(self: *ParticleSystem, b: *Ball, i: u16, ob: u6, col: Collider, t: f32, dt: f32, h: f32) void {
        const rect = lerpRect(col.from, col.to, t);
        if (rect.w < 1 or rect.h < 1) return;
        const hx = rect.w * 0.5;
        const hy = rect.h * 0.5;
        const px = b.x[0] - (rect.x + hx);
        const py = b.x[1] - (rect.y + hy);
        const qx = @abs(px) - hx;
        const qy = @abs(py) - hy;
        // Cheap reject before the square root.
        if (qx > b.r or qy > b.r) return;

        var dist: f32 = undefined;
        var nrm: [2]f32 = undefined;
        if (qx > 0 and qy > 0) {
            // Outside a corner: the rounded part of the expanded box.
            dist = @sqrt(qx * qx + qy * qy);
            if (dist >= b.r) return;
            nrm = .{ sgn(px) * qx / dist, sgn(py) * qy / dist };
        } else if (qx > qy) {
            dist = qx; // beside (or inside, nearest) a vertical edge
            nrm = .{ sgn(px), 0 };
        } else {
            dist = qy;
            nrm = .{ 0, sgn(py) };
        }
        const depth = b.r - dist;
        if (depth <= 0) return;

        // Velocity of the rect at the contact point: each coordinate
        // interpolates between the velocities of the two edges bounding it.
        var wv: [2]f32 = .{ 0, 0 };
        if (col.moving and dt > 0) {
            const u = std.math.clamp((b.x[0] - rect.x) / rect.w, 0.0, 1.0);
            const v = std.math.clamp((b.x[1] - rect.y) / rect.h, 0.0, 1.0);
            const vl = (col.to.x - col.from.x) / dt;
            const vr = ((col.to.x + col.to.w) - (col.from.x + col.from.w)) / dt;
            const vb = (col.to.y - col.from.y) / dt;
            const vt = ((col.to.y + col.to.h) - (col.from.y + col.from.h)) / dt;
            wv = .{ vl + (vr - vl) * u, vb + (vt - vb) * v };
        }

        // The correction cap is for overlap that was already there (a
        // window opening on a ball). An edge advancing into the ball may
        // always push it the full distance it advanced this substep, or a
        // fast window would overtake the ball and drag it along inside.
        const advance = @max(wv[0] * nrm[0] + wv[1] * nrm[1], 0) * h;
        const push = @min(depth, self.params.max_correction + advance);
        b.x[0] += nrm[0] * push;
        b.x[1] += nrm[1] * push;
        self.addContact(.{ .a = i, .b = null, .n = nrm, .wall_v = wv, .fresh = self.touchObstacle(i, ob) });
    }

    fn solvePairs(self: *ParticleSystem) void {
        var i: u16 = 0;
        while (i < self.count) : (i += 1) {
            var j: u16 = i + 1;
            while (j < self.count) : (j += 1) {
                const a = &self.balls[i];
                const b = &self.balls[j];
                const dx = a.x[0] - b.x[0];
                const dy = a.x[1] - b.x[1];
                const rr = a.r + b.r;
                if (@abs(dx) >= rr or @abs(dy) >= rr) continue;
                const d2 = dx * dx + dy * dy;
                if (d2 >= rr * rr) continue;
                const d = @sqrt(d2);
                const nrm: [2]f32 = if (d > 1e-4) .{ dx / d, dy / d } else .{ 1, 0 };
                const depth = @min(rr - d, self.params.max_correction);
                const wsum = a.inv_mass + b.inv_mass;
                const ka = depth * a.inv_mass / wsum;
                const kb = depth * b.inv_mass / wsum;
                a.x[0] += nrm[0] * ka;
                a.x[1] += nrm[1] * ka;
                b.x[0] -= nrm[0] * kb;
                b.x[1] -= nrm[1] * kb;
                self.addContact(.{ .a = i, .b = j, .n = nrm, .wall_v = .{ 0, 0 }, .fresh = self.touchPair(i, j) });
            }
        }
    }

    /// Restitution and friction on this substep's contacts, relative to
    /// whatever the ball touched. Also where ball-ball impacts pop.
    fn velocityPass(self: *ParticleSystem, h: f32) void {
        _ = h;
        const p = self.params;
        for (self.contacts[0..self.contact_count]) |ct| {
            const a = &self.balls[ct.a];
            const n = ct.n;
            if (ct.b) |bi| {
                const b = &self.balls[bi];
                const vrel = .{ a.v[0] - b.v[0], a.v[1] - b.v[1] };
                const vn = vrel[0] * n[0] + vrel[1] * n[1];
                const pre = self.v_pre[ct.a];
                const pre_b = self.v_pre[bi];
                const vn_pre = (pre[0] - pre_b[0]) * n[0] + (pre[1] - pre_b[1]) * n[1];
                if (ct.fresh and -vn_pre > p.pop_speed) {
                    self.pop(if (a.r <= b.r) ct.a else bi, -vn_pre);
                    continue;
                }
                const target: f32 = if (ct.fresh and -vn_pre > p.rest_speed) -p.restitution * vn_pre else 0;
                const dvn = target - vn;
                const wsum = a.inv_mass + b.inv_mass;
                var dv = .{ n[0] * dvn, n[1] * dvn };
                // Coulomb-style friction, bounded by the normal change.
                const vt = .{ vrel[0] - n[0] * vn, vrel[1] - n[1] * vn };
                const vtl = @sqrt(vt[0] * vt[0] + vt[1] * vt[1]);
                if (vtl > 1e-3) {
                    const k = @min(p.friction * @abs(dvn), vtl) / vtl;
                    dv[0] -= vt[0] * k;
                    dv[1] -= vt[1] * k;
                }
                a.v[0] += dv[0] * a.inv_mass / wsum;
                a.v[1] += dv[1] * a.inv_mass / wsum;
                b.v[0] -= dv[0] * b.inv_mass / wsum;
                b.v[1] -= dv[1] * b.inv_mass / wsum;
            } else {
                const wv = ct.wall_v;
                const vrel = .{ a.v[0] - wv[0], a.v[1] - wv[1] };
                const vn = vrel[0] * n[0] + vrel[1] * n[1];
                const pre = self.v_pre[ct.a];
                const vn_pre = (pre[0] - wv[0]) * n[0] + (pre[1] - wv[1]) * n[1];
                const target: f32 = if (ct.fresh and -vn_pre > p.rest_speed) -p.wall_restitution * vn_pre else 0;
                // Never pull a ball back into the obstacle.
                const dvn = @max(target - vn, -vn);
                var dv = .{ n[0] * dvn, n[1] * dvn };
                const vt = .{ vrel[0] - n[0] * vn, vrel[1] - n[1] * vn };
                const vtl = @sqrt(vt[0] * vt[0] + vt[1] * vt[1]);
                if (vtl > 1e-3) {
                    const k = @min(p.friction * @abs(dvn), vtl) / vtl;
                    dv[0] -= vt[0] * k;
                    dv[1] -= vt[1] * k;
                }
                a.v[0] += dv[0];
                a.v[1] += dv[1];
            }
        }
    }

    /// Burst ball `i`: a ring where it was, a blast on its neighbours, and
    /// the ball reborn at a screen edge clear of windows.
    fn pop(self: *ParticleSystem, i: u16, impact: f32) void {
        const b = &self.balls[i];
        self.pops[self.next_pop] = .{ .x = b.x, .r = b.r, .color = b.color, .age = 0 };
        self.next_pop = (self.next_pop + 1) % max_pops;

        const blast_radius: f32 = 150.0;
        const strength = impact * 0.6;
        for (self.balls[0..self.count], 0..) |*o, k| {
            if (k == i) continue;
            const dx = o.x[0] - b.x[0];
            const dy = o.x[1] - b.x[1];
            const d2 = dx * dx + dy * dy;
            if (d2 > blast_radius * blast_radius) continue;
            const d = @sqrt(d2) + 1.0;
            const push = strength * (1.0 - d / blast_radius);
            o.v[0] += dx / d * push;
            o.v[1] += dy / d * push;
        }

        const rand = self.rng.random();
        b.r = 6.0 + rand.float(f32) * 8.0;
        b.inv_mass = 1.0 / (b.r * b.r);
        b.color = rand.float(f32);
        b.v = .{ 0, 0 };
        switch (rand.intRangeAtMost(u8, 0, 3)) {
            0 => b.x = .{ b.r, rand.float(f32) * self.height },
            1 => b.x = .{ self.width - b.r, rand.float(f32) * self.height },
            2 => b.x = .{ rand.float(f32) * self.width, b.r },
            else => b.x = .{ rand.float(f32) * self.width, self.height - b.r },
        }
    }
};

/// Sign that never returns 0, so a ball dead centre in a rect still has a
/// way out.
fn sgn(x: f32) f32 {
    return if (x < 0) -1.0 else 1.0;
}

fn lerpRect(a: Rect, b: Rect, t: f32) Rect {
    return .{
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
        .w = a.w + (b.w - a.w) * t,
        .h = a.h + (b.h - a.h) * t,
    };
}

// --- Tests ---

fn oneBall(x: [2]f32, v: [2]f32) ParticleSystem {
    var sys = ParticleSystem.init(0, 1000, 1000);
    sys.count = 1;
    sys.balls[0] = .{ .x = x, .v = v, .r = 10, .inv_mass = 0.01, .color = 0 };
    sys.params.drag = 0;
    sys.params.cursor = 0;
    return sys;
}

const far_cursor = [2]f32{ -1e6, -1e6 };

test "a fast ball bounces off a window instead of tunnelling through it" {
    var sys = oneBall(.{ 100, 500 }, .{ 3000, 0 });
    const win = Rect{ .x = 300, .y = 300, .w = 60, .h = 400 };
    const cols = [_]Collider{.{ .from = win, .to = win, .moving = false }};
    // 200px to the window at 3000px/s: hit within 4 frames, then away.
    for (0..8) |_| sys.step(1.0 / 60.0, null, far_cursor, &cols);
    try std.testing.expect(sys.balls[0].x[0] < 300);
    try std.testing.expect(sys.balls[0].v[0] < 0);
}

test "a ball rests on a window edge by its radius, not its centre" {
    var sys = oneBall(.{ 500, 250 }, .{ 0, 0 });
    const win = Rect{ .x = 300, .y = 300, .w = 400, .h = 300 };
    const cols = [_]Collider{.{ .from = win, .to = win, .moving = false }};
    // Pull toward the window's centre, so the ball comes to rest on its
    // bottom edge (y-up: the edge at y=300).
    for (0..600) |_| sys.step(1.0 / 60.0, .{ 500, 450 }, far_cursor, &cols);
    try std.testing.expectApproxEqAbs(@as(f32, 290), sys.balls[0].x[1], 0.5);
    try std.testing.expect(@abs(sys.balls[0].v[1]) < 5);
}

test "a moving window bats a resting ball" {
    var sys = oneBall(.{ 290, 500 }, .{ 0, 0 });
    const a = Rect{ .x = 300, .y = 300, .w = 200, .h = 400 };
    const b = Rect{ .x = 280, .y = 300, .w = 200, .h = 400 };
    const cols = [_]Collider{.{ .from = a, .to = b, .moving = true }};
    sys.step(1.0 / 60.0, null, far_cursor, &cols);
    // Window moving left at 1200px/s: the ball leaves faster than it.
    try std.testing.expect(sys.balls[0].v[0] < -1200);
    try std.testing.expect(sys.balls[0].x[0] <= 270.5);
}

test "a window opening on a ball slides it out, never teleports it" {
    var sys = oneBall(.{ 500, 500 }, .{ 0, 0 });
    const win = Rect{ .x = 300, .y = 300, .w = 400, .h = 400 };
    const cols = [_]Collider{.{ .from = win, .to = win, .moving = false }};
    sys.step(1.0 / 60.0, null, far_cursor, &cols);
    const moved = @abs(sys.balls[0].x[0] - 500) + @abs(sys.balls[0].x[1] - 500);
    try std.testing.expect(moved <= sys.params.max_correction * 8 + 0.01);
    for (0..240) |_| sys.step(1.0 / 60.0, null, far_cursor, &cols);
    const b = sys.balls[0];
    const outside = b.x[0] <= 290.5 or b.x[0] >= 709.5 or b.x[1] <= 290.5 or b.x[1] >= 709.5;
    try std.testing.expect(outside);
}

test "a fast window pushes a ball ahead of it, never engulfs it" {
    var sys = oneBall(.{ 500, 500 }, .{ 0, 0 });
    // An edge sweeping right at 4800px/s (10px per substep) into a ball
    // whose own speed is capped well below that: only the edge's push can
    // keep it in front.
    sys.params.max_speed = 1000;
    // Five frames: the edge ends at 880, short of the screen's right wall.
    var x: f32 = 180;
    var worst: f32 = 0;
    for (0..5) |_| {
        const from = Rect{ .x = x, .y = 300, .w = 300, .h = 400 };
        x += 80;
        const to = Rect{ .x = x, .y = 300, .w = 300, .h = 400 };
        const cols = [_]Collider{.{ .from = from, .to = to, .moving = true }};
        sys.step(1.0 / 60.0, null, far_cursor, &cols);
        // Penetration past the window's right edge (ball's left side).
        worst = @max(worst, (x + 300) - (sys.balls[0].x[0] - 10));
    }
    try std.testing.expect(worst < 6);
}

test "a hard ball-ball impact pops the smaller ball" {
    var sys = ParticleSystem.init(0, 1000, 1000);
    sys.params.drag = 0;
    sys.params.cursor = 0;
    sys.count = 2;
    sys.balls[0] = .{ .x = .{ 400, 500 }, .v = .{ 2000, 0 }, .r = 6, .inv_mass = 1.0 / 36.0, .color = 0 };
    sys.balls[1] = .{ .x = .{ 460, 500 }, .v = .{ -2000, 0 }, .r = 12, .inv_mass = 1.0 / 144.0, .color = 0 };
    for (0..6) |_| sys.step(1.0 / 60.0, null, far_cursor, &.{});
    var popped = false;
    for (sys.pops) |p| popped = popped or p.age < 1;
    try std.testing.expect(popped);
}
