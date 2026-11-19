//! swarm: a murmuration of starlings. The flock itself is flock.zig; this
//! is its music, its day (when it flies and when it roosts) and its
//! drawing. Every bird is one instanced quad whose fragment shader fills a
//! tiny silhouette, body and two wings, into a full-size layer that
//! shaders/swarm.frag lays over the background.

const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const palette_mod = @import("../../core/palette.zig");
const effects = @import("../../effects.zig");
const spectral = @import("../spectral.zig");
const geometry = @import("../geometry.zig");
const flock_mod = @import("flock.zig");

const Uniforms = @import("../uniforms.zig").Uniforms;

const c = @import("c");

const log = std.log.scoped(.swarm);

const max_windows = 32;

/// The flock steps at this rate whatever the display's. A frame draws the
/// birds on their way from the previous step to the last one, each carried
/// along its velocity by the vertex shader, so motion is smooth and the
/// CPU only touches the flock twenty times a second.
const step: f32 = 1.0 / 20.0;

const bird_vert: [*:0]const u8 =
    \\#version 300 es
    \\layout(location = 0) in vec2 aCorner;
    \\layout(location = 1) in vec4 aPosBody;  // center, half the body
    \\layout(location = 2) in vec4 aWing;     // wing axis, wing normal
    \\layout(location = 3) in vec4 aLook;     // alpha, far, flash, size
    \\layout(location = 4) in vec4 aMove;     // velocity px/s, wingbeat phase, rate
    \\uniform vec2 uRes;
    \\uniform float uLead;                   // seconds from the last step (<= 0)
    \\out vec2 vP;
    \\flat out vec2 vBody;
    \\flat out vec4 vWings;
    \\flat out vec4 vLook;
    \\void main() {
    \\    // The beat lifts both tips together; the wings sweep back along
    \\    // the body. Beaten here, the wings move at the display's rate
    \\    // however slowly the flock steps.
    \\    float beat = 0.1 + 0.5 * sin(aMove.z + aMove.w * uLead);
    \\    if (aMove.w == 0.0) beat = 0.0;
    \\    vec2 lift = aWing.zw * sin(beat);
    \\    vec2 reach = aWing.xy * cos(beat);
    \\    vec2 sweep = aPosBody.zw * 0.81 * (1.0 + 0.7 * aLook.z);
    \\    vWings = vec4(lift - reach - sweep, lift + reach - sweep);
    \\    if (aMove.w == 0.0) vWings = vec4(0.0);
    \\    float ext = length(aPosBody.zw) + max(length(vWings.xy), length(vWings.zw)) + 3.0 * aLook.w;
    \\    vP = aCorner * ext;
    \\    vBody = aPosBody.zw;
    \\    vLook = aLook;
    \\    vec2 at = aPosBody.xy + aMove.xy * uLead;
    \\    gl_Position = vec4((at + vP) / uRes * 2.0 - 1.0, 0.0, 1.0);
    \\}
;

// A bird is three tapered strokes: the body, nose to tail, and a wing from
// the shoulder out to each tip. Flat ink with one pixel of antialiasing.
const bird_frag: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\in vec2 vP;
    \\flat in vec2 vBody;
    \\flat in vec4 vWings;
    \\flat in vec4 vLook;
    \\uniform vec3 uInk;
    \\uniform vec3 uFar;
    \\out vec4 fragColor;
    \\
    \\// Distance to a stroke from a to b whose radius runs from r0 to r1.
    \\float stroke(vec2 p, vec2 a, vec2 b, float r0, float r1) {
    \\    vec2 pa = p - a;
    \\    vec2 ba = b - a;
    \\    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    \\    return length(pa - ba * h) - mix(r0, r1, h);
    \\}
    \\
    \\void main() {
    \\    float size = vLook.w;
    \\    float flash = vLook.z;
    \\    // A stubby body, fuller toward the head, and two pointed wings
    \\    // broad where they join it.
    \\    float d = stroke(vP, vBody, -vBody, 1.3 * size, 0.55 * size);
    \\    vec2 shoulder = vBody * 0.25;
    \\    float chord = (1.3 + 1.1 * flash) * size;
    \\    d = min(d, stroke(vP, shoulder, shoulder + vWings.xy, chord, 0.15 * size));
    \\    d = min(d, stroke(vP, shoulder, shoulder + vWings.zw, chord, 0.15 * size));
    \\    float a = vLook.x * clamp(0.5 - d, 0.0, 1.0);
    \\    // A flashing wing catches the light, however far off.
    \\    vec3 col = mix(uInk, uFar, vLook.y * 0.6 * (1.0 - flash));
    \\    col = mix(col, vec3(1.0), flash * 0.45);
    \\    fragColor = vec4(col * a, a);
    \\}
