const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const effects = @import("../../effects.zig");
const spectral = @import("../spectral.zig");
const presets = @import("presets.zig");
const geometry = @import("../geometry.zig");
const Batch = geometry.Batch;
const Vertex = geometry.Vertex;
const max_verts = geometry.max_verts;
const compileProgram = geometry.compileProgram;
const iohelp = @import("../../core/io_helper.zig");

const log = std.log.scoped(.milkdrop);

const Uniforms = @import("../uniforms.zig").Uniforms;

const c = @import("c");

// MilkDrop, the way Ryan Geiss built it: a feedback buffer that every frame
// is re-sampled through a per-pixel motion field (zoom, rotation, the
// four-sine warp, centre, translation, stretch) and decayed, then has this
// frame's waveforms, shapes and borders drawn on top. Presets are bundles
// of per-frame equations (presets.zig); every so often the next one blends
// in through a patterned transition, its motion field mixed per pixel.
// The display pass (shaders/milkdrop.frag) adds video echo and the
// gamma/brighten/darken/solarize/invert filters, and lays it over the theme.

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
    \\uniform vec2 uRes;
    \\uniform float uTime;
    \\uniform vec4 uA[5];
    \\uniform vec4 uB[5];
    \\uniform float uBlend;
    \\uniform vec4 uPattern;
    \\out vec4 fragColor;
    \\
    \\float hash12(vec2 p) {
    \\    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    \\    p3 += dot(p3, p3.yzx + 33.33);
    \\    return fract((p3.x + p3.y) * p3.z);
    \\}
    \\
    \\// Where this pixel samples last frame from, for one preset's motion.
    \\// p0 zoom, zoomexp, rot, warp; p1 warp speed, warp scale, cx, cy;
    \\// p2 dx, dy, sx, sy; p3 ripple amp, freq, speed, twist; p4 kaleido.
    \\vec2 motion(vec2 uv, vec4 p0, vec4 p1, vec4 p2, vec4 p3, vec4 p4) {
    \\    float aspect = uRes.x / uRes.y;
    \\    vec2 q = uv - p1.zw;
    \\    q.x *= aspect;
    \\    if (p4.x >= 2.0) {
    \\        float seg = 6.2831853 / floor(p4.x);
    \\        float a = mod(atan(q.y, q.x), seg);
    \\        if (a > seg * 0.5) a = seg - a;
    \\        q = vec2(cos(a), sin(a)) * length(q);
    \\    }
    \\    float rad = length(q) / length(vec2(0.5 * aspect, 0.5));
    \\    float z = pow(p0.x, pow(p0.y, rad * 2.0 - 1.0));
    \\    z += p3.x * sin(rad * p3.y - uTime * p3.z);
    \\    q /= max(z, 0.05);
    \\    float r = p0.z + p3.w * rad;
    \\    float cr = cos(r);
    \\    float sr = sin(r);
    \\    q = mat2(cr, sr, -sr, cr) * q;
    \\    q /= p2.zw;
    \\    q.x /= aspect;
    \\    vec2 u = q + p1.zw - p2.xy;
    \\
    \\    // MilkDrop's warp: four drifting sines.
    \\    float wt = uTime * p1.x;
    \\    float ws = 1.0 / p1.y;
    \\    vec4 f = vec4(11.68 + 4.0 * cos(wt * 1.413 + 10.0), 8.77 + 3.0 * cos(wt * 1.113 + 7.0),
    \\                  10.54 + 3.0 * cos(wt * 1.233 + 3.0), 11.49 + 4.0 * cos(wt * 0.933 + 5.0));
    \\    vec2 xy = uv * 2.0 - 1.0;
    \\    float w = p0.w * 0.0035;
    \\    u.x += w * sin(wt * 0.333 + ws * (xy.x * f.x - xy.y * f.w));
    \\    u.y += w * cos(wt * 0.375 - ws * (xy.x * f.z + xy.y * f.y));
    \\    u.x += w * cos(wt * 0.753 - ws * (xy.x * f.y - xy.y * f.z));
    \\    u.y += w * sin(wt * 0.825 + ws * (xy.x * f.x + xy.y * f.w));
    \\    return u;
    \\}
    \\
    \\void main() {
    \\    vec2 uv = gl_FragCoord.xy / uRes;
    \\
    \\    // Transition: B takes over pixel by pixel in the pattern's order.
    \\    float pat = 0.0;
    \\    int kind = int(uPattern.x);
    \\    vec2 cuv = (uv - 0.5) * vec2(uRes.x / uRes.y, 1.0);
    \\    if (kind == 1) pat = clamp(length(cuv) * 1.3, 0.0, 1.0);
    \\    else if (kind == 2) pat = 1.0 - clamp(length(cuv) * 1.3, 0.0, 1.0);
    \\    else if (kind == 3) pat = clamp(dot(uv - 0.5, vec2(cos(uPattern.y), sin(uPattern.y))) + 0.5, 0.0, 1.0);
    \\    else if (kind == 4) pat = 0.5 + 0.25 * sin(cuv.x * 7.0 + uPattern.y) + 0.25 * sin(cuv.y * 9.0 - uPattern.y * 1.7);
    \\    else if (kind == 5) pat = hash12(floor(uv * 12.0) + uPattern.y);
    \\    float k = kind == 0 ? 0.0 : 3.0;
    \\    float b = smoothstep(0.0, 1.0, clamp(uBlend * (1.0 + k) - pat * k, 0.0, 1.0));
    \\
    \\    vec2 ua = motion(uv, uA[0], uA[1], uA[2], uA[3], uA[4]);
    \\    vec2 ub = motion(uv, uB[0], uB[1], uB[2], uB[3], uB[4]);
    \\    vec2 u = mix(ua, ub, b);
    \\    float decay = mix(uA[4].y, uB[4].y, b);
    \\    float wrap = mix(uA[4].z, uB[4].z, b);
    \\
    \\    vec3 prev = texture(uPrev, u).rgb;
    \\    // Without wrap, whatever slides in from off-screen is black.
    \\    vec2 off = step(vec2(0.0), u) * step(u, vec2(1.0));
    \\    prev *= mix(off.x * off.y, 1.0, step(0.5, wrap));
    \\    // Decay, less a hair so no trail lingers forever.
    \\    fragColor = vec4(max(prev * decay - 1.0 / 1024.0, 0.0), 1.0);
    \\}
