const std = @import("std");
const shader_mod = @import("../core/shader.zig");
const config_mod = @import("../core/config.zig");
const effects = @import("../effects.zig");
const spectral = @import("spectral.zig");
const iohelp = @import("../core/io_helper.zig");

const Uniforms = @import("uniforms.zig").Uniforms;

const c = @import("c");

// A circuit-bent video feedback loop: a camera pointed at its own monitor,
// with the desktop's window frames as the only light in the room. Each sim
// tick re-films the last frame through a zoom and twist about the focused
// window, so every frame recurses outward in a tunnel of its own copies.
// The bends are what a probe on the wrong pin does: the camera's frame
// rate drops or locks (stutter, freeze), horizontal bands stop updating,
// hsync drifts and shears rows, vsync loses lock and rolls, and shorted
// data lines overflow the signal so it wraps into contour bands.
//
// The loop carries a monochrome signal, not colour: the composite pass
// (shaders/glitch.frag) maps it onto the theme's surface tones, and only a
// second, fast-fading channel paints accents, injected during short bursts.
//
// Texture channels: r = luma, g = accent strength, b = accent hue (0..1).

const sim_frag: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec3 iResolution;
    \\uniform vec4 iWindow;
    \\uniform vec4 iWindows[32];
    \\uniform int iWindowCount;
    \\uniform vec4 iMouse;
    \\uniform sampler2D uPrev;
    \\uniform float uDiv;
    \\uniform vec2 uCenter;
    \\uniform vec4 uXform;
    \\uniform vec4 uTone;
    \\uniform vec4 uSync;
    \\uniform vec4 uBands;
    \\uniform vec4 uShort;
    \\uniform vec2 uAccent;
    \\uniform vec4 uLoop;
    \\uniform float uMeanLod;
    \\uniform float uTick;
    \\out vec4 fragColor;
    \\
    \\float hash12(vec2 p) {
    \\    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    \\    p3 += dot(p3, p3.yzx + 33.33);
    \\    return fract((p3.x + p3.y) * p3.z);
    \\}
    \\
    \\float boxSd(vec2 p, vec4 r) {
    \\    vec2 q = abs(p - (r.xy + r.zw * 0.5)) - r.zw * 0.5;
    \\    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
    \\}
    \\
    \\void main() {
    \\    vec2 fc = gl_FragCoord.xy;
    \\    vec2 res = iResolution.xy;
    \\
    \\    // Stuck bands: rows whose line buffer stopped latching.
    \\    float band = floor(fc.y / uBands.z);
    \\    if (hash12(vec2(band, uBands.y)) < uBands.x) {
    \\        fragColor = texelFetch(uPrev, ivec2(fc), 0);
    \\        return;
    \\    }
    \\
    \\    // Sync: hsync jitter shears rows, vsync slip rolls the frame. Both
    \\    // are per-tick offsets, so the loop integrates them into drift.
    \\    float dx = uSync.x * (sin(fc.y * 0.021 + uSync.y) + 0.5 * sin(fc.y * 0.093 - uSync.y * 1.7));
    \\    dx += uSync.w * step(0.5, hash12(vec2(floor(fc.y / 3.0), floor(uTick))));
    \\    vec2 src = fc + vec2(dx, uSync.z);
    \\
    \\    // The camera: zoom and twist about the centre, then pan.
    \\    vec2 q = src - uCenter;
    \\    float cr = cos(uXform.y);
    \\    float sr = sin(uXform.y);
    \\    q = mat2(cr, sr, -sr, cr) * q / uXform.x;
    \\    vec2 s = uCenter + q + uXform.zw;
    \\    // Mirror bend: a second camera filming the first one's reflection.
    \\    if (uLoop.z > 0.0) {
    \\        vec2 m = vec2(2.0 * uCenter.x - s.x, s.y);
    \\        if (textureLod(uPrev, m / res, 0.0).r > textureLod(uPrev, s / res, 0.0).r) s = mix(s, m, uLoop.z);
    \\    }
    \\    vec2 suv = s / res;
    \\    vec4 prev = textureLod(uPrev, suv, 0.0);
    \\    vec4 near = texelFetch(uPrev, ivec2(mod(floor(s), res)), 0);
    \\
    \\    // The lens: a defocus blur, and the sharpening the camera adds back,
    \\    // overshoot and all. Fed back, the overshoot grows into ripples.
    \\    vec2 o = uLoop.x / res;
    \\    float blur = (textureLod(uPrev, suv + vec2(o.x, 0.0), 0.0).r + textureLod(uPrev, suv - vec2(o.x, 0.0), 0.0).r +
    \\                  textureLod(uPrev, suv + vec2(0.0, o.y), 0.0).r + textureLod(uPrev, suv - vec2(0.0, o.y), 0.0).r) * 0.25;
    \\    float y = mix(blur, prev.r, 0.5) + uLoop.y * (prev.r - blur);
    \\
    \\    // Gain and an S-curve: mids get pushed to black or white, which is
    \\    // what turns a blurry echo into crisp feedback structure.
    \\    // Auto exposure: the camera's AGC reads the frame's mean (the top mip)
    \\    // and backs the gain off as it runs bright, so no flood can hold.
    \\    float mean = textureLod(uPrev, vec2(0.5), uMeanLod).r;
    \\    y *= uTone.x * clamp(0.28 / max(mean, 1e-3), 0.65, 1.15);
    \\    y = clamp((y - uTone.z) * uTone.y + 0.5, 0.0, 1.0);
    \\
    \\    // Shorted inverter: whole zones flip polarity for a tick.
    \\    if (hash12(floor(fc / 48.0) + floor(uTick) * 0.37) < uLoop.w) y = 1.0 - y;
    \\
    \\    // Shorted data lines: in bent zones the signal overflows and wraps
    \\    // (contour bands), or the low bits stick (posterised slabs).
    \\    vec2 zone = floor(fc / vec2(uShort.z * 5.0, uShort.z));
    \\    float zh = hash12(zone + uShort.y);
    \\    if (zh < uShort.x) y = fract(y * 1.9 + 0.07);
    \\    else if (zh < uShort.x * 1.7) y = floor(y * 3.0 + 0.5) / 3.0;
    \\
    \\    // Snow.
    \\    y += (hash12(fc + fract(uTick * 0.618) * 913.0) - 0.5) * uTone.w;
    \\
    \\    // Light: every window frame, a doubled frame round the focused one,
    \\    // and the cursor. The camera sees these and nothing else.
    \\    vec2 pb = fc * uDiv;
    \\    float lw = 1.2 * uDiv;
    \\    float lit = 0.0;
    \\    for (int i = 0; i < 32; i++) {
    \\        if (i >= iWindowCount) break;
    \\        vec4 r = iWindows[i];
    \\        if (r.z < 1.0) continue;
    \\        float d = boxSd(pb, r) - 2.0 * uDiv;
    \\        lit = max(lit, 1.0 - smoothstep(0.0, lw, abs(d)));
    \\    }
    \\    float hot = 0.0;
    \\    if (iWindow.z >= 1.0) {
    \\        float d = boxSd(pb, iWindow) - 6.0 * uDiv;
    \\        hot = 1.0 - smoothstep(0.0, lw, abs(d));
    \\    }
    \\    float cur = 1.0 - smoothstep(1.5 * uDiv, 3.0 * uDiv, length(pb - iMouse.xy));
    \\    hot = max(hot, cur);
    \\    y = max(y, max(lit * 0.8, hot));
    \\
    \\    // Accent rides the loop on its own channel and fades fast.
    \\    float a = prev.g * 0.955;
    \\    float hue = near.b;
    \\    float inj = hot * uAccent.x;
    \\    if (inj > a) { a = inj; hue = uAccent.y; }
    \\
    \\    fragColor = vec4(clamp(y, 0.0, 1.0), a, hue, 1.0);
    \\}
