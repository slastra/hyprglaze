const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const audio_mod = @import("visualizer/audio.zig");
const rhythm_mod = @import("meshflow/rhythm.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

pub const Context = struct {
    const max_segments = 240;
    const Tip = struct { x: f32, y: f32, angle: f32, len: f32, depth: u8, parent: i16 };

    audio: *audio_mod.AudioCapture,
    rhythm: rhythm_mod.RhythmEngine,
    state: rhythm_mod.RhythmState = .{},
    allocator: std.mem.Allocator,
    scale: f32,
    prev_cursor: [2]f32 = .{ 0, 0 },
    cursor_velocity: [2]f32 = .{ 0, 0 },
    disturbance: f32 = 0,
    initialized: bool = false,
    segments: [max_segments][4]f32 = undefined,
    segment_meta: [max_segments]f32 = undefined,
    base_angles: [max_segments]f32 = undefined,
    base_lengths: [max_segments]f32 = undefined,
    parents: [max_segments]i16 = undefined,
    segment_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const audio = try allocator.create(audio_mod.AudioCapture);
        errdefer allocator.destroy(audio);
        audio.* = audio_mod.AudioCapture.init(params.getString("sink", null));
        audio.start();
        errdefer audio.stop();
        var result: Context = .{
            .audio = audio,
            .rhythm = try rhythm_mod.RhythmEngine.init(allocator),
            .allocator = allocator,
            .scale = @max(width, height),
        };
        result.generateNetwork(width, height);
        return result;
    }

    fn generateNetwork(self: *Context, width: f32, height: f32) void {
        var rng = std.Random.DefaultPrng.init(0x6d7963656c69756d); // "mycelium"
        const random = rng.random();
        var queue: [512]Tip = undefined;
        var head: usize = 0;
        var tail: usize = 0;

        // Colonies enter from every edge and grow inward. Breadth-first
        // expansion prevents the first root from consuming the segment budget.
        for (0..2) |i| {
            const f = (@as(f32, @floatFromInt(i)) + 0.7) / 2.4;
            queue[tail] = .{ .x = f * width, .y = -22, .angle = std.math.pi * (0.42 + random.float(f32) * 0.16), .len = 175 + random.float(f32) * 55, .depth = 0, .parent = -1 };
            tail += 1;
            queue[tail] = .{ .x = (1.0 - f) * width, .y = height + 22, .angle = -std.math.pi * (0.42 + random.float(f32) * 0.16), .len = 175 + random.float(f32) * 55, .depth = 0, .parent = -1 };
            tail += 1;
        }
        queue[tail] = .{ .x = -22, .y = height * 0.58, .angle = (random.float(f32) - 0.5) * 0.28, .len = 190 + random.float(f32) * 55, .depth = 0, .parent = -1 };
        tail += 1;
        queue[tail] = .{ .x = width + 22, .y = height * 0.34, .angle = std.math.pi + (random.float(f32) - 0.5) * 0.28, .len = 190 + random.float(f32) * 55, .depth = 0, .parent = -1 };
        tail += 1;

        while (head < tail and self.segment_count < max_segments) : (head += 1) {
            const tip = queue[head];
            const bend = (random.float(f32) - 0.5) * 0.48;
            const angle = tip.angle + bend;
            const x2 = tip.x + @cos(angle) * tip.len;
            const y2 = tip.y + @sin(angle) * tip.len;
            const segment_index = self.segment_count;
            self.segments[segment_index] = .{ tip.x, tip.y, x2, y2 };
            self.segment_meta[segment_index] = @as(f32, @floatFromInt(tip.depth)) / 10.0;
            self.base_angles[segment_index] = angle;
            self.base_lengths[segment_index] = tip.len;
            self.parents[segment_index] = tip.parent;
            self.segment_count += 1;

            if (tip.depth >= 9 or tip.len < 11 or tail + 2 >= queue.len) continue;
            const next_len = tip.len * (0.72 + random.float(f32) * 0.13);
            const spread = 0.34 + random.float(f32) * 0.35;
            queue[tail] = .{ .x = x2, .y = y2, .angle = angle + spread, .len = next_len, .depth = tip.depth + 1, .parent = @intCast(segment_index) };
            tail += 1;
            // Most generations fork, but gaps keep the silhouette fungal
            // rather than becoming a perfectly balanced ornamental tree.
            if (random.float(f32) < 0.78) {
                queue[tail] = .{ .x = x2, .y = y2, .angle = angle - spread * (0.75 + random.float(f32) * 0.5), .len = next_len * (0.80 + random.float(f32) * 0.16), .depth = tip.depth + 1, .parent = @intCast(segment_index) };
                tail += 1;
            }
        }

        // Mark endpoints which never became parents as living growth tips.
        for (0..self.segment_count) |i| {
            const end_x = self.segments[i][2];
            const end_y = self.segments[i][3];
            var has_child = false;
            for (i + 1..self.segment_count) |j| {
                const dx = self.segments[j][0] - end_x;
                const dy = self.segments[j][1] - end_y;
                if (dx * dx + dy * dy < 0.25) {
                    has_child = true;
                    break;
                }
            }
            if (!has_child) self.segment_meta[i] = -self.segment_meta[i] - 0.05;
        }
    }

    pub fn update(self: *Context, fs: effects.FrameState) void {
        const wave = self.audio.getWaveform();
        self.state = self.rhythm.tick(&wave, fs.dt);
        const dt = @max(1.0 / 240.0, @min(fs.dt, 0.05));
        if (!self.initialized) {
            self.prev_cursor = fs.cursor;
            self.initialized = true;
        }
        const raw = [2]f32{
            (fs.cursor[0] - self.prev_cursor[0]) / dt,
            (fs.cursor[1] - self.prev_cursor[1]) / dt,
        };
        const alpha = 1.0 - @exp(-dt * 14.0);
        self.cursor_velocity[0] += (raw[0] - self.cursor_velocity[0]) * alpha;
        self.cursor_velocity[1] += (raw[1] - self.cursor_velocity[1]) * alpha;
        const speed = @sqrt(raw[0] * raw[0] + raw[1] * raw[1]);
        self.disturbance = @max(@min(speed / self.scale, 1.0), self.disturbance * @exp(-dt * 2.2));
        self.prev_cursor = fs.cursor;
        self.animateNetwork(fs);
    }

    fn animateNetwork(self: *Context, fs: effects.FrameState) void {
        for (0..self.segment_count) |i| {
            const parent = self.parents[i];
            if (parent >= 0) {
                const p: usize = @intCast(parent);
                self.segments[i][0] = self.segments[p][2];
                self.segments[i][1] = self.segments[p][3];
            }

            const generation = @abs(self.segment_meta[i]);
            var angle = self.base_angles[i];
            // Old load-bearing trunks barely move; young hyphae continuously
            // search the substrate with independent slow phases.
            angle += @sin(fs.time * (0.42 + generation * 0.35) + @as(f32, @floatFromInt(i)) * 1.731) * (0.008 + generation * 0.075);

            const start_x = self.segments[i][0];
            const start_y = self.segments[i][1];
            const probe_x = start_x + @cos(angle) * self.base_lengths[i];
            const probe_y = start_y + @sin(angle) * self.base_lengths[i];

            // Windows behave like nutrient slabs. Nearby young branches steer
            // toward their closest center, and the focused slab is richest.
            var best_dist_sq: f32 = 520.0 * 520.0;
            var target_angle: ?f32 = null;
            for (fs.windows) |win| {
                const cx = win.x + win.w * 0.5;
                const cy = win.y + win.h * 0.5;
                const dx = cx - probe_x;
                const dy = cy - probe_y;
                const dsq = dx * dx + dy * dy;
                if (dsq < best_dist_sq) {
                    best_dist_sq = dsq;
                    target_angle = std.math.atan2(dy, dx);
                }
            }
            if (target_angle) |target| {
                const delta = std.math.atan2(@sin(target - angle), @cos(target - angle));
                const proximity = 1.0 - @sqrt(best_dist_sq) / 520.0;
                angle += delta * proximity * generation * 0.10;
            }

            // Cursor steering is deliberately anatomical only: no ring, trail,
            // or gradient is rendered at the pointer.
            const cdx = fs.cursor[0] - probe_x;
            const cdy = fs.cursor[1] - probe_y;
            const cdsq = cdx * cdx + cdy * cdy;
            if (cdsq < 360.0 * 360.0) {
                const target = std.math.atan2(cdy, cdx);
                const delta = std.math.atan2(@sin(target - angle), @cos(target - angle));
                const proximity = 1.0 - @sqrt(cdsq) / 360.0;
                angle += delta * proximity * generation * (0.025 + self.disturbance * 0.12);
            }

            self.segments[i][2] = start_x + @cos(angle) * self.base_lengths[i];
            self.segments[i][3] = start_y + @sin(angle) * self.base_lengths[i];
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        c.glUseProgram(prog.program);
        var buf: [24]u8 = undefined;
        for (0..rhythm_mod.n_bands) |i| {
            const band = std.fmt.bufPrintZ(&buf, "iMycBands[{d}]", .{i}) catch continue;
            const bl = c.glGetUniformLocation(prog.program, band.ptr);
            if (bl >= 0) c.glUniform1f(bl, self.state.bands[i]);
            const onset = std.fmt.bufPrintZ(&buf, "iMycOnsets[{d}]", .{i}) catch continue;
            const ol = c.glGetUniformLocation(prog.program, onset.ptr);
            if (ol >= 0) c.glUniform1f(ol, self.state.onsets[i]);
        }
        setFloat(prog.program, "iMycBeat", self.state.beat_phase);
        setFloat(prog.program, "iMycDownbeat", self.state.down_phase);
        const gesture = c.glGetUniformLocation(prog.program, "iMycGesture");
        if (gesture >= 0) c.glUniform4f(gesture, self.cursor_velocity[0], self.cursor_velocity[1], self.disturbance, 0);

        for (0..self.segment_count) |i| {
            const seg_name = std.fmt.bufPrintZ(&buf, "iMycSegments[{d}]", .{i}) catch continue;
            const sl = c.glGetUniformLocation(prog.program, seg_name.ptr);
            if (sl >= 0) c.glUniform4fv(sl, 1, &self.segments[i]);
        }
        for (0..(self.segment_count + 3) / 4) |slot| {
            var meta_values: [4]f32 = .{ 0, 0, 0, 0 };
            for (0..4) |lane| {
                const idx = slot * 4 + lane;
                if (idx < self.segment_count) meta_values[lane] = self.segment_meta[idx];
            }
            const meta_name = std.fmt.bufPrintZ(&buf, "iMycMeta[{d}]", .{slot}) catch continue;
            const ml = c.glGetUniformLocation(prog.program, meta_name.ptr);
            if (ml >= 0) c.glUniform4fv(ml, 1, &meta_values);
        }
        const count_loc = c.glGetUniformLocation(prog.program, "iMycSegmentCount");
        if (count_loc >= 0) c.glUniform1i(count_loc, @intCast(self.segment_count));
    }

    fn setFloat(program: c.GLuint, name: [*:0]const u8, value: f32) void {
        const loc = c.glGetUniformLocation(program, name);
        if (loc >= 0) c.glUniform1f(loc, value);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
        self.rhythm.deinit();
    }
};
