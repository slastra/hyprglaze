const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const texture_mod = @import("../core/texture.zig");
const effects = @import("../effects.zig");
const transition_mod = @import("../core/transition.zig");

const c = @cImport({ @cInclude("GLES3/gl3.h"); });

// Same sprite sheet as buddy: 256x352, 32x32 cells, 8 cols x 11 rows
const CELL: f32 = 32;
const SHEET_W: f32 = 256;
const SHEET_H: f32 = 352;

const Anim = struct { row: u8, frames: u8, fps: f32, looping: bool = true };
const IDLE    = Anim{ .row = 0,  .frames = 4, .fps = 4.0 };
const WALK    = Anim{ .row = 1,  .frames = 6, .fps = 8.0 };
const RUN     = Anim{ .row = 2,  .frames = 6, .fps = 12.0 };
const JUMP    = Anim{ .row = 3,  .frames = 8, .fps = 10.0, .looping = false };
const ATTACK1 = Anim{ .row = 4,  .frames = 4, .fps = 8.0,  .looping = false };
const ATTACK2 = Anim{ .row = 5,  .frames = 6, .fps = 10.0, .looping = false };
const PUSH    = Anim{ .row = 6,  .frames = 6, .fps = 6.0 };
const THROW   = Anim{ .row = 7,  .frames = 4, .fps = 6.0,  .looping = false };
const CLIMB   = Anim{ .row = 8,  .frames = 4, .fps = 6.0 };
const HURT    = Anim{ .row = 9,  .frames = 4, .fps = 8.0,  .looping = false };
const DEATH   = Anim{ .row = 10, .frames = 8, .fps = 6.0,  .looping = false };

const Behavior = enum {
    idle, wander, chase, jump_to, wave, push, throw_rock,
    trip, dramatic_death, climb, curious, flee, celebrate,
};

// Event log for Haiku context
const max_events = 8;
const Event = struct {
    text: [128]u8 = undefined,
    len: u8 = 0,

    fn set(self: *Event, msg: []const u8) void {
        const l: u8 = @intCast(@min(msg.len, 128));
        @memcpy(self.text[0..l], msg[0..l]);
        self.len = l;
    }

    fn slice(self: *const Event) []const u8 {
        return self.text[0..self.len];
    }
};

pub const QueuedAction = struct {
    behavior: Behavior,
    duration: f32,
    dir: f32,
};

