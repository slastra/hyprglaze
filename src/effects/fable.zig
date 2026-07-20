const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const bands_mod = @import("bands.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// Fable — a self-portrait. A small warm starburst (the eight-armed Claude
// asterisk, coral blended into the theme) that lives on the desktop like a
// familiar. It attends: gliding to hover near the corner of the focused
// window, wandering gently when nothing holds its attention. It listens:
// each opposing pair of arms rides an audio band, so music turns the star
// into a radial equalizer; beats flare it and give it a little spin. And it
// thinks: now and then it sheds curved thought-sparks from its arm tips
// that arc away and dissolve — more often when the music moves it.
const arms = 8;
const max_sparks = 12;
const spark_pts = 6;
const spark_vec4s = max_sparks * spark_pts / 2;

/// A thought: a stroke shed from an arm tip. It writes itself outward
/// (head advances along the arc), then dissolves tail-first while
/// drifting — the thought forms, then lets go.
const Spark = struct {
    active: bool = false,
    pts: [spark_pts][2]f32 = undefined,
    vel: [2]f32 = .{ 0, 0 },
    age: f32 = 0,
    life: f32 = 1,
    /// Seconds to fully draw the stroke.
    grow: f32 = 0.3,
    /// Beat-born thoughts burn brighter than idle musings.
    intensity: f32 = 1,
};

const smoothstep = bands_mod.smoothstep;

pub const Context = struct {
    allocator: std.mem.Allocator,
    audio: *audio_mod.AudioCapture,
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    now: f32 = 0,

    // The spark's body: a gentle spring toward wherever attention rests.
    pos: [2]f32 = .{ 0, 0 },
    vel: [2]f32 = .{ 0, 0 },
    rot: f32 = 0,
    rot_vel: f32 = 0,
    spin_sign: f32 = 1,
    flare: f32 = 0,
    /// Smoothed cursor-proximity envelope — the star brightens when noticed.
    curiosity: f32 = 0,

    /// Per-arm length envelopes, smoothed so the equalizer sways rather
    /// than jitters. Opposing arms share a band (the star stays symmetric).
    arm_len: [arms]f32 = [_]f32{0.8} ** arms,

    sparks: [max_sparks]Spark = [_]Spark{.{}} ** max_sparks,
    next_spark: u8 = 0,
    muse_timer: f32 = 4.0,

    // Audio analysis (voltaic pattern, shared in bands.zig).
    an: bands_mod.Splitter = .{},

    scale: f32 = 1.0,
    brightness: f32 = 1.0,

    cached_program: c.GLuint = 0,
    loc_body: c.GLint = -1,
    loc_vel: c.GLint = -1,
    loc_arm: c.GLint = -1,
    loc_spark_pts: c.GLint = -1,
    loc_spark_meta: c.GLint = -1,
    loc_time: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_mid: c.GLint = -1,
    loc_treble: c.GLint = -1,
    loc_energy: c.GLint = -1,
    loc_beat: c.GLint = -1,
    loc_bright: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const audio = try audio_mod.spawn(allocator, params);

        return .{
            .allocator = allocator,
            .audio = audio,
            .rng = std.Random.DefaultPrng.init(0x636c61756465), // "claude"
            .width = width,
            .height = height,
            .pos = .{ width * 0.5, height * 0.5 },
            .scale = params.getFloat("scale", 1.0),
            .brightness = params.getFloat("brightness", 1.0),
        };
    }

    /// Body radius this frame: breath, music, and beat flare folded in.
    fn radius(self: *const Context) f32 {
        return 44.0 * self.scale *
            (1.0 + 0.05 * @sin(self.now * 0.9) + self.an.energy * 0.10 + self.flare * 0.35 + self.curiosity * 0.07);
    }

    fn shedSpark(self: *Context, intensity: f32) void {
        const r = self.rng.random();
        const k = r.intRangeLessThan(u32, 0, arms);
        const ang0 = self.rot + @as(f32, @floatFromInt(k)) * (std.math.tau / @as(f32, arms));
        const tip_r = self.radius() * self.arm_len[k];
        const slot = self.next_spark;
        self.next_spark = (self.next_spark + 1) % max_sparks;
        const s = &self.sparks[slot];

        // Temperament: most thoughts are tight curls or lazy arcs; the
        // occasional straight dart is a decision leaving in a hurry.
        var curve: f32 = undefined;
        var step_base: f32 = undefined;
        var drift: f32 = undefined;
        const roll = r.float(f32);
        if (roll < 0.4) { // curl
            curve = 0.55 + r.float(f32) * 0.4;
            step_base = 8.0 + r.float(f32) * 4.0;
            drift = 22.0;
            s.life = 1.0 + r.float(f32) * 0.5;
            s.grow = 0.38;
        } else if (roll < 0.88) { // arc
            curve = 0.18 + r.float(f32) * 0.28;
            step_base = 13.0 + r.float(f32) * 7.0;
            drift = 34.0;
            s.life = 0.8 + r.float(f32) * 0.5;
            s.grow = 0.30;
        } else { // dart
            curve = r.float(f32) * 0.07;
            step_base = 20.0 + r.float(f32) * 10.0;
            drift = 85.0;
            s.life = 0.5 + r.float(f32) * 0.3;
            s.grow = 0.18;
        }
        if (r.boolean()) curve = -curve;

        var ang = ang0;
        var p = [2]f32{
            self.pos[0] + @cos(ang0) * tip_r,
            self.pos[1] + @sin(ang0) * tip_r,
        };
        for (0..spark_pts) |j| {
            s.pts[j] = p;
            ang += curve;
            p = .{ p[0] + @cos(ang) * step_base, p[1] + @sin(ang) * step_base };
        }
        s.vel = .{ @cos(ang0) * drift, @sin(ang0) * drift };
        s.age = 0;
        s.intensity = intensity;
        s.active = true;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;
        const r = self.rng.random();

        // ---- audio analysis (voltaic band split + flux beats, bands.zig) ----
        const wave = self.audio.getWaveform();
        const beat_hit = self.an.update(&wave, dt);

        // ---- listening: opposing arm pairs ride the bands ----
        // Pair map: bass, low-mid, high-mid, treble around the star.
        const pair_val = [4]f32{
            self.an.bass,
            self.an.bands[2],
            self.an.bands[3],
            self.an.treble,
        };
        for (0..arms) |k| {
            const target = 0.72 + @min(pair_val[k % 4], 1.3) * 0.55;
            self.arm_len[k] += (target - self.arm_len[k]) * @min(1.0, 10.0 * dt);
        }

        // ---- attention: hover near the focused window's corner ----
        var target = [2]f32{ 0, 0 };
        if (state.focused_win.hasArea()) {
            const fw = state.focused_win;
            target = .{ fw.x + fw.w + 64.0, fw.y + fw.h + 64.0 };
        } else {
            // Nothing focused: an unhurried wander around the middle field.
            target = .{
                self.width * (0.5 + 0.30 * @sin(self.now * 0.11)),
                self.height * (0.5 + 0.25 * @sin(self.now * 0.083 + 1.7)),
            };
        }
        // A little bob so hovering never reads as parked.
        target[0] += @sin(self.now * 0.7) * 10.0;
        target[1] += @cos(self.now * 0.53) * 8.0;
        const margin = 70.0;
        target[0] = std.math.clamp(target[0], margin, self.width - margin);
        target[1] = std.math.clamp(target[1], margin, self.height - margin);

        // Soft spring: glides over with a hint of overshoot, like interest.
        const k_spring: f32 = 14.0;
        const k_damp: f32 = 6.5;
        self.vel[0] += ((target[0] - self.pos[0]) * k_spring - self.vel[0] * k_damp) * dt;
        self.vel[1] += ((target[1] - self.pos[1]) * k_spring - self.vel[1] * k_damp) * dt;
        self.pos[0] += self.vel[0] * dt;
        self.pos[1] += self.vel[1] * dt;

        // ---- spin and flare ----
        self.rot_vel *= @exp(-1.6 * dt);
        self.rot += (0.15 + self.rot_vel) * dt;
        self.flare *= @exp(-5.0 * dt);
        if (beat_hit) {
            const punch = std.math.clamp(self.an.flux / (self.an.flux_avg * 3.0 + 0.03), 1.0, 2.0);
            self.flare = @max(self.flare, 0.20 + punch * 0.28);
            // Reverse spin only occasionally — momentum builds across a few
            // beats instead of twitching direction on every hit.
            if (r.float(f32) < 0.25) self.spin_sign = -self.spin_sign;
            self.rot_vel += self.spin_sign * (0.55 + punch * 0.7);
        }

        // ---- curiosity: notice the cursor when it comes close ----
        // The star leans toward a nearby pointer and brightens a touch —
        // attention isn't only windows; it's you.
        const cdx = state.cursor[0] - self.pos[0];
        const cdy = state.cursor[1] - self.pos[1];
        const cdist = @sqrt(cdx * cdx + cdy * cdy);
        const notice = smoothstep(420.0, 120.0, cdist);
        if (notice > 0.001 and cdist > 1.0) {
            self.vel[0] += cdx / cdist * notice * 60.0 * dt;
            self.vel[1] += cdy / cdist * notice * 60.0 * dt;
        }
        self.curiosity += (notice - self.curiosity) * @min(1.0, 4.0 * dt);

        // ---- thoughts ----
        for (&self.sparks) |*s| {
            if (!s.active) continue;
            s.age += dt;
            if (s.age >= s.life) {
                s.active = false;
                continue;
            }
            const damp = @exp(-1.5 * dt);
            s.vel[0] *= damp;
            s.vel[1] *= damp;
            for (&s.pts) |*p| {
                p[0] += s.vel[0] * dt;
                p[1] += s.vel[1] * dt;
            }
        }
        if (beat_hit) {
            const punch = std.math.clamp(self.an.flux / (self.an.flux_avg * 3.0 + 0.03), 1.0, 2.0);
            self.shedSpark(0.85 + punch * 0.35);
            self.shedSpark(0.85 + punch * 0.35);
        }
        // Idle musing: even in silence a thought escapes now and then,
        // dimmer and unhurried.
        self.muse_timer -= dt;
        if (self.muse_timer <= 0) {
            self.muse_timer = 3.0 + r.float(f32) * 4.0;
            self.shedSpark(0.55);
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_body = c.glGetUniformLocation(prog.program, "iFableBody");
            self.loc_vel = c.glGetUniformLocation(prog.program, "iFableVel");
            self.loc_arm = c.glGetUniformLocation(prog.program, "iArm[0]");
            self.loc_spark_pts = c.glGetUniformLocation(prog.program, "iSparkPts[0]");
            self.loc_spark_meta = c.glGetUniformLocation(prog.program, "iSparkMeta[0]");
            self.loc_time = c.glGetUniformLocation(prog.program, "iFableTime");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iBass");
            self.loc_mid = c.glGetUniformLocation(prog.program, "iMid");
            self.loc_treble = c.glGetUniformLocation(prog.program, "iTreble");
            self.loc_energy = c.glGetUniformLocation(prog.program, "iEnergy");
            self.loc_beat = c.glGetUniformLocation(prog.program, "iBeat");
            self.loc_bright = c.glGetUniformLocation(prog.program, "iBright");
        }

        if (self.loc_body >= 0) {
            c.glUniform4f(self.loc_body, self.pos[0], self.pos[1], self.radius(), self.rot);
        }
        if (self.loc_vel >= 0) {
            c.glUniform2f(self.loc_vel, self.vel[0], self.vel[1]);
        }
        if (self.loc_arm >= 0) {
            var av: [2][4]f32 = undefined;
            for (0..arms) |k| av[k / 4][k % 4] = self.arm_len[k];
            c.glUniform4fv(self.loc_arm, 2, @ptrCast(&av[0]));
        }
        if (self.loc_spark_pts >= 0 and self.loc_spark_meta >= 0) {
            var pts: [spark_vec4s][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** spark_vec4s;
            // Per spark: (head, tail, env, glint). Head advances 0->5 as
            // the stroke writes itself; tail follows 0->5 as it dissolves;
            // glint flashes the origin tip at the moment of shedding.
            var meta: [max_sparks][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** max_sparks;
            for (self.sparks, 0..) |s, i| {
                if (!s.active) continue;
                const p = s.age / s.life;
                const head = @min(s.age / s.grow, 1.0) * 5.0;
                const tail = std.math.clamp((p - 0.55) / 0.42, 0.0, 1.0) * 5.0;
                const env = s.intensity * (1.0 - p * p * 0.45);
                const glint = s.intensity * @max(1.0 - s.age / 0.25, 0.0);
                meta[i] = .{ head, tail, env, glint };
                for (0..spark_pts) |j| {
                    const gi = i * spark_pts + j;
                    pts[gi / 2][(gi % 2) * 2] = s.pts[j][0];
                    pts[gi / 2][(gi % 2) * 2 + 1] = s.pts[j][1];
                }
            }
            c.glUniform4fv(self.loc_spark_pts, spark_vec4s, @ptrCast(&pts[0]));
            c.glUniform4fv(self.loc_spark_meta, max_sparks, @ptrCast(&meta[0]));
        }

        // Effect-local time (fire.zig pattern) — keeps shader noise
        // coordinates small so f32 precision holds over long sessions.
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.an.bass);
        if (self.loc_mid >= 0) c.glUniform1f(self.loc_mid, self.an.mid);
        if (self.loc_treble >= 0) c.glUniform1f(self.loc_treble, self.an.treble);
        if (self.loc_energy >= 0) c.glUniform1f(self.loc_energy, self.an.energy);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.an.beat);
        // Curiosity brightens the whole body a touch when the cursor is near.
        if (self.loc_bright >= 0) c.glUniform1f(self.loc_bright, self.brightness * (1.0 + self.curiosity * 0.25));
    }

    pub fn deinit(self: *Context) void {
        audio_mod.shutdown(self.audio, self.allocator);
    }
};