;

/// Sim lines tall at 1x: the loop runs at video resolution.
const default_lines: f32 = 720.0;
/// Most sim ticks one display frame may run (catch-up after a hitch).
const max_ticks_per_frame = 3;
/// Frames of history the display can skip back through.
const hist_slots = 16;

pub const Context = struct {
    allocator: std.mem.Allocator,
    music: spectral.Analyzer = .{},
    rng: std.Random.DefaultPrng,

    width: f32,
    height: f32,
    /// Buffer pixels per sim pixel.
    div: f32,
    sim_w: i32,
    sim_h: i32,

    sim: ?shader_mod.ShaderProgram = null,
    fbo: c.GLuint = 0,
    tex: [2]c.GLuint = .{ 0, 0 },
    /// Index of the texture holding the newest frame.
    current: u1 = 0,
    /// The last `hist_slots` frames, newest at layer `head`.
    hist_tex: c.GLuint = 0,
    hist_fbo: c.GLuint = 0,
    head: i32 = 0,
    gl_failed: bool = false,

    su: Uniforms(.{
        .prev = "uPrev",
        .div = "uDiv",
        .center = "uCenter",
        .xform = "uXform",
        .tone = "uTone",
        .sync = "uSync",
        .bands = "uBands",
        .short = "uShort",
        .accent = "uAccent",
        .loop = "uLoop",
        .mean_lod = "uMeanLod",
        .tick = "uTick",
    }) = .{},
    mu: Uniforms(.{
        .hist = "iGlitchHist",
        .head = "iGlitchHead",
        .slit = "iGlitchSlit",
        .sim = "iGlitchSim",
        .tear = "iGlitchTear",
        .chroma = "iGlitchChroma",
        .pix = "iGlitchPix",
        .dither = "iGlitchDither",
        .vsync = "iGlitchVsync",
    }) = .{},

    // Desktop snapshot for the sim pass (FrameState slices die with update).
    windows: [shader_mod.max_windows][4]f32 = undefined,
    window_count: usize = 0,
    focus: [4]f32 = .{ 0, 0, 0, 0 },
    cursor: [2]f32 = .{ 0, 0 },

    now: f64 = 0,
    tick: u32 = 0,
    tick_acc: f32 = 0,
    pending_ticks: u32 = 0,

    // The camera, sample-and-hold: it jumps between settings, never glides.
    zoom: f32 = 1.03,
    twist: f32 = 0.02,
    pan: [2]f32 = .{ 0, 0 },
    /// Camera aim offset from the focused window centre, buffer px.
    aim: [2]f32 = .{ 0, 0 },
    gain: f32 = 0.97,
    contrast: f32 = 1.15,
    /// S-curve pivot: above 0.5 the loop leans toward black.
    pivot: f32 = 0.55,
    /// Defocus radius (sim px) and how hard the camera sharpens it back.
    lens: f32 = 1.5,
    sharpen: f32 = 0.6,
    scene_left: f32 = 0,

    // Bends: each runs for its `_left` seconds once triggered.
    /// Camera frame rate while stuttering (ticks/s); 60 otherwise.
    stutter_rate: f32 = 60,
    stutter_left: f32 = 0,
    freeze_left: f32 = 0,
    band_prob: f32 = 0,
    band_h: f32 = 24,
    band_seed: f32 = 0,
    band_reseed: f32 = 0,
    band_left: f32 = 0,
    skew: f32 = 0.4,
    skew_phase: f32 = 0,
    skew_left: f32 = 0,
    shred: f32 = 0,
    roll: f32 = 0,
    roll_left: f32 = 0,
    short_amt: f32 = 0,
    short_seed: f32 = 0,
    short_zone: f32 = 12,
    short_left: f32 = 0,
    accent_hue: f32 = 0,
    accent_left: f32 = 0,
    tear: [3]f32 = .{ 0, 0, 0 },
    tear_left: f32 = 0,
    /// Display bends: mosaic, ordered dither, and lost vertical hold.
    pix: [3]f32 = .{ 0, 0, 0 },
    pix_left: f32 = 0,
    dither: [2]f32 = .{ 0, 0 },
    dither_left: f32 = 0,
    vroll_speed: f32 = 0,
    vroll: f32 = 0,
    vbar: f32 = 0,
    vbounce: f32 = 0,
    vsync_left: f32 = 0,
    mirror_left: f32 = 0,
    invert: f32 = 0,
    invert_left: f32 = 0,
    /// Skip: the display loops the last `skip_len` frames like a scratched
    /// disc, and history stops recording so the loop holds still.
    skip_len: i32 = 0,
    skip_step: i32 = 0,
    skip_hold: f32 = 0,
    skip_left: f32 = 0,
    /// Slit-scan: bands of rows show frames up to `slit_depth` old.
    slit_depth: f32 = 0,
    slit_band: f32 = 0.05,
    slit_seed: f32 = 0,
    slit_left: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const lines = std.math.clamp(params.getFloat("lines", default_lines), 120.0, 2160.0);
        const div = @max(1.0, height / lines);
        const music = try spectral.Analyzer.init(allocator, params);
        return .{
            .allocator = allocator,
            .music = music,
            .rng = std.Random.DefaultPrng.init(iohelp.nowNs()),
            .width = width,
            .height = height,
            .div = div,
            .sim_w = @intFromFloat(@ceil(width / div)),
            .sim_h = @intFromFloat(@ceil(height / div)),
        };
    }

    fn rand(self: *Context) f32 {
        return self.rng.random().float(f32);
    }

    fn range(self: *Context, lo: f32, hi: f32) f32 {
        return lo + (hi - lo) * self.rand();
    }

    /// Poisson trigger: fires on average `per_sec` times a second.
    fn chance(self: *Context, per_sec: f32, dt: f32) bool {
        return self.rand() < per_sec * dt;
    }

    /// New camera setting. Zoom above 1 pushes copies outward from the
    /// aim point; twist curls them into a spiral, either way round.
    fn jumpScene(self: *Context) void {
        self.zoom = self.range(1.008, 1.06);
        const sign: f32 = if (self.rand() < 0.5) -1.0 else 1.0;
        self.twist = sign * self.range(0.0, 0.07) * self.range(0.2, 1.0);
        self.pan = .{ self.range(-1.0, 1.0) * self.range(0.0, 1.5), self.range(-1.0, 1.0) * self.range(0.0, 1.5) };
        self.aim = .{ self.range(-0.25, 0.25) * self.width, self.range(-0.2, 0.2) * self.height };
        if (self.rand() < 0.4) self.aim = .{ 0, 0 };
        self.gain = self.range(0.95, 1.03);
        self.contrast = self.range(1.05, 1.45);
        self.pivot = self.range(0.52, 0.6);
        self.lens = self.range(0.8, 3.5);
        self.sharpen = self.range(0.2, 1.4);
        self.scene_left = self.range(2.0, 6.5);
    }

    fn stutter(self: *Context) void {
        const rates = [_]f32{ 4, 6, 8, 12, 15, 20, 30 };
        self.stutter_rate = rates[self.rng.random().uintLessThan(usize, rates.len)];
        self.stutter_left = self.range(0.3, 1.4);
    }

    fn freeze(self: *Context, max: f32) void {
        self.freeze_left = self.range(0.06, max);
    }

    fn stickBands(self: *Context) void {
        self.band_prob = self.range(0.15, 0.55);
        self.band_h = self.range(4.0, 60.0);
        self.band_left = self.range(0.4, 1.8);
    }

    fn slipSync(self: *Context) void {
        self.skew = self.range(1.5, 7.0);
        self.shred = if (self.rand() < 0.5) self.range(-4.0, 4.0) else 0;
        self.skew_left = self.range(0.3, 1.8);
    }

    fn rollFrame(self: *Context) void {
        const sign: f32 = if (self.rand() < 0.5) -1.0 else 1.0;
        self.roll = sign * self.range(2.0, 22.0);
        self.roll_left = self.range(0.4, 1.6);
    }

    fn shortLines(self: *Context) void {
        self.short_amt = self.range(0.06, 0.3);
        self.short_seed = self.range(0.0, 500.0);
        self.short_zone = self.range(4.0, 28.0);
        self.short_left = self.range(0.25, 1.3);
    }

    fn burstAccent(self: *Context) void {
        self.accent_hue = self.rand();
        self.accent_left = self.range(0.3, 1.2);
    }

    fn mirror(self: *Context) void {
        self.mirror_left = self.range(0.5, 2.5);
    }

    fn shortInverter(self: *Context) void {
        self.invert = self.range(0.02, 0.15);
        self.invert_left = self.range(0.1, 0.5);
    }

    fn skip(self: *Context) void {
        const lens = [_]i32{ 2, 3, 4, 6, 8 };
        self.skip_len = lens[self.rng.random().uintLessThan(usize, lens.len)];
        self.skip_step = 0;
        self.skip_hold = 0;
        self.skip_left = self.range(0.25, 1.2);
    }

    fn slitScan(self: *Context) void {
        self.slit_depth = self.range(4.0, @as(f32, hist_slots - 1));
        self.slit_band = self.range(0.004, 0.08);
        self.slit_seed = self.range(0.0, 100.0);
        self.slit_left = self.range(0.5, 2.5);
    }

    fn pixelate(self: *Context) void {
        const blocks = [_]f32{ 3, 4, 6, 8, 12, 16, 24 };
        const share: f32 = if (self.rand() < 0.3) 1.0 else self.range(0.15, 0.6);
        self.pix = .{ blocks[self.rng.random().uintLessThan(usize, blocks.len)], share, self.range(0.0, 100.0) };
        self.pix_left = self.range(0.25, 2.0);
    }

    fn crushDither(self: *Context) void {
        const cells = [_]f32{ 2, 3, 4, 6 };
        self.dither = .{
            @floatFromInt(1 + self.rng.random().uintLessThan(u8, 3)),
            cells[self.rng.random().uintLessThan(usize, cells.len)],
        };
        self.dither_left = self.range(0.8, 4.0);
    }

    fn loseVsync(self: *Context) void {
        const sign: f32 = if (self.rand() < 0.5) -1.0 else 1.0;
        // Sometimes a full roll, sometimes it only shudders in place.
        self.vroll_speed = if (self.rand() < 0.65) sign * self.range(0.3, 3.0) else 0;
        self.vbar = self.range(0.03, 0.09);
        self.vbounce = self.range(2.0, 30.0);
        self.vsync_left = self.range(0.4, 2.5);
    }

    fn tearFrame(self: *Context) void {
        self.tear = .{ self.rand(), self.range(-0.2, 0.2), self.range(0.01, 0.12) };
        self.tear_left = self.range(0.04, 0.25);
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = std.math.clamp(state.dt, 0.0, 0.05);
        self.now += dt;
        const kick = self.music.update(dt);
        const energy = self.music.bands.energy_ema;

        // Snapshot the desktop for the sim pass.
        self.window_count = @min(state.windows.len, self.windows.len);
        var on_screen = false;
        for (state.windows[0..self.window_count], 0..) |w, i| {
            self.windows[i] = .{ w.x, w.y, w.w, w.h };
            if (w.w >= 1.0 and w.x < self.width and w.x + w.w > 0 and w.y < self.height and w.y + w.h > 0) on_screen = true;
        }
        const f = state.focused_win;
        self.focus = .{ f.x, f.y, f.w, f.h };
        self.cursor = state.cursor;
        // An empty screen gives the camera nothing to film, and the loop
        // starves to black. Stand a ghost frame in the middle instead.
        if (!on_screen) {
            const s = self.height * 0.3;
            self.focus = .{ (self.width - s) * 0.5, (self.height - s) * 0.5, s, s };
        }

        // Bends fire at random; music raises every rate, and each kick
        // throws one more in.
        const heat = 1.0 + energy * 2.5;
        self.scene_left -= dt;
        if (self.scene_left <= 0) self.jumpScene();
        if (self.chance(0.22 * heat, dt)) self.stutter();
        if (self.chance(0.12 * heat, dt)) self.freeze(0.45);
        if (self.chance(0.2 * heat, dt)) self.stickBands();
        if (self.chance(0.18 * heat, dt)) self.slipSync();
        if (self.chance(0.07 * heat, dt)) self.rollFrame();
        if (self.chance(0.14 * heat, dt)) self.shortLines();
        if (self.chance(0.1 * heat, dt)) self.burstAccent();
        if (self.chance(0.3 * heat, dt)) self.tearFrame();
        if (self.chance(0.08 * heat, dt)) self.mirror();
        if (self.chance(0.1 * heat, dt)) self.shortInverter();
        if (self.chance(0.16 * heat, dt)) self.skip();
        if (self.chance(0.12 * heat, dt)) self.slitScan();
        if (self.chance(0.16 * heat, dt)) self.pixelate();
        if (self.chance(0.1 * heat, dt)) self.crushDither();
        if (self.chance(0.09 * heat, dt)) self.loseVsync();
        if (kick) switch (self.rng.random().uintLessThan(u8, 10)) {
            8 => self.pixelate(),
            9 => self.loseVsync(),
            0 => self.jumpScene(),
            1 => self.skip(),
            2 => self.tearFrame(),
            3 => self.burstAccent(),
            4 => self.stickBands(),
            5 => self.shortInverter(),
            6 => self.slitScan(),
            else => self.shortLines(),
        };

        self.stutter_left -= dt;
        self.freeze_left -= dt;
        self.band_left -= dt;
        self.skew_left -= dt;
        self.roll_left -= dt;
        self.short_left -= dt;
        self.accent_left -= dt;
        self.tear_left -= dt;
        self.mirror_left -= dt;
        self.invert_left -= dt;
        self.slit_left -= dt;
        self.skip_left -= dt;
        self.pix_left -= dt;
        self.dither_left -= dt;
        self.vsync_left -= dt;
        if (self.vsync_left > 0) {
            self.vroll = @mod(self.vroll + self.vroll_speed * dt, 1.0);
        } else {
            // The hold catches: the roll snaps back to frame.
            self.vroll = 0;
        }
        if (self.skip_left > 0) {
            // Each looped frame holds for one or two display frames.
            self.skip_hold -= dt;
            if (self.skip_hold <= 0) {
                self.skip_step = @mod(self.skip_step + 1, self.skip_len);
                self.skip_hold = 1.0 / 30.0;
            }
        }
        if (self.band_left > 0) {
            // Stuck bands flicker between rows rather than holding still.
            self.band_reseed -= dt;
            if (self.band_reseed <= 0) {
                self.band_seed = self.range(0.0, 1000.0);
                self.band_reseed = self.range(0.04, 0.25);
            }
        }
        self.skew_phase += dt * (if (self.skew_left > 0) @as(f32, 9.0) else 0.7);

        // Camera clock: 60 ticks/s, unless stuttering or frozen.
        if (self.freeze_left <= 0) {
            const rate: f32 = if (self.stutter_left > 0) self.stutter_rate else 60.0;
            self.tick_acc += dt * rate;
            const n: u32 = @intFromFloat(@floor(self.tick_acc));
            self.tick_acc -= @floatFromInt(n);
            self.pending_ticks = @min(self.pending_ticks + n, max_ticks_per_frame);
        }
    }

    fn ensureGl(self: *Context) bool {
        if (self.sim != null) return true;
        if (self.gl_failed) return false;
        self.gl_failed = true;
        self.sim = shader_mod.ShaderProgram.init(sim_frag) catch return false;

        c.glGenTextures(2, &self.tex);
        c.glGenFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        for (self.tex) |t| {
            c.glBindTexture(c.GL_TEXTURE_2D, t);
            c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, self.sim_w, self.sim_h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
            // Mipmapped only for the AGC's mean (the sim samples level 0).
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR_MIPMAP_NEAREST);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
            c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
            c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, t, 0);
            c.glClearColor(0, 0, 0, 1);
            c.glClear(c.GL_COLOR_BUFFER_BIT);
            c.glGenerateMipmap(c.GL_TEXTURE_2D);
        }
        var status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);

        c.glGenTextures(1, &self.hist_tex);
        c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, self.hist_tex);
        c.glTexStorage3D(c.GL_TEXTURE_2D_ARRAY, 1, c.GL_RGBA8, self.sim_w, self.sim_h, hist_slots);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_WRAP_S, c.GL_REPEAT);
        c.glTexParameteri(c.GL_TEXTURE_2D_ARRAY, c.GL_TEXTURE_WRAP_T, c.GL_REPEAT);
        c.glGenFramebuffers(1, &self.hist_fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.hist_fbo);
        for (0..hist_slots) |layer| {
            c.glFramebufferTextureLayer(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, self.hist_tex, 0, @intCast(layer));
            c.glClear(c.GL_COLOR_BUFFER_BIT);
        }
        if (status == c.GL_FRAMEBUFFER_COMPLETE) status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        if (status != c.GL_FRAMEBUFFER_COMPLETE) return false;
        self.gl_failed = false;
        return true;
    }

    /// One camera frame: film tex[current] into the other texture.
    fn runTick(self: *Context, sp: *const shader_mod.ShaderProgram) void {
        const src = self.current;
        const dst = 1 - self.current;
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.tex[dst], 0);
        c.glViewport(0, 0, self.sim_w, self.sim_h);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[src]);

        self.tick +%= 1;
        // Aim at the focused window (the whole screen when none), offset
        // by the scene's aim, in sim pixels.
        var cx = self.width * 0.5;
        var cy = self.height * 0.5;
        if (self.focus[2] >= 1.0) {
            cx = self.focus[0] + self.focus[2] * 0.5;
            cy = self.focus[1] + self.focus[3] * 0.5;
        }
        cx = (cx + self.aim[0]) / self.div;
        cy = (cy + self.aim[1]) / self.div;
        const bass = self.music.bass();
        const treble = self.music.treble();

        self.su.int(.prev, 0);
        self.su.f1(.div, self.div);
        self.su.f2(.center, cx, cy);
        self.su.f4(.xform, self.zoom + bass * 0.02, self.twist, self.pan[0], self.pan[1]);
        self.su.f4(.tone, self.gain, self.contrast, self.pivot, 0.05 + treble * 0.12);
        const skewing = self.skew_left > 0;
        self.su.f4(
            .sync,
            if (skewing) self.skew else 0.35,
            self.skew_phase,
            if (self.roll_left > 0) self.roll else 0,
            if (skewing) self.shred else 0,
        );
        self.su.f4(.bands, if (self.band_left > 0) self.band_prob else 0, self.band_seed, self.band_h, 0);
        self.su.f4(.short, if (self.short_left > 0) self.short_amt else 0, self.short_seed, self.short_zone, 0);
        self.su.f2(.accent, if (self.accent_left > 0) 1.0 else 0.0, self.accent_hue);
        self.su.f4(
            .loop,
            self.lens,
            self.sharpen,
            if (self.mirror_left > 0) 1.0 else 0.0,
            if (self.invert_left > 0) self.invert else 0.0,
        );
        self.su.f1(.tick, @floatFromInt(self.tick % 100000));
        self.su.f1(.mean_lod, @floor(std.math.log2(@as(f32, @floatFromInt(@max(self.sim_w, self.sim_h))))));

        c.glBindVertexArray(sp.vao);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        c.glBindTexture(c.GL_TEXTURE_2D, self.tex[dst]);
        c.glGenerateMipmap(c.GL_TEXTURE_2D);
        self.current = dst;

        // Record it, unless a skip is holding history still.
        if (self.skip_left > 0) return;
        self.head = @mod(self.head + 1, hist_slots);
        c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, self.hist_fbo);
        c.glFramebufferTextureLayer(c.GL_DRAW_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, self.hist_tex, 0, self.head);
        c.glBlitFramebuffer(0, 0, self.sim_w, self.sim_h, 0, 0, self.sim_w, self.sim_h, c.GL_COLOR_BUFFER_BIT, c.GL_NEAREST);
        c.glBindFramebuffer(c.GL_DRAW_FRAMEBUFFER, 0);
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        if (self.ensureGl()) {
            const sp = &self.sim.?;
            self.su.use(sp.program);
            if (sp.i_resolution >= 0)
                c.glUniform3f(sp.i_resolution, @floatFromInt(self.sim_w), @floatFromInt(self.sim_h), 1.0);
            for (self.windows[0..self.window_count], 0..) |w, i| {
                if (sp.i_windows[i] >= 0) c.glUniform4f(sp.i_windows[i], w[0], w[1], w[2], w[3]);
            }
            if (sp.i_window_count >= 0) c.glUniform1i(sp.i_window_count, @intCast(self.window_count));
            if (sp.i_window >= 0) c.glUniform4f(sp.i_window, self.focus[0], self.focus[1], self.focus[2], self.focus[3]);
            if (sp.i_mouse >= 0) c.glUniform4f(sp.i_mouse, self.cursor[0], self.cursor[1], 0, 0);

            while (self.pending_ticks > 0) : (self.pending_ticks -= 1) self.runTick(sp);
            c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        }

        self.mu.use(prog.program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D_ARRAY, self.hist_tex);
        self.mu.int(.hist, 0);
        const shown = if (self.skip_left > 0) self.head - (self.skip_len - 1) + self.skip_step else self.head;
        self.mu.int(.head, @mod(shown, hist_slots));
        if (self.slit_left > 0)
            self.mu.f4(.slit, self.slit_depth, self.slit_band, self.slit_seed, 0)
        else
            self.mu.f4(.slit, 0, 1, 0, 0);
        self.mu.f2(.sim, @floatFromInt(self.sim_w), @floatFromInt(self.sim_h));
        if (self.tear_left > 0)
            self.mu.f4(.tear, self.tear[0], self.tear[1], self.tear[2], 0)
        else
            self.mu.f4(.tear, 0, 0, 0, 0);
        self.mu.f1(.chroma, 2.0 + self.music.beat() * 6.0);
        self.mu.f4(.pix, if (self.pix_left > 0) self.pix[0] else 0, self.pix[1], self.pix[2], 0);
        self.mu.f4(.dither, if (self.dither_left > 0) self.dither[0] else 0, self.dither[1], 0, 0);
        if (self.vsync_left > 0) {
            const bounce = (self.rand() - 0.5) * 2.0 * self.vbounce;
            self.mu.f4(.vsync, self.vroll, if (self.vroll_speed != 0) self.vbar else 0, bounce, 0);
        } else self.mu.f4(.vsync, 0, 0, 0, 0);
    }

    pub fn deinit(self: *Context) void {
        self.music.deinit(self.allocator);
        if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
        if (self.tex[0] != 0) c.glDeleteTextures(2, &self.tex);
        if (self.hist_fbo != 0) c.glDeleteFramebuffers(1, &self.hist_fbo);
        if (self.hist_tex != 0) c.glDeleteTextures(1, &self.hist_tex);
        if (self.sim) |*sp| sp.deinit();
    }
};