;

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer,
    flock: flock_mod.Flock,
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    /// Time owed to the flock since its last step.
    owed: f32 = 0,
    /// A kick heard since the last step.
    kick: bool = false,

    // The flock's day. With music it stays up. In quiet it flies for a
    // while, comes down to roost, and goes up again.
    roost_enabled: bool,
    roost: bool = false,
    phase_t: f32 = 0,
    phase_len: f32,

    // Ink for the nearest birds and for the farthest.
    ink: [3]f32 = .{ 0.9, 0.9, 0.9 },
    far: [3]f32 = .{ 0.4, 0.45, 0.6 },

    inst: []flock_mod.Instance,
    inst_n: usize = 0,
    /// The instances changed since they were last sent to the GPU.
    inst_dirty: bool = false,

    // GL, created on the first upload.
    gl_ready: bool = false,
    gl_failed: bool = false,
    prog: c.GLuint = 0,
    vao: c.GLuint = 0,
    quad_vbo: c.GLuint = 0,
    inst_vbo: c.GLuint = 0,
    tex: c.GLuint = 0,
    fbo: c.GLuint = 0,
    u_res: c.GLint = -1,
    u_ink: c.GLint = -1,
    u_far: c.GLint = -1,
    u_lead: c.GLint = -1,

    mu: Uniforms(.{ .flock = "iFlock" }) = .{},

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        var music = try spectral.Analyzer.init(allocator, params);
        errdefer music.deinit(allocator);

        const count: usize = @intCast(std.math.clamp(params.getInt("count", 4000), 1, flock_mod.max_birds));
        const speed = std.math.clamp(params.getFloat("speed", 300.0), 60.0, 900.0);
        var flock = try flock_mod.Flock.init(allocator, count, width, height, speed);
        errdefer flock.deinit();

        const inst = try allocator.alloc(flock_mod.Instance, count);

        return .{
            .allocator = allocator,
            .music = music,
            .flock = flock,
            .rng = std.Random.DefaultPrng.init(0xF10C_C0DE),
            .width = width,
            .height = height,
            .roost_enabled = params.getBool("roost", true),
            .phase_len = 45.0,
            .inst = inst,
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
        const r = self.rng.random();
        const kicked = self.music.update(dt);

        // ---- the day ----
        self.phase_t += dt;
        if (self.music.bands.energy_ema > 0.06 or kicked) {
            // Sound keeps the flock up, and puts it up if it was down.
            self.roost = false;
            self.phase_t = 0;
            self.phase_len = 8.0; // once it goes quiet, not long to settle
        } else if (self.roost_enabled and self.phase_t > self.phase_len) {
            self.roost = !self.roost;
            self.phase_t = 0;
            self.phase_len = if (self.roost) 30.0 + r.float(f32) * 15.0 else 50.0 + r.float(f32) * 35.0;
        }

        var rects: [max_windows]flock_mod.Rect = undefined;
        const n = @min(state.windows.len, max_windows);
        for (state.windows[0..n], rects[0..n]) |w, *rect| {
            rect.* = .{ .x = w.x, .y = w.y, .w = w.w, .h = w.h, .address = w.address };
        }
        self.kick = self.kick or kicked;
        self.owed = @min(self.owed + dt, step * 2.0);
        var stepped = false;
        while (self.owed >= step) : (self.owed -= step) {
            stepped = true;
            self.flock.update(.{
                .dt = step,
                .windows = rects[0..n],
                .cursor = state.cursor,
                .bass = self.music.bass(),
                .kick = if (self.kick) 1.0 else 0.0,
                .roost = self.roost,
            });
            self.kick = false;
            if (self.flock.alarm) {
                // Flushed by the falcon: a short, nervous flight before it
                // dares come down again.
                self.roost = false;
                self.phase_t = 0;
                self.phase_len = 16.0 + r.float(f32) * 10.0;
            }
        }

        if (state.palette) |p| {
            self.ink = .{ p.foreground.r, p.foreground.g, p.foreground.b };
            // Far birds fade toward the theme's bright blue, held down
            // toward the background: distance, not another color.
            const tint = if (p.color_count > 12) p.colors[12] else p.foreground;
            const bg = p.background;
            self.far = .{
                (tint.r * 0.6 + self.ink[0] * 0.4) * 0.6 + bg.r * 0.4,
                (tint.g * 0.6 + self.ink[1] * 0.4) * 0.6 + bg.g * 0.4,
                (tint.b * 0.6 + self.ink[2] * 0.4) * 0.6 + bg.b * 0.4,
            };
        }

        if (stepped) {
            self.inst_n = self.flock.instances(self.inst);
            self.inst_dirty = true;
        }
    }

    fn ensureGl(self: *Context) bool {
        if (self.gl_ready) return true;
        if (self.gl_failed) return false;
        self.gl_failed = true;

        self.prog = geometry.compileProgram(bird_vert, bird_frag);
        if (self.prog == 0) return false;
        self.u_res = c.glGetUniformLocation(self.prog, "uRes");
        self.u_ink = c.glGetUniformLocation(self.prog, "uInk");
        self.u_far = c.glGetUniformLocation(self.prog, "uFar");
        self.u_lead = c.glGetUniformLocation(self.prog, "uLead");

        const Instance = flock_mod.Instance;
        const corners = [_]f32{ -1, -1, 1, -1, -1, 1, 1, 1 };
        c.glGenVertexArrays(1, &self.vao);
        c.glBindVertexArray(self.vao);
        c.glGenBuffers(1, &self.quad_vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.quad_vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(corners)), &corners, c.GL_STATIC_DRAW);
        c.glEnableVertexAttribArray(0);
        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 0, null);

        c.glGenBuffers(1, &self.inst_vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.inst_vbo);
        c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(@sizeOf(Instance) * self.inst.len), null, c.GL_STREAM_DRAW);
        inline for (.{ 1, 2, 3, 4 }) |loc| {
            c.glEnableVertexAttribArray(loc);
            c.glVertexAttribPointer(loc, 4, c.GL_FLOAT, c.GL_FALSE, @sizeOf(Instance), @ptrFromInt((loc - 1) * 4 * @sizeOf(f32)));
            c.glVertexAttribDivisor(loc, 1);
        }
        c.glBindVertexArray(0);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);

        c.glGenTextures(1, &self.tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, @intFromFloat(self.width), @intFromFloat(self.height), 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
        c.glGenFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex, 0);
        const complete = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) == c.GL_FRAMEBUFFER_COMPLETE;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (!complete) {
            log.err("flock layer framebuffer incomplete", .{});
            return false;
        }
        self.gl_failed = false;
        self.gl_ready = true;
        return true;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        if (!self.ensureGl()) return;

        // ---- the flock, into its own layer ----
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glViewport(0, 0, @intFromFloat(self.width), @intFromFloat(self.height));
        c.glClearColor(0, 0, 0, 0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
        if (self.inst_n > 0) {
            c.glUseProgram(self.prog);
            c.glUniform2f(self.u_res, self.width, self.height);
            c.glUniform3f(self.u_ink, self.ink[0], self.ink[1], self.ink[2]);
            c.glUniform3f(self.u_far, self.far[0], self.far[1], self.far[2]);
            c.glBindVertexArray(self.vao);
            // The last step ended `owed` ago; draw the birds that far along
            // the step before it.
            c.glUniform1f(self.u_lead, self.owed - step);
            if (self.inst_dirty) {
                c.glBindBuffer(c.GL_ARRAY_BUFFER, self.inst_vbo);
                // A fresh store each time: writing into the one the GPU may
                // still be drawing from makes the driver wait for it.
                c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(@sizeOf(flock_mod.Instance) * self.inst.len), null, c.GL_STREAM_DRAW);
                c.glBufferSubData(c.GL_ARRAY_BUFFER, 0, @intCast(@sizeOf(flock_mod.Instance) * self.inst_n), self.inst.ptr);
                self.inst_dirty = false;
            }
            // Premultiplied over: where birds overlap the ink builds up,
            // which is what makes the thick of the flock read as mass.
            c.glEnable(c.GL_BLEND);
            c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
            c.glDrawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(self.inst_n));
            c.glDisable(c.GL_BLEND);
            c.glBindVertexArray(0);
            c.glBindBuffer(c.GL_ARRAY_BUFFER, 0);
        }
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

        // ---- hand the layer to the main pass ----
        self.mu.use(prog.program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        self.mu.int(.flock, 0);
    }

    pub fn deinit(self: *Context) void {
        if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
        if (self.inst_vbo != 0) c.glDeleteBuffers(1, &self.inst_vbo);
        if (self.quad_vbo != 0) c.glDeleteBuffers(1, &self.quad_vbo);
        if (self.vao != 0) c.glDeleteVertexArrays(1, &self.vao);
        if (self.prog != 0) c.glDeleteProgram(self.prog);
        self.music.deinit(self.allocator);
        self.flock.deinit();
        self.allocator.free(self.inst);
    }
};
