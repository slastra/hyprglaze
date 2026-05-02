const std = @import("std");
const effects = @import("../../effects.zig");
const sprite = @import("../buddy/sprite.zig");
const context_mod = @import("context.zig");

const log = std.log.scoped(.ai_buddy);

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

/// Downward acceleration applied each frame in non-climb behaviors. Tuned
/// against `walk_speed`/`run_speed` and the jump-impulse calculation in
/// `.jump_to`; changing this changes both jump arc height and fall speed.
pub const GRAVITY: f32 = 900.0;

/// Run the climb-override OR the per-behavior intent switch. Mutates the
/// motion intent on `ctx` (vx, vy, anim, facing_right, behavior); does
/// NOT integrate position — `physics.step` handles that.
pub fn execute(ctx: *context_mod.Context, state: effects.FrameState, dt: f32) void {
    const fw = state.focused_win;
    const has_target = fw.w > 0 and fw.h > 0;

    // Wall climb overrides the per-behavior switch entirely.
    if (ctx.climbing) {
        ctx.setAnim(CLIMB);
        ctx.vy = ctx.climb_speed;
        ctx.vx = 0;
        ctx.x = ctx.climb_wall_x;
        ctx.grounded = false;
        ctx.facing_right = ctx.climb_wall_x > ctx.x - 1;
        if (ctx.y >= ctx.climb_target_y) {
            ctx.y = ctx.climb_target_y;
            ctx.vy = 0;
            ctx.grounded = true;
            ctx.climbing = false;
            ctx.landed_on_new = true;
            ctx.failed_jumps = 0;
            ctx.setBehavior(.idle, 0.5);
            ctx.event_log.log("climbed up", .{});
            log.debug("AI ~ reached top", .{});
        }
        return;
    }

    ctx.vy -= GRAVITY * dt;

    switch (ctx.behavior) {
        .idle => {
            ctx.vx *= 0.9;
            ctx.idle_time += dt;
            ctx.setAnim(IDLE);
        },
        .wander => {
            if (ctx.grounded) {
                const target_vx = ctx.wander_dir * ctx.walk_speed;
                ctx.vx += (target_vx - ctx.vx) * 5.0 * dt;
            }
            ctx.facing_right = ctx.wander_dir > 0;
            ctx.setAnim(WALK);
            if (ctx.x < 50 or ctx.x > ctx.screen_w - 50) ctx.wander_dir = -ctx.wander_dir;
        },
        .chase => {
            if (has_target and ctx.grounded) {
                const target_x = fw.x + fw.w * 0.5;
                const target_top = fw.y + fw.h;
                const dx = target_x - ctx.x;
                const dy = target_top - ctx.y;

                // Arrived: horizontally close AND on the same vertical level.
                if (@abs(dx) < 30 and @abs(dy) < 10) {
                    ctx.failed_jumps = 0;
                    ctx.setBehavior(.idle, 1.0);
                } else if (dy > 200 or (dy > 30 and ctx.failed_jumps >= 2)) {
                    // Target too high to jump (or jump failed twice) — climb.
                    const dist_left = @abs(ctx.x - fw.x);
                    const dist_right = @abs(ctx.x - (fw.x + fw.w));
                    const wall_x = if (dist_left < dist_right) fw.x else fw.x + fw.w;
                    const wall_dist = @abs(ctx.x - wall_x);

                    if (wall_dist < 10) {
                        // At the wall — latch and climb.
                        ctx.climbing = true;
                        ctx.climb_wall_x = wall_x;
                        ctx.climb_target_y = fw.y + fw.h;
                        ctx.setBehavior(.climb, 15.0);
                        log.debug("AI ~ climbing wall", .{});
                    } else {
                        ctx.facing_right = wall_x > ctx.x;
                        const dir: f32 = if (wall_x > ctx.x) 1.0 else -1.0;
                        const target_vx = dir * ctx.run_speed;
                        ctx.vx += (target_vx - ctx.vx) * 5.0 * dt;
                        ctx.setAnim(RUN);
                    }
                } else if (dy > 30 and ctx.jump_cooldown <= 0) {
                    ctx.failed_jumps +|= 1;
                    ctx.setBehavior(.jump_to, 2.0);
                } else if (dy < -30) {
                    // Target below — drop through current platform.
                    ctx.dropping = true;
                    ctx.drop_platform_y = ctx.y;
                    log.debug("AI ~ dropping through platform", .{});
                    ctx.grounded = false;
                    ctx.vy = -50.0;
                    ctx.vx = std.math.clamp(dx * 0.3, -100, 100);
                    ctx.setAnim(JUMP);
                } else {
                    // Same height — run toward target.
                    ctx.facing_right = dx > 0;
                    const dir: f32 = if (dx > 0) 1.0 else -1.0;
                    const use_run = @abs(dx) > 200;
                    const target_vx = dir * (if (use_run) ctx.run_speed else ctx.walk_speed);
                    ctx.vx += (target_vx - ctx.vx) * 5.0 * dt;
                    ctx.setAnim(if (use_run) RUN else WALK);
                }
            }
        },
        .jump_to => {
            if (ctx.grounded and ctx.jump_cooldown <= 0 and has_target) {
                const target_top = fw.y + fw.h;
                const height_diff = target_top - ctx.y;
                if (height_diff > -20) {
                    const jump_h = @max(height_diff + 80.0, 120.0);
                    ctx.vy = @sqrt(2.0 * GRAVITY * @min(jump_h, 600.0));
                    ctx.grounded = false;
                    ctx.jump_cooldown = 0.8;
                    const dx = (fw.x + fw.w * 0.5) - ctx.x;
                    ctx.vx = std.math.clamp(dx * 0.8, -250, 250);
                } else {
                    // Target below — switch to chase (which handles drop).
                    ctx.setBehavior(.chase, 3.0);
                }
            }
            if (!ctx.grounded) {
                ctx.setAnim(JUMP);
                ctx.setJumpFrame();
            } else {
                ctx.setBehavior(.idle, 0.5);
            }
        },
        .wave => {
            ctx.vx *= 0.9;
            ctx.setAnim(ATTACK1);
        },
        .celebrate => {
            ctx.vx *= 0.9;
            ctx.setAnim(ATTACK2);
        },
        .push => {
            ctx.setAnim(PUSH);
            if (has_target) {
                const dl = @abs(ctx.x - fw.x);
                const dr = @abs(ctx.x - (fw.x + fw.w));
                if (dl < dr) {
                    ctx.vx -= 30.0 * dt;
                    ctx.facing_right = false;
                } else {
                    ctx.vx += 30.0 * dt;
                    ctx.facing_right = true;
                }
            }
        },
        .throw_rock => {
            ctx.vx *= 0.9;
            ctx.facing_right = state.cursor[0] > ctx.x;
            ctx.setAnim(THROW);
        },
        .trip => {
            ctx.vx *= 0.95;
            ctx.setAnim(HURT);
        },
        .dramatic_death => {
            ctx.vx *= 0.95;
            ctx.setAnim(DEATH);
            if (ctx.anim_done) {
                ctx.x = ctx.screen_w * 0.5;
                ctx.y = ctx.screen_h;
                ctx.vx = 0;
                ctx.vy = 0;
                ctx.setBehavior(.idle, 1.0);
                ctx.event_log.log("respawned", .{});
            }
        },
        .climb => {
            // Wall climb is handled by the override above; this is a fallback
            // for the .climb behavior when not actually latched to a wall.
            if (!ctx.climbing) ctx.setBehavior(.idle, 0.5);
        },
        .curious => {
            ctx.facing_right = state.cursor[0] > ctx.x;
            const cdx = state.cursor[0] - ctx.x;
            if (@abs(cdx) > 40) {
                const dir: f32 = if (cdx > 0) 1.0 else -1.0;
                ctx.vx += (dir * ctx.walk_speed - ctx.vx) * 5.0 * dt;
                ctx.setAnim(WALK);
            } else {
                ctx.vx *= 0.85;
                ctx.setAnim(ATTACK1);
            }
        },
        .flee => {
            ctx.facing_right = ctx.wander_dir > 0;
            const target_vx = ctx.wander_dir * ctx.run_speed;
            ctx.vx += (target_vx - ctx.vx) * 8.0 * dt;
            ctx.setAnim(RUN);
        },
    }
}
