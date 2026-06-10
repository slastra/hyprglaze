const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const effects = @import("../../effects.zig");
const audio_mod = @import("../visualizer/audio.zig");
const boids_mod = @import("boids.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// Field resolution: the flock is splatted into this grid each frame and the
// shader renders the field, not the boids — that's what turns dots into a
// continuous murmuration. ~19px cells at 3072x1728; bilinear filtering and
// shader-side noise hide the grid entirely.
const field_w = 160;
const field_h = 90;
const field_cells = field_w * field_h;

// Velocity normalization for the RG channels (pixels/sec mapped to ±1).
const vel_scale: f32 = 700.0;

const Accum = struct {
    dens: [field_cells]f32,
    velx: [field_cells]f32,
    vely: [field_cells]f32,
    agit: [field_cells]f32,
    bytes: [field_cells * 4]u8,
};

pub const Context = struct {
    audio: *audio_mod.AudioCapture,
    sys: boids_mod.BoidSystem,
    allocator: std.mem.Allocator,
    accum: *Accum,

    now: f32 = 0,

    // Audio analysis (glitch.zig pattern)
    bands: [6]f32 = [_]f32{0} ** 6,
    bass: f32 = 0,
    bass_instant: f32 = 0,
    bass_smooth: f32 = 0,
    bass_prev: f32 = 0,
    flux: f32 = 0,
    flux_avg: f32 = 0,
    beat: f32 = 0,
    beat_cooldown: f32 = 0,
    total_energy: f32 = 0,

    /// Roost state: sustained silence settles the flock onto window tops;
    /// returning music bursts it back into the air.
    quiet_t: f32 = 0,
    roost: f32 = 0,

    /// Field texture — created lazily on first upload, when GL is current.
    tex: c.GLuint = 0,
    cached_program: c.GLuint = 0,
    loc_field: c.GLint = -1,
    loc_time: c.GLint = -1,
    loc_beat: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_energy: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const sink = params.getString("sink", null);
        const audio = try allocator.create(audio_mod.AudioCapture);
        errdefer allocator.destroy(audio);
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();

        const accum = try allocator.create(Accum);
        accum.* = std.mem.zeroes(Accum);

        var count: u32 = @intCast(params.getInt("count", 240));
        count = @min(count, boids_mod.max_boids);

        var sys = boids_mod.BoidSystem.init(count, width, height);
        sys.base_speed = params.getFloat("speed", 220.0);
        sys.perception = params.getFloat("perception", 240.0);
        sys.separation_dist = params.getFloat("separation", 54.0);

        return .{
            .audio = audio,
            .sys = sys,
            .allocator = allocator,
            .accum = accum,
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
        self.now += dt;
        const wave = self.audio.getWaveform();

        // 6 spectrum bands from waveform (same as glitch.zig)
        const ranges = [_][2]u8{ .{ 0, 10 }, .{ 10, 25 }, .{ 25, 45 }, .{ 45, 70 }, .{ 70, 95 }, .{ 95, 128 } };
        var energy_sum: f32 = 0;
        for (0..6) |b| {
            var energy: f32 = 0;
            const lo = ranges[b][0];
            const hi = ranges[b][1];
            for (lo..hi) |j| {
                energy += @abs(wave[j]) + @abs(wave[128 + j]);
            }
            energy /= @as(f32, @floatFromInt((hi - lo) * 2));
            const raw = energy * 6.0;
            const attack = @min(1.0, 25.0 * dt);
            const decay = @min(1.0, 5.0 * dt);
            self.bands[b] += (raw - self.bands[b]) * (if (raw > self.bands[b]) attack else decay);
            energy_sum += self.bands[b];
        }
        self.total_energy = energy_sum / 6.0;

        // Beat detection (spectral flux)
        const bass_e = (self.bands[0] + self.bands[1]) * 0.5;
        self.bass = bass_e;
        self.bass_instant = bass_e;
        self.bass_smooth += (bass_e - self.bass_smooth) * @min(1.0, 0.8 * dt);

        const flux_raw = @max(0.0, self.bass_instant - self.bass_prev);
        self.bass_prev = self.bass_instant;
        self.flux = flux_raw;
        self.flux_avg += (flux_raw - self.flux_avg) * @min(1.0, 1.5 * dt);

        self.beat_cooldown -= dt;
        var beat_hit = false;
        var punch: f32 = 1.0;
        if (self.flux > self.flux_avg * 3.0 + 0.03 and self.beat_cooldown <= 0 and self.bass_instant > self.bass_smooth * 1.5) {
            self.beat = 1.0;
            self.beat_cooldown = 0.25;
            beat_hit = true;
            punch = std.math.clamp(self.flux / (self.flux_avg * 3.0 + 0.03), 1.0, 2.0);
        }
        self.beat *= @exp(-4.0 * dt);
        if (self.beat < 0.01) self.beat = 0;

        // Silence settles the flock; sound lifts it. Roost ramps in slowly
        // (the birds drift down over a few seconds) but releases fast.
        if (self.total_energy < 0.05) {
            self.quiet_t += dt;
        } else {
            self.quiet_t = @max(0.0, self.quiet_t - dt * 6.0);
        }
        const roost_target: f32 = std.math.clamp((self.quiet_t - 4.0) / 3.0, 0.0, 1.0);
        const roost_prev = self.roost;
        const roost_k: f32 = if (roost_target > self.roost) 0.5 else 2.5;
        self.roost += (roost_target - self.roost) * @min(1.0, roost_k * dt);
        // The frame the roost breaks, the flock explodes off its perches.
        const burst = roost_prev > 0.55 and self.roost <= 0.55;

        // Flock + predator simulation
        self.sys.update(dt, state.cursor[0], state.cursor[1], state.collision_rects, .{
            .bass = self.bass,
            .beat = self.beat,
            .beat_hit = beat_hit,
            .punch = punch,
            .total_energy = self.total_energy,
            .roost = self.roost,
            .burst = burst,
        });

        self.splatField();
    }

    /// Rasterize the flock into the density/velocity/agitation field.
    /// Each boid drops a 3x3 gaussian; velocity is density-weighted so the
    /// shader can streak the cloud along local motion.
    fn splatField(self: *Context) void {
        const a = self.accum;
        @memset(&a.dens, 0);
        @memset(&a.velx, 0);
        @memset(&a.vely, 0);
        @memset(&a.agit, 0);

        const sx = @as(f32, field_w) / self.sys.width;
        const sy = @as(f32, field_h) / self.sys.height;

        for (0..self.sys.count) |i| {
            const b = self.sys.boids[i];
            const fx = b.x * sx;
            const fy = b.y * sy;
            const cx: i32 = @intFromFloat(@floor(fx));
            const cy: i32 = @intFromFloat(@floor(fy));

            var oy: i32 = -3;
            while (oy <= 3) : (oy += 1) {
                var ox: i32 = -3;
                while (ox <= 3) : (ox += 1) {
                    const gx = cx + ox;
                    const gy = cy + oy;
                    if (gx < 0 or gx >= field_w or gy < 0 or gy >= field_h) continue;
                    const dx = (@as(f32, @floatFromInt(gx)) + 0.5) - fx;
                    const dy = (@as(f32, @floatFromInt(gy)) + 0.5) - fy;
                    const w = @exp(-(dx * dx + dy * dy) * 0.22);
                    const idx: usize = @intCast(gy * field_w + gx);
                    a.dens[idx] += w;
                    a.velx[idx] += b.vx * w;
                    a.vely[idx] += b.vy * w;
                    a.agit[idx] += b.agit * w;
                }
            }
        }

        // Pack to RGBA8: R/G = density-weighted velocity (biased ±vel_scale),
        // B = agitation, A = soft-saturated density.
        for (0..field_cells) |i| {
            const d = a.dens[i];
            var vx: f32 = 0;
            var vy: f32 = 0;
            var ag: f32 = 0;
            if (d > 0.001) {
                vx = std.math.clamp(a.velx[i] / d / vel_scale, -1.0, 1.0);
                vy = std.math.clamp(a.vely[i] / d / vel_scale, -1.0, 1.0);
                ag = std.math.clamp(a.agit[i] / d, 0.0, 1.0);
            }
            const dens = 1.0 - @exp(-d * 0.55);
            a.bytes[i * 4 + 0] = @intFromFloat((vx * 0.5 + 0.5) * 255.0);
            a.bytes[i * 4 + 1] = @intFromFloat((vy * 0.5 + 0.5) * 255.0);
            a.bytes[i * 4 + 2] = @intFromFloat(ag * 255.0);
            a.bytes[i * 4 + 3] = @intFromFloat(dens * 255.0);
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        if (self.tex == 0) {
            c.glGenTextures(1, &self.tex);
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, field_w, field_h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        }

        if (self.cached_program != prog.program) {
            self.cached_program = prog.program;
            self.loc_field = c.glGetUniformLocation(prog.program, "iField");
            self.loc_time = c.glGetUniformLocation(prog.program, "iSwarmTime");
            self.loc_beat = c.glGetUniformLocation(prog.program, "iBeat");
            self.loc_bass = c.glGetUniformLocation(prog.program, "iBass");
            self.loc_energy = c.glGetUniformLocation(prog.program, "iEnergy");
        }

        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, field_w, field_h, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &self.accum.bytes[0]);
        if (self.loc_field >= 0) c.glUniform1i(self.loc_field, 0);

        // Effect-local time (fire.zig pattern) for noise precision.
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.beat);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.bass);
        if (self.loc_energy >= 0) c.glUniform1f(self.loc_energy, self.total_energy);
    }

    pub fn deinit(self: *Context) void {
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
        self.audio.stop();
        self.allocator.destroy(self.audio);
        self.allocator.destroy(self.accum);
    }
};
