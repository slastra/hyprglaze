const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const max_windows = 32;

// 300 iParticles slots, swarm-style layout: head + trail dots per body.
const trail_len = 4;
// Longer history so the fuzz-mode Doppler echoes spread far enough apart to
// read as a streak rather than overlapping the head into one blob.
const trail_history = 90;
const slots_per = trail_len + 1;
const max_bodies = 300 / slots_per; // 60

// Gravitational constant, tuned for orbital periods of a few seconds at
// a few hundred pixels around a typical window (mass = sqrt(area)).
const G: f32 = 4.3e4;

// Plummer softening radius — keeps close passes finite so nothing
// slingshots off at machine-epsilon perihelion.
const soften: f32 = 60.0;
const soften2: f32 = soften * soften;

// Cursor's mass, in the same sqrt-area units as windows.
const cursor_mass: f32 = 180.0;

const focus_boost: f32 = 2.0;
const speed_cap: f32 = 2200.0;
const respawn_margin: f32 = 260.0;

// A body parked deep inside a window for this long is an invisible moon —
// rescue it into a fresh visible orbit. (No velocity drag: drag drains
// orbital energy and every body ends up buried under a window within
// minutes. Semi-implicit Euler is stable enough on its own; the speed cap
// and respawn margin handle slingshot heating instead.)
const buried_rescue_secs: f32 = 6.0;

const Body = struct {
    pos: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    size: f32 = 3.0,
    /// Dynamic size/brightness multiplier — swells near perihelion (close
    /// passes) and relaxes at apoapsis, smoothed frame to frame.
    glow: f32 = 1.0,
    /// Seconds since (re)spawn — drives a brief fade-in so recaptured bodies
    /// materialize instead of popping into view at full size.
    birth: f32 = 0,
    color_idx: f32 = 0,
    buried_t: f32 = 0,
};

// Clamp on the rendered wave-packet size so swelling bodies never grow a
// packet wider than the shader's cheap bounding-box reject (~sigma).
const render_size_max: f32 = 7.0;
// Distance (px) at which a body begins to swell as it nears a mass.
const swell_radius: f32 = 340.0;
// Fade-in duration for a freshly (re)spawned body.
const birth_fade_secs: f32 = 0.7;

