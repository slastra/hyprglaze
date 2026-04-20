const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const effects = @import("../../effects.zig");
const audio_mod = @import("../visualizer/audio.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

const vert_src: [*:0]const u8 =
    \\#version 300 es
    \\void main() {
    \\    vec2 p = vec2(gl_VertexID & 1, (gl_VertexID >> 1) & 1) * 2.0 - 1.0;
    \\    gl_Position = vec4(p, 0.0, 1.0);
    \\}
;

const warp_frag_src: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform sampler2D uPrev;
    \\uniform float uBass;
    \\uniform float uMid;
    \\uniform float uHigh;
    \\uniform float uBeat;
    \\uniform float uTime;
    \\uniform vec2 uRes;
    \\uniform int uKaleidoSegments;
    \\uniform vec3 uBg;
    \\out vec4 fragColor;
    \\
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy / uRes;
    \\    vec2 centered = uv - 0.5;
    \\
    \\    // Kaleidoscope: mirror into segments
    \\    float angle = atan(centered.y, centered.x);
    \\    float radius = length(centered);
    \\    float seg = 6.28318 / float(uKaleidoSegments);
    \\    angle = mod(angle, seg);
    \\    if (angle > seg * 0.5) angle = seg - angle;
    \\    vec2 kuv = vec2(cos(angle), sin(angle)) * radius + 0.5;
    \\
    \\    // Warp the kaleidoscoped UV
    \\    vec2 wuv = kuv;
    \\
    \\    // Zoom — pulses on beat
    \\    float zoom = 0.004 + uBass * 0.01 + uBeat * 0.02;
    \\    wuv = (wuv - 0.5) * (1.0 - zoom) + 0.5;
    \\
    \\    // Rotation — direction shifts on beat
    \\    float rot_speed = 0.003 + uMid * 0.005;
    \\    float rot = rot_speed * (1.0 + uBeat * 3.0);
    \\    float ca = cos(rot); float sa = sin(rot);
    \\    wuv = (wuv - 0.5) * mat2(ca, -sa, sa, ca) + 0.5;
    \\
    \\    // Per-pixel warp — more chaotic with energy
    \\    float warp = 0.002 + uHigh * 0.005;
    \\    wuv.x += sin(kuv.y * 8.0 + uTime * 0.4) * warp;
    \\    wuv.y += cos(kuv.x * 8.0 + uTime * 0.5) * warp;
    \\
    \\    // Radial warp — breathing
    \\    vec2 rd = wuv - 0.5;
    \\    float rdist = length(rd);
    \\    wuv += normalize(rd + 0.001) * sin(rdist * 12.0 - uTime * 1.5) * 0.003 * (1.0 + uBass * 2.0);
    \\
    \\    // Sample with decay toward background color
    \\    float decay = 0.955 - uBeat * 0.02;
    \\    vec3 prev = texture(uPrev, clamp(wuv, 0.0, 1.0)).rgb;
    \\    prev = mix(uBg, prev, decay);
    \\    fragColor = vec4(prev, 1.0);
    \\}
;

