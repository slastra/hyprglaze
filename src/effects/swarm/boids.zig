const std = @import("std");
const particles_sys = @import("../particles/system.zig");

pub const max_boids = 100;

pub const Boid = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    size: f32,
    color_idx: f32,
    heading: f32,
};

pub const AudioParams = struct {
    bass: f32 = 0,
    beat: f32 = 0,
    total_energy: f32 = 0,
};

pub const BoidSystem = struct {
    boids: [max_boids]Boid = undefined,
    count: u32,
    width: f32,
    height: f32,

    // Tunable parameters
    base_speed: f32 = 200.0,
    max_force: f32 = 400.0,
    perception: f32 = 150.0,
    separation_dist: f32 = 40.0,

    // Flocking weights
    separation_w: f32 = 1.8,
    alignment_w: f32 = 1.0,
    cohesion_w: f32 = 1.0,

    // Window avoidance
    avoidance_radius: f32 = 120.0,

    pub fn init(count: u32, width: f32, height: f32) BoidSystem {
        var sys = BoidSystem{
            .count = @min(count, max_boids),
            .width = width,
            .height = height,
        };

        var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
        const rng = prng.random();

        for (0..sys.count) |i| {
            const angle = rng.float(f32) * std.math.tau;
            const speed = 50.0 + rng.float(f32) * 100.0;
            sys.boids[i] = .{
                .x = rng.float(f32) * width,
                .y = rng.float(f32) * height,
                .vx = @cos(angle) * speed,
                .vy = @sin(angle) * speed,
                .size = 4.0 + rng.float(f32) * 3.0,
                .color_idx = rng.float(f32),
                .heading = angle,
            };
        }
        return sys;
    }

    pub fn update(
        self: *BoidSystem,
        dt: f32,
        mouse_x: f32,
        mouse_y: f32,
        windows: []const particles_sys.Rect,
        audio: AudioParams,
    ) void {
        const max_speed = self.base_speed + audio.bass * 300.0;
        const cohesion_mod = 1.0 + audio.total_energy;
        const sep_dist = self.separation_dist + audio.beat * 40.0;
        const perception_sq = self.perception * self.perception;
        const sep_sq = sep_dist * sep_dist;

        for (0..self.count) |i| {
            const b = &self.boids[i];

            // Accumulate flocking forces
            var sep_x: f32 = 0;
            var sep_y: f32 = 0;
            var align_vx: f32 = 0;
            var align_vy: f32 = 0;
            var coh_x: f32 = 0;
            var coh_y: f32 = 0;
            var sep_count: f32 = 0;
            var neighbor_count: f32 = 0;

            for (0..self.count) |j| {
                if (i == j) continue;
                const o = &self.boids[j];
                const dx = o.x - b.x;
                const dy = o.y - b.y;

                // Wrapped distance for toroidal space
                const wx = wrapDelta(dx, self.width);
                const wy = wrapDelta(dy, self.height);
                const dist_sq = wx * wx + wy * wy;

                if (dist_sq > perception_sq) continue;

                neighbor_count += 1;
                align_vx += o.vx;
                align_vy += o.vy;
                coh_x += wx;
                coh_y += wy;

                if (dist_sq < sep_sq and dist_sq > 0.01) {
                    const inv = 1.0 / dist_sq;
                    sep_x -= wx * inv;
                    sep_y -= wy * inv;
                    sep_count += 1;

                    // Hard repulsion when nearly overlapping (< half separation dist)
                    const hard_thresh = sep_dist * 0.5;
                    if (dist_sq < hard_thresh * hard_thresh) {
                        const hard_inv = 1.0 / (dist_sq + 1.0);
                        sep_x -= wx * hard_inv * 8.0;
                        sep_y -= wy * hard_inv * 8.0;
                    }
                }
            }

            var steer_x: f32 = 0;
            var steer_y: f32 = 0;

            if (neighbor_count > 0) {
                // Separation
                if (sep_count > 0) {
                    const s = self.separation_w * self.separation_dist;
                    steer_x += sep_x * s;
                    steer_y += sep_y * s;
                }
                // Alignment: steer toward average velocity
                const inv_n = 1.0 / neighbor_count;
                const avg_vx = align_vx * inv_n;
                const avg_vy = align_vy * inv_n;
                steer_x += (avg_vx - b.vx) * self.alignment_w;
                steer_y += (avg_vy - b.vy) * self.alignment_w;

                // Cohesion: steer toward centroid of neighbors
                const cen_x = coh_x * inv_n;
                const cen_y = coh_y * inv_n;
                steer_x += cen_x * self.cohesion_w * cohesion_mod;
                steer_y += cen_y * self.cohesion_w * cohesion_mod;
            }

            // Window avoidance — tangential steering
            for (windows) |win| {
                if (win.w < 1 or win.h < 1) continue;
                const avoid = windowAvoidForce(b, win, self.avoidance_radius);
                steer_x += avoid[0];
                steer_y += avoid[1];
            }

            // Cursor interaction: attract far, repel close
            const cdx = mouse_x - b.x;
            const cdy = mouse_y - b.y;
            const cdist = @sqrt(cdx * cdx + cdy * cdy + 1.0);
            const comfort = 150.0;
            const cursor_factor = (cdist - comfort) / cdist;
            const cursor_strength: f32 = if (cdist < comfort) -600.0 else 80.0;
            steer_x += (cdx / cdist) * cursor_strength * cursor_factor;
            steer_y += (cdy / cdist) * cursor_strength * cursor_factor;

            // Beat scatter: on beat, impulse away from flock centroid
            if (audio.beat > 0.1 and neighbor_count > 0) {
                const inv_n = 1.0 / neighbor_count;
                const scatter_dx = -(coh_x * inv_n);
                const scatter_dy = -(coh_y * inv_n);
                const scatter_len = @sqrt(scatter_dx * scatter_dx + scatter_dy * scatter_dy + 1.0);
                steer_x += (scatter_dx / scatter_len) * audio.beat * 800.0;
                steer_y += (scatter_dy / scatter_len) * audio.beat * 800.0;
            }

            // Clamp total steering force
            const force_mag = @sqrt(steer_x * steer_x + steer_y * steer_y);
            if (force_mag > self.max_force) {
                const scale = self.max_force / force_mag;
                steer_x *= scale;
                steer_y *= scale;
            }

            // Integrate velocity
            b.vx += steer_x * dt;
            b.vy += steer_y * dt;

            // Clamp speed
            const speed = @sqrt(b.vx * b.vx + b.vy * b.vy);
            if (speed > max_speed) {
                const scale = max_speed / speed;
                b.vx *= scale;
                b.vy *= scale;
            }

            // Integrate position
            b.x += b.vx * dt;
            b.y += b.vy * dt;

            // Smooth heading tracking (skip when nearly stationary)
            if (speed > 10.0) {
                const target = std.math.atan2(b.vy, b.vx);
                b.heading = lerpAngle(b.heading, target, @min(1.0, 8.0 * dt));
            }

            // Wrap around screen edges
            b.x = @mod(b.x, self.width);
            b.y = @mod(b.y, self.height);
        }
    }
};

