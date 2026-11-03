// Shared types, constants and sprite plumbing for buddy effects.
// Both buddy and ai_buddy import from here.

const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const texture_mod = @import("../../core/texture.zig");
const Uniforms = @import("../uniforms.zig").Uniforms;

const c = @import("c");

const log = std.log.scoped(.buddy);

pub const CELL: f32 = 32;
pub const SHEET_W: f32 = 256;
pub const SHEET_H: f32 = 352;

pub const Anim = struct { row: u8, frames: u8, fps: f32, looping: bool = true };
pub const IDLE    = Anim{ .row = 0,  .frames = 4, .fps = 4.0 };
pub const WALK    = Anim{ .row = 1,  .frames = 6, .fps = 8.0 };
pub const RUN     = Anim{ .row = 2,  .frames = 6, .fps = 12.0 };
pub const JUMP    = Anim{ .row = 3,  .frames = 8, .fps = 10.0, .looping = false };
pub const ATTACK1 = Anim{ .row = 4,  .frames = 4, .fps = 8.0,  .looping = false };
pub const ATTACK2 = Anim{ .row = 5,  .frames = 6, .fps = 10.0, .looping = false };
pub const PUSH    = Anim{ .row = 6,  .frames = 6, .fps = 6.0 };
pub const THROW   = Anim{ .row = 7,  .frames = 4, .fps = 6.0,  .looping = false };
pub const CLIMB   = Anim{ .row = 8,  .frames = 4, .fps = 6.0 };
pub const HURT    = Anim{ .row = 9,  .frames = 4, .fps = 8.0,  .looping = false };
pub const DEATH   = Anim{ .row = 10, .frames = 8, .fps = 6.0,  .looping = false };

pub const Behavior = enum {
    idle, wander, chase, jump_to, wave, push, throw_rock,
    trip, dramatic_death, climb, curious, flee, celebrate,
};

/// Playhead over the sprite sheet: the current animation row, frame, and
/// the fractional time toward the next frame.
pub const Player = struct {
    anim: Anim = IDLE,
    frame: u8 = 0,
    timer: f32 = 0,
    /// A non-looping animation reached its last frame.
    done: bool = false,

    /// Switch animation; a no-op when it is already playing.
    pub fn set(self: *Player, anim: Anim) void {
        if (self.anim.row != anim.row) self.* = .{ .anim = anim };
    }

    /// Mid-air, the jump frame follows vertical velocity rather than time.
    pub fn setJumpFrame(self: *Player, vy: f32) void {
        self.frame = if (vy > 100) 0
            else if (vy > 50) 1
            else if (vy > 0) 2
            else if (vy > -30) 3
            else if (vy > -80) 4
            else if (vy > -150) 5
            else 6;
    }

    pub fn advance(self: *Player, dt: f32, airborne: bool) void {
        if (self.anim.row == JUMP.row and airborne) return;
        self.timer += dt * self.anim.fps;
        if (self.timer >= 1.0) {
            self.timer -= 1.0;
            if (self.frame + 1 >= self.anim.frames) {
                if (self.anim.looping) self.frame = 0 else self.done = true;
            } else {
                self.frame += 1;
            }
        }
    }
};

/// The sprite sheet texture. Loaded on the first upload, not in init:
/// effects create no GL objects before the context they draw with exists,
/// and a context rebuild hands a fresh effect a fresh texture.
pub const Sheet = struct {
    path_buf: [256]u8 = undefined,
    path_len: usize = 0,
    tex: ?texture_mod.Texture = null,
    tried: bool = false,
    u: Uniforms(.{ .sprite = "iSprite" }) = .{},

    /// Copies `path`: config strings die with their config on a reload.
    pub fn init(path: []const u8) Sheet {
        var sheet = Sheet{};
        sheet.path_len = @min(path.len, sheet.path_buf.len);
        @memcpy(sheet.path_buf[0..sheet.path_len], path[0..sheet.path_len]);
        return sheet;
    }

    fn texture(self: *Sheet) ?*texture_mod.Texture {
        if (!self.tried) {
            self.tried = true;
            const path = self.path_buf[0..self.path_len];
            self.tex = texture_mod.Texture.loadFromFile(path) catch |err| blk: {
                log.warn("sprite load failed: {s} ({}) - buddy renders without a texture", .{ path, err });
                break :blk null;
            };
        }
        return if (self.tex) |*t| t else null;
    }

    pub fn deinit(self: *Sheet) void {
        if (self.tex) |*t| t.deinit();
        self.tex = null;
    }
};

/// Bind the sheet and write the sprite's two iParticles slots:
/// [0] = (x, y, scale, facing), [1] = the current frame's UV rect.
pub fn upload(
    prog: *const shader_mod.ShaderProgram,
    sheet: *Sheet,
    play: *const Player,
    x: f32,
    y: f32,
    scale: f32,
    facing_right: bool,
) void {
    sheet.u.use(prog.program);
    if (sheet.texture()) |tex| {
        tex.bind(0);
        sheet.u.int(.sprite, 0);
    }
    const facing: f32 = if (facing_right) 1.0 else -1.0;
    const col_f: f32 = @floatFromInt(play.frame);
    const row_f: f32 = @floatFromInt(play.anim.row);
    if (prog.i_particles[0] >= 0)
        c.glUniform4f(prog.i_particles[0], x, y, scale, facing);
    if (prog.i_particles[1] >= 0)
        c.glUniform4f(prog.i_particles[1],
            col_f * CELL / SHEET_W, row_f * CELL / SHEET_H,
            (col_f + 1.0) * CELL / SHEET_W, (row_f + 1.0) * CELL / SHEET_H);
}

test "Player switches, advances and finishes one-shot animations" {
    var p = Player{};
    p.set(ATTACK1);
    try std.testing.expectEqual(ATTACK1.row, p.anim.row);
    for (0..ATTACK1.frames) |_| p.advance(1.0 / ATTACK1.fps, false);
    try std.testing.expect(p.done);
    try std.testing.expectEqual(ATTACK1.frames - 1, p.frame);
    p.set(JUMP);
    p.setJumpFrame(-200);
    p.advance(1.0, true); // airborne: the jump frame is held
    try std.testing.expectEqual(@as(u8, 6), p.frame);
}