const Mass = struct {
    pos: [2]f32,
    m: f32,
    /// Half of the window's smaller dimension — sizes spawn orbits so they
    /// clear the border instead of circling unseen behind the window.
    half_min: f32,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: *audio_mod.AudioCapture,
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    now: f32 = 0,

    bodies: [max_bodies]Body = [_]Body{.{}} ** max_bodies,
    count: u32 = max_bodies,
    history: [max_bodies][trail_history][2]f32 = undefined,
    history_idx: u32 = 0,
    seeded: bool = false,

    bass: f32 = 0,
    /// Six-band spectrum (sub-bass → air). Each body is assigned one band by
    /// its color index and pulses with that band, so the field splits the
    /// music across the swarm instead of every body reacting to everything.
    bands: [6]f32 = [_]f32{0} ** 6,
    /// Broadband energy envelope — drives the ring flow speed.
    energy: f32 = 0,
    /// Outward-ripple phase clock; advances faster with energy so the rings
    /// flow quicker on louder passages. Accumulated (not time*speed) so the
    /// rate can change without phase discontinuities.
    flow: f32 = 0,

    // Bass-flux beat detection.
    bass_prev: f32 = 0,
    flux_avg: f32 = 0,
    beat_cooldown: f32 = 0,
    /// Beat-pulse envelope — punches the field brightness and ring spacing so
    /// beats land hard against a calmer baseline flow. `beat` eases toward
    /// `beat_target` (set on a hit, then decaying) so the pulse swells in
    /// smoothly over a few frames rather than snapping in one.
    beat: f32 = 0,
    beat_target: f32 = 0,

    /// Render mode: wave-packet interference fuzz (default) vs. comet dots.
    fuzz: bool = true,

    cached_program: c.GLuint = 0,
    loc_time: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_fuzz: c.GLint = -1,
    loc_flow: c.GLint = -1,
    loc_bands: c.GLint = -1,
    loc_beat: c.GLint = -1,
    loc_vel: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const sink = params.getString("sink", null);
        const audio = try allocator.create(audio_mod.AudioCapture);
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();

        var count: u32 = @intCast(params.getInt("count", max_bodies));
        count = @min(count, max_bodies);

        return .{
            .allocator = allocator,
            .audio = audio,
            .rng = std.Random.DefaultPrng.init(0x6b65706c6572),
            .width = width,
            .height = height,
            .count = count,
            .fuzz = params.getBool("fuzz", true),
        };
    }

    /// Window masses for this frame: m = sqrt(area), focused window heavier.
    /// With no windows, a weak attractor at screen center keeps the field
    /// alive on an empty workspace.
    fn gatherMasses(self: *Context, state: effects.FrameState, out: *[max_windows + 2]Mass) u32 {
        var n: u32 = 0;
        const wcount = @min(state.windows.len, max_windows);

        const fc = [2]f32{
            state.focused_win.x + state.focused_win.w * 0.5,
            state.focused_win.y + state.focused_win.h * 0.5,
        };

        for (0..wcount) |i| {
            const w = state.windows[i];
            if (w.w < 8.0 or w.h < 8.0) continue;
            var m = @sqrt(w.w * w.h);
            const cx = w.x + w.w * 0.5;
            const cy = w.y + w.h * 0.5;
            // Focused window (matched by smoothed center) pulls harder.
            if (state.focused_win.hasArea() and @abs(cx - fc[0]) < 40.0 and @abs(cy - fc[1]) < 40.0) {
                m *= focus_boost;
            }
            out[n] = .{ .pos = .{ cx, cy }, .m = m, .half_min = @min(w.w, w.h) * 0.5 };
            n += 1;
        }

        if (n == 0) {
            out[0] = .{ .pos = .{ self.width * 0.5, self.height * 0.5 }, .m = 350.0, .half_min = 0 };
            n = 1;
        }

        // Cursor: rogue comet.
        out[n] = .{ .pos = state.cursor, .m = cursor_mass, .half_min = 0 };
        n += 1;
        return n;
    }

    /// Drop a body into a circular orbit around a random mass. Direction is
    /// random, so systems end up with mixed prograde/retrograde moons.
    fn spawnOrbit(self: *Context, body: *Body, masses: []const Mass) void {
        const r = self.rng.random();
        // Exclude the cursor (last slot) as a spawn anchor.
        const anchor_count = if (masses.len > 1) masses.len - 1 else masses.len;
        const a = masses[r.intRangeLessThan(usize, 0, anchor_count)];

        // Clear the window border by a margin so the whole orbit is visible.
        const radius = a.half_min + 90.0 + r.float(f32) * 320.0;
        const theta = r.float(f32) * std.math.tau;
        body.pos = .{
            a.pos[0] + radius * @cos(theta),
            a.pos[1] + radius * @sin(theta),
        };

        const v_circ = @sqrt(G * a.m / radius);
        const sign: f32 = if (r.boolean()) 1.0 else -1.0;
        body.vel = .{
            -@sin(theta) * v_circ * sign,
            @cos(theta) * v_circ * sign,
        };
        // Quadratic weighting: mostly small moons, a few large bodies — a
        // far wider, more varied spread than a flat random range.
        const u = r.float(f32);
        body.size = 1.4 + u * u * 4.6;
        body.glow = 1.0;
        body.birth = 0;
        body.color_idx = @floatFromInt(r.intRangeAtMost(u8, 1, 14));
        body.buried_t = 0;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.033);
        self.now += dt;

        // Bass envelope — breathes the lens depth in the shader.
        const wave = self.audio.getWaveform();
        var energy: f32 = 0;
        for (0..25) |j| energy += @abs(wave[j]) + @abs(wave[128 + j]);
        const raw = (energy / 50.0) * 6.0;
        const k = if (raw > self.bass) @min(1.0, 25.0 * dt) else @min(1.0, 5.0 * dt);
        self.bass += (raw - self.bass) * k;

        // Broadband energy across the whole waveform, same attack/decay shape.
        var e_sum: f32 = 0;
        for (0..128) |j| e_sum += @abs(wave[j]) + @abs(wave[128 + j]);
        const e_raw = (e_sum / 256.0) * 6.0;
        const ek = if (e_raw > self.energy) @min(1.0, 25.0 * dt) else @min(1.0, 5.0 * dt);
        self.energy += (e_raw - self.energy) * ek;

        // Six-band split (glitch/voltaic pattern): per-band envelope so each
        // body can ride its own slice of the spectrum.
        const ranges = [_][2]u8{ .{ 0, 10 }, .{ 10, 25 }, .{ 25, 45 }, .{ 45, 70 }, .{ 70, 95 }, .{ 95, 128 } };
        for (0..6) |bi| {
            var en: f32 = 0;
            const lo = ranges[bi][0];
            const hi = ranges[bi][1];
            for (lo..hi) |j| en += @abs(wave[j]) + @abs(wave[128 + j]);
            en /= @floatFromInt((hi - lo) * 2);
            const b_raw = en * 6.0;
            const attack = @min(1.0, 25.0 * dt);
            const decay = @min(1.0, 5.0 * dt);
            self.bands[bi] += (b_raw - self.bands[bi]) * (if (b_raw > self.bands[bi]) attack else decay);
        }

        // Advance the ripple clock: a calm baseline flow plus a gentle
        // energy boost — kept low so the field doesn't constantly vibrate;
        // the punch comes from the beat envelope instead.
        self.flow += dt * (1.3 + self.energy * 1.8);

        var masses: [max_windows + 2]Mass = undefined;
        const n_mass = self.gatherMasses(state, &masses);

        // Bass-flux beat detection → drives the beat-pulse envelope.
        const flux = @max(0.0, self.bass - self.bass_prev);
        self.bass_prev = self.bass;
        self.flux_avg += (flux - self.flux_avg) * @min(1.0, 1.5 * dt);
        self.beat_cooldown -= dt;
        if (flux > self.flux_avg * 3.0 + 0.02 and self.beat_cooldown <= 0 and self.bass > 0.15) {
            self.beat_cooldown = 0.22;
            self.beat_target = std.math.clamp(flux / (self.flux_avg * 3.0 + 0.02), 1.0, 2.0);
        }
        // Smooth attack + decay: the target relaxes toward zero while `beat`
        // eases toward it, so the punch swells in over ~100ms and falls off
        // rather than snapping in a single frame (which read as a hard jerk).
        self.beat_target *= @exp(-6.0 * dt);
        self.beat += (self.beat_target - self.beat) * @min(1.0, 14.0 * dt);
        if (self.beat < 0.01 and self.beat_target < 0.01) self.beat = 0;

        if (!self.seeded) {
            self.seeded = true;
            for (self.bodies[0..self.count]) |*b| self.spawnOrbit(b, masses[0..n_mass]);
            for (0..self.count) |i| {
                for (0..trail_history) |h| self.history[i][h] = self.bodies[i].pos;
            }
        }

        for (self.bodies[0..self.count], 0..) |*b, i| {
            b.birth += dt;

            // Softened gravity from every mass (semi-implicit Euler), tracking
            // the closest mass so the body can swell at perihelion.
            var ax: f32 = 0;
            var ay: f32 = 0;
            var r2_min: f32 = std.math.floatMax(f32);
            for (masses[0..n_mass]) |mass| {
                const dx = mass.pos[0] - b.pos[0];
                const dy = mass.pos[1] - b.pos[1];
                const r2_raw = dx * dx + dy * dy;
                if (r2_raw < r2_min) r2_min = r2_raw;
                const r2 = r2_raw + soften2;
                const inv_r3 = 1.0 / (r2 * @sqrt(r2));
                const gm = G * mass.m * inv_r3;
                ax += gm * dx;
                ay += gm * dy;
            }

            // Perihelion swell: the nearer the closest mass, the larger and
            // brighter the body grows. Smoothed so it breathes rather than
            // snaps as the body rounds a tight pass.
            const r_min = @sqrt(r2_min);
            const prox = std.math.clamp((swell_radius - r_min) / swell_radius, 0.0, 1.0);
            const target_glow = 1.0 + prox * prox * 0.8;
            b.glow += (target_glow - b.glow) * @min(1.0, 8.0 * dt);

            b.vel[0] += ax * dt;
            b.vel[1] += ay * dt;

            const speed = @sqrt(b.vel[0] * b.vel[0] + b.vel[1] * b.vel[1]);
            if (speed > speed_cap) {
                const s = speed_cap / speed;
                b.vel[0] *= s;
                b.vel[1] *= s;
            }

            b.pos[0] += b.vel[0] * dt;
            b.pos[1] += b.vel[1] * dt;

            // Escaped the system → recapture into a fresh orbit.
            if (b.pos[0] < -respawn_margin or b.pos[0] > self.width + respawn_margin or
                b.pos[1] < -respawn_margin or b.pos[1] > self.height + respawn_margin)
            {
                self.spawnOrbit(b, masses[0..n_mass]);
                for (0..trail_history) |h| self.history[i][h] = b.pos;
                continue;
            }

            // Buried-moon rescue: a body lingering deep inside a window is
            // invisible — after a grace period, recapture it somewhere seen.
            var buried = false;
            const wcount = @min(state.windows.len, max_windows);
            for (0..wcount) |wi| {
                const w = state.windows[wi];
                const inset_x = w.w * 0.15;
                const inset_y = w.h * 0.15;
                if (b.pos[0] > w.x + inset_x and b.pos[0] < w.x + w.w - inset_x and
                    b.pos[1] > w.y + inset_y and b.pos[1] < w.y + w.h - inset_y)
                {
                    buried = true;
                    break;
                }
            }
            if (buried) {
                b.buried_t += dt;
                if (b.buried_t > buried_rescue_secs) {
                    self.spawnOrbit(b, masses[0..n_mass]);
                    for (0..trail_history) |h| self.history[i][h] = b.pos;
                }
            } else {
                b.buried_t = 0;
            }
        }

        const idx = self.history_idx % trail_history;
        for (0..self.count) |i| {
            self.history[i][idx] = self.bodies[i].pos;
        }
        self.history_idx +%= 1;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_time = c.glGetUniformLocation(prog.program, "iKepTime");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iBass");
            self.loc_fuzz = c.glGetUniformLocation(prog.program, "iFuzz");
            self.loc_flow = c.glGetUniformLocation(prog.program, "iFlow");
            self.loc_bands = c.glGetUniformLocation(prog.program, "iBands[0]");
            self.loc_beat = c.glGetUniformLocation(prog.program, "iBeat");
            self.loc_vel = c.glGetUniformLocation(prog.program, "iVel[0]");
        }

        // Slot layout: (x, y, size, color_idx + 16*trail_age). Age 0 = head.
        // Spacing uses trail_len+1 so the oldest sample stays short of a full
        // history wrap (which would land back on the head).
        var slot: u32 = 0;
        const spacing = trail_history / (trail_len + 1);
        for (0..self.count) |i| {
            const b = self.bodies[i];
            // Render size folds in the perihelion swell and this body's own
            // spectral band (assigned by color index), clamped so the packet
            // never outgrows the shader's reject box, then scaled by a
            // smoothstep fade-in so fresh bodies grow in.
            const band = @as(usize, @intFromFloat(b.color_idx)) % 6;
            const be = @min(self.bands[band], 1.4);
            const ft = std.math.clamp(b.birth / birth_fade_secs, 0.0, 1.0);
            const fade = ft * ft * (3.0 - 2.0 * ft);
            const dsize = @min(b.size * b.glow * (1.0 + be * 0.6), render_size_max) * fade;
            if (prog.i_particles[slot] >= 0) {
                c.glUniform4f(prog.i_particles[slot], b.pos[0], b.pos[1], dsize, b.color_idx);
            }
            slot += 1;

            for (0..trail_len) |t| {
                const age = (t + 1) * spacing;
                const h_idx = (self.history_idx -% @as(u32, @intCast(age))) % trail_history;
                const pos = self.history[i][h_idx];
                const tag = b.color_idx + 16.0 * @as(f32, @floatFromInt(t + 1));
                if (prog.i_particles[slot] >= 0) {
                    c.glUniform4f(prog.i_particles[slot], pos[0], pos[1], dsize, tag);
                }
                slot += 1;
            }
        }
        if (prog.i_particle_count >= 0) {
            c.glUniform1i(prog.i_particle_count, @intCast(slot));
        }

        // Effect-local time (fire.zig pattern) — keeps shader noise/twinkle
        // coordinates small so f32 precision holds over long sessions.
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.bass);
        if (self.loc_fuzz >= 0) c.glUniform1f(self.loc_fuzz, if (self.fuzz) 1.0 else 0.0);
        if (self.loc_flow >= 0) c.glUniform1f(self.loc_flow, self.flow);
        if (self.loc_bands >= 0) c.glUniform1fv(self.loc_bands, 6, &self.bands[0]);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.beat);
        if (self.loc_vel >= 0) {
            // Per-body velocity for the shader's Doppler term (one vec2 each).
            var vels: [max_bodies][2]f32 = undefined;
            for (0..self.count) |i| vels[i] = self.bodies[i].vel;
            c.glUniform2fv(self.loc_vel, @intCast(self.count), @ptrCast(&vels[0]));
        }
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
    }
};
