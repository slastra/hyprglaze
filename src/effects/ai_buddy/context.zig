const std = @import("std");
const iohelp = @import("../../core/io_helper.zig");
const shader_mod = @import("../../core/shader.zig");
const texture_mod = @import("../../core/texture.zig");
const config_mod = @import("../../core/config.zig");
const transition_mod = @import("../../core/transition.zig");
const effects = @import("../../effects.zig");
const sprite = @import("../buddy/sprite.zig");
const ai_mod = @import("ai.zig");
const events_mod = @import("events.zig");
const physics = @import("physics.zig");
const behaviors = @import("behaviors.zig");
const ai_brain = @import("ai_brain.zig");

const log = std.log.scoped(.ai_buddy);

const c = @cImport({
    @cInclude("GLES3/gl3.h");
    @cInclude("time.h");
});

const Anim = sprite.Anim;
const Behavior = sprite.Behavior;
// Only the JUMP row is referenced here (advanceFrame freezes on jump while
// airborne). The rest of the sprite anim aliases live in behaviors.zig.
const JUMP = sprite.JUMP;

pub const Mood = enum(u8) {
    neutral = 0,
    happy = 1,
    curious = 2,
    sleepy = 3,
    bored = 4,
    excited = 5,
    anxious = 6,
};

pub const TimePeriod = enum { morning, afternoon, evening, night };

pub const EmoteType = enum(u8) {
    none = 0,
    heart = 1,
    star = 2,
    zzz = 3,
    exclaim = 4,
    music = 5,
    question = 6,
};

pub const EmoteParticle = struct {
    etype: EmoteType = .none,
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    life: f32 = 0,
    max_life: f32 = 1.5,
};

const max_emotes = 6;

pub fn getLocalHour() u8 {
    var t = c.time(null);
    const tm = c.localtime(&t);
    if (tm) |local| {
        return @intCast(@as(u32, @bitCast(local.*.tm_hour)));
    }
    return 12;
}

pub fn timePeriod(hour: u8) TimePeriod {
    if (hour >= 6 and hour < 12) return .morning;
    if (hour >= 12 and hour < 18) return .afternoon;
    if (hour >= 18 and hour < 23) return .evening;
    return .night;
}

pub fn timePeriodName(p: TimePeriod) []const u8 {
    return switch (p) {
        .morning => "morning",
        .afternoon => "afternoon",
        .evening => "evening",
        .night => "night",
    };
}

pub fn moodName(m: Mood) []const u8 {
    return switch (m) {
        .neutral => "neutral",
        .happy => "happy",
        .curious => "curious",
        .sleepy => "sleepy",
        .bored => "bored",
        .excited => "excited",
        .anxious => "anxious",
    };
}

pub fn mapMood(name: []const u8) Mood {
    const moods = [_]struct { n: []const u8, m: Mood }{
        .{ .n = "happy", .m = .happy },
        .{ .n = "curious", .m = .curious },
        .{ .n = "sleepy", .m = .sleepy },
        .{ .n = "bored", .m = .bored },
        .{ .n = "excited", .m = .excited },
        .{ .n = "anxious", .m = .anxious },
        .{ .n = "neutral", .m = .neutral },
    };
    for (moods) |entry| {
        if (std.mem.eql(u8, name, entry.n)) return entry.m;
    }
    return .neutral;
}

pub fn mapEmote(name: []const u8) EmoteType {
    const emotes = [_]struct { n: []const u8, e: EmoteType }{
        .{ .n = "heart", .e = .heart },
        .{ .n = "star", .e = .star },
        .{ .n = "zzz", .e = .zzz },
        .{ .n = "exclaim", .e = .exclaim },
        .{ .n = "music", .e = .music },
        .{ .n = "question", .e = .question },
    };
    for (emotes) |entry| {
        if (std.mem.eql(u8, name, entry.n)) return entry.e;
    }
    return .none;
}

