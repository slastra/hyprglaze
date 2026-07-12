const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");

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
const spark_meta_vec4s = max_sparks / 4;

/// A thought: a short arc shed from an arm tip, drifting and dissolving.
const Spark = struct {
    active: bool = false,
    pts: [spark_pts][2]f32 = undefined,
    vel: [2]f32 = .{ 0, 0 },
    age: f32 = 0,
    life: f32 = 1,
};

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

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

    // Audio analysis (voltaic pattern).
    bands: [6]f32 = [_]f32{0} ** 6,
    bass: f32 = 0,
    mid: f32 = 0,
    treble: f32 = 0,
    energy: f32 = 0,
    bass_smooth: f32 = 0,
    bass_prev: f32 = 0,
    flux_avg: f32 = 0,
    beat: f32 = 0,
    beat_cooldown: f32 = 0,

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
        const sink = params.getString("sink", null);
        const audio = try allocator.create(audio_mod.AudioCapture);
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();

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
            (1.0 + 0.05 * @sin(self.now * 0.9) + self.energy * 0.10 + self.flare * 0.35 + self.curiosity * 0.07);
    }

    fn shedSpark(self: *Context) void {
        const r = self.rng.random();
        const k = r.intRangeLessThan(u32, 0, arms);
        const ang0 = self.rot + @as(f32, @floatFromInt(k)) * (std.math.tau / @as(f32, arms));
        const tip_r = self.radius() * self.arm_len[k];
        const slot = self.next_spark;
        self.next_spark = (self.next_spark + 1) % max_sparks;
        const s = &self.sparks[slot];
        var ang = ang0;
        const curve = (0.22 + r.float(f32) * 0.5) * (if (r.boolean()) @as(f32, 1.0) else -1.0);
        var p = [2]f32{
            self.pos[0] + @cos(ang0) * tip_r,
            self.pos[1] + @sin(ang0) * tip_r,
        };
        for (0..spark_pts) |j| {
            s.pts[j] = p;
            const step = 13.0 + r.float(f32) * 8.0;
            ang += curve;
            p = .{ p[0] + @cos(ang) * step, p[1] + @sin(ang) * step };
        }
        s.vel = .{ @cos(ang0) * 34.0, @sin(ang0) * 34.0 };
        s.age = 0;
        s.life = 0.8 + r.float(f32) * 0.5;
        s.active = true;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;
        const r = self.rng.random();

        // ---- audio analysis (voltaic band split + flux beats) ----
        const wave = self.audio.getWaveform();
        const ranges = [_][2]u8{ .{ 0, 10 }, .{ 10, 25 }, .{ 25, 45 }, .{ 45, 70 }, .{ 70, 95 }, .{ 95, 128 } };
        for (0..6) |bi| {
            var en: f32 = 0;
            const lo = ranges[bi][0];
            const hi = ranges[bi][1];
            for (lo..hi) |j| en += @abs(wave[j]) + @abs(wave[128 + j]);
            en /= @floatFromInt((hi - lo) * 2);
            const raw = en * 6.0;
            const attack = @min(1.0, 25.0 * dt);
            const decay = @min(1.0, 5.0 * dt);
            self.bands[bi] += (raw - self.bands[bi]) * (if (raw > self.bands[bi]) attack else decay);
        }
        self.bass = (self.bands[0] + self.bands[1]) * 0.5;
        self.mid = (self.bands[2] + self.bands[3]) * 0.5;
        self.treble = (self.bands[4] + self.bands[5]) * 0.5;
        self.energy = (self.bands[0] + self.bands[1] + self.bands[2] +
            self.bands[3] + self.bands[4] + self.bands[5]) / 6.0;

        self.bass_smooth += (self.bass - self.bass_smooth) * @min(1.0, 0.8 * dt);
        const flux = @max(0.0, self.bass - self.bass_prev);
        self.bass_prev = self.bass;
        self.flux_avg += (flux - self.flux_avg) * @min(1.0, 1.5 * dt);
        self.beat_cooldown -= dt;
        var beat_hit = false;
        if (flux > self.flux_avg * 3.0 + 0.03 and self.beat_cooldown <= 0 and self.bass > self.bass_smooth * 1.5) {
            self.beat = 1.0;
            self.beat_cooldown = 0.25;
            beat_hit = true;
        }
        self.beat *= @exp(-4.0 * dt);
        if (self.beat < 0.01) self.beat = 0;

        // ---- listening: opposing arm pairs ride the bands ----
        // Pair map: bass, low-mid, high-mid, treble around the star.
        const pair_val = [4]f32{
            self.bass,
            self.bands[2],
            self.bands[3],
            self.treble,
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
            const punch = std.math.clamp(flux / (self.flux_avg * 3.0 + 0.03), 1.0, 2.0);
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
            self.shedSpark();
            self.shedSpark();
        }
        // Idle musing: even in silence a thought escapes now and then.
        self.muse_timer -= dt;
        if (self.muse_timer <= 0) {
            self.muse_timer = 3.0 + r.float(f32) * 4.0;
            self.shedSpark();
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
            var meta: [spark_meta_vec4s][4]f32 = [_][4]f32{.{ 0, 0, 0, 0 }} ** spark_meta_vec4s;
            for (self.sparks, 0..) |s, i| {
                if (!s.active) continue;
                const p = s.age / s.life;
                meta[i / 4][i % 4] = smoothstep(0.0, 0.10, p) * (1.0 - p) * (1.0 - p);
                for (0..spark_pts) |j| {
                    const gi = i * spark_pts + j;
                    pts[gi / 2][(gi % 2) * 2] = s.pts[j][0];
                    pts[gi / 2][(gi % 2) * 2 + 1] = s.pts[j][1];
                }
            }
            c.glUniform4fv(self.loc_spark_pts, spark_vec4s, @ptrCast(&pts[0]));
            c.glUniform4fv(self.loc_spark_meta, spark_meta_vec4s, @ptrCast(&meta[0]));
        }

        // Effect-local time (fire.zig pattern) — keeps shader noise
        // coordinates small so f32 precision holds over long sessions.
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.bass);
        if (self.loc_mid >= 0) c.glUniform1f(self.loc_mid, self.mid);
        if (self.loc_treble >= 0) c.glUniform1f(self.loc_treble, self.treble);
        if (self.loc_energy >= 0) c.glUniform1f(self.loc_energy, self.energy);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.beat);
        // Curiosity brightens the whole body a touch when the cursor is near.
        if (self.loc_bright >= 0) c.glUniform1f(self.loc_bright, self.brightness * (1.0 + self.curiosity * 0.25));
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
    }
};
