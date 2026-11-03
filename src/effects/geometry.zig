//! Soft-edged 2D geometry an effect draws into its own framebuffer: lines
//! that fade from a bright spine to nothing at their edges, round dots,
//! filled polygons, frames. Built on the CPU each frame into a Batch (uv
//! coordinates, y up) and drawn by a Painter with additive or alpha blending.
//! Grown in milkdrop; starfield shares it.

const std = @import("std");

const log = std.log.scoped(.geometry);

const c = @import("c");

const prim_vert_src: [*:0]const u8 =
    \\#version 300 es
    \\layout(location = 0) in vec2 aPos;
    \\layout(location = 1) in vec4 aCol;
    \\out vec4 vCol;
    \\void main() {
    \\    vCol = aCol;
    \\    gl_Position = vec4(aPos * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

const prim_frag_src: [*:0]const u8 =
    \\#version 300 es
    \\precision mediump float;
    \\in vec4 vCol;
    \\out vec4 fragColor;
    \\void main() {
    \\    fragColor = vec4(vCol.rgb * vCol.a, vCol.a);
    \\}
;

const dot_sides = 8;
/// The dot's rim, closed (the last point repeats the first).
const unit_circle: [dot_sides + 1][2]f32 = blk: {
    var pts: [dot_sides + 1][2]f32 = undefined;
    for (0..dot_sides + 1) |i| {
        const a = @as(f32, @floatFromInt(i)) / dot_sides * std.math.tau;
        pts[i] = .{ @cos(a), @sin(a) };
    }
    break :blk pts;
};

pub const Vertex = extern struct { x: f32, y: f32, r: f32, g: f32, b: f32, a: f32 };

/// Vertices per batch: waves at 256 points, a few shapes, borders, frames.
pub const max_verts = 32768;

/// Geometry for one frame, in uv (0..1, y up) with soft-edged lines.
pub const Batch = struct {
    verts: []Vertex,
    len: usize = 0,
    /// Loop size in pixels, to keep line widths even on both axes.
    px: [2]f32,

    fn push(self: *Batch, x: f32, y: f32, col: [4]f32) void {
        if (self.len >= self.verts.len) return;
        self.verts[self.len] = .{ .x = x, .y = y, .r = col[0], .g = col[1], .b = col[2], .a = col[3] };
        self.len += 1;
    }

    fn tri(self: *Batch, a: [2]f32, ca: [4]f32, b: [2]f32, cb: [4]f32, d: [2]f32, cd: [4]f32) void {
        if (self.len + 3 > self.verts.len) return;
        self.push(a[0], a[1], ca);
        self.push(b[0], b[1], cb);
        self.push(d[0], d[1], cd);
    }

    /// A line `width` px across, full colour on its spine fading to
    /// nothing at its edges.
    pub fn line(self: *Batch, p0: [2]f32, p1: [2]f32, width: f32, col: [4]f32) void {
        const dx = (p1[0] - p0[0]) * self.px[0];
        const dy = (p1[1] - p0[1]) * self.px[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 1e-3) return;
        const nx = -dy / len * width * 0.5 / self.px[0];
        const ny = dx / len * width * 0.5 / self.px[1];
        var clear = col;
        clear[3] = 0;
        inline for (.{ 1.0, -1.0 }) |s| {
            const e0 = [2]f32{ p0[0] + nx * s, p0[1] + ny * s };
            const e1 = [2]f32{ p1[0] + nx * s, p1[1] + ny * s };
            self.tri(p0, col, p1, col, e1, clear);
            self.tri(p0, col, e1, clear, e0, clear);
        }
    }

    pub fn polyline(self: *Batch, pts: []const [2]f32, closed: bool, width: f32, col: [4]f32) void {
        if (pts.len < 2) return;
        for (0..pts.len - 1) |i| self.line(pts[i], pts[i + 1], width, col);
        if (closed) self.line(pts[pts.len - 1], pts[0], width, col);
    }

    /// A soft round dot `size` px across.
    pub fn dot(self: *Batch, p: [2]f32, size: f32, col: [4]f32) void {
        var clear = col;
        clear[3] = 0;
        const r = [2]f32{ size * 0.5 / self.px[0], size * 0.5 / self.px[1] };
        for (0..dot_sides) |i| {
            const a = unit_circle[i];
            const b = unit_circle[i + 1];
            self.tri(p, col, .{ p[0] + a[0] * r[0], p[1] + a[1] * r[1] }, clear, .{ p[0] + b[0] * r[0], p[1] + b[1] * r[1] }, clear);
        }
    }

    /// A filled polygon: `inner` at the centre, `outer` at the rim.
    /// `rad` is in screen heights, so the shape stays regular.
    pub fn polygon(self: *Batch, center: [2]f32, rad: f32, sides: u32, ang: f32, inner: [4]f32, outer: [4]f32) void {
        const aspect = self.px[0] / self.px[1];
        for (0..sides) |i| {
            const a0 = ang + @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(sides)) * std.math.tau;
            const a1 = ang + @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(sides)) * std.math.tau;
            self.tri(
                center,
                inner,
                .{ center[0] + @cos(a0) * rad / aspect, center[1] + @sin(a0) * rad },
                outer,
                .{ center[0] + @cos(a1) * rad / aspect, center[1] + @sin(a1) * rad },
                outer,
            );
        }
    }

    /// A polygon's outline.
    pub fn ring(self: *Batch, center: [2]f32, rad: f32, sides: u32, ang: f32, width: f32, col: [4]f32) void {
        const aspect = self.px[0] / self.px[1];
        var pts: [64][2]f32 = undefined;
        const n = @min(sides, 64);
        for (0..n) |i| {
            const a = ang + @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n)) * std.math.tau;
            pts[i] = .{ center[0] + @cos(a) * rad / aspect, center[1] + @sin(a) * rad };
        }
        self.polyline(pts[0..n], true, width, col);
    }

    /// A solid frame `size` (screen heights) thick, inset by `inset`.
    pub fn border(self: *Batch, inset: f32, size: f32, col: [4]f32) void {
        if (size <= 0 or col[3] <= 0) return;
        const aspect = self.px[0] / self.px[1];
        const ix = inset / aspect;
        const sx = size / aspect;
        const quads = [_][4]f32{
            .{ ix, inset, 1 - ix, inset + size },
            .{ ix, 1 - inset - size, 1 - ix, 1 - inset },
            .{ ix, inset + size, ix + sx, 1 - inset - size },
            .{ 1 - ix - sx, inset + size, 1 - ix, 1 - inset - size },
        };
        for (quads) |q| {
            self.tri(.{ q[0], q[1] }, col, .{ q[2], q[1] }, col, .{ q[2], q[3] }, col);
            self.tri(.{ q[0], q[1] }, col, .{ q[2], q[3] }, col, .{ q[0], q[3] }, col);
        }
    }
};

