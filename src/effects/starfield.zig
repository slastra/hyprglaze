const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");
const geometry = @import("geometry.zig");
const iohelp = @import("../core/io_helper.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

// Flight through a 3D starfield. Stars live in a box ahead of the camera
// and stream toward it; each is projected through the vanishing point and
// drawn into an offscreen layer as soft geometry, a glow, a core and,
// moving fast, a streak back along its path, the brightest near ones with
// diffraction spikes. The vanishing point eases toward the cursor, so the
// cursor steers the ship, and the camera banks into the turn. The main
// shader (shaders/starfield.frag) lays the star layer over a nebula that
// zooms past forever and a fixed field of distant stars.
//
// Music pushes the cruise speed and every kick surges it; now and then,
// music or not, the ship jumps to hyperspace for a few seconds.

const vert_src: [*:0]const u8 =
    \\#version 300 es
    \\void main() {
    \\    vec2 p = vec2(gl_VertexID & 1, (gl_VertexID >> 1) & 1) * 2.0 - 1.0;
    \\    gl_Position = vec4(p, 0.0, 1.0);
    \\}
;

// The nebula is soft, so it renders at a quarter of the screen's size
// (sixteenth of the pixels) and the main shader scales it up.
const nebula_frag_src: [*:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec2 uRes;
    \\uniform vec2 uVp;
    \\uniform float uRoll;
    \\uniform float uFlight;
    \\uniform vec3 uTint[3];
    \\out vec4 fragColor;
    \\
    \\float hash12(vec2 p) {
    \\    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    \\    p3 += dot(p3, p3.yzx + 33.33);
    \\    return fract((p3.x + p3.y) * p3.z);
    \\}
    \\float noise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x),
    \\               mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
    \\}
    \\float fbm(vec2 p) {
    \\    float v = 0.0;
    \\    float a = 0.5;
    \\    for (int i = 0; i < 5; i++) {
    \\        v += a * noise(p);
    \\        p = mat2(1.6, 1.2, -1.2, 1.6) * p;
    \\        a *= 0.5;
    \\    }
    \\    return v;
    \\}
    \\// One octave of zoom: domain-warped clouds with darker dust lanes.
    \\vec3 cloud(vec2 q) {
    \\    vec2 w = vec2(fbm(q * 1.7 + 3.1), fbm(q * 1.7 - 5.7));
    \\    float d = fbm(q * 2.2 + w * 1.4);
    \\    float lane = fbm(q * 4.0 - w);
    \\    d = smoothstep(0.42, 0.85, d) * (0.55 + 0.45 * smoothstep(0.3, 0.7, lane));
    \\    vec3 tint = mix(mix(uTint[0], uTint[1], smoothstep(0.3, 0.7, w.x)), uTint[2], smoothstep(0.55, 0.8, w.y) * 0.5);
    \\    return tint * d;
    \\}
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy / uRes;
    \\    vec2 p = (uv - uVp) * vec2(uRes.x / uRes.y, 1.0);
    \\    float cr = cos(-uRoll);
    \\    float sr = sin(-uRoll);
    \\    p = mat2(cr, sr, -sr, cr) * p;
    \\    // Two octaves cross-fading on a log-periodic cycle: it comes at us
    \\    // without end. 0.04 * 1000 is whole, so the flight wrap is seamless.
    \\    float s = fract(uFlight * 0.04);
    \\    vec3 neb = cloud(p * exp2(-s) * 1.3) * (1.0 - s) + cloud(p * exp2(1.0 - s) * 1.3) * s;
    \\    fragColor = vec4(neb, 1.0);
    \\}
;

const Star = struct {
    x: f32,
    y: f32,
    z: f32,
    /// Intrinsic brightness, 0..1, skewed dim: most stars are faint.
    mag: f32,
    /// 0 = the theme's foreground, else a chromatic slot.
    tint: u8,
    phase: f32,
};