pub const Context = struct {
    // Base buddy state (same as buddy.zig)
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

    rng: std.Random.DefaultPrng,
    sprite_tex: ?texture_mod.Texture = null,
    allocator: std.mem.Allocator,

    // AI state
    events: [max_events]Event = [_]Event{.{}} ** max_events,
    event_count: u8 = 0,
    current_window: [64]u8 = undefined,
    current_window_len: u8 = 0,
    prev_window: [64]u8 = undefined,
    prev_window_len: u8 = 0,
    ai_cooldown: f32 = 5.0,
    ai_timer: f32 = 0,
    ai_pending: bool = false,
    ai_pending_timer: f32 = 0,

    action_queue: [8]QueuedAction = undefined,
    queue_len: u8 = 0,
    queue_pos: u8 = 0,
    landed_on_new: bool = false,
    prev_focused_addr: u64 = 0,

    // Rate limiting
    calls_this_minute: u8 = 0,
    minute_timer: f32 = 0,
    max_calls_per_minute: u8 = 6, // max 6 calls/min = 360/hr ≈ $0.01/hr
    last_event_time: f32 = 0,
    event_debounce: f32 = 2.0, // min seconds between logging same event type
    windows_visited: u8 = 0,
    cached_windows: [32]shader_mod.ShaderProgram.WindowRect = undefined,
    cached_window_count: u8 = 0,
    cached_focused: transition_mod.Rect = .{},

    const config_mod = @import("../core/config.zig");

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) Context {
        const sprite_path = params.getString("sprite", "sprites/buddy.png") orelse "sprites/buddy.png";
        const tex = texture_mod.Texture.loadFromFile(sprite_path) catch
            texture_mod.Texture.loadFromFile("/home/shaun/hyprglaze/sprites/buddy.png") catch null;

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

    fn logEvent(self: *Context, comptime fmt: []const u8, args: anytype) void {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        // Shift events
        if (self.event_count >= max_events) {
            for (0..max_events - 1) |i| {
                self.events[i] = self.events[i + 1];
            }
            self.event_count = max_events - 1;
        }
        self.events[self.event_count].set(msg);
        self.event_count += 1;
    }

    fn describeLayout(self: *Context, state_windows: []const shader_mod.ShaderProgram.WindowRect, focused: transition_mod.Rect, buf: []u8) []const u8 {
        var pos: usize = 0;
        const my_x = self.x;
        const my_y = self.y;

        // Describe buddy position
        const me = std.fmt.bufPrint(buf[pos..], "You are at ({d:.0},{d:.0}). ", .{ my_x, my_y }) catch return buf[0..pos];
        pos += me.len;

        // Describe nearby windows
        for (state_windows) |win| {
            if (win.w < 1) continue;
            if (pos + 100 >= buf.len) break;
            const cx = win.x + win.w * 0.5;
            const cy = win.y + win.h * 0.5;
            const dx = cx - my_x;
            const dy = cy - my_y;

            const horiz: []const u8 = if (dx > 50) "right" else if (dx < -50) "left" else "here";
            const vert: []const u8 = if (dy > 50) "above" else if (dy < -50) "below" else "level";

            // Is this the focused window?
            const is_focused = @abs(win.x - focused.x) < 2 and @abs(win.y - focused.y) < 2;

            const desc = std.fmt.bufPrint(buf[pos..], "Window {s}{s} to the {s}. ", .{
                if (is_focused) "(focused) " else "",
                vert,
                horiz,
            }) catch break;
            pos += desc.len;
        }

        return buf[0..pos];
    }

    fn callHaiku(self: *Context) void {
        // Build event context
        var context_buf: [512]u8 = undefined;
        var pos: usize = 0;

        const header = "Recent: ";
        @memcpy(context_buf[pos..pos + header.len], header);
        pos += header.len;

        for (0..self.event_count) |i| {
            const ev = self.events[i].slice();
            if (pos + ev.len + 2 >= context_buf.len) break;
            @memcpy(context_buf[pos..pos + ev.len], ev);
            pos += ev.len;
            context_buf[pos] = '.';
            context_buf[pos + 1] = ' ';
            pos += 2;
        }

        const context = context_buf[0..pos];

        // Build spatial layout description
        var layout_buf: [512]u8 = undefined;
        const layout = self.describeLayout(self.cached_windows[0..self.cached_window_count], self.cached_focused, &layout_buf);

        var prompt_buf: [2048]u8 = undefined;
        const prompt = std.fmt.bufPrint(&prompt_buf,
            \\You are a tiny cute monster on a desktop. Curious and adventurous.
            \\Phase 1: Explore! Jump and chase to visit windows you haven't seen.
            \\Phase 2: Once you've explored (3+ windows), find the focused window and hang out near it.
            \\You like being near the action. If you're not on the focused window, chase or jump toward it.
            \\When on the focused window, relax - idle, wave, push, or do something playful.
            \\
            \\{s}
            \\{s}
            \\
            \\Standing on: {s}
            \\Explored: {d} windows
            \\On focused window: {s}
            \\
            \\Respond JSON only: {{"actions":[{{"action":"<action>","direction":"left"|"right"}}, ...]}}
            \\Chain 1-4 actions. Actions: idle, wander, chase, jump, wave, push, throw, trip, death, climb, celebrate
        , .{
            layout,
            context,
            if (self.current_window_len > 0) self.current_window[0..self.current_window_len] else "ground",
            self.windows_visited,
            blk: {
                const on_focused = self.grounded and self.cached_focused.w > 0 and
                    self.x > self.cached_focused.x and
                    self.x < self.cached_focused.x + self.cached_focused.w and
                    @abs(self.y - (self.cached_focused.y + self.cached_focused.h)) < 5;
                break :blk if (on_focused) "yes" else "no";
            },
        }) catch return;

        // Build the Bedrock request body — escape prompt for JSON
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

        std.debug.print("AI > standing={s} visited={d} on_focused={s}\n", .{
            if (self.current_window_len > 0) self.current_window[0..self.current_window_len] else "ground",
            self.windows_visited,
            blk: {
                const on_f = self.grounded and self.cached_focused.w > 0 and
                    self.x > self.cached_focused.x and
                    self.x < self.cached_focused.x + self.cached_focused.w and
                    @abs(self.y - (self.cached_focused.y + self.cached_focused.h)) < 5;
                break :blk if (on_f) "yes" else "no";
            },
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
        // Check if the done marker exists
        std.fs.accessAbsolute("/tmp/hyprglaze-ai-done", .{}) catch return;

        // Read response
        const file = std.fs.openFileAbsolute("/tmp/hyprglaze-ai-response.json", .{}) catch return;
        defer file.close();

        var resp_buf: [4096]u8 = undefined;
        const resp_len = file.readAll(&resp_buf) catch return;
        const resp = resp_buf[0..resp_len];

        // Parse outer Bedrock response to get content
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
            // Single action fallback
            self.parseOneAction(ai_resp.value.object);
        }

        // Start first action and log the chain
        if (self.queue_len > 0) {
            self.popNextAction();
            var log_buf: [128]u8 = undefined;
            var lp: usize = 0;
            for (0..self.queue_len) |qi| {
                const name = actionName(self.action_queue[qi].behavior);
                if (lp + name.len + 2 >= log_buf.len) break;
                if (qi > 0) { log_buf[lp] = '>'; lp += 1; }
                @memcpy(log_buf[lp..lp + name.len], name);
                lp += name.len;
            }
            std.debug.print("AI < {s}\n", .{log_buf[0..lp]});
            self.logEvent("plan: {s}", .{log_buf[0..lp]});
        }

        self.ai_pending = false;
        std.fs.deleteFileAbsolute("/tmp/hyprglaze-ai-done") catch {};
        std.fs.deleteFileAbsolute("/tmp/hyprglaze-ai-request.json") catch {};
    }

    fn parseOneAction(self: *Context, obj: std.json.ObjectMap) void {
        const act_val = obj.get("action") orelse return;
        if (act_val != .string) return;
        const mapped = mapAction(act_val.string) orelse return;

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

    fn mapAction(name: []const u8) ?QueuedAction {
        const map = [_]struct { n: []const u8, b: Behavior, d: f32 }{
            .{ .n = "idle", .b = .idle, .d = 2.0 },
            .{ .n = "wander", .b = .wander, .d = 3.0 },
            .{ .n = "chase", .b = .chase, .d = 4.0 },
            .{ .n = "jump", .b = .jump_to, .d = 2.0 },
            .{ .n = "wave", .b = .wave, .d = 1.5 },
            .{ .n = "push", .b = .push, .d = 2.0 },
            .{ .n = "throw", .b = .throw_rock, .d = 1.2 },
            .{ .n = "trip", .b = .trip, .d = 1.0 },
            .{ .n = "death", .b = .dramatic_death, .d = 3.0 },
            .{ .n = "climb", .b = .climb, .d = 1.5 },
            .{ .n = "celebrate", .b = .celebrate, .d = 1.5 },
        };
        for (map) |m| {
            if (std.mem.eql(u8, name, m.n)) return .{ .behavior = m.b, .duration = m.d, .dir = 1.0 };
        }
        return null;
    }

    fn actionName(b: Behavior) []const u8 {
        return switch (b) {
            .idle => "idle", .wander => "wander", .chase => "chase",
            .jump_to => "jump", .wave => "wave", .push => "push",
            .throw_rock => "throw", .trip => "trip", .dramatic_death => "death",
            .climb => "climb", .celebrate => "celebrate",
            .curious => "curious", .flee => "flee",
        };
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

        // Detect landing on window
        if (self.grounded and self.landed_on_new) {
            self.landed_on_new = false;
            self.windows_visited +|= 1;
            if (self.current_window_len > 0) {
                self.logEvent("landed on {s}", .{self.current_window[0..self.current_window_len]});
            } else {
                self.logEvent("landed on ground", .{});
            }
        }

        // Detect cursor approach
        if (cursor_dist < 100 and self.cursor_speed < 50) {
            // Only log occasionally
            if (self.ai_timer > self.ai_cooldown * 0.5) {
                self.logEvent("cursor hovering nearby", .{});
            }
        } else if (cursor_dist < 80 and self.cursor_speed > 500) {
            self.logEvent("cursor swooped past", .{});
        }

        // --- Rate limiting ---
        self.ai_timer += dt;
        self.minute_timer += dt;
        if (self.minute_timer >= 60.0) {
            self.minute_timer = 0;
            self.calls_this_minute = 0;
        }

        // --- AI decision making ---
        if (self.ai_pending) {
            self.ai_pending_timer += dt;
            if (self.ai_pending_timer > 10.0) {
                // Timed out — give up and fall back to procedural
                std.debug.print("AI timeout, falling back\n", .{});
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
        if (self.grounded and cursor_dist < 120 and
            self.behavior != .trip and self.behavior != .dramatic_death)
        {
            if (self.cursor_speed > 2000) {
                self.vx += (state.cursor[0] - self.x) * 3.0;
                self.setBehavior(.trip, 0.8);
                self.logEvent("got knocked by cursor", .{});
            } else if (self.cursor_speed > 800 and cursor_dist < 80) {
                self.setBehavior(.flee, 1.5);
                self.wander_dir = if (state.cursor[0] > self.x) -1.0 else 1.0;
                self.logEvent("fleeing from cursor", .{});
            }
        }

        // --- Behavior timer ---
        self.behavior_timer += dt;
        self.jump_cooldown -= dt;

        // Behavior expired — pop next from queue, or procedural fallback
        if (self.behavior_timer >= self.behavior_duration) {
            if (self.queue_pos < self.queue_len) {
                self.popNextAction();
            } else {
                const roll = rand.float(f32);
                if (has_target and roll < 0.4) {
                    self.setBehavior(.chase, 3.0);
                } else if (roll < 0.7) {
                    self.setBehavior(.wander, 2.0 + rand.float(f32) * 2.0);
                    self.wander_dir = if (rand.boolean()) @as(f32, 1.0) else -1.0;
                } else {
                    self.setBehavior(.idle, 1.5 + rand.float(f32) * 2.0);
                }
            }
        }

        // --- Execute behavior ---
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
                    const dx = target_x - self.x;
                    self.facing_right = dx > 0;
                    const dir: f32 = if (dx > 0) 1.0 else -1.0;
                    const use_run = @abs(dx) > 200;
                    const target_vx = dir * (if (use_run) self.run_speed else self.walk_speed);
                    self.vx += (target_vx - self.vx) * 5.0 * dt;
                    self.setAnim(if (use_run) RUN else WALK);

                    const target_y = fw.y + fw.h;
                    if (target_y - self.y > 30 and self.jump_cooldown <= 0) {
                        self.setBehavior(.jump_to, 2.0);
                    }
                    if (@abs(dx) < 30 and @abs(fw.y + fw.h - self.y) < 10) {
                        self.setBehavior(.idle, 1.0);
                    }
                }
            },
            .jump_to => {
                if (self.grounded and self.jump_cooldown <= 0 and has_target) {
                    const jump_h = @max((fw.y + fw.h) - self.y + 80.0, 120.0);
                    self.vy = @sqrt(2.0 * gravity * jump_h);
                    self.grounded = false;
                    self.jump_cooldown = 0.8;
                    const dx = (fw.x + fw.w * 0.5) - self.x;
                    self.vx += std.math.clamp(dx * 0.5, -150, 150);
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
                    self.logEvent("respawned", .{});
                }
            },
            .climb => {
                self.setAnim(CLIMB);
                if (self.grounded) { self.vy = 60.0; self.grounded = false; }
                self.vx *= 0.8;
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

        // Face direction of movement
        if (@abs(self.vx) > 5.0) {
            self.facing_right = self.vx > 0;
        }

        // Friction + clamp
        if (self.grounded) self.vx *= 0.88;
        self.vx = std.math.clamp(self.vx, -self.run_speed, self.run_speed);

        // Integrate
        self.x += self.vx * dt;
        self.y += self.vy * dt;

        // --- Collisions ---
        const was_grounded = self.grounded;
        self.grounded = false;

        if (self.y <= 0) {
            self.y = 0;
            self.vy = 0;
            self.grounded = true;
            if (!was_grounded) {
                self.landed_on_new = true;
                self.current_window_len = 0;
            }
        }

        // Track which window we're on
        for (state.windows) |win| {
            if (win.w < 1) continue;
            const wt = win.y + win.h;
            if (self.x < win.x - 5 or self.x > win.x + win.w + 5) continue;
            if (self.vy <= 0 and self.y <= wt and self.y > wt - 20) {
                self.y = wt;
                self.vy = 0;
                if (!self.grounded) {
                    self.landed_on_new = true;
                    // Try to identify window by matching to focused
                    if (has_target and @abs(win.x - fw.x) < 2 and @abs(win.y - fw.y) < 2) {
                        // This is the focused window — we know its class from IPC
                        // For now just mark as "focused window"
                        const label = "focused window";
                        @memcpy(self.current_window[0..label.len], label);
                        self.current_window_len = label.len;
                    }
                }
                self.grounded = true;
            }
        }

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
                col_f * CELL / SHEET_W, row_f * CELL / SHEET_H,
                (col_f + 1.0) * CELL / SHEET_W, (row_f + 1.0) * CELL / SHEET_H);
        if (prog.i_particle_count >= 0)
            c.glUniform1i(prog.i_particle_count, 2);
    }

    pub fn deinit(self: *Context) void {
        if (self.sprite_tex) |*tex| tex.deinit();
    }
};
