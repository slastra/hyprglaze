const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const effects = @import("../../effects.zig");
const audio_mod = @import("../visualizer/audio.zig");
const boids_mod = @import("boids.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const TRAIL_LEN = 4;
const TRAIL_HISTORY = 24;
const SLOTS_PER = TRAIL_LEN + 1;
const MAX_BOIDS = 300 / SLOTS_PER; // 60

pub const Context = struct {
    audio: *audio_mod.AudioCapture,
    sys: boids_mod.BoidSystem,
    allocator: std.mem.Allocator,

    // Position history ring buffer for trails
    history: [boids_mod.max_boids][TRAIL_HISTORY][2]f32 = undefined,
    history_idx: u32 = 0,

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

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const sink = params.getString("sink", null);
        const audio = try allocator.create(audio_mod.AudioCapture);
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();

        var count: u32 = @intCast(params.getInt("count", 60));
        count = @min(count, MAX_BOIDS);

        var sys = boids_mod.BoidSystem.init(count, width, height);
        sys.base_speed = params.getFloat("speed", 200.0);
        sys.perception = params.getFloat("perception", 150.0);
        sys.separation_dist = params.getFloat("separation", 40.0);

        var ctx = Context{
            .audio = audio,
            .sys = sys,
            .allocator = allocator,
        };

        // Seed history with initial positions
        for (0..count) |i| {
            for (0..TRAIL_HISTORY) |h| {
                ctx.history[i][h] = .{ sys.boids[i].x, sys.boids[i].y };
            }
        }
        return ctx;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
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
        if (self.flux > self.flux_avg * 3.0 + 0.03 and self.beat_cooldown <= 0 and self.bass_instant > self.bass_smooth * 1.5) {
            self.beat = 1.0;
            self.beat_cooldown = 0.25;
        }
        self.beat *= @exp(-4.0 * dt);
        if (self.beat < 0.01) self.beat = 0;

        // Update screen dimensions from FrameState windows
        if (state.windows.len > 0) {
            // Infer screen size from the first window's parent info or just use
            // a large-enough boundary. The collision_rects and cursor positions
            // are in screen coordinates, so we track via iResolution if available.
        }

        // Update boid simulation
        self.sys.update(dt, state.cursor[0], state.cursor[1], state.collision_rects, .{
            .bass = self.bass,
            .beat = self.beat,
            .total_energy = self.total_energy,
        });

        // Record position history
        const idx = self.history_idx % TRAIL_HISTORY;
        for (0..self.sys.count) |i| {
            self.history[i][idx] = .{ self.sys.boids[i].x, self.sys.boids[i].y };
        }
        self.history_idx +%= 1;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);

        const count = @min(self.sys.count, MAX_BOIDS);
        var slot: u32 = 0;
        const spacing = TRAIL_HISTORY / TRAIL_LEN;

        for (0..count) |i| {
            if (slot >= 300) break;
            const b = self.sys.boids[i];

            // Head: (pos.x, pos.y, heading, color_idx)
            if (prog.i_particles[slot] >= 0) {
                c.glUniform4f(prog.i_particles[slot], b.x, b.y, b.heading, b.color_idx);
            }
            slot += 1;

            // Trail dots
            for (0..TRAIL_LEN) |t| {
                if (slot >= 300) break;
                const age = (t + 1) * spacing;
                const h_idx = (self.history_idx -% @as(u32, @intCast(age))) % TRAIL_HISTORY;
                const pos = self.history[i][h_idx];

                const fade: f32 = 1.0 - @as(f32, @floatFromInt(t + 1)) / @as(f32, @floatFromInt(TRAIL_LEN + 1));
                const trail_size = b.size * fade;
                const age_tag: f32 = @as(f32, @floatFromInt(t + 1)) * 10.0;

                if (prog.i_particles[slot] >= 0) {
                    c.glUniform4f(prog.i_particles[slot], pos[0], pos[1], trail_size, b.color_idx + age_tag);
                }
                slot += 1;
            }
        }

        if (prog.i_particle_count >= 0) {
            c.glUniform1i(prog.i_particle_count, @intCast(slot));
        }

        // Custom audio uniforms
        var name_buf: [16]u8 = undefined;
        for (0..6) |i| {
            const bn = std.fmt.bufPrintZ(&name_buf, "iBands[{d}]", .{i}) catch continue;
            const loc = c.glGetUniformLocation(prog.program, bn.ptr);
            if (loc >= 0) c.glUniform1f(loc, self.bands[i]);
        }
        const beat_loc = c.glGetUniformLocation(prog.program, "iBeat");
        if (beat_loc >= 0) c.glUniform1f(beat_loc, self.beat);
        const bass_loc = c.glGetUniformLocation(prog.program, "iBass");
        if (bass_loc >= 0) c.glUniform1f(bass_loc, self.bass);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
    }
};