const reactive_frag_src: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec4 uWave[64];
    \\uniform float uBass;
    \\uniform float uMid;
    \\uniform float uHigh;
    \\uniform float uBeat;
    \\uniform float uTime;
    \\uniform vec2 uRes;
    \\uniform vec3 uPalette[16];
    \\uniform int uPaletteSize;
    \\uniform vec3 uBg;
    \\uniform vec3 uFg;
    \\out vec4 fragColor;
    \\
    \\float rawSample(int base, int i) {
    \\    int slot = base + i / 4;
    \\    int sub = i - (i / 4) * 4;
    \\    if (sub == 0) return uWave[slot].x;
    \\    if (sub == 1) return uWave[slot].y;
    \\    if (sub == 2) return uWave[slot].z;
    \\    return uWave[slot].w;
    \\}
    \\
    \\float getSample(int base, float x) {
    \\    float fi = x * 127.0;
    \\    int i1 = int(fi); float t = fract(fi);
    \\    float p0 = rawSample(base, max(i1-1,0));
    \\    float p1 = rawSample(base, i1);
    \\    float p2 = rawSample(base, min(i1+1,127));
    \\    float p3 = rawSample(base, min(i1+2,127));
    \\    float t2 = t*t; float t3 = t2*t;
    \\    return 0.5*((2.0*p1)+(-p0+p2)*t+(2.0*p0-5.0*p1+4.0*p2-p3)*t2+(-p0+3.0*p1-3.0*p2+p3)*t3);
    \\}
    \\
    \\vec3 palColor(int i) {
    \\    if (uPaletteSize > i) return uPalette[i];
    \\    return vec3(0.5);
    \\}
    \\
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy / uRes;
    \\    vec2 centered = uv - 0.5;
    \\    float dist = length(centered);
    \\    float angle = atan(centered.y, centered.x);
    \\    float norm_a = (angle + 3.14159) / 6.28318;
    \\    vec4 out_col = vec4(0.0);
    \\
    \\    // --- Waveform ring (main visual) ---
    \\    float ring_r = 0.12 + uBass * 0.06;
    \\    float left = getSample(0, norm_a);
    \\    float right = getSample(32, norm_a);
    \\    float wave = (left + right) * 0.5;
    \\    float wave_r = ring_r + wave * 0.1;
    \\    float ring_dist = abs(dist - wave_r);
    \\    float ring = 1.0 - smoothstep(0.0, 0.003, ring_dist);
    \\    float ring_glow = 1.0 - smoothstep(0.0, 0.025 + uBass * 0.02, ring_dist);
    \\
    \\    // Color cycles through palette based on angle
    \\    float color_phase = norm_a * 6.0;
    \\    int ci0 = 1 + int(mod(color_phase, 6.0));
    \\    int ci1 = 1 + int(mod(color_phase + 1.0, 6.0));
    \\    vec3 ring_col = mix(palColor(ci0), palColor(ci1), fract(color_phase));
    \\    out_col.rgb += ring_col * (ring + ring_glow * 0.4);
    \\    out_col.a = max(out_col.a, ring * 0.9 + ring_glow * 0.3);
    \\
    \\    // --- Inner ring (second waveform) ---
    \\    float inner_r = 0.06 + uMid * 0.03;
    \\    float inner_wave = (left - right) * 0.5;
    \\    float inner_dist = abs(dist - inner_r - inner_wave * 0.05);
    \\    float inner = 1.0 - smoothstep(0.0, 0.002, inner_dist);
    \\    float inner_glow = 1.0 - smoothstep(0.0, 0.015, inner_dist);
    \\    vec3 inner_col = mix(palColor(3), palColor(5), norm_a);
    \\    out_col.rgb += inner_col * (inner + inner_glow * 0.3);
    \\    out_col.a = max(out_col.a, inner * 0.7);
    \\
    \\    // --- Beat flash — starburst ---
    \\    if (uBeat > 0.3) {
    \\        float rays = abs(sin(angle * 8.0 + uTime * 2.0));
    \\        float burst = (1.0 - smoothstep(0.0, 0.3, dist)) * rays * uBeat;
    \\        vec3 burst_col = mix(palColor(1), palColor(2), rays);
    \\        out_col.rgb += burst_col * burst * 0.5;
    \\        out_col.a = max(out_col.a, burst * 0.4);
    \\    }
    \\
    \\    // --- Outer shimmer particles ---
    \\    float outer_r = 0.3 + uHigh * 0.1;
    \\    for (int i = 0; i < 12; i++) {
    \\        float a = float(i) * 0.5236 + uTime * (0.2 + uMid * 0.3);
    \\        float r = outer_r + sin(uTime * 0.7 + float(i)) * 0.03;
    \\        vec2 pos = vec2(cos(a), sin(a)) * r + 0.5;
    \\        float dd = length(uv - pos);
    \\        float dot = 1.0 - smoothstep(0.0, 0.006 + uBeat * 0.008, dd);
    \\        int dci = 1 + i % 6;
    \\        out_col.rgb += palColor(dci) * dot * 0.6;
    \\        out_col.a = max(out_col.a, dot * 0.4);
    \\    }
    \\
    \\    fragColor = out_col;
    \\}
;

