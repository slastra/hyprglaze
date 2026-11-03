//! Cached uniform locations for an effect's own uniforms.
//!
//!     u: Uniforms(.{ .flow = "iBloomFlow", .bands = "iBloomBands[0]" }) = .{},
//!     ...
//!     self.u.use(prog.program);
//!     self.u.f1(.flow, self.flow);
//!     self.u.f1v(.bands, 6, &self.bands);
//!
//! `use` binds the program and looks the locations up again only when the
//! program changed (a shader hot reload or a rebuilt GL context). Each
//! setter skips a uniform the shader does not declare (location -1). The
//! array setters take the count and pointer the GL call would.

const std = @import("std");

const c = @import("c");

pub fn Uniforms(comptime spec: anytype) type {
    const Spec = @TypeOf(spec);
    const fields = @typeInfo(Spec).@"struct".field_names;
    return struct {
        const Self = @This();
        pub const Name = std.meta.FieldEnum(Spec);

        program: c.GLuint = 0,
        locs: [fields.len]c.GLint = @splat(-1),

        pub fn use(self: *Self, program: c.GLuint) void {
            c.glUseProgram(program);
            if (self.program == program) return;
            self.program = program;
            inline for (fields, 0..) |f_name, i| {
                self.locs[i] = c.glGetUniformLocation(program, @field(spec, f_name));
            }
        }

        /// The location, or -1 when the shader lacks the uniform.
        pub fn loc(self: *const Self, comptime name: Name) c.GLint {
            return self.locs[@intFromEnum(name)];
        }

        pub fn f1(self: *const Self, comptime name: Name, x: f32) void {
            const l = self.loc(name);
            if (l >= 0) c.glUniform1f(l, x);
        }
        pub fn f2(self: *const Self, comptime name: Name, x: f32, y: f32) void {
            const l = self.loc(name);
            if (l >= 0) c.glUniform2f(l, x, y);
        }
        pub fn f3(self: *const Self, comptime name: Name, x: f32, y: f32, z: f32) void {
            const l = self.loc(name);
            if (l >= 0) c.glUniform3f(l, x, y, z);
        }
        pub fn f4(self: *const Self, comptime name: Name, x: f32, y: f32, z: f32, w: f32) void {
            const l = self.loc(name);
            if (l >= 0) c.glUniform4f(l, x, y, z, w);
        }
        pub fn int(self: *const Self, comptime name: Name, x: i32) void {
            const l = self.loc(name);
            if (l >= 0) c.glUniform1i(l, x);
        }
        pub fn f1v(self: *const Self, comptime name: Name, count: c.GLsizei, v: anytype) void {
            const l = self.loc(name);
            if (l >= 0 and count > 0) c.glUniform1fv(l, count, @ptrCast(v));
        }
        pub fn f2v(self: *const Self, comptime name: Name, count: c.GLsizei, v: anytype) void {
            const l = self.loc(name);
            if (l >= 0 and count > 0) c.glUniform2fv(l, count, @ptrCast(v));
        }
        pub fn f3v(self: *const Self, comptime name: Name, count: c.GLsizei, v: anytype) void {
            const l = self.loc(name);
            if (l >= 0 and count > 0) c.glUniform3fv(l, count, @ptrCast(v));
        }
        pub fn f4v(self: *const Self, comptime name: Name, count: c.GLsizei, v: anytype) void {
            const l = self.loc(name);
            if (l >= 0 and count > 0) c.glUniform4fv(l, count, @ptrCast(v));
        }
        pub fn intv(self: *const Self, comptime name: Name, count: c.GLsizei, v: anytype) void {
            const l = self.loc(name);
            if (l >= 0 and count > 0) c.glUniform1iv(l, count, @ptrCast(v));
        }
    };
}