fn wrapDelta(d: f32, size: f32) f32 {
    const half = size * 0.5;
    if (d > half) return d - size;
    if (d < -half) return d + size;
    return d;
}

fn lerpAngle(from: f32, to: f32, t: f32) f32 {
    var diff = to - from;
    while (diff > std.math.pi) diff -= std.math.tau;
    while (diff < -std.math.pi) diff += std.math.tau;
    return from + diff * t;
}

fn windowAvoidForce(b: *const Boid, win: particles_sys.Rect, radius: f32) [2]f32 {
    // Signed distance to rect boundary (negative = inside)
    const cx = win.x + win.w * 0.5;
    const cy = win.y + win.h * 0.5;
    const hx = win.w * 0.5;
    const hy = win.h * 0.5;

    const dx = @abs(b.x - cx) - hx;
    const dy = @abs(b.y - cy) - hy;
    const dist = @sqrt(@max(dx, 0) * @max(dx, 0) + @max(dy, 0) * @max(dy, 0)) +
        @min(@max(dx, dy), 0);

    if (dist > radius) return .{ 0, 0 };
    if (dist < -radius) {
        // Deep inside — hard push to nearest edge
        const to_left = b.x - win.x;
        const to_right = win.x + win.w - b.x;
        const to_top = b.y - win.y;
        const to_bottom = win.y + win.h - b.y;
        const min_d = @min(@min(to_left, to_right), @min(to_top, to_bottom));
        if (min_d == to_left) return .{ -2000.0, 0 };
        if (min_d == to_right) return .{ 2000.0, 0 };
        if (min_d == to_top) return .{ 0, -2000.0 };
        return .{ 0, 2000.0 };
    }

    // Normal pointing away from rect surface
    var nx: f32 = 0;
    var ny: f32 = 0;
    if (dx > 0 and dy > 0) {
        // Corner region
        const len = @sqrt(dx * dx + dy * dy);
        nx = @max(dx, 0) / len * std.math.sign(b.x - cx);
        ny = @max(dy, 0) / len * std.math.sign(b.y - cy);
    } else if (dx > dy) {
        nx = std.math.sign(b.x - cx);
    } else {
        ny = std.math.sign(b.y - cy);
    }

    // Tangential component — steer along edge, not just away
    const tx = -ny;
    const ty = nx;
    // Blend: heading into window → more tangential; heading away → more normal
    const dot_heading = b.vx * nx + b.vy * ny;
    const approaching = @max(0.0, -dot_heading) / (@sqrt(b.vx * b.vx + b.vy * b.vy) + 1.0);
    const tangent_blend = 0.3 + approaching * 0.5;

    // Choose tangent direction based on which side of the window center
    const cross = (b.x - cx) * b.vy - (b.y - cy) * b.vx;
    const t_sign: f32 = if (cross > 0) 1.0 else -1.0;

    const strength = 800.0 * (1.0 - dist / radius);
    const fx = (nx * (1.0 - tangent_blend) + tx * t_sign * tangent_blend) * strength;
    const fy = (ny * (1.0 - tangent_blend) + ty * t_sign * tangent_blend) * strength;

    return .{ fx, fy };
}
