const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const transition_mod = @import("../core/transition.zig");
const effects = @import("../effects.zig");

pub const max_particles = 300;

pub const Particle = struct {
    x: f32,
    y: f32,
    prev_x: f32,
    prev_y: f32,
    size: f32,
    color_idx: f32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const ParticleSystem = struct {
    particles: [max_particles]Particle = undefined,
    count: u32,
    width: f32,
    height: f32,

    // Forces
    gravity_y: f32 = 0.0,
    damping: f32 = 0.999,
    cursor_strength: f32 = 200.0,
    cursor_radius: f32 = 300.0,
    bounce_restitution: f32 = 0.5,
    pop_threshold: f32 = 50.0, // velocity at which particles pop on collision

    pub fn init(count: u32, width: f32, height: f32) ParticleSystem {
        var sys = ParticleSystem{
            .count = @min(count, max_particles),
            .width = width,
            .height = height,
        };

        // Seed particles with deterministic random positions + small initial velocity
        var rng = std.Random.DefaultPrng.init(0xDEADBEEF);
        const rand = rng.random();

        for (0..sys.count) |i| {
            const x = rand.float(f32) * width;
            const y = rand.float(f32) * height;
            const vx = (rand.float(f32) - 0.5) * 2.0;
            const vy = (rand.float(f32) - 0.5) * 2.0;

            sys.particles[i] = .{
                .x = x,
                .y = y,
                .prev_x = x - vx,
                .prev_y = y - vy,
                .size = 30.0 + rand.float(f32) * 30.0,
                .color_idx = rand.float(f32),
            };
        }

        return sys;
    }

    pub fn update(
        self: *ParticleSystem,
        dt: f32,
        mouse_x: f32,
        mouse_y: f32,
        windows: []const Rect,
    ) void {
        const step = @min(dt, 0.033);

        // --- Particle-particle collision (circle-circle) ---
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            var j: u32 = i + 1;
            while (j < self.count) : (j += 1) {
                const a = &self.particles[i];
                const b = &self.particles[j];
                const dx = b.x - a.x;
                const dy = b.y - a.y;
                const min_dist = a.size + b.size;

                // Quick rejection
                if (@abs(dx) > min_dist or @abs(dy) > min_dist) continue;

                const dist_sq = dx * dx + dy * dy;
                if (dist_sq >= min_dist * min_dist or dist_sq < 0.01) continue;

                const dist = @sqrt(dist_sq);
                const overlap = min_dist - dist;
                const nx = dx / dist;
                const ny = dy / dist;

                // Relative velocity along collision normal
                const va_x = a.x - a.prev_x;
                const va_y = a.y - a.prev_y;
                const vb_x = b.x - b.prev_x;
                const vb_y = b.y - b.prev_y;
                const rel_v = (vb_x - va_x) * nx + (vb_y - va_y) * ny;
                const impact_speed = @abs(rel_v);

                // Pop if impact too hard
                if (impact_speed > self.pop_threshold) {
                    // Pop the smaller particle, blast the other away
                    const blast: f32 = impact_speed * 2.0;
                    if (a.size <= b.size) {
                        // Push all nearby particles away from pop site
                        self.blastFrom(a.x, a.y, blast, i);
                        self.respawn(a);
                    } else {
                        self.blastFrom(b.x, b.y, blast, j);
                        self.respawn(b);
                    }
                    continue;
                }

                // Separate: push apart by half overlap each
                const sep = overlap * 0.5;
                a.x -= nx * sep;
                a.y -= ny * sep;
                b.x += nx * sep;
                b.y += ny * sep;

                // Bounce: reflect velocity along normal
                if (rel_v < 0) { // approaching
                    const impulse = rel_v * self.bounce_restitution;
                    a.prev_x -= nx * impulse;
                    a.prev_y -= ny * impulse;
                    b.prev_x += nx * impulse;
                    b.prev_y += ny * impulse;
                }
            }
        }

        // --- Per-particle forces + integration ---
        for (0..self.count) |pi| {
            var p = &self.particles[pi];

            // Verlet velocity
            var vx = (p.x - p.prev_x) * self.damping;
            var vy = (p.y - p.prev_y) * self.damping;

            // Gravity (negative = down in GL coords where Y=0 is bottom)
            vy += self.gravity_y * step;

            // Cursor attraction (inverse square)
            const cdx = mouse_x - p.x;
            const cdy = mouse_y - p.y;
            const cdist_sq = cdx * cdx + cdy * cdy;
            const cdist = @sqrt(cdist_sq + 1.0);

            if (cdist < self.cursor_radius) {
                const force = self.cursor_strength / (cdist_sq + 500.0);
                vx += cdx / cdist * force;
                vy += cdy / cdist * force;
            }

            // No ambient drift — window forces drive all motion

            // Integrate
            p.prev_x = p.x;
            p.prev_y = p.y;
            p.x += vx;
            p.y += vy;

            // Bounce off screen edges
            if (p.x < 0) {
                p.x = -p.x;
                p.prev_x = p.x + vx * self.bounce_restitution;
            } else if (p.x > self.width) {
                p.x = 2.0 * self.width - p.x;
                p.prev_x = p.x + vx * self.bounce_restitution;
            }
            if (p.y < 0) {
                p.y = -p.y;
                p.prev_y = p.y + vy * self.bounce_restitution;
            } else if (p.y > self.height) {
                p.y = 2.0 * self.height - p.y;
                p.prev_y = p.y + vy * self.bounce_restitution;
            }

            // Bounce off windows
            for (windows) |win| {
                if (win.w < 1 or win.h < 1) continue;
                self.bounceOffRect(p, win);
            }
        }
    }

    fn blastFrom(self: *ParticleSystem, bx: f32, by: f32, strength: f32, skip_idx: u32) void {
        const blast_radius: f32 = 150.0;
        for (0..self.count) |k| {
            if (k == skip_idx) continue;
            const p = &self.particles[k];
            const dx = p.x - bx;
            const dy = p.y - by;
            const dist_sq = dx * dx + dy * dy;
            if (dist_sq > blast_radius * blast_radius) continue;
            const dist = @sqrt(dist_sq + 1.0);
            const falloff = 1.0 - dist / blast_radius;
            const push = strength * falloff;
            p.prev_x -= dx / dist * push;
            p.prev_y -= dy / dist * push;
        }
    }

    fn respawn(self: *ParticleSystem, p: *Particle) void {
        // Respawn at a random edge position with low velocity
        // Use current position as seed for deterministic-ish randomness
        const seed = @as(u64, @bitCast(@as(i64, @intFromFloat(p.x * 1000.0 + p.y))));
        var rng = std.Random.DefaultPrng.init(seed);
        const rand = rng.random();

        const edge = rand.intRangeAtMost(u8, 0, 3);
        switch (edge) {
            0 => { p.x = 0; p.y = rand.float(f32) * self.height; },         // left
            1 => { p.x = self.width; p.y = rand.float(f32) * self.height; }, // right
            2 => { p.x = rand.float(f32) * self.width; p.y = 0; },          // bottom
            else => { p.x = rand.float(f32) * self.width; p.y = self.height; }, // top
        }
        p.prev_x = p.x;
        p.prev_y = p.y;
        p.size = 30.0 + rand.float(f32) * 30.0;
    }

    fn bounceOffRect(self: *ParticleSystem, p: *Particle, win: Rect) void {
        const wl = win.x;
        const wr = win.x + win.w;
        const wb = win.y;
        const wt = win.y + win.h;

        if (p.x < wl or p.x > wr or p.y < wb or p.y > wt) return;

        const dl = p.x - wl;
        const dr = wr - p.x;
        const db = p.y - wb;
        const dt2 = wt - p.y;
        const min_d = @min(@min(dl, dr), @min(db, dt2));

        const vx = p.x - p.prev_x;
        const vy = p.y - p.prev_y;
        const rest = self.bounce_restitution;

        if (min_d == dl) {
            p.x = wl - dl;
            p.prev_x = p.x + @abs(vx) * rest;
        } else if (min_d == dr) {
            p.x = wr + dr;
            p.prev_x = p.x - @abs(vx) * rest;
        } else if (min_d == db) {
            p.y = wb - db;
            p.prev_y = p.y + @abs(vy) * rest;
        } else {
            p.y = wt + dt2;
            p.prev_y = p.y - @abs(vy) * rest;
        }
    }
};