const max_stars = 4000;
const near: f32 = 0.03;
const far: f32 = 1.0;
/// Projection scale, screen heights per unit at z = 1.
const focal: f32 = 0.45;
/// Half-extent of the star box across, in world units at any depth.
const spread: f32 = 1.6;

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    count: usize,
    stars: []Star,

    verts: []geometry.Vertex,
    batch: geometry.Batch,
    point_verts: []geometry.Point,
    points: geometry.Points,

    painter: geometry.Painter = .{},
    point_painter: geometry.PointPainter = .{},
    fbo: c.GLuint = 0,
    tex: c.GLuint = 0,
    neb_fbo: c.GLuint = 0,
    neb_tex: c.GLuint = 0,
    neb_prog: c.GLuint = 0,
    vao: c.GLuint = 0,
    nu: Uniforms(.{
        .res = "uRes",
        .vp = "uVp",
        .roll = "uRoll",
        .flight = "uFlight",
        .tint = "uTint[0]",
    }) = .{},
    gl_ready: bool = false,
    gl_failed: bool = false,

    u: Uniforms(.{
        .sprite = "iSprite",
        .nebula = "iStarNebula",
        .vp = "iStarVp",
        .roll = "iStarRoll",
        .warp = "iStarWarp",
    }) = .{},

    /// Vanishing point, uv; eased toward the cursor.
    vp: [2]f32 = .{ 0.5, 0.5 },
    vp_vel: [2]f32 = .{ 0, 0 },
    roll: f32 = 0,
    bank: f32 = 0,
    /// cos and sin of the roll as drawn this frame (roll + bank).
    roll_cs: [2]f32 = .{ 1, 0 },
    speed: f32 = 0.12,
    surge: f32 = 0,
    /// Distance flown, for the nebula's zoom.
    flight: f64 = 0,
    now: f64 = 0,

    jumps: bool,
    jump_left: f32 = 0,
    /// Hyperspace envelope, 0..1.
    warp: f32 = 0,
    next_jump: f32 = 0,

    colors: [16][3]f32 = @splat(.{ 0.8, 0.85, 1.0 }),
    color_count: usize = 0,
    fg: [3]f32 = .{ 0.92, 0.92, 0.96 },

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const count: usize = @intCast(std.math.clamp(params.getInt("stars", 2500), 100, max_stars));
        const stars = try allocator.alloc(Star, count);
        errdefer allocator.free(stars);
        // Worst case per star: two streak lines and two spikes, 12 vertices
        // a line; and up to three dots.
        const verts = try allocator.alloc(geometry.Vertex, count * 48);
        errdefer allocator.free(verts);
        const point_verts = try allocator.alloc(geometry.Point, count * 3);
        errdefer allocator.free(point_verts);
        const music = try spectral.Analyzer.init(allocator, params);

        var self = Context{
            .allocator = allocator,
            .music = music,
            .rng = std.Random.DefaultPrng.init(iohelp.nowNs()),
            .width = width,
            .height = height,
            .count = count,
            .stars = stars,
            .verts = verts,
            .batch = .{ .verts = verts, .px = .{ width, height } },
            .point_verts = point_verts,
            .points = .{ .verts = point_verts },
            .jumps = params.getBool("jumps", true),
        };
        for (self.stars) |*s| s.* = self.spawn(self.range(near, far));
        self.next_jump = self.range(40.0, 90.0);
        return self;
    }

    fn rand(self: *Context) f32 {
        return self.rng.random().float(f32);
    }

    fn range(self: *Context, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.rand();
    }

    fn spawn(self: *Context, z: f32) Star {
        const aspect = self.width / self.height;
        const m = self.rand();
        return .{
            .x = self.range(-spread, spread) * aspect,
            .y = self.range(-spread, spread),
            .z = z,
            .mag = 0.22 + 0.78 * m * m,
            .tint = if (self.rand() < 0.7) 0 else 1 + self.rng.random().uintLessThan(u8, 12),
            .phase = self.range(0.0, std.math.tau),
        };
    }

    fn color(self: *const Context, tint: u8) [3]f32 {
        if (tint == 0 or self.color_count < 8) return self.fg;
        const slots = [_]usize{ 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14 };
        const n: usize = if (self.color_count >= 15) 12 else 6;
        const col = self.colors[slots[(tint - 1) % n]];
        // Starlight is pale: tints lean toward the foreground.
        return .{
            col[0] + (self.fg[0] - col[0]) * 0.35,
            col[1] + (self.fg[1] - col[1]) * 0.35,
            col[2] + (self.fg[2] - col[2]) * 0.35,
        };
    }

    /// Screen uv of a world point seen from the camera (rolled about the
    /// view axis, looking through the vanishing point).
    fn project(self: *const Context, x: f32, y: f32, z: f32) [2]f32 {
        const aspect = self.width / self.height;
        const cr = self.roll_cs[0];
        const sr = self.roll_cs[1];
        const rx = x * cr - y * sr;
        const ry = x * sr + y * cr;
        return .{ self.vp[0] + rx / z * focal / aspect, self.vp[1] + ry / z * focal };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        const kick = self.music.update(dt);
        self.now += dt;

        if (state.palette) |pal| {
            self.color_count = pal.color_count;
            for (0..pal.color_count) |i| self.colors[i] = .{ pal.colors[i].r, pal.colors[i].g, pal.colors[i].b };
            self.fg = .{ pal.foreground.r, pal.foreground.g, pal.foreground.b };
        }

        // Steering: a damped spring pulls the vanishing point toward the
        // cursor (held in from the edges), and the camera banks against
        // the turn's sideways velocity.
        const target = [2]f32{
            0.5 + (std.math.clamp(state.cursor[0] / self.width, 0.0, 1.0) - 0.5) * 0.6,
            0.5 + (std.math.clamp(state.cursor[1] / self.height, 0.0, 1.0) - 0.5) * 0.6,
        };
        const k: f32 = 2.2;
        const damp: f32 = 2.6;
        for (0..2) |i| {
            self.vp_vel[i] += ((target[i] - self.vp[i]) * k - self.vp_vel[i] * damp) * dt;
            self.vp[i] += self.vp_vel[i] * dt;
        }
        const bank_target = std.math.clamp(-self.vp_vel[0] * 1.6, -0.35, 0.35);
        self.bank += (bank_target - self.bank) * @min(1.0, 2.0 * dt);
        self.roll += dt * 0.006;
        self.roll_cs = .{ @cos(self.roll + self.bank), @sin(self.roll + self.bank) };

        // Speed: cruise, music, kicks, and hyperspace.
        if (kick) self.surge = 1.0;
        self.surge *= @exp(-3.0 * dt);
        if (self.jumps) {
            self.next_jump -= dt;
            if (self.next_jump <= 0 and self.jump_left <= 0) {
                self.jump_left = self.range(2.5, 4.5);
                self.next_jump = self.range(60.0, 150.0);
            }
        }
        self.jump_left -= dt;
        const warp_target: f32 = if (self.jump_left > 0) 1.0 else 0.0;
        // Spool up slower than the drop out.
        self.warp += (warp_target - self.warp) * @min(1.0, (if (warp_target > self.warp) @as(f32, 1.2) else 2.5) * dt);
        const cruise = 0.1 + self.music.bass() * 0.12 + self.surge * 0.25;
        self.speed = cruise + self.warp * self.warp * 2.4;
        self.flight += self.speed * dt;

        // Fly: stars come at the camera; past it or out of view, a fresh
        // one appears at the back of the box.
        const tw: f32 = @floatCast(@mod(self.now, 1000.0));
        self.batch.len = 0;
        self.points.len = 0;
        const px_scale = self.height / 1440.0;
        // Streaks trail back over the distance flown in this many seconds.
        const trail_secs: f32 = 0.018 + self.surge * 0.03 + self.warp * 0.14;
        for (self.stars) |*s| {
            s.z -= self.speed * dt;
            var p = self.project(s.x, s.y, s.z);
            if (s.z < near or p[0] < -0.2 or p[0] > 1.2 or p[1] < -0.2 or p[1] > 1.2) {
                s.* = self.spawn(self.range(far * 0.85, far));
                p = self.project(s.x, s.y, s.z);
            }

            // Fade in from the back of the box; brighten as it nears.
            const depth = (far - s.z) / (far - near);
            const fade_in = std.math.clamp((far - s.z) / 0.25, 0.0, 1.0);
            const twinkle = 0.85 + 0.15 * @sin(tw * (2.0 + s.mag * 3.0) + s.phase);
            const bright = s.mag * fade_in * (0.35 + 0.65 * depth) * (if (s.z > 0.4) twinkle else 1.0);
            if (bright < 0.01) continue;
            const r = std.math.clamp(0.18 * s.mag / s.z, 0.9, 6.5) * px_scale;
            const col = self.color(s.tint);
            const head = [4]f32{ col[0], col[1], col[2], @min(bright * 1.3, 1.0) };
            const glow = [4]f32{ col[0], col[1], col[2], bright * 0.16 };

            // Only what shows: a far star is one dot; streaks, the white
            // core and the halo come in as it nears and brightens.
            const tail = self.project(s.x, s.y, s.z + self.speed * trail_secs);
            const sx = (p[0] - tail[0]) * self.width;
            const sy = (p[1] - tail[1]) * self.height;
            if (sx * sx + sy * sy > 1.0) {
                self.batch.line(tail, p, r * 1.6, head);
                if (bright > 0.25) self.batch.line(tail, p, r * 5.0, glow);
            }
            self.points.dot(p, r * 3.0, head);
            if (r > 1.5 * px_scale) self.points.dot(p, r * 1.4, .{ 1, 1, 1, head[3] * 0.6 });
            if (bright * r > 0.8 * px_scale) self.points.dot(p, r * 10.0, glow);

            // Diffraction spikes on the brightest, nearest stars.
            if (s.mag > 0.75 and s.z < 0.35 and self.warp < 0.3) {
                const len = r * 9.0 / self.width;
                const len_y = r * 9.0 / self.height;
                const spike = [4]f32{ col[0], col[1], col[2], bright * 0.5 * (1.0 - self.warp / 0.3) };
                self.batch.line(.{ p[0] - len, p[1] }, .{ p[0] + len, p[1] }, 1.2 * px_scale, spike);
                self.batch.line(.{ p[0], p[1] - len_y }, .{ p[0], p[1] + len_y }, 1.2 * px_scale, spike);
            }
        }
    }

    fn ensureGl(self: *Context) bool {
        if (self.gl_ready) return true;
        if (self.gl_failed) return false;
        self.gl_failed = true;
        self.painter = geometry.Painter.init(self.verts.len) catch return false;
        self.point_painter = geometry.PointPainter.init(self.point_verts.len) catch return false;

        const w: i32 = @intFromFloat(self.width);
        const h: i32 = @intFromFloat(self.height);
        c.glGenTextures(1, &self.tex);
        c.glGenFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        var complete = false;
        // Half float keeps overlapping glows from clipping; 8-bit if not.
        inline for (.{ .{ c.GL_RGBA16F, c.GL_HALF_FLOAT }, .{ c.GL_RGBA8, c.GL_UNSIGNED_BYTE } }) |fmt| {
            if (!complete) {
                c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
                c.glTexImage2D(c.GL_TEXTURE_2D, 0, fmt[0], w, h, 0, c.GL_RGBA, fmt[1], null);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
                c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
                c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex, 0);
                complete = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) == c.GL_FRAMEBUFFER_COMPLETE;
            }
        }
        if (complete) {
            self.neb_prog = geometry.compileProgram(vert_src, nebula_frag_src);
            c.glGenVertexArrays(1, &self.vao);
            c.glGenTextures(1, &self.neb_tex);
            c.glGenFramebuffers(1, &self.neb_fbo);
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.neb_fbo);
            c.glBindTexture(c.GL_TEXTURE_2D, self.neb_tex);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA16F, @divTrunc(w + 3, 4), @divTrunc(h + 3, 4), 0, c.GL_RGBA, c.GL_HALF_FLOAT, null);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
            c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.neb_tex, 0);
            complete = self.neb_prog != 0 and c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) == c.GL_FRAMEBUFFER_COMPLETE;
        }
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (!complete) return false;
        self.gl_failed = false;
        self.gl_ready = true;
        return true;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        if (self.ensureGl()) {
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
            c.glViewport(0, 0, @intFromFloat(self.width), @intFromFloat(self.height));
            c.glClearColor(0, 0, 0, 0);
            c.glClear(c.GL_COLOR_BUFFER_BIT);
            self.painter.draw(&self.batch, .additive);
            self.point_painter.draw(&self.points);

            const nw = @divTrunc(@as(i32, @intFromFloat(self.width)) + 3, 4);
            const nh = @divTrunc(@as(i32, @intFromFloat(self.height)) + 3, 4);
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.neb_fbo);
            c.glViewport(0, 0, nw, nh);
            self.nu.use(self.neb_prog);
            self.nu.f2(.res, @floatFromInt(nw), @floatFromInt(nh));
            self.nu.f2(.vp, self.vp[0], self.vp[1]);
            self.nu.f1(.roll, self.roll + self.bank);
            self.nu.f1(.flight, @floatCast(@mod(self.flight, 1000.0)));
            const tints = [9]f32{
                self.colors[4][0], self.colors[4][1], self.colors[4][2],
                self.colors[5][0], self.colors[5][1], self.colors[5][2],
                self.colors[6][0], self.colors[6][1], self.colors[6][2],
            };
            self.nu.f3v(.tint, 3, &tints);
            c.glBindVertexArray(self.vao);
            c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
            c.glBindVertexArray(0);
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        }

        self.u.use(prog.program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex);
        self.u.int(.sprite, 0);
        c.glActiveTexture(c.GL_TEXTURE1);
        c.glBindTexture(c.GL_TEXTURE_2D, self.neb_tex);
        self.u.int(.nebula, 1);
        c.glActiveTexture(c.GL_TEXTURE0);
        self.u.f2(.vp, self.vp[0], self.vp[1]);
        self.u.f1(.roll, self.roll + self.bank);
        self.u.f1(.warp, self.warp);
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
        self.allocator.free(self.stars);
        self.allocator.free(self.verts);
        self.allocator.free(self.point_verts);
        if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
        if (self.tex != 0) c.glDeleteTextures(1, &self.tex);
        if (self.neb_fbo != 0) c.glDeleteFramebuffers(1, &self.neb_fbo);
        if (self.neb_tex != 0) c.glDeleteTextures(1, &self.neb_tex);
        if (self.neb_prog != 0) c.glDeleteProgram(self.neb_prog);
        if (self.vao != 0) c.glDeleteVertexArrays(1, &self.vao);
        self.painter.deinit();
        self.point_painter.deinit();
    }
};
