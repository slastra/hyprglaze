const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const texture_mod = @import("../../core/texture.zig");
const config_mod = @import("../../core/config.zig");
const transition_mod = @import("../../core/transition.zig");
const effects = @import("../../effects.zig");
const sprite = @import("../buddy/sprite.zig");
const ai_mod = @import("ai.zig");
const events_mod = @import("events.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
    @cInclude("time.h");
});

const Anim = sprite.Anim;
const Behavior = sprite.Behavior;
const IDLE = sprite.IDLE;
const WALK = sprite.WALK;
const RUN = sprite.RUN;
const JUMP = sprite.JUMP;
const ATTACK1 = sprite.ATTACK1;
const ATTACK2 = sprite.ATTACK2;
const PUSH = sprite.PUSH;
const THROW = sprite.THROW;
const CLIMB = sprite.CLIMB;
const HURT = sprite.HURT;
const DEATH = sprite.DEATH;

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

fn getLocalHour() u8 {
    var t = c.time(null);
    const tm = c.localtime(&t);
    if (tm) |local| {
        return @intCast(@as(u32, @bitCast(local.*.tm_hour)));
    }
    return 12;
}

fn timePeriod(hour: u8) TimePeriod {
    if (hour >= 6 and hour < 12) return .morning;
    if (hour >= 12 and hour < 18) return .afternoon;
    if (hour >= 18 and hour < 23) return .evening;
    return .night;
}

fn timePeriodName(p: TimePeriod) []const u8 {
    return switch (p) {
        .morning => "morning",
        .afternoon => "afternoon",
        .evening => "evening",
        .night => "night",
    };
}