pub const Context = struct {
    audio: *audio_mod.AudioCapture,
    allocator: std.mem.Allocator,

    fbo: c.GLuint = 0,
    tex: [2]c.GLuint = .{ 0, 0 },
    current: u8 = 0,
    width: i32 = 0,
    height: i32 = 0,

    warp_prog: c.GLuint = 0,
    reactive_prog: c.GLuint = 0,
    vao: c.GLuint = 0,

    // Smoothed energy bands
    bass: f32 = 0,
    mid: f32 = 0,
    high: f32 = 0,

    // Beat detection
    bass_avg: f32 = 0,
    beat: f32 = 0,
    beat_cooldown: f32 = 0,
    kaleido_segments: i32 = 6,
    beat_count: u32 = 0,

    // Palette cache (read from main shader)
    palette: [48]f32 = [_]f32{0.5} ** 48,
    palette_size: i32 = 0,
    palette_bg: [3]f32 = .{ 0.02, 0.02, 0.02 },
    palette_fg: [3]f32 = .{ 0.9, 0.9, 0.9 },

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) Context {
        const sink = params.getString("sink", null);
        const audio = allocator.create(audio_mod.AudioCapture) catch @panic("alloc failed");
        audio.* = audio_mod.AudioCapture.init(sink);
        audio.start();

        const w: i32 = @intFromFloat(width);
        const h: i32 = @intFromFloat(height);

        var textures: [2]c.GLuint = .{ 0, 0 };
        c.glGenTextures(2, &textures);
        for (0..2) |i| {
            c.glBindTexture(c.GL_TEXTURE_2D, textures[i]);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, w, h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        }

        var fbo: c.GLuint = 0;
        c.glGenFramebuffers(1, &fbo);
        var vao: c.GLuint = 0;
        c.glGenVertexArrays(1, &vao);

        const warp_prog = compileProgram(vert_src, warp_frag_src);
        const reactive_prog = compileProgram(vert_src, reactive_frag_src);
        if (warp_prog == 0 or reactive_prog == 0)
            std.debug.print("Milkdrop: internal shader compile failed\n", .{});

        return .{
            .audio = audio,
            .allocator = allocator,
            .fbo = fbo,
            .tex = textures,
            .width = w,
            .height = h,
            .warp_prog = warp_prog,
            .reactive_prog = reactive_prog,
            .vao = vao,
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
        const wave = self.audio.getWaveform();

        // Cache palette from FrameState
        if (state.palette) |pal| {
            self.palette_size = @intCast(pal.color_count);
            for (0..pal.color_count) |i| {
                self.palette[i * 3] = pal.colors[i].r;
                self.palette[i * 3 + 1] = pal.colors[i].g;
                self.palette[i * 3 + 2] = pal.colors[i].b;
            }
            self.palette_bg = .{ pal.background.r, pal.background.g, pal.background.b };
            self.palette_fg = .{ pal.foreground.r, pal.foreground.g, pal.foreground.b };
        }

        // Compute energy bands
        var bass_e: f32 = 0;
        var mid_e: f32 = 0;
        var high_e: f32 = 0;
        for (0..20) |i| bass_e += @abs(wave[i]) + @abs(wave[128 + i]);
        for (20..60) |i| mid_e += @abs(wave[i]) + @abs(wave[128 + i]);
        for (60..128) |i| high_e += @abs(wave[i]) + @abs(wave[128 + i]);
        bass_e /= 40.0;
        mid_e /= 80.0;
        high_e /= 136.0;

        // Smooth with fast attack, slow decay
        const attack = @min(1.0, 25.0 * dt);
        const decay = @min(1.0, 5.0 * dt);
        self.bass += (bass_e - self.bass) * (if (bass_e > self.bass) attack else decay);
        self.mid += (mid_e - self.mid) * (if (mid_e > self.mid) attack else decay);
        self.high += (high_e - self.high) * (if (high_e > self.high) attack else decay);

        // Beat detection: onset when bass exceeds running average by threshold
        self.bass_avg += (bass_e - self.bass_avg) * 0.5 * dt;
        self.beat_cooldown -= dt;
        if (bass_e > self.bass_avg * 1.8 + 0.02 and self.beat_cooldown <= 0) {
            self.beat = 1.0;
            self.beat_cooldown = 0.15;
            self.beat_count += 1;
            // Change kaleidoscope every 4 beats
            if (self.beat_count % 4 == 0) {
                const segments = [_]i32{ 3, 4, 6, 8, 10, 12 };
                self.kaleido_segments = segments[self.beat_count / 4 % segments.len];
            }
        }
        self.beat *= @max(0.0, 1.0 - 8.0 * dt);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        const wave = self.audio.getWaveform();
        const time: f32 = @floatCast(@as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0);
        const prev = 1 - self.current;
        const curr = self.current;

        // --- Pass 1: Warp ---
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex[curr], 0);
        c.glViewport(0, 0, self.width, self.height);

        c.glUseProgram(self.warp_prog);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[prev]);
        setU1i(self.warp_prog, "uPrev", 0);
        setU1f(self.warp_prog, "uBass", self.bass * 4.0);
        setU1f(self.warp_prog, "uMid", self.mid * 4.0);
        setU1f(self.warp_prog, "uHigh", self.high * 4.0);
        setU1f(self.warp_prog, "uBeat", self.beat);
        setU1f(self.warp_prog, "uTime", time);
        setU2f(self.warp_prog, "uRes", @floatFromInt(self.width), @floatFromInt(self.height));
        setU1i(self.warp_prog, "uKaleidoSegments", self.kaleido_segments);
        const warp_bg_loc = c.glGetUniformLocation(self.warp_prog, "uBg");
        if (warp_bg_loc >= 0) c.glUniform3fv(warp_bg_loc, 1, &self.palette_bg);

        c.glBindVertexArray(self.vao);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);

        // --- Pass 2: Reactive elements (additive) ---
        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE);

        c.glUseProgram(self.reactive_prog);
        const wave_loc = c.glGetUniformLocation(self.reactive_prog, "uWave");
        if (wave_loc >= 0) c.glUniform4fv(wave_loc, 64, @ptrCast(&wave));
        setU1f(self.reactive_prog, "uBass", self.bass * 4.0);
        setU1f(self.reactive_prog, "uMid", self.mid * 4.0);
        setU1f(self.reactive_prog, "uHigh", self.high * 4.0);
        setU1f(self.reactive_prog, "uBeat", self.beat);
        setU1f(self.reactive_prog, "uTime", time);
        setU2f(self.reactive_prog, "uRes", @floatFromInt(self.width), @floatFromInt(self.height));

        // Upload palette
        const pal_loc = c.glGetUniformLocation(self.reactive_prog, "uPalette");
        if (pal_loc >= 0) c.glUniform3fv(pal_loc, 16, &self.palette);
        setU1i(self.reactive_prog, "uPaletteSize", self.palette_size);
        const bg_loc = c.glGetUniformLocation(self.reactive_prog, "uBg");
        if (bg_loc >= 0) c.glUniform3fv(bg_loc, 1, &self.palette_bg);
        const fg_loc = c.glGetUniformLocation(self.reactive_prog, "uFg");
        if (fg_loc >= 0) c.glUniform3fv(fg_loc, 1, &self.palette_fg);

        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
        c.glDisable(c.GL_BLEND);

        // --- Unbind, swap ---
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        c.glViewport(0, 0, self.width, self.height);
        self.current = 1 - self.current;

        // --- Blit result via main shader ---
        c.glUseProgram(prog.program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[curr]);
        const sprite_loc = c.glGetUniformLocation(prog.program, "iSprite");
        if (sprite_loc >= 0) c.glUniform1i(sprite_loc, 0);
    }

    pub fn deinit(self: *Context) void {
        self.audio.stop();
        self.allocator.destroy(self.audio);
        c.glDeleteFramebuffers(1, &self.fbo);
        c.glDeleteTextures(2, &self.tex);
        c.glDeleteVertexArrays(1, &self.vao);
        if (self.warp_prog != 0) c.glDeleteProgram(self.warp_prog);
        if (self.reactive_prog != 0) c.glDeleteProgram(self.reactive_prog);
    }
};