pub const Context = struct {
    // Base buddy state
    x: f32,
    y: f32,
    vx: f32 = 0,
    vy: f32 = 0,
    screen_w: f32,
    screen_h: f32,
    scale: f32 = 2.0,

    anim: Anim = sprite.IDLE,
    frame: u8 = 0,
    frame_timer: f32 = 0,
    anim_done: bool = false,
    facing_right: bool = true,

    walk_speed: f32 = 0,
    run_speed: f32 = 0,

    behavior: Behavior = .idle,
    behavior_timer: f32 = 0,
    behavior_duration: f32 = 3.0,
    idle_time: f32 = 0,
    wander_dir: f32 = 1,

    prev_cursor: [2]f32 = .{ 0, 0 },
    cursor_speed: f32 = 0,

    grounded: bool = false,
    jump_cooldown: f32 = 0,
    dropping: bool = false,
    drop_platform_y: f32 = 0,
    land_cooldown: f32 = 0,
    airborne_time: f32 = 0,
    flee_cooldown: f32 = 0,
    climbing: bool = false,
    climb_wall_x: f32 = 0,
    climb_target_y: f32 = 0,
    climb_speed: f32 = 80.0,
    failed_jumps: u8 = 0,

    rng: std.Random.DefaultPrng,
    sprite_tex: ?texture_mod.Texture = null,
    allocator: std.mem.Allocator,

    // AI state
    event_log: events_mod.EventLog = .{},
    current_window: [64]u8 = undefined,
    current_window_len: u8 = 0,
    ai_cooldown: f32 = 5.0,
    ai_timer: f32 = 0,
    ai_pending: bool = false,
    ai_pending_timer: f32 = 0,

    action_queue: [8]ai_mod.QueuedAction = undefined,
    queue_len: u8 = 0,
    queue_pos: u8 = 0,
    landed_on_new: bool = false,

    // Rate limiting
    calls_this_minute: u8 = 0,
    minute_timer: f32 = 0,
    max_calls_per_minute: u8 = 6,
    windows_visited: u8 = 0,
    cached_windows: [32]shader_mod.ShaderProgram.WindowRect = undefined,
    cached_window_count: u8 = 0,
    cached_focused: transition_mod.Rect = .{},

    // Speech bubble
    bubble_text: [20]u8 = undefined,
    bubble_len: u8 = 0,
    bubble_timer: f32 = 0,
    bubble_duration: f32 = 4.0,

    // Mood system
    mood: Mood = .neutral,
    mood_intensity: f32 = 0.5,
    mood_timer: f32 = 0,

    // Time-of-day
    current_hour: u8 = 12,
    time_update_timer: f32 = 60.0, // trigger immediate first update

    // Emote particles
    emotes: [max_emotes]EmoteParticle = [_]EmoteParticle{.{}} ** max_emotes,
    emote_spawn_timer: f32 = 0,

    // Window metadata cache
    cached_window_classes: [32][32]u8 = undefined,
    cached_window_class_lens: [32]u8 = [_]u8{0} ** 32,
    cached_focused_class: [32]u8 = undefined,
    cached_focused_class_len: u8 = 0,
    cached_focused_title: [48]u8 = undefined,
    cached_focused_title_len: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) Context {
        const sprite_path = params.getString("sprite", "sprites/buddy.png") orelse "sprites/buddy.png";
        const tex = texture_mod.Texture.loadFromFile(sprite_path) catch null;

        const scale: f32 = params.getFloat("scale", 2.0);
        const walk_spd = (32.0 * scale) / (6.0 / 8.0);
        const run_spd = (32.0 * scale * 2.0) / (6.0 / 12.0);
        const cooldown: f32 = params.getFloat("ai_cooldown", 5.0);
        const max_calls: u8 = @intCast(params.getInt("max_calls_per_minute", 6));

        return .{
            .x = width * 0.5,
            .y = height - 50,
            .screen_w = width,
            .screen_h = height,
            .scale = scale,
            .sprite_tex = tex,
            .rng = std.Random.DefaultPrng.init(iohelp.nowNs()),
            .walk_speed = walk_spd,
            .run_speed = run_spd,
            .allocator = allocator,
            .ai_cooldown = cooldown,
            .max_calls_per_minute = max_calls,
        };
    }

    fn updateMood(self: *Context, dt: f32) void {
        self.mood_timer += dt;
        // Intensity decays toward 0.5
        self.mood_intensity += (0.5 - self.mood_intensity) * 0.1 * dt;
        // After 60s sustained mood, drift to neutral
        if (self.mood_timer > 60.0 and self.mood != .neutral) {
            self.mood = .neutral;
            self.mood_timer = 0;
        }
        // Night pressure toward sleepy
        const period = timePeriod(self.current_hour);
        if (period == .night and self.mood == .neutral and self.mood_timer > 30.0) {
            self.mood = .sleepy;
            self.mood_intensity = 0.7;
            self.mood_timer = 0;
        }
        // Idle pressure toward bored
        if (self.idle_time > 20.0 and self.mood == .neutral) {
            self.mood = .bored;
            self.mood_intensity = 0.6;
            self.mood_timer = 0;
        }
    }

    pub fn spawnEmote(self: *Context, etype: EmoteType) void {
        const rand = self.rng.random();
        for (&self.emotes) |*e| {
            if (e.life <= 0) {
                e.* = .{
                    .etype = etype,
                    .x = self.x + (rand.float(f32) - 0.5) * 20.0,
                    .y = self.y + 32.0 * self.scale + 10.0,
                    .vx = (rand.float(f32) - 0.5) * 15.0,
                    .vy = 30.0 + rand.float(f32) * 20.0,
                    .life = 1.5,
                    .max_life = 1.5,
                };
                return;
            }
        }
    }

    fn updateEmotes(self: *Context, dt: f32) void {
        for (&self.emotes) |*e| {
            if (e.life <= 0) continue;
            e.life -= dt;
            e.x += e.vx * dt;
            e.y += e.vy * dt;
            e.vy *= 0.98;
            e.vx += (self.rng.random().float(f32) - 0.5) * 5.0 * dt;
        }
    }


    pub fn popNextAction(self: *Context) void {
        if (self.queue_pos < self.queue_len) {
            const qa = self.action_queue[self.queue_pos];
            self.setBehavior(qa.behavior, qa.duration);
            self.wander_dir = qa.dir;
            self.queue_pos += 1;
        }
    }

    pub fn setBehavior(self: *Context, b: Behavior, duration: f32) void {
        self.behavior = b;
        self.behavior_timer = 0;
        self.behavior_duration = duration;
        self.anim_done = false;
        self.frame = 0;
        self.frame_timer = 0;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
        const rand = self.rng.random();

        // --- Cursor tracking ---
        const cursor_dx = state.cursor[0] - self.prev_cursor[0];
        const cursor_dy = state.cursor[1] - self.prev_cursor[1];
        self.cursor_speed = @sqrt(cursor_dx * cursor_dx + cursor_dy * cursor_dy) / @max(dt, 0.001);
        self.prev_cursor = state.cursor;

        const cursor_dist = @sqrt(
            (state.cursor[0] - self.x) * (state.cursor[0] - self.x) +
            (state.cursor[1] - self.y) * (state.cursor[1] - self.y),
        );

        // --- Detect events for AI context ---
        const fw = state.focused_win;
        const has_target = fw.w > 0 and fw.h > 0;

        // Cache for AI use
        self.cached_focused = fw;
        self.cached_window_count = @intCast(@min(state.windows.len, 32));
        for (0..self.cached_window_count) |i| {
            self.cached_windows[i] = state.windows[i];
        }
        // Cache window metadata
        if (state.window_info) |infos| {
            for (0..@min(infos.len, 32)) |i| {
                const clen: u8 = @intCast(@min(infos[i].class_len, 32));
                if (clen > 0) @memcpy(self.cached_window_classes[i][0..clen], infos[i].class[0..clen]);
                self.cached_window_class_lens[i] = clen;
            }
        }
        {
            const fcl: u8 = @intCast(@min(state.focused_class_len, 32));
            if (fcl > 0) @memcpy(self.cached_focused_class[0..fcl], state.focused_class[0..fcl]);
            self.cached_focused_class_len = fcl;
            const ftl: u8 = @intCast(@min(state.focused_title_len, 48));
            if (ftl > 0) @memcpy(self.cached_focused_title[0..ftl], state.focused_title[0..ftl]);
            self.cached_focused_title_len = ftl;
        }

        // Detect landing on window
        self.land_cooldown -= dt;
        if (self.grounded and self.landed_on_new and self.land_cooldown <= 0) {
            self.landed_on_new = false;
            self.land_cooldown = 1.0;
            self.windows_visited +|= 1;
            if (self.current_window_len > 0) {
                self.event_log.log("landed on {s}", .{self.current_window[0..self.current_window_len]});
            } else {
                self.event_log.log("landed on ground", .{});
            }
            // Landing triggers excited mood briefly
            if (self.mood != .anxious) {
                self.mood = .excited;
                self.mood_intensity = 0.7;
                self.mood_timer = 0;
            }
        }

        // Detect cursor approach
        if (cursor_dist < 100 and self.cursor_speed < 50) {
            if (self.ai_timer > self.ai_cooldown * 0.5) {
                self.event_log.log("cursor hovering nearby", .{});
                if (self.mood == .neutral or self.mood == .bored) {
                    self.mood = .curious;
                    self.mood_intensity = 0.6;
                    self.mood_timer = 0;
                }
            }
        } else if (cursor_dist < 80 and self.cursor_speed > 500) {
            self.event_log.log("cursor swooped past", .{});
        }

        // --- Time-of-day ---
        self.time_update_timer += dt;
        if (self.time_update_timer >= 60.0) {
            self.time_update_timer = 0;
            self.current_hour = getLocalHour();
        }

        // --- Mood + emotes ---
        self.updateMood(dt);
        self.updateEmotes(dt);
        self.emote_spawn_timer += dt;
        if (self.emote_spawn_timer >= 2.5 and self.mood_intensity > 0.4) {
            self.emote_spawn_timer = 0;
            switch (self.mood) {
                .happy => self.spawnEmote(.heart),
                .excited => self.spawnEmote(.star),
                .sleepy => self.spawnEmote(.zzz),
                .curious => self.spawnEmote(.question),
                .anxious => self.spawnEmote(.exclaim),
                else => {},
            }
        }

        // Speech bubble timer (UI, not AI rate-limit).
        if (self.bubble_timer > 0) self.bubble_timer -= dt;

        // AI rate-limit + decision driver.
        ai_brain.tick(self, dt);

        // --- Immediate cursor reactions (override AI) ---
        if (self.grounded and !self.climbing and cursor_dist < 120 and
            self.behavior != .trip and self.behavior != .dramatic_death)
        {
            if (self.cursor_speed > 2000) {
                self.vx += (state.cursor[0] - self.x) * 3.0;
                self.setBehavior(.trip, 0.8);
                self.event_log.log("got knocked by cursor", .{});
                log.debug("AI ~ knocked by cursor! mood->anxious", .{});
                self.mood = .anxious;
                self.mood_intensity = 0.9;
                self.mood_timer = 0;
                self.spawnEmote(.exclaim);
            } else if (self.cursor_speed > 800 and cursor_dist < 80 and self.flee_cooldown <= 0) {
                self.setBehavior(.flee, 1.5);
                self.wander_dir = if (state.cursor[0] > self.x) -1.0 else 1.0;
                self.event_log.log("fleeing from cursor", .{});
                log.debug("AI ~ fleeing from cursor!", .{});
                self.flee_cooldown = 2.0;
                self.mood = .anxious;
                self.mood_intensity = 0.7;
                self.mood_timer = 0;
            }
        }

        // --- Behavior timer ---
        if (!self.climbing) self.behavior_timer += dt;
        self.jump_cooldown -= dt;
        self.flee_cooldown -= dt;

        // Behavior expired — pop next from queue, or procedural fallback
        if (self.behavior_timer >= self.behavior_duration) {
            if (self.queue_pos < self.queue_len) {
                self.popNextAction();
            } else {
                // Mood-influenced procedural fallback
                const roll = rand.float(f32);
                switch (self.mood) {
                    .sleepy => {
                        if (roll < 0.7) self.setBehavior(.idle, 3.0 + rand.float(f32) * 3.0)
                        else self.setBehavior(.wander, 2.0);
                    },
                    .excited => {
                        if (roll < 0.4) self.setBehavior(.chase, 3.0)
                        else if (roll < 0.6) self.setBehavior(.celebrate, 1.5)
                        else { self.setBehavior(.wander, 2.0); self.wander_dir = if (rand.boolean()) @as(f32, 1.0) else -1.0; }
                    },
                    .bored => {
                        if (roll < 0.4) { self.setBehavior(.wander, 3.0); self.wander_dir = if (rand.boolean()) @as(f32, 1.0) else -1.0; }
                        else if (roll < 0.6) self.setBehavior(.climb, 1.5)
                        else self.setBehavior(.idle, 2.0);
                    },
                    .curious => {
                        if (roll < 0.5) self.setBehavior(.curious, 2.0)
                        else self.setBehavior(.chase, 3.0);
                    },
                    .anxious => {
                        if (roll < 0.4) { self.setBehavior(.flee, 1.5); self.wander_dir = if (rand.boolean()) @as(f32, 1.0) else -1.0; }
                        else { self.setBehavior(.wander, 2.0); self.wander_dir = if (rand.boolean()) @as(f32, 1.0) else -1.0; }
                    },
                    .happy => {
                        if (roll < 0.3) self.setBehavior(.wave, 1.5)
                        else if (roll < 0.6) { self.setBehavior(.wander, 2.0); self.wander_dir = if (rand.boolean()) @as(f32, 1.0) else -1.0; }
                        else self.setBehavior(.idle, 2.0);
                    },
                    .neutral => {
                        if (has_target and roll < 0.4) self.setBehavior(.chase, 3.0)
                        else if (roll < 0.7) { self.setBehavior(.wander, 2.0 + rand.float(f32) * 2.0); self.wander_dir = if (rand.boolean()) @as(f32, 1.0) else -1.0; }
                        else self.setBehavior(.idle, 1.5 + rand.float(f32) * 2.0);
                    },
                }
            }
        }

        // --- Execute behavior + physics ---
        behaviors.execute(self, state, dt);
        physics.step(self, state, dt);

        // --- Animate ---
        self.advanceFrame(dt);
    }

    pub fn setAnim(self: *Context, anim: Anim) void {
        if (self.anim.row != anim.row) {
            self.anim = anim;
            self.frame = 0;
            self.frame_timer = 0;
            self.anim_done = false;
        }
    }

    pub fn setJumpFrame(self: *Context) void {
        if (self.vy > 100) { self.frame = 0; }
        else if (self.vy > 50) { self.frame = 1; }
        else if (self.vy > 0) { self.frame = 2; }
        else if (self.vy > -30) { self.frame = 3; }
        else if (self.vy > -80) { self.frame = 4; }
        else if (self.vy > -150) { self.frame = 5; }
        else { self.frame = 6; }
    }

    fn advanceFrame(self: *Context, dt: f32) void {
        if (self.anim.row == JUMP.row and !self.grounded) return;
        self.frame_timer += dt * self.anim.fps;
        if (self.frame_timer >= 1.0) {
            self.frame_timer -= 1.0;
            if (self.frame + 1 >= self.anim.frames) {
                if (self.anim.looping) { self.frame = 0; } else { self.anim_done = true; }
            } else { self.frame += 1; }
        }
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        if (self.sprite_tex) |*tex| {
            tex.bind(0);
            c.glUseProgram(prog.program);
            const loc = c.glGetUniformLocation(prog.program, "iSprite");
            if (loc >= 0) c.glUniform1i(loc, 0);
        }

        c.glUseProgram(prog.program);
        const facing: f32 = if (self.facing_right) 1.0 else -1.0;
        const col_f: f32 = @floatFromInt(self.frame);
        const row_f: f32 = @floatFromInt(self.anim.row);

        if (prog.i_particles[0] >= 0)
            c.glUniform4f(prog.i_particles[0], self.x, self.y, self.scale, facing);
        if (prog.i_particles[1] >= 0)
            c.glUniform4f(prog.i_particles[1],
                col_f * sprite.CELL / sprite.SHEET_W, row_f * sprite.CELL / sprite.SHEET_H,
                (col_f + 1.0) * sprite.CELL / sprite.SHEET_W, (row_f + 1.0) * sprite.CELL / sprite.SHEET_H);
        // Bubble data: [2] = (len, timer, duration, mood), [3..8] = packed chars
        if (self.bubble_timer > 0 and self.bubble_len > 0) {
            if (prog.i_particles[2] >= 0)
                c.glUniform4f(prog.i_particles[2],
                    @floatFromInt(self.bubble_len), self.bubble_timer, self.bubble_duration,
                    @floatFromInt(@intFromEnum(self.mood)));

            var slot: u32 = 3;
            var ci: u32 = 0;
            while (ci < self.bubble_len) {
                if (slot >= 9) break;
                const c0: f32 = if (ci < self.bubble_len) @floatFromInt(self.bubble_text[ci]) else 0;
                const c1: f32 = if (ci + 1 < self.bubble_len) @floatFromInt(self.bubble_text[ci + 1]) else 0;
                const c2: f32 = if (ci + 2 < self.bubble_len) @floatFromInt(self.bubble_text[ci + 2]) else 0;
                const c3: f32 = if (ci + 3 < self.bubble_len) @floatFromInt(self.bubble_text[ci + 3]) else 0;
                if (prog.i_particles[slot] >= 0)
                    c.glUniform4f(prog.i_particles[slot], c0, c1, c2, c3);
                slot += 1;
                ci += 4;
            }
            // Zero-pad remaining bubble slots
            while (slot < 9) : (slot += 1) {
                if (prog.i_particles[slot] >= 0)
                    c.glUniform4f(prog.i_particles[slot], 0, 0, 0, 0);
            }
        } else {
            if (prog.i_particles[2] >= 0)
                c.glUniform4f(prog.i_particles[2], 0, 0, 0, @floatFromInt(@intFromEnum(self.mood)));
            // Zero bubble text slots
            for (3..9) |si| {
                if (prog.i_particles[si] >= 0)
                    c.glUniform4f(prog.i_particles[si], 0, 0, 0, 0);
            }
        }

        // Emote particles: slots [9..14] = (type, x, y, alpha)
        for (0..max_emotes) |ei| {
            const slot = 9 + ei;
            if (slot >= 300) break;
            const e = self.emotes[ei];
            if (e.life > 0 and e.etype != .none) {
                if (prog.i_particles[slot] >= 0)
                    c.glUniform4f(prog.i_particles[slot],
                        @floatFromInt(@intFromEnum(e.etype)),
                        e.x, e.y,
                        e.life / e.max_life);
            } else {
                if (prog.i_particles[slot] >= 0)
                    c.glUniform4f(prog.i_particles[slot], 0, 0, 0, 0);
            }
        }

        if (prog.i_particle_count >= 0)
            c.glUniform1i(prog.i_particle_count, 15);
    }

    pub fn deinit(self: *Context) void {
        if (self.sprite_tex) |*tex| tex.deinit();
    }
};
