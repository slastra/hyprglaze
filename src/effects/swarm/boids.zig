const std = @import("std");
const particles_sys = @import("../particles/system.zig");

pub const max_boids = 256;

pub const Boid = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    /// Agitation: spikes when fleeing the predator, decays over ~a second.
    /// Splatted into the field so scattered regions render hot.
    agit: f32 = 0,
};

pub const AudioParams = struct {
    bass: f32 = 0,
    beat: f32 = 0,
    /// True only on the frame a beat was detected — triggers a predator dive.
    beat_hit: bool = false,
    /// How hard the beat punched over its flux average (1..2).
    punch: f32 = 1.0,
    total_energy: f32 = 0,
    /// 0 = airborne, 1 = fully roosted (sustained silence). Smoothed.
    roost: f32 = 0,
    /// True for one frame when music returns and the flock bursts off
    /// its perches.
    burst: bool = false,
};

/// The hawk. Patrols lazily between waypoints; on a beat it locks the
/// flock's center of mass and dives through it.
pub const Predator = struct {
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    /// 1 at dive start, exponential decay; doubles as flee-strength scale.
    dive: f32 = 0,
    /// Punch of the beat that launched the current dive (1..2).
    punch: f32 = 1.0,
    target: [2]f32 = .{ 0, 0 },
    waypoint: [2]f32 = .{ 0, 0 },
    waypoint_t: f32 = 0,
};

