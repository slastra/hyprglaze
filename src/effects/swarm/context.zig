const std = @import("std");
const shader_mod = @import("../../core/shader.zig");
const config_mod = @import("../../core/config.zig");
const palette_mod = @import("../../core/palette.zig");
const effects = @import("../../effects.zig");
const audio_mod = @import("../visualizer/audio.zig");
const bands_mod = @import("../bands.zig");
const boids_mod = @import("boids.zig");

const c = @cImport({
    @cInclude("GLES3/gl3.h");
});

// Field resolution: the flock is splatted into this grid each frame and the
// shader renders the field, not the boids — that's what turns dots into a
// continuous murmuration. ~19px cells at 3072x1728.
const field_w = 160;
const field_h = 90;
const field_cells = field_w * field_h;

// Velocity normalization for the RG channels (pixels/sec mapped to ±1).
const vel_scale: f32 = 700.0;

const max_windows = 32;

// The heavy rendering runs in this compute pass at ONE FRAGMENT PER BLOCK
// (canvas = screen / pixel_size), then shaders/swarm.frag nearest-upscales
// the canvas to the screen. At the default 30px blocks that's ~6k fragments
// doing the streaks/fbm/contour math instead of 5.3M — the pixelation IS
// the optimization.
const compute_frag: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\
    \\// Screen resolution (real pixels) — the canvas is smaller; fragment
    \\// coords are scaled up by iPixel so all math stays in screen space.
    \\uniform vec3 iResolution;
    \\uniform float iPixel;
    \\uniform float iSwarmTime;
    \\uniform vec4 iWindows[32];
    \\uniform int iWindowCount;
    \\
    \\uniform vec3 iPalette[16];
    \\uniform int iPaletteSize;
    \\uniform vec3 iPaletteBg;
    \\uniform vec3 iPaletteFg;
    \\
    \\// Flock field: RG = density-weighted velocity (biased), B = agitation
    \\// (predator fear), A = density.
    \\uniform sampler2D iField;
    \\uniform float iBeat;
    \\uniform float iBass;
    \\uniform float iEnergy;
    \\// Ink saturation: 0 = full palette color, 1 = greyscale.
    \\uniform float iMute;
    \\// 1 = topographic isolines, 0 = posterized field blocks.
    \\uniform float iContour;
    \\
    \\out vec4 fragColor;
    \\
    \\float hash21(vec2 p) {
    \\    p = fract(p * vec2(123.34, 456.21));
    \\    p += dot(p, p + 45.32);
    \\    return fract(p.x * p.y);
    \\}
    \\
    \\float vnoise(vec2 p) {
    \\    vec2 i = floor(p);
    \\    vec2 f = fract(p);
    \\    f = f * f * (3.0 - 2.0 * f);
    \\    float a = hash21(i);
    \\    float b = hash21(i + vec2(1.0, 0.0));
    \\    float c = hash21(i + vec2(0.0, 1.0));
    \\    float d = hash21(i + vec2(1.0, 1.0));
    \\    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
    \\}
    \\
    \\float fbm(vec2 p) {
    \\    float v = 0.0;
    \\    float a = 0.5;
    \\    for (int i = 0; i < 4; i++) {
    \\        v += a * vnoise(p);
    \\        p = p * 2.1 + 17.3;
    \\        a *= 0.5;
    \\    }
    \\    return v;
    \\}
    \\
    \\// Density streaked along local velocity — smears the cloud into
    \\// ribbons that follow the flock's motion.
    \\float streakDensity(vec2 uv, vec2 vel_uv) {
    \\    float total = texture(iField, uv).a * 1.2;
    \\    float wsum = 1.2;
    \\    for (int k = 1; k <= 3; k++) {
    \\        float t = float(k) / 3.0;
    \\        float w = 1.0 - t * 0.65;
    \\        total += texture(iField, uv - vel_uv * t).a * w;
    \\        total += texture(iField, uv + vel_uv * t * 0.4).a * w * 0.6;
    \\        wsum += w * 1.6;
    \\    }
    \\    return total / wsum;
    \\}
    \\
    \\float sdRoundBox(vec2 p, vec2 center, vec2 half_size, float radius) {
    \\    vec2 d = abs(p - center) - half_size + radius;
    \\    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
    \\}
    \\
    \\void main() {
    \\    // One fragment per block: scale canvas coords back to screen space.
    \\    vec2 fc = gl_FragCoord.xy * iPixel;
    \\    vec2 uv = fc / iResolution.xy;
    \\
    \\    vec3 bg = (iPaletteSize > 0) ? iPaletteBg : vec3(0.02, 0.025, 0.04);
    \\    vec3 fg = (iPaletteSize > 0) ? iPaletteFg : vec3(0.9);
    \\    // Hypsometric ramp from the theme's ANSI colors.
    \\    vec3 elev0 = (iPaletteSize > 4) ? iPalette[4] : vec3(0.25, 0.35, 0.70);
    \\    vec3 elev1 = (iPaletteSize > 6) ? iPalette[6] : vec3(0.30, 0.60, 0.80);
    \\    vec3 elev2 = (iPaletteSize > 2) ? iPalette[2] : vec3(0.30, 0.70, 0.40);
    \\    vec3 elev3 = (iPaletteSize > 3) ? iPalette[3] : vec3(0.80, 0.70, 0.30);
    \\    vec3 hot   = (iPaletteSize > 9) ? iPalette[9] : vec3(1.0, 0.4, 0.3);
    \\
    \\    // Dusk sky: vertical falloff plus the faintest large-scale drift.
    \\    float sky = 1.0 - uv.y * 0.25;
    \\    vec3 col = bg * (0.8 * sky + 0.06 * fbm(uv * 3.0 + iSwarmTime * 0.02));
    \\
    \\    vec4 field = texture(iField, uv);
    \\    vec2 vel = (field.rg - 0.5) * 2.0;
    \\    float agit = field.b;
    \\
    \\    vec2 vel_uv = vel * 0.08;
    \\    float dens = streakDensity(uv, vel_uv);
    \\
    \\    // Feathering: fbm advected against the flow plumes the cloud edge.
    \\    float feather = fbm(fc * 0.013 - vel * 2.5 + vec2(0.0, iSwarmTime * 0.35));
    \\    dens *= 0.55 + 0.9 * feather;
    \\    dens *= 1.0 + iBass * 0.5; // bass thickens the murmuration
    \\
    \\    float panic = agit * (0.7 + 0.3 * vnoise(fc * 0.05 + iSwarmTime * 9.0));
    \\
    \\    const float levels = 4.0;
    \\    float q = dens * levels;
    \\    float level = floor(q);
    \\    float g = fract(q);
    \\    float line_d = min(g, 1.0 - g);
    \\    float lw = fwidth(q) * 0.7 + 0.01;
    \\    float iso = 1.0 - smoothstep(lw, lw * 1.8, line_d);
    \\
    \\    // Elevation tint, posterized into flat steps in field mode so
    \\    // neighboring blocks snap to distinct colors.
    \\    float lt = (iContour > 0.5)
    \\        ? clamp(level / levels, 0.0, 1.0)
    \\        : floor(clamp(dens, 0.0, 1.0) * 5.0 + 0.5) / 5.0;
    \\    float e = lt * 4.0;
    \\    vec3 ramp;
    \\    if      (e < 1.0) ramp = mix(elev0, elev1, e);
    \\    else if (e < 2.0) ramp = mix(elev1, elev2, e - 1.0);
    \\    else if (e < 3.0) ramp = mix(elev2, elev3, e - 2.0);
    \\    else              ramp = mix(elev3, fg, min(e - 3.0, 1.0));
    \\    // Mute toward ink; panic stays vivid.
    \\    float lum = dot(ramp, vec3(0.299, 0.587, 0.114));
    \\    ramp = mix(ramp, vec3(lum), iMute);
    \\    ramp = mix(ramp, fg, 0.15);
    \\    ramp = mix(ramp, hot, clamp(panic * 1.4, 0.0, 0.75));
    \\
    \\    float present = smoothstep(0.02, 0.10, dens);
    \\    if (iContour > 0.5) {
    \\        // Pure line-work: crisp colored isolines, drawn cartography.
    \\        col += ramp * iso * present * (0.8 + iEnergy * 0.4);
    \\    } else {
    \\        // Posterized field: brightness snaps to flat levels too.
    \\        float fill = smoothstep(0.03, 0.75, dens);
    \\        fill = floor(fill * 5.0 + 0.5) / 5.0;
    \\        col += ramp * fill * (0.7 + iEnergy * 0.4);
    \\    }
    \\
    \\    // The predator is deliberately invisible — you read its position
    \\    // from the holes it tears and the hot panic of birds fleeing it.
    \\
    \\    // Window edges catch a faint glow from passing density.
    \\    for (int i = 0; i < iWindowCount && i < 32; i++) {
    \\        vec4 win = iWindows[i];
    \\        if (win.z < 1.0 || win.w < 1.0) continue;
    \\        float d = sdRoundBox(fc, win.xy + win.zw * 0.5, win.zw * 0.5, 8.0);
    \\        if (d < 0.0 || d > 60.0) continue;
    \\        col += ramp * exp(-d * d / 800.0) * 0.08 * present * (1.0 + iBeat);
    \\    }
    \\
    \\    // Grain: per-block flicker — CRT static breathing under the image.
    \\    col += (hash21(fc + fract(iSwarmTime) * 100.0) - 0.5) * 0.012;
    \\
    \\    fragColor = vec4(col, 1.0);
    \\}
