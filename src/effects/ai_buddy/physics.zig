const std = @import("std");
const effects = @import("../../effects.zig");
const context_mod = @import("context.zig");

/// Post-behavior physics step: air control, friction, position integration,
/// ground/window/screen-edge collisions. Runs after `behaviors.execute`,
/// which is responsible for gravity application and the per-behavior
/// motion-intent updates.
pub fn step(ctx: *context_mod.Context, state: effects.FrameState, dt: f32) void {
    const fw = state.focused_win;
    const has_target = fw.w > 0 and fw.h > 0;

    // Gentle airborne steering toward the focused window.
    if (!ctx.grounded and !ctx.climbing and has_target) {
        const target_x = fw.x + fw.w * 0.5;
        const air_dx = target_x - ctx.x;
        ctx.vx += std.math.clamp(air_dx * 0.5, -80, 80) * dt;
    }

    // Face direction of movement (climb has its own facing rule).
    if (!ctx.climbing and @abs(ctx.vx) > 5.0) {
        ctx.facing_right = ctx.vx > 0;
    }

    // Friction + clamp.
    if (ctx.grounded) ctx.vx *= 0.92;
    ctx.vx = std.math.clamp(ctx.vx, -ctx.run_speed * 1.5, ctx.run_speed * 1.5);

    // Integrate.
    ctx.x += ctx.vx * dt;
    ctx.y += ctx.vy * dt;

    // --- Collisions ---
    const was_grounded = ctx.grounded;
    ctx.grounded = false;
    if (!was_grounded) ctx.airborne_time += dt;

    if (ctx.y <= 0) {
        ctx.y = 0;
        ctx.vy = 0;
        ctx.grounded = true;
        if (!was_grounded and ctx.airborne_time > 0.15) {
            ctx.landed_on_new = true;
            ctx.current_window_len = 0;
        }
        ctx.airborne_time = 0;
    }

    // Clear drop state once we've fallen well below the platform.
    if (ctx.dropping and ctx.y < ctx.drop_platform_y - 30) {
        ctx.dropping = false;
    }

    // Window-top collisions (skip while climbing).
    if (!ctx.climbing) {
        for (state.windows, 0..) |win, wi| {
            if (win.w < 1) continue;
            const wt = win.y + win.h;
            if (ctx.x < win.x - 5 or ctx.x > win.x + win.w + 5) continue;

            // Skip the platform we're dropping through.
            if (ctx.dropping and @abs(wt - ctx.drop_platform_y) < 10) continue;

            if (ctx.vy <= 0 and ctx.y <= wt and ctx.y > wt - 20) {
                ctx.y = wt;
                ctx.vy = 0;
                ctx.dropping = false;
                if (!ctx.grounded and ctx.airborne_time > 0.15) {
                    ctx.landed_on_new = true;
                    ctx.airborne_time = 0;
                    // Identify the landed-on window by class from the cache.
                    if (wi < ctx.cached_window_count) {
                        const clen = ctx.cached_window_class_lens[wi];
                        if (clen > 0) {
                            const copy_len = @min(clen, 64);
                            @memcpy(ctx.current_window[0..copy_len], ctx.cached_window_classes[wi][0..copy_len]);
                            ctx.current_window_len = copy_len;
                        } else {
                            const label = "window";
                            @memcpy(ctx.current_window[0..label.len], label);
                            ctx.current_window_len = label.len;
                        }
                    }
                }
                ctx.grounded = true;
            }
        }
    }

    // Screen edges.
    if (ctx.x < 20) {
        ctx.x = 20;
        ctx.vx = 0;
    }
    if (ctx.x > ctx.screen_w - 20) {
        ctx.x = ctx.screen_w - 20;
        ctx.vx = 0;
    }
    if (ctx.y > ctx.screen_h) {
        ctx.y = ctx.screen_h;
        ctx.vy = 0;
    }
}
