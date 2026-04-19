const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const texture_mod = @import("../../core/texture.zig");
const config_mod = @import("../../core/config.zig");
const transition_mod = @import("../../core/transition.zig");
const effects = @import("../../effects.zig");
const sprite = @import("sprite.zig");

const c = @cImport({ @cInclude("GLES3/gl3.h"); });

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

pub const Context = struct {
    x: f32,
    y: f32,
    vx: f32 = 0,
    vy: f32 = 0,
    screen_w: f32,
    screen_h: f32,
    scale: f32 = 2.0,

    // Animation
    anim: Anim = IDLE,
    frame: u8 = 0,
    frame_timer: f32 = 0,
    anim_done: bool = false,
    facing_right: bool = true,

    // Movement speeds synced to animation
    walk_speed: f32 = 0,
    run_speed: f32 = 0,

    // Behavior
    behavior: Behavior = .idle,
    behavior_timer: f32 = 0,
    behavior_duration: f32 = 0,
    idle_time: f32 = 0,
    wander_dir: f32 = 1,

    // Cursor tracking
    prev_cursor: [2]f32 = .{ 0, 0 },
    cursor_speed: f32 = 0,

    // Physics
    grounded: bool = false,
    jump_cooldown: f32 = 0,

    // RNG
    rng: std.Random.DefaultPrng,

    // Texture
    sprite_tex: ?texture_mod.Texture = null,

    pub fn init(_: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) Context {
        const sprite_path = params.getString("sprite", "sprites/buddy.png") orelse "sprites/buddy.png";
        const tex = texture_mod.Texture.loadFromFile(sprite_path) catch null;

        const scale: f32 = params.getFloat("scale", 2.0);
        const walk_spd = (32.0 * scale) / (6.0 / 8.0);
        const run_spd = (32.0 * scale * 2.0) / (6.0 / 12.0);

        return .{
            .x = width * 0.5,
            .y = height - 50,
            .screen_w = width,
            .screen_h = height,
            .sprite_tex = tex,
            .rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp())),
            .walk_speed = walk_spd,
            .run_speed = run_spd,
        };
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
        const cursor_dx_to_buddy = state.cursor[0] - self.x;

        // --- Cursor reactions ---
        if (self.grounded and cursor_dist < 120 and
            self.behavior != .trip and self.behavior != .dramatic_death)
        {
            if (self.cursor_speed > 2000) {
                self.vx += cursor_dx * 3.0;
                self.behavior = .trip;
                self.behavior_timer = 0;
                self.behavior_duration = 0.8;
                self.anim_done = false;
                self.frame = 0;
            } else if (self.cursor_speed > 800 and cursor_dist < 80) {
                self.behavior = .flee;
                self.wander_dir = if (cursor_dx_to_buddy > 0) -1.0 else 1.0;
                self.behavior_timer = 0;
                self.behavior_duration = 1.5;
            } else if (self.cursor_speed < 50 and
                (self.behavior == .idle or self.behavior == .curious))
            {
                self.behavior = .curious;
                self.behavior_timer = 0;
                self.behavior_duration = 3.0;
            }
        }

        // --- Behavior decisions ---
        self.behavior_timer += dt;
        self.jump_cooldown -= dt;

        const fw = state.focused_win;
        const has_target = fw.w > 0 and fw.h > 0;

        var pick_new = self.behavior_timer >= self.behavior_duration;
        if (self.behavior == .wave or self.behavior == .throw_rock or
            self.behavior == .trip or self.behavior == .dramatic_death)
        {
            pick_new = pick_new or self.anim_done;
        }

        if (pick_new) {
            self.pickBehavior(rand, has_target, cursor_dist);
        }

        // --- Execute current behavior ---
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
                if (self.x < 50 or self.x > self.screen_w - 50) {
                    self.wander_dir = -self.wander_dir;
                }
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
                        self.behavior = .jump_to;
                        self.behavior_timer = 0;
                        self.behavior_duration = 2.0;
                    }

                    if (@abs(dx) < 30 and @abs(fw.y + fw.h - self.y) < 10) {
                        self.behavior = .idle;
                        self.behavior_timer = 0;
                        self.behavior_duration = 1.0 + rand.float(f32) * 2.0;
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
                    self.behavior = .idle;
                    self.behavior_duration = 0.5;
                    self.behavior_timer = 0;
                }
            },
            .wave, .celebrate => {
                self.vx *= 0.9;
                self.facing_right = state.cursor[0] > self.x;
                self.setAnim(if (self.behavior == .celebrate) ATTACK2 else ATTACK1);
            },
            .push => {
                self.setAnim(PUSH);
                if (has_target) {
                    const edge_left = fw.x;
                    const edge_right = fw.x + fw.w;
                    const dl = @abs(self.x - edge_left);
                    const dr = @abs(self.x - edge_right);
                    if (dl < dr) {
                        self.vx -= 30.0 * dt;
                        self.facing_right = false;
                    } else {
                        self.vx += 30.0 * dt;
                        self.facing_right = true;
                    }
                }
            },
            .throw_rock => {
                self.vx *= 0.9;
                self.facing_right = state.cursor[0] > self.x;
                self.setAnim(THROW);
            },
            .trip => {
                self.vx *= 0.95;
                self.setAnim(HURT);
            },
            .dramatic_death => {
                self.vx *= 0.95;
                self.setAnim(DEATH);
                if (self.anim_done) {
                    self.x = self.screen_w * 0.5;
                    self.y = self.screen_h;
                    self.vx = 0;
                    self.vy = 0;
                    self.behavior = .idle;
                    self.behavior_duration = 1.0;
                    self.behavior_timer = 0;
                }
            },
            .climb => {
                self.setAnim(CLIMB);
                if (self.grounded) {
                    self.vy = 60.0;
                    self.grounded = false;
                }
                self.vx *= 0.8;
            },
            .curious => {
                self.facing_right = state.cursor[0] > self.x;
                const cdx = state.cursor[0] - self.x;
                if (@abs(cdx) > 40) {
                    const dir: f32 = if (cdx > 0) 1.0 else -1.0;
                    self.vx += (dir * self.walk_speed - self.vx) * 5.0 * dt;
                    self.setAnim(WALK);
                } else {
                    self.vx *= 0.85;
                    self.setAnim(ATTACK1);
                }
            },
            .flee => {
                self.facing_right = self.wander_dir > 0;
                const target_vx = self.wander_dir * self.run_speed;
                self.vx += (target_vx - self.vx) * 8.0 * dt;
                self.setAnim(RUN);
            },
        }

        // Friction
        if (self.grounded) self.vx *= 0.88;
        self.vx = std.math.clamp(self.vx, -self.run_speed, self.run_speed);

        // Integrate
        self.x += self.vx * dt;
        self.y += self.vy * dt;

        // --- Collisions ---
        self.grounded = false;

        if (self.y <= 0) {
            self.y = 0;
            self.vy = 0;
            self.grounded = true;
        }

        for (state.windows) |win| {
            if (win.w < 1) continue;
            const wt = win.y + win.h;
            if (self.x < win.x - 5 or self.x > win.x + win.w + 5) continue;
            if (self.vy <= 0 and self.y <= wt and self.y > wt - 20) {
                self.y = wt;
                self.vy = 0;
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

    fn pickBehavior(self: *Context, rand: std.Random, has_target: bool, cursor_dist: f32) void {
        self.behavior_timer = 0;
        self.anim_done = false;
        self.frame = 0;
        self.frame_timer = 0;

        const roll = rand.float(f32);

        if (cursor_dist < 150 and roll < 0.4) {
            if (roll < 0.2) {
                self.behavior = .wave;
                self.behavior_duration = 1.5;
            } else {
                self.behavior = .throw_rock;
                self.behavior_duration = 1.2;
            }
            return;
        }

        if (has_target and roll < 0.5) {
            self.behavior = .chase;
            self.behavior_duration = 3.0 + rand.float(f32) * 2.0;
            self.idle_time = 0;
            return;
        }

        if (self.idle_time > 5.0 and roll < 0.3) {
            if (roll < 0.05) {
                self.behavior = .dramatic_death;
                self.behavior_duration = 3.0;
            } else if (roll < 0.1) {
                self.behavior = .trip;
                self.behavior_duration = 1.0;
            } else if (roll < 0.2) {
                self.behavior = .push;
                self.behavior_duration = 2.0;
            } else {
                self.behavior = .climb;
                self.behavior_duration = 1.5;
            }
            self.idle_time = 0;
            return;
        }

        if (roll < 0.6) {
            self.behavior = .idle;
            self.behavior_duration = 2.0 + rand.float(f32) * 3.0;
        } else {
            self.behavior = .wander;
            self.behavior_duration = 2.0 + rand.float(f32) * 3.0;
            self.wander_dir = if (rand.boolean()) @as(f32, 1.0) else -1.0;
        }
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
            } else {
                self.frame += 1;
            }
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
                col_f * sprite.CELL / sprite.SHEET_W,
                row_f * sprite.CELL / sprite.SHEET_H,
                (col_f + 1.0) * sprite.CELL / sprite.SHEET_W,
                (row_f + 1.0) * sprite.CELL / sprite.SHEET_H);
        if (prog.i_particle_count >= 0)
            c.glUniform1i(prog.i_particle_count, 2);
    }

    pub fn deinit(self: *Context) void {
        if (self.sprite_tex) |*tex| tex.deinit();
    }
};
