const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const transition_mod = @import("../../core/transition.zig");
const effects = @import("../../effects.zig");
const system = @import("system.zig");

const c = @cImport({ @cInclude("GLES3/gl3.h"); });

const TRAIL_LEN = 4;
const TRAIL_HISTORY = 20; // frames stored per particle
const SLOTS_PER = TRAIL_LEN + 1; // head + trail dots
const MAX_TRAIL_PARTICLES = 300 / SLOTS_PER; // 60

pub const Context = struct {
    sys: system.ParticleSystem,
    accumulator: f32 = 0,
    physics_dt: f32 = 4.0 / 120.0,

    // Position history ring buffer
    history: [system.max_particles][TRAIL_HISTORY][2]f32 = undefined,
    history_idx: u32 = 0,
    frame_count: u32 = 0,

    pub fn init(_: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) Context {
        var count: u32 = @intCast(params.getInt("count", 60));
        count = @min(count, MAX_TRAIL_PARTICLES);
        var sys = system.ParticleSystem.init(count, width, height);
        sys.damping = params.getFloat("damping", 0.999);
        sys.pop_threshold = params.getFloat("pop_threshold", 50.0);

        var ctx = Context{ .sys = sys };

        // Seed history with initial positions
        for (0..count) |i| {
            for (0..TRAIL_HISTORY) |h| {
                ctx.history[i][h] = .{ sys.particles[i].x, sys.particles[i].y };
            }
        }

        return ctx;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);

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
                p.prev_x += -dx / dist * force * dt;
                p.prev_y += -dy / dist * force * dt;
            }
        }

        // Soft window repulsion
        for (state.collision_rects) |win| {
            if (win.w < 1 or win.h < 1) continue;
            for (0..self.sys.count) |i| {
                const p = &self.sys.particles[i];
                if (p.x < win.x or p.x > win.x + win.w or
                    p.y < win.y or p.y > win.y + win.h) continue;
                const dl = p.x - win.x;
                const dr = win.x + win.w - p.x;
                const db = p.y - win.y;
                const dt2 = win.y + win.h - p.y;
                const min_d = @min(@min(dl, dr), @min(db, dt2));
                const push: f32 = (min_d + 5.0) * 3.0 * dt;
                if (min_d == dl) { p.x -= push; p.prev_x -= push; }
                else if (min_d == dr) { p.x += push; p.prev_x += push; }
                else if (min_d == db) { p.y -= push; p.prev_y -= push; }
                else { p.y += push; p.prev_y += push; }
            }
        }

        // Fixed timestep physics
        self.accumulator += dt;
        while (self.accumulator >= self.physics_dt) {
            self.sys.update(
                self.physics_dt,
                state.cursor[0],
                state.cursor[1],
                state.collision_rects,
            );
            self.accumulator -= self.physics_dt;
        }

        // Record position history every frame
        const idx = self.history_idx % TRAIL_HISTORY;
        for (0..self.sys.count) |i| {
            self.history[i][idx] = .{ self.sys.particles[i].x, self.sys.particles[i].y };
        }
        self.history_idx +%= 1;
        self.frame_count +%= 1;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        const count = @min(self.sys.count, MAX_TRAIL_PARTICLES);
        var slot: u32 = 0;

        // Trail spacing: evenly spaced through history
        const spacing = TRAIL_HISTORY / TRAIL_LEN; // 5 frames apart

        for (0..count) |i| {
            if (slot >= 300) break;
            const p = self.sys.particles[i];

            // Head dot — full size
            if (prog.i_particles[slot] >= 0) {
                c.glUniform4f(prog.i_particles[slot], p.x, p.y, p.size, p.color_idx);
            }
            slot += 1;

            // Trail dots — decreasing size, sampled from history
            for (0..TRAIL_LEN) |t| {
                if (slot >= 300) break;
                const age = (t + 1) * spacing;
                // Ring buffer index: go backward from current
                const h_idx = (self.history_idx -% @as(u32, @intCast(age))) % TRAIL_HISTORY;
                const pos = self.history[i][h_idx];

                const fade: f32 = 1.0 - @as(f32, @floatFromInt(t + 1)) / @as(f32, @floatFromInt(TRAIL_LEN + 1));
                const trail_size = p.size * fade;

                if (prog.i_particles[slot] >= 0) {
                    c.glUniform4f(prog.i_particles[slot], pos[0], pos[1], trail_size, p.color_idx);
                }
                slot += 1;
            }
        }

        if (prog.i_particle_count >= 0) {
            c.glUniform1i(prog.i_particle_count, @intCast(slot));
        }
    }

    pub fn deinit(_: *Context) void {}
};