;

const Accum = struct {
    dens: [field_cells]f32,
    velx: [field_cells]f32,
    vely: [field_cells]f32,
    agit: [field_cells]f32,
    bytes: [field_cells * 4]u8,
};

pub const Context = struct {
    audio: *audio_mod.AudioCapture,
    sys: boids_mod.BoidSystem,
    allocator: std.mem.Allocator,
    accum: *Accum,

    now: f32 = 0,

    // Audio analysis (glitch.zig pattern, shared in bands.zig)
    an: bands_mod.Splitter = .{},

    /// Roost state: sustained silence settles the flock onto window tops;
    /// returning music bursts it back into the air.
    quiet_t: f32 = 0,
    roost: f32 = 0,

    // Render config (hot-reloads with the config watcher).
    mute: f32 = 0.55,
    pixel: f32 = 30.0,
    contour: bool = false,

    // Frame snapshot for the compute pass (FrameState slices aren't
    // guaranteed to outlive update()).
    windows: [max_windows]shader_mod.ShaderProgram.WindowRect = undefined,
    window_count: u8 = 0,
    palette: ?*const palette_mod.Palette = null,
    palette_uploaded: bool = false,

    /// GL resources — created lazily on first upload, when GL is current.
    field_tex: c.GLuint = 0,
    canvas_tex: c.GLuint = 0,
    fbo: c.GLuint = 0,
    canvas_w: c.GLsizei = 0,
    canvas_h: c.GLsizei = 0,
    compute: ?shader_mod.ShaderProgram = null,

    // Cached uniform locations on the compute program.
    loc_field: c.GLint = -1,
    loc_pixel: c.GLint = -1,
    loc_time: c.GLint = -1,
    loc_beat: c.GLint = -1,
    loc_bass: c.GLint = -1,
    loc_energy: c.GLint = -1,
    loc_mute: c.GLint = -1,
    loc_contour: c.GLint = -1,

    // Cached location on the main (upscale) program.
    cached_main: c.GLuint = 0,
    loc_canvas: c.GLint = -1,

    pub fn init(allocator: std.mem.Allocator, width: f32, height: f32, params: config_mod.EffectParams) !Context {
        const audio = try audio_mod.spawn(allocator, params);
        errdefer audio_mod.shutdown(audio, allocator);

        const accum = try allocator.create(Accum);
        accum.* = std.mem.zeroes(Accum);

        const count: u32 = @intCast(std.math.clamp(params.getInt("count", 240), 0, boids_mod.max_boids));

        var sys = boids_mod.BoidSystem.init(count, width, height);
        sys.base_speed = params.getFloat("speed", 220.0);
        sys.perception = params.getFloat("perception", 240.0);
        sys.separation_dist = params.getFloat("separation", 54.0);

        return .{
            .audio = audio,
            .sys = sys,
            .allocator = allocator,
            .accum = accum,
            .mute = params.getFloat("mute", 0.55),
            .pixel = std.math.clamp(params.getFloat("pixel", 30.0), 1.0, 120.0),
            .contour = params.getBool("contour", false),
        };
    }

    pub fn update(self: *Context, state: effects.FrameState) void {
        const dt = @min(state.dt, 0.05);
        self.now += dt;
        const wave = self.audio.getWaveform();

        // 6 spectrum bands + beat detection (same as glitch.zig, bands.zig)
        const beat_hit = self.an.update(&wave, dt);
        var punch: f32 = 1.0;
        if (beat_hit)
            punch = std.math.clamp(self.an.flux / (self.an.flux_avg * 3.0 + 0.03), 1.0, 2.0);

        // Silence settles the flock; sound lifts it. Roost ramps in slowly
        // (the birds drift down over a few seconds) but releases fast.
        if (self.an.energy < 0.05) {
            self.quiet_t += dt;
        } else {
            self.quiet_t = @max(0.0, self.quiet_t - dt * 6.0);
        }
        const roost_target: f32 = std.math.clamp((self.quiet_t - 4.0) / 3.0, 0.0, 1.0);
        const roost_prev = self.roost;
        const roost_k: f32 = if (roost_target > self.roost) 0.5 else 2.5;
        self.roost += (roost_target - self.roost) * @min(1.0, roost_k * dt);
        // The frame the roost breaks, the flock explodes off its perches.
        const burst = roost_prev > 0.55 and self.roost <= 0.55;

        // Flock + predator simulation
        self.sys.update(dt, state.cursor[0], state.cursor[1], state.collision_rects, .{
            .bass = self.an.bass,
            .beat = self.an.beat,
            .beat_hit = beat_hit,
            .punch = punch,
            .total_energy = self.an.energy,
            .roost = self.roost,
            .burst = burst,
        });

        // Snapshot what the compute pass needs.
        self.window_count = @intCast(@min(state.windows.len, max_windows));
        for (0..self.window_count) |i| self.windows[i] = state.windows[i];
        if (state.palette) |p| {
            if (self.palette != p) self.palette_uploaded = false;
            self.palette = p;
        }

        self.splatField();
    }

    /// Rasterize the flock into the density/velocity/agitation field.
    /// Each boid drops a 7x7 gaussian; velocity is density-weighted so the
    /// shader can streak the cloud along local motion.
    fn splatField(self: *Context) void {
        const a = self.accum;
        @memset(&a.dens, 0);
        @memset(&a.velx, 0);
        @memset(&a.vely, 0);
        @memset(&a.agit, 0);

        const sx = @as(f32, field_w) / self.sys.width;
        const sy = @as(f32, field_h) / self.sys.height;

        for (0..self.sys.count) |i| {
            const b = self.sys.boids[i];
            const fx = b.x * sx;
            const fy = b.y * sy;
            const cx: i32 = @intFromFloat(@floor(fx));
            const cy: i32 = @intFromFloat(@floor(fy));

            var oy: i32 = -3;
            while (oy <= 3) : (oy += 1) {
                var ox: i32 = -3;
                while (ox <= 3) : (ox += 1) {
                    const gx = cx + ox;
                    const gy = cy + oy;
                    if (gx < 0 or gx >= field_w or gy < 0 or gy >= field_h) continue;
                    const dx = (@as(f32, @floatFromInt(gx)) + 0.5) - fx;
                    const dy = (@as(f32, @floatFromInt(gy)) + 0.5) - fy;
                    const w = @exp(-(dx * dx + dy * dy) * 0.22);
                    const idx: usize = @intCast(gy * field_w + gx);
                    a.dens[idx] += w;
                    a.velx[idx] += b.vx * w;
                    a.vely[idx] += b.vy * w;
                    a.agit[idx] += b.agit * w;
                }
            }
        }

        // Pack to RGBA8: R/G = density-weighted velocity (biased ±vel_scale),
        // B = agitation, A = soft-saturated density.
        for (0..field_cells) |i| {
            const d = a.dens[i];
            var vx: f32 = 0;
            var vy: f32 = 0;
            var ag: f32 = 0;
            if (d > 0.001) {
                vx = std.math.clamp(a.velx[i] / d / vel_scale, -1.0, 1.0);
                vy = std.math.clamp(a.vely[i] / d / vel_scale, -1.0, 1.0);
                ag = std.math.clamp(a.agit[i] / d, 0.0, 1.0);
            }
            const dens = 1.0 - @exp(-d * 0.55);
            a.bytes[i * 4 + 0] = @intFromFloat((vx * 0.5 + 0.5) * 255.0);
            a.bytes[i * 4 + 1] = @intFromFloat((vy * 0.5 + 0.5) * 255.0);
            a.bytes[i * 4 + 2] = @intFromFloat(ag * 255.0);
            a.bytes[i * 4 + 3] = @intFromFloat(dens * 255.0);
        }
    }

    fn ensureGl(self: *Context) bool {
        if (self.compute != null) return true;

        self.compute = shader_mod.ShaderProgram.init(compute_frag) catch return false;
        const cp = &self.compute.?;
        self.loc_field = c.glGetUniformLocation(cp.program, "iField");
        self.loc_pixel = c.glGetUniformLocation(cp.program, "iPixel");
        self.loc_time = c.glGetUniformLocation(cp.program, "iSwarmTime");
        self.loc_beat = c.glGetUniformLocation(cp.program, "iBeat");
        self.loc_bass = c.glGetUniformLocation(cp.program, "iBass");
        self.loc_energy = c.glGetUniformLocation(cp.program, "iEnergy");
        self.loc_mute = c.glGetUniformLocation(cp.program, "iMute");
        self.loc_contour = c.glGetUniformLocation(cp.program, "iContour");

        c.glGenTextures(1, &self.field_tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.field_tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, field_w, field_h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

        // Canvas: one texel per block, nearest-upscaled by the main shader,
        // which is what keeps the blocks razor sharp.
        self.canvas_w = @intFromFloat(@ceil(self.sys.width / self.pixel));
        self.canvas_h = @intFromFloat(@ceil(self.sys.height / self.pixel));
        c.glGenTextures(1, &self.canvas_tex);
        c.glBindTexture(c.GL_TEXTURE_2D, self.canvas_tex);
        c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, self.canvas_w, self.canvas_h, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, null);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

        c.glGenFramebuffers(1, &self.fbo);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glFramebufferTexture2D(c.GL_FRAMEBUFFER, c.GL_COLOR_ATTACHMENT0, c.GL_TEXTURE_2D, self.canvas_tex, 0);
        const status = c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);
        return status == c.GL_FRAMEBUFFER_COMPLETE;
    }

    pub fn upload(self: *Context, prog: *const shader_mod.ShaderProgram) void {
        if (!self.ensureGl()) return;
        const cp = &self.compute.?;

        // ---- compute pass: render the effect at one fragment per block ----
        c.glUseProgram(cp.program);

        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.field_tex);
        c.glTexSubImage2D(c.GL_TEXTURE_2D, 0, 0, 0, field_w, field_h, c.GL_RGBA, c.GL_UNSIGNED_BYTE, &self.accum.bytes[0]);
        if (self.loc_field >= 0) c.glUniform1i(self.loc_field, 0);

        if (self.palette) |p| {
            if (!self.palette_uploaded) {
                cp.setPalette(p);
                self.palette_uploaded = true;
                c.glUseProgram(cp.program);
            }
        }

        if (cp.i_resolution >= 0) c.glUniform3f(cp.i_resolution, self.sys.width, self.sys.height, 1.0);
        for (0..self.window_count) |i| {
            if (cp.i_windows[i] >= 0) {
                const w = self.windows[i];
                c.glUniform4f(cp.i_windows[i], w.x, w.y, w.w, w.h);
            }
        }
        if (cp.i_window_count >= 0) c.glUniform1i(cp.i_window_count, self.window_count);

        if (self.loc_pixel >= 0) c.glUniform1f(self.loc_pixel, self.pixel);
        // Effect-local time (fire.zig pattern) for noise precision.
        if (self.loc_time >= 0) c.glUniform1f(self.loc_time, self.now);
        if (self.loc_beat >= 0) c.glUniform1f(self.loc_beat, self.an.beat);
        if (self.loc_bass >= 0) c.glUniform1f(self.loc_bass, self.an.bass);
        if (self.loc_energy >= 0) c.glUniform1f(self.loc_energy, self.an.energy);
        if (self.loc_mute >= 0) c.glUniform1f(self.loc_mute, self.mute);
        if (self.loc_contour >= 0) c.glUniform1f(self.loc_contour, if (self.contour) 1.0 else 0.0);

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, self.fbo);
        c.glViewport(0, 0, self.canvas_w, self.canvas_h);
        c.glBindVertexArray(cp.vao);
        c.glDrawArrays(c.GL_TRIANGLES, 0, 3);
        c.glBindFramebuffer(c.GL_FRAMEBUFFER, 0);

        // ---- main pass setup: hand the canvas to the upscale shader ----
        c.glUseProgram(prog.program);
        if (self.cached_main != prog.program) {
            self.cached_main = prog.program;
            self.loc_canvas = c.glGetUniformLocation(prog.program, "iCanvas");
        }
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, self.canvas_tex);
        if (self.loc_canvas >= 0) c.glUniform1i(self.loc_canvas, 0);
    }

    pub fn deinit(self: *Context) void {
        if (self.fbo != 0) c.glDeleteFramebuffers(1, &self.fbo);
        if (self.canvas_tex != 0) c.glDeleteTextures(1, &self.canvas_tex);
        if (self.field_tex != 0) c.glDeleteTextures(1, &self.field_tex);
        if (self.compute) |*cp| cp.deinit();
        audio_mod.shutdown(self.audio, self.allocator);
        self.allocator.destroy(self.accum);
    }
};
