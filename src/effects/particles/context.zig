const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const effects = @import("../../effects.zig");
const system = @import("system.zig");

const Uniforms = @import("../uniforms.zig").Uniforms;

const c = @import("c");

/// Motion streak length: where the ball was this long ago.
const trail_secs: f32 = 0.06;

pub const Context = struct {
    sys: system.ParticleSystem,

    // Last frame's window rects by address, for window velocities.
    prev_addr: [system.max_colliders]u64 = @splat(0),
    prev_rect: [system.max_colliders]system.Rect = undefined,
    prev_count: usize = 0,
    last_ws_switches: u32 = 0,
    last_slide: f32 = 1.0,

    u: Uniforms(.{
        .balls = "iBalls[0]",
        .ball_count = "iBallCount",
        .pops = "iPops[0]",
    }) = .{},

    pub fn init(_: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) Context {
        const count: u32 = @intCast(std.math.clamp(params.getInt("count", 60), 0, system.max_balls));
        var sys = system.ParticleSystem.init(count, width, height);
        // Both knobs predate the rewrite and were per-step at 30Hz: keep
        // their meaning in the new units.
        const damping = std.math.clamp(params.getFloat("damping", 0.999), 0.5, 1.0);
        sys.params.drag = -@log(damping) * 30.0;
        sys.params.pop_speed = params.getFloat("pop_threshold", 50.0) * 30.0;
        return .{ .sys = sys };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);

        // Window displacement is the window's own unless the workspace
        // camera moved it (a slide, or a snap across workspaces): then
        // windows still block, but bat nothing.
        const camera_moving = state.workspace_switches != self.last_ws_switches or
            state.workspace_slide < 1.0 or self.last_slide < 1.0;
        self.last_ws_switches = state.workspace_switches;
        self.last_slide = state.workspace_slide;

        var cols: [system.max_colliders]system.Collider = undefined;
        const n = @min(state.windows.len, system.max_colliders);
        for (state.windows[0..n], 0..) |w, i| {
            const to = system.Rect{ .x = w.x, .y = w.y, .w = w.w, .h = w.h };
            var from = to;
            var known = false;
            for (self.prev_addr[0..self.prev_count], self.prev_rect[0..self.prev_count]) |a, r| {
                if (a == w.address and a != 0) {
                    from = r;
                    known = true;
                    break;
                }
            }
            cols[i] = .{ .from = from, .to = to, .moving = known and !camera_moving };
        }
        for (state.windows[0..n], 0..) |w, i| {
            self.prev_addr[i] = w.address;
            self.prev_rect[i] = .{ .x = w.x, .y = w.y, .w = w.w, .h = w.h };
        }
        self.prev_count = n;

        // The focused window is the gravity well.
        const fw = state.focused_win;
        const well: ?[2]f32 = if (fw.hasArea()) .{ fw.x + fw.w * 0.5, fw.y + fw.h * 0.5 } else null;

        self.sys.step(dt, well, state.cursor, cols[0..n]);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        self.u.use(prog.program);

        // Two vec4 per ball: (x, y, r, colour), (streak tail x, y, 0, 0).
        var buf: [system.max_balls * 2][4]f32 = undefined;
        const count = self.sys.count;
        for (self.sys.balls[0..count], 0..) |b, i| {
            var tx = b.x[0] - b.v[0] * trail_secs;
            var ty = b.x[1] - b.v[1] * trail_secs;
            // Cap the streak so a batted ball reads as fast, not as a line.
            const dx = tx - b.x[0];
            const dy = ty - b.x[1];
            const len = @sqrt(dx * dx + dy * dy);
            const cap = b.r * 6.0;
            if (len > cap) {
                tx = b.x[0] + dx / len * cap;
                ty = b.x[1] + dy / len * cap;
            }
            buf[i * 2] = .{ b.x[0], b.x[1], b.r, b.color };
            buf[i * 2 + 1] = .{ tx, ty, 0, 0 };
        }
        self.u.f4v(.balls, @intCast(count * 2), &buf[0]);
        self.u.int(.ball_count, @intCast(count));

        if (self.u.loc(.pops) >= 0) {
            // (x, y, r, colour + age): age in [0, 1), colour's integer part
            // picks the palette slot.
            var pv: [system.max_pops][4]f32 = undefined;
            for (self.sys.pops, 0..) |p, i| {
                pv[i] = .{ p.x[0], p.x[1], if (p.age < 1) p.r else 0, @floor(p.color * 5.99) + @min(p.age, 0.999) };
            }
            self.u.f4v(.pops, system.max_pops, &pv[0]);
        }
    }

    pub fn deinit(_: *Context) void {}
};