fn setU1i(prog: c.GLuint, name: [*:0]const u8, val: c.GLint) void {
    const loc = c.glGetUniformLocation(prog, name);
    if (loc >= 0) c.glUniform1i(loc, val);
}
fn setU1f(prog: c.GLuint, name: [*:0]const u8, val: f32) void {
    const loc = c.glGetUniformLocation(prog, name);
    if (loc >= 0) c.glUniform1f(loc, val);
}
fn setU2f(prog: c.GLuint, name: [*:0]const u8, x: f32, y: f32) void {
    const loc = c.glGetUniformLocation(prog, name);
    if (loc >= 0) c.glUniform2f(loc, x, y);
}

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
        std.debug.print("Milkdrop shader error:\n{s}\n", .{buf[0..@intCast(len)]});
        c.glDeleteShader(shader);
        return 0;
    }
    return shader;
}

fn compileProgram(vert: [*:0]const u8, frag: [*:0]const u8) c.GLuint {
    const vs = compileShader(vert, c.GL_VERTEX_SHADER);
    if (vs == 0) return 0;
    const fs = compileShader(frag, c.GL_FRAGMENT_SHADER);
    if (fs == 0) { c.glDeleteShader(vs); return 0; }
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
        std.debug.print("Milkdrop link error:\n{s}\n", .{buf[0..@intCast(len)]});
        c.glDeleteProgram(prog);
        return 0;
    }
    return prog;
}