/// The program, vertex array and stream buffer that draw Batches. Create
/// it with GL current (an effect's first upload).
pub const Painter = struct {
    prog: c.GLuint = 0,
    vao: c.GLuint = 0,
    vbo: c.GLuint = 0,
    capacity: usize = 0,

    pub fn init(capacity: usize) !Painter {
        const prog = compileProgram(prim_vert_src, prim_frag_src);
        if (prog == 0) return error.ShaderFailed;
        var self = Painter{ .prog = prog, .capacity = capacity };
        c.glGenVertexArrays(1, &self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(@sizeOf(Vertex) * capacity), null, c.GL_STREAM_DRAW);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(0));
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(1, 4, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Vertex), @ptrFromInt(2 * @sizeOf(f32)));
        c.glBindVertexArray(0);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
        return self;
    }

    pub const Blend = enum { alpha, additive };

    /// Draw `batch` into the bound framebuffer, leaving GL_BLEND off.
    pub fn draw(self: *const Painter, batch: *const Batch, blend: Blend) void {
        const n = @min(batch.len, self.capacity);
        if (n == 0) return;
        c.glUseProgram(self.prog);
        c.glBindVertexArray(self.vao);
        c.glEnable(c.GL_BLEND);
        switch (blend) {
            .alpha => c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA),
            .additive => c.glBlendFunc(c.GL_ONE, c.GL_ONE),
        }
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferSubData(c.GL_ARRAY_BUFFER, 0, @intCast(@sizeOf(Vertex) * n), batch.verts.ptr);
        c.glDrawArrays(c.GL_TRIANGLES, 0, @intCast(n));
        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    }

    pub fn deinit(self: *Painter) void {
        if (self.vbo != 0) c.glDeleteBuffers(1, &self.vbo);
        if (self.vao != 0) c.glDeleteVertexArrays(1, &self.vao);
        if (self.prog != 0) c.glDeleteProgram(self.prog);
        self.* = .{};
    }
};

/// Round soft dots as point sprites: one vertex each, the falloff drawn
/// per fragment. Far cheaper than Batch.dot when there are thousands.
pub const Point = extern struct { x: f32, y: f32, size: f32, r: f32, g: f32, b: f32, a: f32 };