pub const BoidSystem = struct {
    boids: [max_boids]Boid = undefined,
    count: u32,
    predator: Predator = .{},
    width: f32,
    height: f32,
    rng: std.Random.DefaultPrng,
    now: f32 = 0,

    /// Shared migration waypoint: the whole flock drifts toward a slowly
    /// wandering target, which keeps it moving as one body across the sky.
    flock_wp: [2]f32 = .{ 0, 0 },
    flock_wp_t: f32 = 0,

    /// Heart of the densest formation (boid with the most neighbors, one
    /// frame stale). The hawk hunts THIS, not the center of mass — the COM
    /// of two separated islands is the empty sky between them, and a hawk
    /// that dives there looks like it's politely avoiding everyone.
    dense_pt: [2]f32 = .{ 0, 0 },
    dense_valid: bool = false,

    // Tunable parameters. Perception is long and cohesion strong relative
    // to the old dot-swarm: a murmuration must hold together as one body
    // across a 3000px screen, not condense into scattered puffs.
    base_speed: f32 = 220.0,
    max_force: f32 = 500.0,
    perception: f32 = 240.0,
    separation_dist: f32 = 54.0,

    // Flocking weights. Cohesion is deliberately modest — group travel
    // comes from the shared migration waypoint, not from cranking cohesion,
    // which collapses the flock into one static ball given enough time.
    separation_w: f32 = 2.0,
    alignment_w: f32 = 1.2,
    cohesion_w: f32 = 0.9,

    // Window avoidance — kept small so boids can occupy gaps between tiled windows
    avoidance_radius: f32 = 20.0,

    // Predator behavior
    patrol_speed: f32 = 260.0,
    dive_speed: f32 = 1300.0,
    flee_radius: f32 = 340.0,

    /// Perch position for boid `idx`: a slot along some window's top edge,
    /// spaced like birds on a wire. Recomputed each frame from the live
    /// window list so perches ride moving windows. Falls back to the bottom
    /// of the screen when no windows are up.
    fn perchPoint(self: *const BoidSystem, idx: usize, windows: []const particles_sys.Rect) [2]f32 {
        const spacing: f32 = 26.0;
        var capacity: usize = 0;
        for (windows) |win| {
            if (win.w < 80.0 or win.h < 40.0) continue;
            capacity += @intFromFloat(win.w / spacing);
        }
        if (capacity == 0) {
            const n: f32 = @floatFromInt(self.count);
            const fx = (@as(f32, @floatFromInt(idx)) + 0.5) / n;
            return .{ fx * self.width, 6.0 };
        }
        var k = idx % capacity;
        for (windows) |win| {
            if (win.w < 80.0 or win.h < 40.0) continue;
            const slots: usize = @intFromFloat(win.w / spacing);
            if (k < slots) {
                return .{
                    win.x + (@as(f32, @floatFromInt(k)) + 0.5) * spacing,
                    win.y + win.h + 5.0,
                };
            }
            k -= slots;
        }
        return .{ self.width * 0.5, 6.0 };
    }

    pub fn init(count: u32, width: f32, height: f32) BoidSystem {
        var sys = BoidSystem{
            .count = @min(count, max_boids),
            .width = width,
            .height = height,
            .rng = std.Random.DefaultPrng.init(0xDEADBEEF),
        };
        const rng = sys.rng.random();

        // Spawn as one loose cloud with a shared drift, so the murmuration
        // starts unified instead of having to condense out of a uniform mist.
        const cx = width * (0.3 + rng.float(f32) * 0.4);
        const cy = height * (0.3 + rng.float(f32) * 0.4);
        const drift = rng.float(f32) * std.math.tau;
        for (0..sys.count) |i| {
            const angle = rng.float(f32) * std.math.tau;
            const radius = rng.float(f32) * 380.0;
            sys.boids[i] = .{
                .x = cx + @cos(angle) * radius,
                .y = cy + @sin(angle) * radius,
                .vx = @cos(drift) * 120.0 + (rng.float(f32) - 0.5) * 60.0,
                .vy = @sin(drift) * 120.0 + (rng.float(f32) - 0.5) * 60.0,
            };
        }
        sys.predator = .{
            .x = width * 0.5,
            .y = height * 0.85,
            .waypoint = .{ width * 0.3, height * 0.7 },
        };
        return sys;
    }

    fn updatePredator(self: *BoidSystem, dt: f32, com: [2]f32, audio: AudioParams) void {
        const p = &self.predator;
        const rng = self.rng.random();

        // Every beat retargets the hawk — no cooldown gate, so consecutive
        // beats redirect a dive mid-flight and fast sections make it juke
        // with the rhythm. It aims THROUGH the flock's center and out the
        // other side: a slash, not a landing. Perched flocks don't interest
        // it — no dives while roosted.
        if (audio.beat_hit and audio.roost < 0.5) {
            p.dive = @min(1.0, 0.6 + audio.punch * 0.25);
            p.punch = audio.punch;
            const prey = if (self.dense_valid) self.dense_pt else com;
            var tx = prey[0] - p.x;
            var ty = prey[1] - p.y;
            const td = @sqrt(tx * tx + ty * ty + 1.0);
            tx /= td;
            ty /= td;
            const overshoot = 220.0 + audio.punch * 120.0;
            p.target = .{ prey[0] + tx * overshoot, prey[1] + ty * overshoot };
        }
        p.dive *= @exp(-2.2 * dt);
        if (p.dive < 0.02) p.dive = 0;

        var goal: [2]f32 = undefined;
        var speed: f32 = undefined;
        if (p.dive > 0.05) {
            goal = p.target;
            // Heavy drops hit harder than pickup notes.
            speed = self.dive_speed * (0.4 + 0.6 * p.dive) * (0.7 + p.punch * 0.4);
            // Dive locked the target; reaching it ends the stoop early.
            const dx = goal[0] - p.x;
            const dy = goal[1] - p.y;
            if (dx * dx + dy * dy < 80.0 * 80.0) p.dive *= @exp(-8.0 * dt);
        } else {
            // Patrol: amble between random waypoints.
            p.waypoint_t -= dt;
            const wdx = p.waypoint[0] - p.x;
            const wdy = p.waypoint[1] - p.y;
            if (p.waypoint_t <= 0 or wdx * wdx + wdy * wdy < 120.0 * 120.0) {
                if (self.dense_valid and rng.float(f32) < 0.6) {
                    // Shadow the flock: loiter within striking distance.
                    p.waypoint = .{
                        std.math.clamp(self.dense_pt[0] + (rng.float(f32) - 0.5) * 900.0, 0.0, self.width),
                        std.math.clamp(self.dense_pt[1] + (rng.float(f32) - 0.5) * 900.0, 0.0, self.height),
                    };
                } else {
                    p.waypoint = .{
                        self.width * (0.1 + rng.float(f32) * 0.8),
                        self.height * (0.1 + rng.float(f32) * 0.8),
                    };
                }
                p.waypoint_t = 2.5 + rng.float(f32) * 3.0;
            }
            goal = p.waypoint;
            // Loud passages make it restless even between beats.
            speed = self.patrol_speed * (1.0 + audio.total_energy * 1.2);
        }

        const gdx = goal[0] - p.x;
        const gdy = goal[1] - p.y;
        const gd = @sqrt(gdx * gdx + gdy * gdy + 1.0);
        const k = @min(1.0, 4.0 * dt);
        p.vx += ((gdx / gd) * speed - p.vx) * k;
        p.vy += ((gdy / gd) * speed - p.vy) * k;
        p.x += p.vx * dt;
        p.y += p.vy * dt;
        p.x = std.math.clamp(p.x, -100.0, self.width + 100.0);
        p.y = std.math.clamp(p.y, -100.0, self.height + 100.0);
    }

    pub fn update(
        self: *BoidSystem,
        dt: f32,
        mouse_x: f32,
        mouse_y: f32,
        windows: []const particles_sys.Rect,
        audio: AudioParams,
    ) void {
        self.now += dt;
        const max_speed = self.base_speed + audio.bass * 300.0;

        // Migrate: repick the flock's destination every few seconds.
        self.flock_wp_t -= dt;
        if (self.flock_wp_t <= 0) {
            const rng = self.rng.random();
            self.flock_wp = .{
                self.width * (0.15 + rng.float(f32) * 0.7),
                self.height * (0.2 + rng.float(f32) * 0.65),
            };
            self.flock_wp_t = 4.0 + rng.float(f32) * 3.5;
        }
        // Energy tightens the flock: quiet music is a loose haze, loud
        // passages pull into dense ribbons.
        const cohesion_mod = 0.8 + audio.total_energy * 1.8;
        const sep_sq = self.separation_dist * self.separation_dist;
        const perception_sq = self.perception * self.perception;

        // Flock center of mass — predator targeting.
        var com: [2]f32 = .{ 0, 0 };
        for (0..self.count) |i| {
            com[0] += self.boids[i].x;
            com[1] += self.boids[i].y;
        }
        if (self.count > 0) {
            com[0] /= @floatFromInt(self.count);
            com[1] /= @floatFromInt(self.count);
        }

        self.updatePredator(dt, com, audio);
        const pred = self.predator;
        // Fear bubble pulses with the dive and breathes with the beat tail.
        const flee_r = self.flee_radius * (1.0 + pred.dive * 0.8 + audio.beat * 0.35);
        const flee_r_sq = flee_r * flee_r;

        // Roost: airborne behaviors fade out as the flock settles.
        const roost = audio.roost;
        const live = 1.0 - roost;
        const burst_rng = self.rng.random();

        // Track the densest knot of birds for next frame's hunt.
        var best_neighbors: f32 = -1.0;
        var best_pos: [2]f32 = .{ 0, 0 };

        for (0..self.count) |i| {
            const b = &self.boids[i];

            // Music's back: explode off the perch, scared and loud.
            if (audio.burst) {
                b.vx += (burst_rng.float(f32) - 0.5) * 500.0;
                b.vy += 280.0 + burst_rng.float(f32) * 320.0;
                b.agit = 0.7;
            }

            // Accumulate flocking forces
            var sep_x: f32 = 0;
            var sep_y: f32 = 0;
            var align_vx: f32 = 0;
            var align_vy: f32 = 0;
            var coh_x: f32 = 0;
            var coh_y: f32 = 0;
            var sep_count: f32 = 0;
            var neighbor_count: f32 = 0;
            var agit_sum: f32 = 0;

            for (0..self.count) |j| {
                if (i == j) continue;
                const o = &self.boids[j];
                const wx = o.x - b.x;
                const wy = o.y - b.y;
                const dist_sq = wx * wx + wy * wy;

                if (dist_sq > perception_sq) continue;

                neighbor_count += 1;
                align_vx += o.vx;
                align_vy += o.vy;
                coh_x += wx;
                coh_y += wy;
                agit_sum += o.agit;

                if (dist_sq < sep_sq and dist_sq > 0.01) {
                    const inv = 1.0 / dist_sq;
                    sep_x -= wx * inv;
                    sep_y -= wy * inv;
                    sep_count += 1;
                }
            }

            if (neighbor_count > best_neighbors) {
                best_neighbors = neighbor_count;
                best_pos = .{ b.x, b.y };
            }

            var steer_x: f32 = 0;
            var steer_y: f32 = 0;

            if (neighbor_count > 0) {
                // Fear contagion: panic propagates bird-to-bird through the
                // formation faster than the hawk flies — this is what lets a
                // single dive shatter a large island instead of denting it.
                const avg_agit = agit_sum / neighbor_count;
                if (avg_agit > b.agit) {
                    b.agit = @min(1.0, b.agit + (avg_agit - b.agit) * 3.0 * dt);
                }

                // Separation — panicked birds shove apart hard.
                if (sep_count > 0) {
                    const s = self.separation_w * self.separation_dist * (1.0 + b.agit * 2.5);
                    steer_x += sep_x * s;
                    steer_y += sep_y * s;
                }
                // Alignment: steer toward average velocity (fades at roost,
                // collapses in panic — scared birds fly their own way).
                const inv_n = 1.0 / neighbor_count;
                const avg_vx = align_vx * inv_n;
                const avg_vy = align_vy * inv_n;
                const align_k = self.alignment_w * live * (1.0 - b.agit * 0.7);
                steer_x += (avg_vx - b.vx) * align_k;
                steer_y += (avg_vy - b.vy) * align_k;

                // Cohesion: steer toward centroid of neighbors (fades at roost)
                const cen_x = coh_x * inv_n;
                const cen_y = coh_y * inv_n;
                steer_x += cen_x * self.cohesion_w * cohesion_mod * live;
                steer_y += cen_y * self.cohesion_w * cohesion_mod * live;
            }

            // Window avoidance — gap-aware centering.
            // Find the nearest window edge in each cardinal direction.
            // When between two windows, steer toward the gap center
            // rather than fleeing both walls (which makes gaps uninhabitable).
            var nearest_left: f32 = b.x; // distance to nearest edge on left
            var nearest_right: f32 = self.width - b.x;
            var nearest_above: f32 = b.y;
            var nearest_below: f32 = self.height - b.y;
            var inside_any = false;

            for (windows) |win| {
                if (win.w < 1 or win.h < 1) continue;
                const wx1 = win.x;
                const wy1 = win.y;
                const wx2 = win.x + win.w;
                const wy2 = win.y + win.h;

                // If boid is inside this window, push it out
                if (b.x >= wx1 and b.x <= wx2 and b.y >= wy1 and b.y <= wy2) {
                    inside_any = true;
                    const to_l = b.x - wx1;
                    const to_r = wx2 - b.x;
                    const to_t = b.y - wy1;
                    const to_b = wy2 - b.y;
                    const min_d = @min(@min(to_l, to_r), @min(to_t, to_b));
                    const push: f32 = 3000.0;
                    if (min_d == to_l) steer_x -= push
                    else if (min_d == to_r) steer_x += push
                    else if (min_d == to_t) steer_y -= push
                    else steer_y += push;
                    continue;
                }

                // Horizontally aligned — window is to the left or right
                if (b.y >= wy1 and b.y <= wy2) {
                    if (wx1 > b.x) nearest_right = @min(nearest_right, wx1 - b.x);
                    if (wx2 < b.x) nearest_left = @min(nearest_left, b.x - wx2);
                }
                // Vertically aligned — window is above or below
                if (b.x >= wx1 and b.x <= wx2) {
                    if (wy1 > b.y) nearest_below = @min(nearest_below, wy1 - b.y);
                    if (wy2 < b.y) nearest_above = @min(nearest_above, b.y - wy2);
                }
            }

            if (!inside_any) {
                const radius = self.avoidance_radius;
                // Horizontal gap centering
                if (nearest_left < radius or nearest_right < radius) {
                    const gap_w = nearest_left + nearest_right;
                    const center_offset = (nearest_right - nearest_left) * 0.5;
                    const urgency = 1.0 - @min(gap_w, radius * 4.0) / (radius * 4.0);
                    steer_x += center_offset * (200.0 + urgency * 600.0);
                }
                // Vertical gap centering
                if (nearest_above < radius or nearest_below < radius) {
                    const gap_h = nearest_above + nearest_below;
                    const center_offset = (nearest_below - nearest_above) * 0.5;
                    const urgency = 1.0 - @min(gap_h, radius * 4.0) / (radius * 4.0);
                    steer_y += center_offset * (200.0 + urgency * 600.0);
                }
            }

            // Soft screen bounds: the sky has edges. Turn-back force ramps
            // inside the margin so the organism banks instead of tearing
            // through a wrap seam.
            const margin: f32 = 180.0;
            if (b.x < margin) steer_x += (1.0 - b.x / margin) * 900.0;
            if (b.x > self.width - margin) steer_x -= (1.0 - (self.width - b.x) / margin) * 900.0;
            if (b.y < margin) steer_y += (1.0 - b.y / margin) * 900.0;
            if (b.y > self.height - margin) steer_y -= (1.0 - (self.height - b.y) / margin) * 900.0;

            // Migration pull toward the wandering flock waypoint.
            steer_x += (self.flock_wp[0] - b.x) * 0.12 * live;
            steer_y += (self.flock_wp[1] - b.y) * 0.12 * live;

            // Roost: settle onto an assigned perch slot along a window's
            // top edge, birds-on-a-wire style.
            if (roost > 0.01) {
                const perch = self.perchPoint(i, windows);
                steer_x += (perch[0] - b.x) * 3.5 * roost;
                steer_y += (perch[1] - b.y) * 3.5 * roost;
            }

            // Look-ahead braking: if current velocity carries us into a
            // window within a quarter second, brake hard before impact —
            // steering forces alone can't stop a 900px/s fleeing boid.
            const ahead_x = b.x + b.vx * 0.25;
            const ahead_y = b.y + b.vy * 0.25;
            for (windows) |win| {
                if (win.w < 1 or win.h < 1) continue;
                if (ahead_x > win.x and ahead_x < win.x + win.w and
                    ahead_y > win.y and ahead_y < win.y + win.h)
                {
                    steer_x -= b.vx * 4.0;
                    steer_y -= b.vy * 4.0;
                    break;
                }
            }

            // Internal waves: slow per-boid wander so the cloud undulates
            // from within instead of gliding as a rigid body.
            const ph = @as(f32, @floatFromInt(i));
            steer_x += @sin(self.now * 0.7 + ph * 2.39) * 70.0 * live;
            steer_y += @cos(self.now * 0.9 + ph * 1.71) * 70.0 * live;

            // Cursor interaction: attract far, repel close
            const cdx = mouse_x - b.x;
            const cdy = mouse_y - b.y;
            const cdist = @sqrt(cdx * cdx + cdy * cdy + 1.0);
            const comfort = 150.0;
            const cursor_factor = (cdist - comfort) / cdist;
            const cursor_strength: f32 = if (cdist < comfort) -600.0 else 80.0;
            steer_x += (cdx / cdist) * cursor_strength * cursor_factor;
            steer_y += (cdy / cdist) * cursor_strength * cursor_factor;

            // Predator flee: terror scales with proximity and dive intensity.
            // This is what tears holes in the murmuration on every beat.
            const pdx = b.x - pred.x;
            const pdy = b.y - pred.y;
            const pd_sq = pdx * pdx + pdy * pdy;
            if (pd_sq < flee_r_sq and pd_sq > 1.0) {
                const pd = @sqrt(pd_sq);
                const fear = (1.0 - pd / flee_r) * (0.5 + pred.dive * 1.5) * (1.0 - roost * 0.8);
                steer_x += (pdx / pd) * fear * 2400.0;
                steer_y += (pdy / pd) * fear * 2400.0;
                b.agit = @min(1.0, b.agit + fear * 4.0 * dt);
            }
            b.agit *= @exp(-1.4 * dt);

            // Clamp total steering force (fleeing overrides the cap a bit)
            const cap = self.max_force * (1.0 + b.agit * 2.0);
            const force_mag = @sqrt(steer_x * steer_x + steer_y * steer_y);
            if (force_mag > cap) {
                const scale = cap / force_mag;
                steer_x *= scale;
                steer_y *= scale;
            }

            // Integrate velocity
            b.vx += steer_x * dt;
            b.vy += steer_y * dt;

            // Clamp speed (scared birds fly faster)
            const cap_speed = max_speed * (1.0 + b.agit * 0.8);
            const speed = @sqrt(b.vx * b.vx + b.vy * b.vy);
            if (speed > cap_speed) {
                const scale = cap_speed / speed;
                b.vx *= scale;
                b.vy *= scale;
            }

            // Settling damping: perched birds bleed velocity and sit still.
            if (roost > 0.01) {
                const damp = @exp(-roost * 4.0 * dt);
                b.vx *= damp;
                b.vy *= damp;
            }

            // Integrate position
            b.x += b.vx * dt;
            b.y += b.vy * dt;

            // Hard collision resolve: steering is advisory, this is law.
            // Any boid that ends the step inside a window gets projected out
            // through the nearest edge with its normal velocity reflected,
            // so no speed can tunnel through a window.
            for (windows) |win| {
                if (win.w < 1 or win.h < 1) continue;
                if (b.x <= win.x or b.x >= win.x + win.w or
                    b.y <= win.y or b.y >= win.y + win.h) continue;
                const to_l = b.x - win.x;
                const to_r = win.x + win.w - b.x;
                const to_d = b.y - win.y;
                const to_u = win.y + win.h - b.y;
                const m = @min(@min(to_l, to_r), @min(to_d, to_u));
                if (m == to_l) {
                    b.x = win.x - 1.0;
                    if (b.vx > 0) b.vx = -b.vx * 0.4;
                } else if (m == to_r) {
                    b.x = win.x + win.w + 1.0;
                    if (b.vx < 0) b.vx = -b.vx * 0.4;
                } else if (m == to_d) {
                    b.y = win.y - 1.0;
                    if (b.vy > 0) b.vy = -b.vy * 0.4;
                } else {
                    b.y = win.y + win.h + 1.0;
                    if (b.vy < 0) b.vy = -b.vy * 0.4;
                }
            }

            // Hard clamp as a backstop — the soft margin does the real work.
            b.x = std.math.clamp(b.x, 0.0, self.width);
            b.y = std.math.clamp(b.y, 0.0, self.height);
        }

        if (best_neighbors >= 0) {
            self.dense_pt = best_pos;
            self.dense_valid = true;
        }
    }
};