// --- Effect Context ---

pub const Context = struct {
    sys: ParticleSystem,
    accumulator: f32 = 0,
    physics_dt: f32 = 4.0 / 120.0,

    const config_mod = @import("../core/config.zig");

    pub fn init(_: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) Context {
        const count: u32 = @intCast(params.getInt("count", 40));
        var sys = ParticleSystem.init(count, width, height);
        sys.damping = params.getFloat("damping", 0.999);
        sys.pop_threshold = params.getFloat("pop_threshold", 50.0);
        return .{ .sys = sys };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        // Focused window gravity (inverse square)
        const fw = state.focused_win;
        if (fw.w > 0 and fw.h > 0) {
            const cx = fw.x + fw.w * 0.5;
            const cy = fw.y + fw.h * 0.5;
            for (0..self.sys.count) |i| {
                const p = &self.sys.particles[i];
                const dx = cx - p.x;
                const dy = cy - p.y;
                const dist_sq = dx * dx + dy * dy;
                const dist = @sqrt(dist_sq + 1.0);
                const force: f32 = 120000.0 / (dist_sq + 1500.0);
                p.prev_x += -dx / dist * force * 0.016;
                p.prev_y += -dy / dist * force * 0.016;
            }
        }

        // Fixed timestep physics
        self.accumulator += @min(state.dt, 0.05);
        while (self.accumulator >= self.physics_dt) {
            self.sys.update(
                self.physics_dt,
                state.cursor[0],
                state.cursor[1],
                state.collision_rects,
            );
            self.accumulator -= self.physics_dt;
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        prog.setParticles(&self.sys);
    }

    pub fn deinit(_: *Context) void {}
};