pub const Points = struct {
    verts: []Point,
    len: usize = 0,

    /// A soft round dot `size` px across at uv `p`, full colour at its
    /// centre fading to nothing at its rim (as Batch.dot).
    pub fn dot(self: *Points, p: [2]f32, size: f32, col: [4]f32) void {
        if (self.len >= self.verts.len) return;
        self.verts[self.len] = .{ .x = p[0], .y = p[1], .size = size, .r = col[0], .g = col[1], .b = col[2], .a = col[3] };
        self.len += 1;
    }
};

const point_vert_src: [*:0]const u8 =
    \\#version 300 es
    \\layout(location = 0) in vec2 aPos;
    \\layout(location = 1) in float aSize;
    \\layout(location = 2) in vec4 aCol;
    \\out vec4 vCol;
    \\void main() {
    \\    vCol = aCol;
    \\    gl_PointSize = aSize;
    \\    gl_Position = vec4(aPos * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

const point_frag_src: [*:0]const u8 =
    \\#version 300 es
    \\precision mediump float;
    \\in vec4 vCol;
    \\out vec4 fragColor;
    \\void main() {
    \\    float a = vCol.a * max(1.0 - length(gl_PointCoord * 2.0 - 1.0), 0.0);
    \\    fragColor = vec4(vCol.rgb * a, a);
    \\}
;

pub const PointPainter = struct {
    prog: c.GLuint = 0,
    vao: c.GLuint = 0,
    vbo: c.GLuint = 0,
    capacity: usize = 0,

    pub fn init(capacity: usize) !PointPainter {
        const prog = compileProgram(point_vert_src, point_frag_src);
        if (prog == 0) return error.ShaderFailed;
        var self = PointPainter{ .prog = prog, .capacity = capacity };
        c.glGenVertexArrays(1, &self.vao);
        c.glGenBuffers(1, &self.vbo);
        c.glBindVertexArray(self.vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(@sizeOf(Point) * capacity), null, c.GL_STREAM_DRAW);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Point), @ptrFromInt(0));
        c.glEnableVertexAttribArray(1);
        c.glVertexAttribPointer(1, 1, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Point), @ptrFromInt(2 * @sizeOf(f32)));
        c.glEnableVertexAttribArray(2);
        c.glVertexAttribPointer(2, 4, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Point), @ptrFromInt(3 * @sizeOf(f32)));
        c.glBindVertexArray(0);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
        return self;
    }

    /// Draw `points` additively into the bound framebuffer.
    pub fn draw(self: *const PointPainter, points: *const Points) void {
        const n = @min(points.len, self.capacity);
        if (n == 0) return;
        c.glUseProgram(self.prog);
        c.glBindVertexArray(self.vao);
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbo);
        c.glBufferSubData(c.GL_ARRAY_BUFFER, 0, @intCast(@sizeOf(Point) * n), points.verts.ptr);
        c.glDrawArrays(c.GL_POINTS, 0, @intCast(n));
        c.glDisable(c.GL_BLEND);
        c.glBindVertexArray(0);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
    }

    pub fn deinit(self: *PointPainter) void {
        if (self.vbo != 0) c.glDeleteBuffers(1, &self.vbo);
        if (self.vao != 0) c.glDeleteVertexArrays(1, &self.vao);
        if (self.prog != 0) c.glDeleteProgram(self.prog);
        self.* = .{};
    }
};

fn compileShader(src: [*:0]const u8, shader_type: c.GLenum) c.GLuint {
    const shader = c.glCreateShader(shader_type);
    c.glShaderSource(shader, 1, &src, null);
    c.glCompileShader(shader);
    var ok: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var buf: [2048]u8 = undefined;
        var len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, 2048, &len, &buf);
        log.err("shader error:\n{s}", .{buf[0..@intCast(len)]});
        c.glDeleteShader(shader);
        return 0;
    }
    return shader;
}

pub fn compileProgram(vert: [*:0]const u8, frag: [*:0]const u8) c.GLuint {
    const vs = compileShader(vert, c.GL_VERTEX_SHADER);
    if (vs == 0) return 0;
    const fs = compileShader(frag, c.GL_FRAGMENT_SHADER);
    if (fs == 0) {
        c.glDeleteShader(vs);
        return 0;
    }
    const prog = c.glCreateProgram();
    c.glAttachShader(prog, vs);
    c.glAttachShader(prog, fs);
    c.glLinkProgram(prog);
    c.glDeleteShader(vs);
    c.glDeleteShader(fs);
    var ok: c.GLint = 0;
    c.glGetProgramiv(prog, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var buf: [2048]u8 = undefined;
        var len: c.GLsizei = 0;
        c.glGetProgramInfoLog(prog, 2048, &len, &buf);
        log.err("link error:\n{s}", .{buf[0..@intCast(len)]});
        c.glDeleteProgram(prog);
        return 0;
    }
    return prog;
}