fn moodName(m: Mood) []const u8 {
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

fn mapMood(name: []const u8) Mood {
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

fn mapEmote(name: []const u8) EmoteType {
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

    anim: Anim = IDLE,
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
    climbing: bool = false,
    climb_wall_x: f32 = 0,
    climb_target_y: f32 = 0,
    climb_speed: f32 = 80.0,

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
            .rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
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

    fn spawnEmote(self: *Context, etype: EmoteType) void {
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

    fn callHaiku(self: *Context) void {
        // Build event context
        var context_buf: [512]u8 = undefined;
        var pos: usize = 0;

        const header = "Recent: ";
        @memcpy(context_buf[pos..pos + header.len], header);
        pos += header.len;

        for (0..self.event_log.count) |i| {
            const ev = self.event_log.events[i].slice();
            if (pos + ev.len + 2 >= context_buf.len) break;
            @memcpy(context_buf[pos..pos + ev.len], ev);
            pos += ev.len;
            context_buf[pos] = '.';
            context_buf[pos + 1] = ' ';
            pos += 2;
        }

        const context = context_buf[0..pos];

        // Build spatial layout description (with window classes)
        var layout_buf: [512]u8 = undefined;
        const layout = events_mod.describeLayout(
            self.x, self.y,
            self.cached_windows[0..self.cached_window_count],
            self.cached_focused,
            &self.cached_window_classes,
            &self.cached_window_class_lens,
            self.cached_window_count,
            &layout_buf,
        );

        const period = timePeriodName(timePeriod(self.current_hour));
        const mood_str = moodName(self.mood);

        // Focused window label
        var focused_label_buf: [80]u8 = undefined;
        const focused_label = if (self.cached_focused_class_len > 0)
            std.fmt.bufPrint(&focused_label_buf, "{s}", .{self.cached_focused_class[0..self.cached_focused_class_len]}) catch "focused window"
        else
            "unknown";

        var prompt_buf: [2560]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf,
            \\You are a tiny cute monster living on a desktop. It's {s} ({d}:00).
            \\Your current mood: {s}
            \\
            \\Personality: Curious, adventurous, emotionally expressive.
            \\- Explore windows you haven't visited. Jump and chase to reach them.
            \\- Once you've explored 3+ windows, gravitate toward the focused window.
            \\- On the focused window: relax, wave, push, celebrate, or be playful.
            \\- React to your environment: get sleepy at night, excited by new windows, anxious near fast cursor.
            \\- Express emotions through mood and emotes.
            \\
            \\{s}
            \\{s}
            \\
            \\Standing on: {s}
            \\Focused window: {s}
            \\Explored: {d} windows
            \\On focused window: {s}
            \\
            \\Respond JSON only: {{"actions":[{{"action":"<act>","direction":"left"|"right"}}],"say":"WORDS","mood":"<mood>","emote":"<emote>"}}
            \\Actions (1-4): idle, wander, chase, jump, wave, push, throw, trip, death, climb, celebrate
            \\"say": 1-3 word uppercase speech bubble (max 16 chars)
            \\"mood": neutral, happy, curious, sleepy, bored, excited, anxious
            \\"emote" (optional): heart, star, zzz, exclaim, music, question
        , .{
            period,
            self.current_hour,
            mood_str,
            layout,
            context,
            if (self.current_window_len > 0) self.current_window[0..self.current_window_len] else "ground",
            focused_label,
            self.windows_visited,
            blk: {
                const on_focused = self.grounded and self.cached_focused.w > 0 and
                    self.x > self.cached_focused.x and
                    self.x < self.cached_focused.x + self.cached_focused.w and
                    @abs(self.y - (self.cached_focused.y + self.cached_focused.h)) < 5;
                break :blk if (on_focused) "yes" else "no";
            },
        }) catch return;

        // Escape prompt for JSON embedding
        var escaped_prompt: [2048]u8 = undefined;
        var ep: usize = 0;
        for (prompt) |ch| {
            if (ep + 2 >= escaped_prompt.len) break;
            if (ch == '"') {
                escaped_prompt[ep] = '\\';
                ep += 1;
                escaped_prompt[ep] = '"';
                ep += 1;
            } else if (ch == '\n') {
                escaped_prompt[ep] = '\\';
                ep += 1;
                escaped_prompt[ep] = 'n';
                ep += 1;
            } else if (ch == '\\') {
                escaped_prompt[ep] = '\\';
                ep += 1;
                escaped_prompt[ep] = '\\';
                ep += 1;
            } else {
                escaped_prompt[ep] = ch;
                ep += 1;
            }
        }

        var body_buf: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\{{"anthropic_version":"bedrock-2023-05-31","max_tokens":100,"messages":[{{"role":"user","content":"{s}"}}]}}
        , .{escaped_prompt[0..ep]}) catch return;

        // Write body to temp file
        const tmp_path = "/tmp/hyprglaze-ai-request.json";
        const tmp_file = std.fs.createFileAbsolute(tmp_path, .{}) catch return;
        tmp_file.writeAll(body) catch { tmp_file.close(); return; };
        tmp_file.close();

        // Shell out to AWS CLI (non-blocking via fork)
        const argv = [_][]const u8{
            "/bin/sh", "-c",
            "export $(cat ~/.config/hypr/hyprglaze-aws.env | xargs) && " ++
            "aws bedrock-runtime invoke-model --region us-east-1 " ++
            "--model-id us.anthropic.claude-haiku-4-5-20251001-v1:0 " ++
            "--content-type application/json " ++
            "--body file:///tmp/hyprglaze-ai-request.json " ++
            "/tmp/hyprglaze-ai-response.json 2>/tmp/hyprglaze-ai-err 1>/dev/null && " ++
            "touch /tmp/hyprglaze-ai-done",
        };

        std.fs.deleteFileAbsolute("/tmp/hyprglaze-ai-done") catch {};

        std.debug.print("AI > standing={s} focused={s} visited={d} mood={s} time={s}({d}:00)\n", .{
            if (self.current_window_len > 0) self.current_window[0..self.current_window_len] else "ground",
            if (self.cached_focused_class_len > 0) self.cached_focused_class[0..self.cached_focused_class_len] else "none",
            self.windows_visited,
            moodName(self.mood),
            timePeriodName(timePeriod(self.current_hour)),
            self.current_hour,
        });

        var child = std.process.Child.init(&argv, self.allocator);
        child.spawn() catch |err| {
            std.debug.print("AI spawn failed: {}\n", .{err});
            return;
        };
        self.ai_pending = true;
        self.ai_pending_timer = 0;
    }

    fn checkAiResponse(self: *Context) void {
        std.fs.accessAbsolute("/tmp/hyprglaze-ai-done", .{}) catch return;

        const file = std.fs.openFileAbsolute("/tmp/hyprglaze-ai-response.json", .{}) catch return;
        defer file.close();

        var resp_buf: [4096]u8 = undefined;
        const resp_len = file.readAll(&resp_buf) catch return;
        const resp = resp_buf[0..resp_len];

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return;
        defer parsed.deinit();

        const content = parsed.value.object.get("content") orelse return;
        const text = content.array.items[0].object.get("text") orelse return;
        if (text != .string) return;

        // Strip markdown code blocks
        var ai_text = text.string;
        if (std.mem.indexOf(u8, ai_text, "{")) |start| {
            if (std.mem.lastIndexOf(u8, ai_text, "}")) |end| {
                ai_text = ai_text[start .. end + 1];
            }
        }

        const ai_resp = std.json.parseFromSlice(std.json.Value, self.allocator, ai_text, .{}) catch return;
        defer ai_resp.deinit();

        // Parse action chain or single action
        self.queue_len = 0;
        self.queue_pos = 0;

        if (ai_resp.value.object.get("actions")) |av| {
            if (av == .array) {
                for (av.array.items) |item| {
                    if (self.queue_len >= 8) break;
                    if (item != .object) continue;
                    self.parseOneAction(item.object);
                }
            }
        } else {
            self.parseOneAction(ai_resp.value.object);
        }

        // Extract speech bubble text
        if (ai_resp.value.object.get("say")) |say_val| {
            if (say_val == .string) {
                const say = say_val.string;
                const slen: u8 = @intCast(@min(say.len, 20));
                @memcpy(self.bubble_text[0..slen], say[0..slen]);
                self.bubble_len = slen;
                self.bubble_timer = self.bubble_duration;
            }
        }

        // Extract mood
        if (ai_resp.value.object.get("mood")) |mood_val| {
            if (mood_val == .string) {
                self.mood = mapMood(mood_val.string);
                self.mood_intensity = 0.9;
                self.mood_timer = 0;
            }
        }

        // Extract emote
        if (ai_resp.value.object.get("emote")) |emote_val| {
            if (emote_val == .string) {
                const etype = mapEmote(emote_val.string);
                if (etype != .none) self.spawnEmote(etype);
            }
        }

        // Start first action and log the chain
        if (self.queue_len > 0) {
            self.popNextAction();
            var log_buf: [128]u8 = undefined;
            var lp: usize = 0;
            for (0..self.queue_len) |qi| {
                const name = ai_mod.actionName(self.action_queue[qi].behavior);
                if (lp + name.len + 2 >= log_buf.len) break;
                if (qi > 0) { log_buf[lp] = '>'; lp += 1; }
                @memcpy(log_buf[lp..lp + name.len], name);
                lp += name.len;
            }
            std.debug.print("AI < actions={s} mood={s} say=\"{s}\" emote={s}\n", .{
                log_buf[0..lp],
                moodName(self.mood),
                if (self.bubble_len > 0) self.bubble_text[0..self.bubble_len] else "",
                if (ai_resp.value.object.get("emote")) |ev| (if (ev == .string) ev.string else "none") else "none",
            });
            self.event_log.log("plan: {s}", .{log_buf[0..lp]});
            if (self.bubble_len > 0) {
                self.event_log.log("said \"{s}\"", .{self.bubble_text[0..self.bubble_len]});
            }
        }

        self.ai_pending = false;
        std.fs.deleteFileAbsolute("/tmp/hyprglaze-ai-done") catch {};
        std.fs.deleteFileAbsolute("/tmp/hyprglaze-ai-request.json") catch {};
    }

    fn parseOneAction(self: *Context, obj: std.json.ObjectMap) void {
        const act_val = obj.get("action") orelse return;
        if (act_val != .string) return;
        const mapped = ai_mod.mapAction(act_val.string) orelse return;

        const dir_val = obj.get("direction");
        const dir: f32 = if (dir_val) |d|
            (if (d == .string and std.mem.eql(u8, d.string, "left")) @as(f32, -1.0) else 1.0)
        else
            1.0;

        self.action_queue[self.queue_len] = .{
            .behavior = mapped.behavior,
            .duration = mapped.duration,
            .dir = dir,
        };
        self.queue_len += 1;
    }

    fn popNextAction(self: *Context) void {
        if (self.queue_pos < self.queue_len) {
            const qa = self.action_queue[self.queue_pos];
            self.setBehavior(qa.behavior, qa.duration);
            self.wander_dir = qa.dir;
            self.queue_pos += 1;
        }
    }

    fn setBehavior(self: *Context, b: Behavior, duration: f32) void {
        self.behavior = b;
        self.behavior_timer = 0;
        self.behavior_duration = duration;
        self.anim_done = false;
        self.frame = 0;
        self.frame_timer = 0;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
        const gravity: f32 = 900.0;
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
                std.debug.print("AI ~ landed on {s}\n", .{self.current_window[0..self.current_window_len]});
            } else {
                self.event_log.log("landed on ground", .{});
                std.debug.print("AI ~ landed on ground\n", .{});
            }
            // Landing triggers excited mood briefly
            if (self.mood != .anxious) {
                self.mood = .excited;
                self.mood_intensity = 0.7;
                self.mood_timer = 0;
                std.debug.print("AI ~ mood->excited (landed)\n", .{});
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

        // --- Rate limiting ---
        self.ai_timer += dt;
        if (self.bubble_timer > 0) self.bubble_timer -= dt;
        self.minute_timer += dt;
        if (self.minute_timer >= 60.0) {
            self.minute_timer = 0;
            self.calls_this_minute = 0;
        }

        // --- AI decision making ---
        if (self.ai_pending) {
            self.ai_pending_timer += dt;
            if (self.ai_pending_timer > 10.0) {
                std.debug.print("AI ! timeout after {d:.1}s, falling back to wander\n", .{self.ai_pending_timer});
                self.ai_pending = false;
                self.ai_pending_timer = 0;
                self.setBehavior(.wander, 3.0);
            }
            self.checkAiResponse();
        } else if (self.ai_timer >= self.ai_cooldown and
            self.behavior_timer >= self.behavior_duration * 0.8 and
            self.calls_this_minute < self.max_calls_per_minute)
        {
            self.ai_timer = 0;
            self.calls_this_minute += 1;
            self.callHaiku();
        }

        // --- Immediate cursor reactions (override AI) ---
        if (self.grounded and !self.climbing and cursor_dist < 120 and
            self.behavior != .trip and self.behavior != .dramatic_death)
        {
            if (self.cursor_speed > 2000) {
                self.vx += (state.cursor[0] - self.x) * 3.0;
                self.setBehavior(.trip, 0.8);
                self.event_log.log("got knocked by cursor", .{});
                std.debug.print("AI ~ knocked by cursor! mood->anxious\n", .{});
                self.mood = .anxious;
                self.mood_intensity = 0.9;
                self.mood_timer = 0;
                self.spawnEmote(.exclaim);
            } else if (self.cursor_speed > 800 and cursor_dist < 80) {
                self.setBehavior(.flee, 1.5);
                self.wander_dir = if (state.cursor[0] > self.x) -1.0 else 1.0;
                self.event_log.log("fleeing from cursor", .{});
                std.debug.print("AI ~ fleeing from cursor!\n", .{});
                self.mood = .anxious;
                self.mood_intensity = 0.7;
                self.mood_timer = 0;
            }
        }

        // --- Behavior timer ---
        if (!self.climbing) self.behavior_timer += dt;
        self.jump_cooldown -= dt;

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

        // --- Execute behavior ---

        // Wall climb overrides everything
        if (self.climbing) {
            self.setAnim(CLIMB);
            self.vy = self.climb_speed;
            self.vx = 0;
            self.x = self.climb_wall_x;
            self.grounded = false;
            self.facing_right = self.climb_wall_x > self.x - 1;
            // Reached the top?
            if (self.y >= self.climb_target_y) {
                self.y = self.climb_target_y;
                self.vy = 0;
                self.grounded = true;
                self.climbing = false;
                self.landed_on_new = true;
                self.setBehavior(.idle, 0.5);
                self.event_log.log("climbed up", .{});
                std.debug.print("AI ~ reached top\n", .{});
            }
        } else {
        self.vy -= gravity * dt;

        switch (self.behavior) {
            .idle => {
                self.vx *= 0.9;
                self.idle_time += dt;
                self.setAnim(IDLE);
            },
            .wander => {
                if (self.grounded) {
                    const target_vx = self.wander_dir * self.walk_speed;
                    self.vx += (target_vx - self.vx) * 5.0 * dt;
                }
                self.facing_right = self.wander_dir > 0;
                self.setAnim(WALK);
                if (self.x < 50 or self.x > self.screen_w - 50) self.wander_dir = -self.wander_dir;
            },
            .chase => {
                if (has_target and self.grounded) {
                    const target_x = fw.x + fw.w * 0.5;
                    const target_top = fw.y + fw.h;
                    const dx = target_x - self.x;
                    const dy = target_top - self.y;

                    // Arrived: horizontally close AND on the same vertical level
                    if (@abs(dx) < 30 and @abs(dy) < 10) {
                        self.setBehavior(.idle, 1.0);
                    } else if (dy > 400) {
                        // Target is too high to jump — run toward wall and climb
                        const dist_left = @abs(self.x - fw.x);
                        const dist_right = @abs(self.x - (fw.x + fw.w));
                        const wall_x = if (dist_left < dist_right) fw.x else fw.x + fw.w;
                        const wall_dist = @abs(self.x - wall_x);

                        if (wall_dist < 10) {
                            // At the wall — latch and climb
                            self.climbing = true;
                            self.climb_wall_x = wall_x;
                            self.climb_target_y = fw.y + fw.h;
                            self.setBehavior(.climb, 15.0);
                            std.debug.print("AI ~ climbing wall\n", .{});
                        } else {
                            // Run toward the wall
                            self.facing_right = wall_x > self.x;
                            const dir: f32 = if (wall_x > self.x) 1.0 else -1.0;
                            const target_vx = dir * self.run_speed;
                            self.vx += (target_vx - self.vx) * 5.0 * dt;
                            self.setAnim(RUN);
                        }
                    } else if (dy > 30 and self.jump_cooldown <= 0) {
                        // Target is above — jump
                        self.setBehavior(.jump_to, 2.0);
                    } else if (dy < -30) {
                        // Target is below — drop through current platform
                        self.dropping = true;
                        self.drop_platform_y = self.y;
                        std.debug.print("AI ~ dropping through platform\n", .{});
                        self.grounded = false;
                        self.vy = -50.0; // small downward kick
                        // Drift toward target horizontally while falling
                        self.vx = std.math.clamp(dx * 0.3, -100, 100);
                        self.setAnim(JUMP);
                    } else {
                        // Same height — run toward target
                        self.facing_right = dx > 0;
                        const dir: f32 = if (dx > 0) 1.0 else -1.0;
                        const use_run = @abs(dx) > 200;
                        const target_vx = dir * (if (use_run) self.run_speed else self.walk_speed);
                        self.vx += (target_vx - self.vx) * 5.0 * dt;
                        self.setAnim(if (use_run) RUN else WALK);
                    }
                }
            },
            .jump_to => {
                if (self.grounded and self.jump_cooldown <= 0 and has_target) {
                    const target_top = fw.y + fw.h;
                    const height_diff = target_top - self.y;
                    // Only jump if target is above or roughly level
                    if (height_diff > -20) {
                        const jump_h = @max(height_diff + 80.0, 120.0);
                        self.vy = @sqrt(2.0 * gravity * @min(jump_h, 600.0));
                        self.grounded = false;
                        self.jump_cooldown = 0.8;
                        // Strong horizontal push toward target
                        const dx = (fw.x + fw.w * 0.5) - self.x;
                        self.vx = std.math.clamp(dx * 0.8, -250, 250);
                    } else {
                        // Target is below — don't jump up, switch to chase (will drop)
                        self.setBehavior(.chase, 3.0);
                    }
                }
                if (!self.grounded) {
                    self.setAnim(JUMP);
                    self.setJumpFrame();
                } else {
                    self.setBehavior(.idle, 0.5);
                }
            },
            .wave => { self.vx *= 0.9; self.setAnim(ATTACK1); },
            .celebrate => { self.vx *= 0.9; self.setAnim(ATTACK2); },
            .push => {
                self.setAnim(PUSH);
                if (has_target) {
                    const dl = @abs(self.x - fw.x);
                    const dr = @abs(self.x - (fw.x + fw.w));
                    if (dl < dr) { self.vx -= 30.0 * dt; self.facing_right = false; }
                    else { self.vx += 30.0 * dt; self.facing_right = true; }
                }
            },
            .throw_rock => {
                self.vx *= 0.9;
                self.facing_right = state.cursor[0] > self.x;
                self.setAnim(THROW);
            },
            .trip => { self.vx *= 0.95; self.setAnim(HURT); },
            .dramatic_death => {
                self.vx *= 0.95;
                self.setAnim(DEATH);
                if (self.anim_done) {
                    self.x = self.screen_w * 0.5;
                    self.y = self.screen_h;
                    self.vx = 0;
                    self.vy = 0;
                    self.setBehavior(.idle, 1.0);
                    self.event_log.log("respawned", .{});
                }
            },
            .climb => {
                // Wall climb handled above the switch; this is a fallback
                if (!self.climbing) self.setBehavior(.idle, 0.5);
            },
            .curious => {
                self.facing_right = state.cursor[0] > self.x;
                const cdx = state.cursor[0] - self.x;
                if (@abs(cdx) > 40) {
                    const dir: f32 = if (cdx > 0) 1.0 else -1.0;
                    self.vx += (dir * self.walk_speed - self.vx) * 5.0 * dt;
                    self.setAnim(WALK);
                } else { self.vx *= 0.85; self.setAnim(ATTACK1); }
            },
            .flee => {
                self.facing_right = self.wander_dir > 0;
                const target_vx = self.wander_dir * self.run_speed;
                self.vx += (target_vx - self.vx) * 8.0 * dt;
                self.setAnim(RUN);
            },
        }
        } // end else (not climbing)

        // Air control — gentle steering toward target while airborne
        if (!self.grounded and !self.climbing and has_target) {
            const target_x = fw.x + fw.w * 0.5;
            const air_dx = target_x - self.x;
            self.vx += std.math.clamp(air_dx * 0.5, -80, 80) * dt;
        }

        // Face direction of movement (not while climbing)
        if (!self.climbing and @abs(self.vx) > 5.0) {
            self.facing_right = self.vx > 0;
        }

        // Friction + clamp
        if (self.grounded) self.vx *= 0.92;
        self.vx = std.math.clamp(self.vx, -self.run_speed * 1.5, self.run_speed * 1.5);

        // Integrate
        self.x += self.vx * dt;
        self.y += self.vy * dt;

        // --- Collisions ---
        const was_grounded = self.grounded;
        const was_falling = self.vy < -10.0;
        self.grounded = false;

        if (self.y <= 0) {
            self.y = 0;
            self.vy = 0;
            self.grounded = true;
            if (!was_grounded and was_falling) {
                self.landed_on_new = true;
                self.current_window_len = 0;
            }
        }

        // Clear drop state once we've fallen well below the platform
        if (self.dropping and self.y < self.drop_platform_y - 30) {
            self.dropping = false;
        }

        // Track which window we're on (skip collisions while climbing)
        if (!self.climbing) {
        for (state.windows, 0..) |win, wi| {
            if (win.w < 1) continue;
            const wt = win.y + win.h;
            if (self.x < win.x - 5 or self.x > win.x + win.w + 5) continue;

            // Skip platform we're dropping through
            if (self.dropping and @abs(wt - self.drop_platform_y) < 10) continue;

            if (self.vy <= 0 and self.y <= wt and self.y > wt - 20) {
                self.y = wt;
                self.vy = 0;
                self.dropping = false;
                if (!self.grounded and was_falling) {
                    self.landed_on_new = true;
                    // Identify window by class name from cached metadata
                    if (wi < self.cached_window_count) {
                        const clen = self.cached_window_class_lens[wi];
                        if (clen > 0) {
                            const copy_len = @min(clen, 64);
                            @memcpy(self.current_window[0..copy_len], self.cached_window_classes[wi][0..copy_len]);
                            self.current_window_len = copy_len;
                        } else {
                            const label = "window";
                            @memcpy(self.current_window[0..label.len], label);
                            self.current_window_len = label.len;
                        }
                    }
                }
                self.grounded = true;
            }
        }
        } // end if (!self.climbing)

        // Screen edges
        if (self.x < 20) { self.x = 20; self.vx = 0; }
        if (self.x > self.screen_w - 20) { self.x = self.screen_w - 20; self.vx = 0; }
        if (self.y > self.screen_h) { self.y = self.screen_h; self.vy = 0; }

        // --- Animate ---
        self.advanceFrame(dt);
    }

    fn setAnim(self: *Context, anim: Anim) void {
        if (self.anim.row != anim.row) {
            self.anim = anim;
            self.frame = 0;
            self.frame_timer = 0;
            self.anim_done = false;
        }
    }

    fn setJumpFrame(self: *Context) void {
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