;

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    sim_w: i32,
    sim_h: i32,

    fbo: c.GLuint = 0,
    tex: [2]c.GLuint = .{ 0, 0 },
    current: u1 = 0,
    warp_prog: c.GLuint = 0,
    vao: c.GLuint = 0,
    painter: geometry.Painter = .{},
    /// GL objects above exist (see ensureGl); false after a failed try too,
    /// with `gl_failed` set so it isn't retried every frame.
    gl_ready: bool = false,
    gl_failed: bool = false,

    wu: Uniforms(.{
        .prev = "uPrev",
        .res = "uRes",
        .time = "uTime",
        .a = "uA[0]",
        .b = "uB[0]",
        .blend = "uBlend",
        .pattern = "uPattern",
    }) = .{},
    mu: Uniforms(.{
        .sprite = "iSprite",
        .echo = "iMdEcho",
        .tone = "iMdTone",
        .invert = "iMdInvert",
    }) = .{},

    /// Backing store for the two batches.
    verts: []Vertex,
    /// Two geometry batches per frame: alpha-blended, then additive.
    alpha_batch: Batch,
    add_batch: Batch,

    now: f64 = 0,
    in: presets.Inputs = .{},
    frame_a: presets.Frame = .{},
    frame_b: presets.Frame = .{},

    // Preset rotation.
    pinned: ?usize,
    cycle: f32,
    cur: usize = 0,
    next: ?usize = null,
    blend: f32 = 0,
    blend_rate: f32 = 0.25,
    pattern: [2]f32 = .{ 0, 0 },
    preset_left: f32 = 0,
    since_switch: f32 = 0,

    /// Idle "dream" wave mix: 1 with no music, 0 with a real signal.
    idle: f32 = 1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const verts = try allocator.alloc(Vertex, max_verts * 2);
        errdefer allocator.free(verts);
        const music = try spectral.Analyzer.init(allocator, params);

        var pinned: ?usize = null;
        if (params.getString("preset", null)) |name| {
            pinned = presets.find(name);
            if (pinned == null) log.warn("unknown preset '{s}', cycling through all", .{name});
        }
        const scale = std.math.clamp(params.getFloat("scale", 0.5), 0.25, 1.0);
        const sim_w: i32 = @intFromFloat(@ceil(width * scale));
        const sim_h: i32 = @intFromFloat(@ceil(height * scale));
        const px = [2]f32{ @floatFromInt(sim_w), @floatFromInt(sim_h) };

        var rng = std.Random.DefaultPrng.init(iohelp.nowNs());
        const first = pinned orelse rng.random().uintLessThan(usize, presets.all.len);
        return .{
            .allocator = allocator,
            .music = music,
            .rng = rng,
            .width = width,
            .height = height,
            .sim_w = sim_w,
            .sim_h = sim_h,
            .verts = verts,
            .alpha_batch = .{ .verts = verts[0..max_verts], .px = px },
            .add_batch = .{ .verts = verts[max_verts..], .px = px },
            .pinned = pinned,
            .cycle = std.math.clamp(params.getFloat("cycle", 24.0), 4.0, 600.0),
            .cur = first,
            .preset_left = 0,
        };
    }

    fn rand(self: *Context) f32 {
        return self.rng.random().float(f32);
    }

    /// Start blending toward a different preset over `secs`.
    fn beginTransition(self: *Context, secs: f32) void {
        if (self.pinned != null or self.next != null) return;
        var n = self.rng.random().uintLessThan(usize, presets.all.len - 1);
        if (n >= self.cur) n += 1;
        self.next = n;
        self.blend = 0;
        self.blend_rate = 1.0 / secs;
        self.pattern = .{ @floatFromInt(self.rng.random().uintLessThan(u8, 6)), self.rand() * std.math.tau };
        self.since_switch = 0;
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;
        const t: f32 = @floatCast(@mod(self.now, 3600.0));
        const kick = self.music.update(dt);

        // Real waveform when there is one, the dream wave when quiet.
        var wave: [256]f32 = @splat(0);
        if (self.music.audio) |a| wave = a.getWaveform();
        var rms: f32 = 0;
        for (wave) |v| rms += v * v;
        rms = @sqrt(rms / 256.0);
        const quiet: f32 = 1.0 - std.math.clamp((rms - 0.01) / 0.05, 0.0, 1.0);
        self.idle += (quiet - self.idle) * @min(1.0, 2.0 * dt);
        if (self.idle > 0.001) {
            for (0..128) |i| {
                const x: f32 = @floatFromInt(i);
                const l = 0.32 * @sin(x * 0.17 + t * 3.1) * @sin(t * 0.63) +
                    0.18 * @sin(x * 0.051 - t * 1.37) + 0.08 * @sin(x * 0.61 + t * 5.3);
                const r = 0.32 * @sin(x * 0.17 + t * 3.1 + 1.3) * @sin(t * 0.63 + 0.4) +
                    0.18 * @sin(x * 0.047 - t * 1.29) + 0.08 * @sin(x * 0.57 + t * 4.7);
                wave[i] = wave[i] * (1 - self.idle) + l * self.idle;
                wave[128 + i] = wave[128 + i] * (1 - self.idle) + r * self.idle;
            }
        }
        const mags = spectral.magnitudes(&wave);

        // Inputs every preset's equations see. Quiet, the bands breathe on
        // slow LFOs instead of sitting at zero.
        const lfo = self.idle * 0.35;
        var in = &self.in;
        in.t = t;
        in.dt = dt;
        in.bass = @max(self.music.bass(), lfo * (0.6 + 0.4 * @sin(t * 0.9)));
        in.mid = @max((self.music.bands.smooth[2] + self.music.bands.smooth[3]) * 0.5, lfo * (0.6 + 0.4 * @sin(t * 0.71 + 2.0)));
        in.treb = @max(self.music.treble(), lfo * (0.6 + 0.4 * @sin(t * 1.13 + 4.0)));
        in.beat = self.music.beat();
        if (kick) in.beats +%= 1;
        // Quiet, a soft synthetic pulse keeps beat-driven presets moving.
        if (self.idle > 0.5) {
            const ph = @mod(t, 2.4);
            in.beat = @max(in.beat, @exp(-ph * 5.0) * 0.6);
            if (ph < dt) in.beats +%= 1;
        }
        in.wave = wave;
        @memcpy(in.spectrum[0..], mags[0..in.spectrum.len]);
        in.aspect = self.width / self.height;
        in.cursor = .{ state.cursor[0] / self.width, state.cursor[1] / self.height };
        const f = state.focused_win;
        in.focus = if (f.w >= 1.0)
            .{ (f.x + f.w * 0.5) / self.width, (f.y + f.h * 0.5) / self.height }
        else
            .{ 0.5, 0.5 };
        in.window_count = @min(state.windows.len, in.windows.len);
        for (state.windows[0..in.window_count], 0..) |w, i| {
            in.windows[i] = .{ w.x / self.width, w.y / self.height, w.w / self.width, w.h / self.height };
        }
        if (state.palette) |pal| in.setPalette(pal);

        // Rotation: a soft blend on the timer, a quick one on a big kick.
        self.since_switch += dt;
        self.preset_left -= dt;
        if (self.preset_left <= 0) {
            self.preset_left = self.cycle * (0.75 + 0.5 * self.rand());
            if (self.since_switch > 1.0) self.beginTransition(2.5 + 2.5 * self.rand());
        } else if (kick and self.since_switch > self.cycle * 0.4 and self.rand() < 0.2) {
            self.preset_left = self.cycle * (0.75 + 0.5 * self.rand());
            self.beginTransition(0.7);
        }
        if (self.next) |n| {
            self.blend += dt * self.blend_rate;
            if (self.blend >= 1.0) {
                self.cur = n;
                self.next = null;
                self.blend = 0;
            }
        }

        self.frame_a = .{};
        presets.all[self.cur].eval(in, &self.frame_a);
        if (self.next) |n| {
            self.frame_b = .{};
            presets.all[n].eval(in, &self.frame_b);
        } else self.frame_b = self.frame_a;

        // Geometry for both presets, each faded by its share of the blend.
        self.alpha_batch.len = 0;
        self.add_batch.len = 0;
        const share = smooth(self.blend);
        self.frame_a.draw(in, &self.alpha_batch, &self.add_batch, if (self.next != null) 1.0 - share else 1.0);
        if (self.next != null) self.frame_b.draw(in, &self.alpha_batch, &self.add_batch, share);
    }

    fn smooth(x: f32) f32 {
        const t = std.math.clamp(x, 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    /// Create the ping-pong textures, FBO, programs and vertex buffer on
    /// first upload: init runs before the GL context it would draw with
    /// exists (and again for a fresh context after a loss).
    fn ensureGl(self: *Context) bool {
        if (self.gl_ready) return true;
        if (self.gl_failed) return false;
        self.gl_failed = true;

        self.warp_prog = compileProgram(vert_src, warp_frag_src);
        if (self.warp_prog == 0) {
            log.err("internal shader compile failed", .{});
            return false;
        }
        self.painter = geometry.Painter.init(max_verts) catch return false;

        c.glGenTextures(2, &self.tex);
        c.glGenFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        // Half float, so a slow decay fades out instead of sticking at the
        // last 8-bit step (MilkDrop's old residue). 8-bit if unsupported.
        var complete = false;
        inline for (.{ .{ c.GL_RGBA16F, c.GL_HALF_FLOAT }, .{ c.GL_RGBA8, c.GL_UNSIGNED_BYTE } }) |fmt| {
            if (!complete) {
                for (self.tex) |t| {
                    c.glBindTexture(c.GL_TEXTURE_2D, t);
                    c.glTexImage2D(c.GL_TEXTURE_2D, 0, fmt[0], self.sim_w, self.sim_h, 0, c.GL_RGBA, fmt[1], null);
                    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
                    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
                    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
                    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
                }
                c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex[0], 0);
                complete = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) == c.GL_FRAMEBUFFER_COMPLETE;
                if (!complete and fmt[0] == c.GL_RGBA16F) log.info("no half-float render target, using RGBA8", .{});
            }
        }
        if (complete) {
            for (self.tex) |t| {
                c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, t, 0);
                c.glClearColor(0, 0, 0, 1);
                c.glClear(c.GL_COLOR_BUFFER_BIT);
            }
        }
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (!complete) return false;

        c.glGenVertexArrays(1, &self.vao);

        self.gl_failed = false;
        self.gl_ready = true;
        return true;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        if (self.ensureGl()) {
            const prev = self.current;
            const curr = 1 - self.current;

            // --- Pass 1: warp last frame through the motion field ---
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
            c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex[curr], 0);
            c.glViewport(0, 0, self.sim_w, self.sim_h);

            self.wu.use(self.warp_prog);
            c.glActiveTexture(c.GL_TEXTURE0);
            c.glBindTexture(c.GL_TEXTURE_2D, self.tex[prev]);
            self.wu.int(.prev, 0);
            self.wu.f2(.res, @floatFromInt(self.sim_w), @floatFromInt(self.sim_h));
            self.wu.f1(.time, self.in.t);
            const pa = self.frame_a.motion.pack();
            const pb = self.frame_b.motion.pack();
            self.wu.f4v(.a, 5, &pa);
            self.wu.f4v(.b, 5, &pb);
            self.wu.f1(.blend, if (self.next != null) self.blend else 0);
            self.wu.f4(.pattern, self.pattern[0], self.pattern[1], 0, 0);
            c.glBindVertexArray(self.vao);
            c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);

            // --- Pass 2: this frame's shapes, borders and waves ---
            self.painter.draw(&self.alpha_batch, .alpha);
            self.painter.draw(&self.add_batch, .additive);

            c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
            self.current = curr;
        }

        // --- Display: hand the frame to the main shader ---
        const m = presets.Motion.lerp(self.frame_a.motion, self.frame_b.motion, if (self.next != null) smooth(self.blend) else 0);
        self.mu.use(prog.program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[self.current]);
        self.mu.int(.sprite, 0);
        self.mu.f4(.echo, m.echo_alpha, m.echo_zoom, @round(m.echo_orient), 0);
        self.mu.f4(.tone, m.gamma, m.brighten, m.darken, m.solarize);
        self.mu.f1(.invert, m.invert);
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
        self.allocator.free(self.verts);
        if (!self.gl_ready) {
            if (self.warp_prog != 0) c.glDeleteProgram(self.warp_prog);
            self.painter.deinit();
            if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
            if (self.tex[0] != 0) c.glDeleteTextures(2, &self.tex);
            return;
        }
        c.glDeleteFramebuffers(1, &self.fbo);
        c.glDeleteTextures(2, &self.tex);
        c.glDeleteVertexArrays(1, &self.vao);
        c.glDeleteProgram(self.warp_prog);
        self.painter.deinit();
    }
};
