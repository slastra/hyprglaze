// Shared types and constants for buddy effects.
// Both buddy and ai_buddy import from here.

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
