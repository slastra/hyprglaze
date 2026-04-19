const std = @import("std");
const c = @cImport({
    @cInclude("GLES3/gl3.h");
});
const palette_mod = @import("palette.zig");
const hypr = @import("hypr.zig");
const particles_mod = @import("../effects/particles.zig");

pub const max_windows = hypr.max_visible_windows;
pub const max_particles = particles_mod.max_particles;

const vertex_shader_source: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\void main() {
    \\    // Fullscreen triangle via gl_VertexID trick
    \\    // 3 vertices cover the entire clip space [-1,1]
    \\    vec2 pos = vec2(
    \\        float((gl_VertexID & 1) * 4 - 1),
    \\        float((gl_VertexID & 2) * 2 - 1)
    \\    );
    \\    gl_Position = vec4(pos, 0.0, 1.0);
    \\}
;

pub const ShaderProgram = struct {
    program: c.GLuint,
    vao: c.GLuint,

    // Uniform locations
    i_resolution: c.GLint,
    i_time: c.GLint,
    i_mouse: c.GLint,
    i_window: c.GLint,
    i_windows: [max_windows]c.GLint,
    i_window_count: c.GLint,
    i_transition: c.GLint,
    i_particles: [max_particles]c.GLint,
    i_particle_count: c.GLint,
    i_palette: [palette_mod.max_palette_colors]c.GLint,
    i_palette_size: c.GLint,
    i_palette_bg: c.GLint,
    i_palette_fg: c.GLint,

    pub fn init(frag_source: [:0]const u8) !ShaderProgram {
        // Compile vertex shader
        const vert = c.glCreateShader(c.GL_VERTEX_SHADER);
        if (vert == 0) return error.CreateVertexShaderFailed;
        defer c.glDeleteShader(vert);

        const vert_src: [*c]const [*c]const u8 = @ptrCast(&vertex_shader_source);
        c.glShaderSource(vert, 1, vert_src, null);
        c.glCompileShader(vert);
        try checkShaderCompile(vert, "vertex");

        // Compile fragment shader
        const frag = c.glCreateShader(c.GL_FRAGMENT_SHADER);
        if (frag == 0) return error.CreateFragmentShaderFailed;
        defer c.glDeleteShader(frag);

        const frag_src_ptr: [*:0]const u8 = frag_source.ptr;
        const frag_src: [*c]const [*c]const u8 = @ptrCast(&frag_src_ptr);
        c.glShaderSource(frag, 1, frag_src, null);
        c.glCompileShader(frag);
        try checkShaderCompile(frag, "fragment");

        // Link program
        const program = c.glCreateProgram();
        if (program == 0) return error.CreateProgramFailed;

        c.glAttachShader(program, vert);
        c.glAttachShader(program, frag);
        c.glLinkProgram(program);
        try checkProgramLink(program);

        // Create empty VAO (required for GLES 3.0 even with no vertex attribs)
        var vao: c.GLuint = 0;
        c.glGenVertexArrays(1, &vao);

        // Look up palette uniform locations
        var palette_locs: [palette_mod.max_palette_colors]c.GLint = undefined;
        var name_buf: [32]u8 = undefined;
        for (0..palette_mod.max_palette_colors) |i| {
            const name = std.fmt.bufPrintZ(&name_buf, "iPalette[{d}]", .{i}) catch unreachable;
            palette_locs[i] = c.glGetUniformLocation(program, name.ptr);
        }

        return .{
            .program = program,
            .vao = vao,
            .i_resolution = c.glGetUniformLocation(program, "iResolution"),
            .i_time = c.glGetUniformLocation(program, "iTime"),
            .i_mouse = c.glGetUniformLocation(program, "iMouse"),
            .i_window = c.glGetUniformLocation(program, "iWindow"),
            .i_windows = blk: {
                var locs: [max_windows]c.GLint = undefined;
                var win_name_buf: [32]u8 = undefined;
                for (0..max_windows) |i| {
                    const n = std.fmt.bufPrintZ(&win_name_buf, "iWindows[{d}]", .{i}) catch unreachable;
                    locs[i] = c.glGetUniformLocation(program, n.ptr);
                }
                break :blk locs;
            },
            .i_window_count = c.glGetUniformLocation(program, "iWindowCount"),
            .i_transition = c.glGetUniformLocation(program, "iTransition"),
            .i_particles = blk2: {
                var locs2: [max_particles]c.GLint = undefined;
                var p_name_buf: [32]u8 = undefined;
                for (0..max_particles) |i| {
                    const n2 = std.fmt.bufPrintZ(&p_name_buf, "iParticles[{d}]", .{i}) catch unreachable;
                    locs2[i] = c.glGetUniformLocation(program, n2.ptr);
                }
                break :blk2 locs2;
            },
            .i_particle_count = c.glGetUniformLocation(program, "iParticleCount"),
            .i_palette = palette_locs,
            .i_palette_size = c.glGetUniformLocation(program, "iPaletteSize"),
            .i_palette_bg = c.glGetUniformLocation(program, "iPaletteBg"),
            .i_palette_fg = c.glGetUniformLocation(program, "iPaletteFg"),
        };
    }

    pub fn setParticles(self: *const ShaderProgram, psys: *const particles_mod.ParticleSystem) void {
        c.glUseProgram(self.program);

        for (0..psys.count) |i| {
            if (self.i_particles[i] >= 0) {
                const p = psys.particles[i];
                c.glUniform4f(self.i_particles[i], p.x, p.y, p.size, p.color_idx);
            }
        }
        if (self.i_particle_count >= 0)
            c.glUniform1i(self.i_particle_count, @intCast(psys.count));
    }

    pub fn setPalette(self: *const ShaderProgram, pal: *const palette_mod.Palette) void {
        c.glUseProgram(self.program);

        for (0..pal.color_count) |i| {
            if (self.i_palette[i] >= 0) {
                c.glUniform3f(self.i_palette[i], pal.colors[i].r, pal.colors[i].g, pal.colors[i].b);
            }
        }
        if (self.i_palette_size >= 0)
            c.glUniform1i(self.i_palette_size, @intCast(pal.color_count));
        if (self.i_palette_bg >= 0)
            c.glUniform3f(self.i_palette_bg, pal.background.r, pal.background.g, pal.background.b);
        if (self.i_palette_fg >= 0)
            c.glUniform3f(self.i_palette_fg, pal.foreground.r, pal.foreground.g, pal.foreground.b);
    }

    pub const WindowRect = struct { x: f32, y: f32, w: f32, h: f32 };

    pub const FrameUniforms = struct {
        width: f32,
        height: f32,
        time: f32,
        mouse_x: f32,
        mouse_y: f32,
        win_x: f32 = 0,
        win_y: f32 = 0,
        win_w: f32 = 0,
        win_h: f32 = 0,
        transition: f32 = 1.0,
        windows: [max_windows]WindowRect = undefined,
        window_count: u8 = 0,
    };

    pub fn draw(self: *const ShaderProgram, u: FrameUniforms) void {
        c.glViewport(0, 0, @intFromFloat(u.width), @intFromFloat(u.height));
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        c.glUseProgram(self.program);
        c.glBindVertexArray(self.vao);

        if (self.i_resolution >= 0)
            c.glUniform3f(self.i_resolution, u.width, u.height, 1.0);
        if (self.i_time >= 0)
            c.glUniform1f(self.i_time, u.time);
        if (self.i_mouse >= 0)
            c.glUniform4f(self.i_mouse, u.mouse_x, u.mouse_y, 0.0, 0.0);
        if (self.i_window >= 0)
            c.glUniform4f(self.i_window, u.win_x, u.win_y, u.win_w, u.win_h);
        if (self.i_transition >= 0)
            c.glUniform1f(self.i_transition, u.transition);

        // Upload all visible windows
        for (0..u.window_count) |i| {
            if (self.i_windows[i] >= 0) {
                c.glUniform4f(self.i_windows[i], u.windows[i].x, u.windows[i].y, u.windows[i].w, u.windows[i].h);
            }
        }
        if (self.i_window_count >= 0)
            c.glUniform1i(self.i_window_count, @intCast(u.window_count));

        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
    }

    pub fn deinit(self: *ShaderProgram) void {
        c.glDeleteVertexArrays(1, &self.vao);
        c.glDeleteProgram(self.program);
    }
};

fn checkShaderCompile(shader: c.GLuint, label: []const u8) !void {
    var success: c.GLint = 0;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &success);
    if (success == 0) {
        var log_buf: [2048]u8 = undefined;
        var log_len: c.GLsizei = 0;
        c.glGetShaderInfoLog(shader, 2048, &log_len, &log_buf);
        const log: []const u8 = log_buf[0..@intCast(log_len)];
        std.debug.print("{s} shader compile error:\n{s}\n", .{ label, log });
        return error.ShaderCompileFailed;
    }
}

fn checkProgramLink(program: c.GLuint) !void {
    var success: c.GLint = 0;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &success);
    if (success == 0) {
        var log_buf: [2048]u8 = undefined;
        var log_len: c.GLsizei = 0;
        c.glGetProgramInfoLog(program, 2048, &log_len, &log_buf);
        const log: []const u8 = log_buf[0..@intCast(log_len)];
        std.debug.print("program link error:\n{s}\n", .{log});
        return error.ProgramLinkFailed;
    }
}
