//! The GL side of the daemon: the EGL context, the fragment shader program,
//! the active effect, the theme palette bound into the shader, and the size
//! of the surface they draw on.
//!
//! Everything that tears the pipeline down or builds it back up goes through
//! here, so the ordering rules live in one place:
//!
//! - An effect's GL names belong to the context that was current when the
//!   effect created them (lazily, on its first `upload`). It is deinited
//!   while THAT context is still current — after the context is destroyed,
//!   GL reissues the same names to whatever is created next, and a late
//!   glDelete* would free the new owner's objects.
//! - `Effect.init` touches no GL, so the replacement effect is built before
//!   anything is torn down, and a failure leaves the old pipeline intact.
//! - A rebuilt surface is primed (drawn and swapped once) before the main
//!   loop waits on a frame callback; see `prime`.

const std = @import("std");
const iohelp = @import("core/io_helper.zig");
const wayland = @import("core/wayland.zig");
const egl_mod = @import("core/egl.zig");
const shader_mod = @import("core/shader.zig");
const hypr = @import("core/hypr.zig");
const palette_mod = @import("core/palette.zig");
const transition = @import("core/transition.zig");
const config_mod = @import("core/config.zig");
const effects = @import("effects.zig");

const log = std.log.scoped(.hyprglaze);

const WindowRect = shader_mod.ShaderProgram.WindowRect;

/// What a frame draws besides the effect: the focus/cursor transition and
/// the window rects, both owned by the main loop.
pub const Scene = struct {
    trans: *const transition.TransitionState,
    windows: *const [hypr.max_visible_windows]WindowRect,
    window_count: u8,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    /// main's config. The struct is replaced in place on a reload, so the
    /// pointer stays valid.
    cfg: *const config_mod.Config,
    egl: egl_mod.EglState,
    prog: shader_mod.ShaderProgram,
    /// Null only between `release` and the next `rebuild`, while there is no
    /// surface and so no context for an effect's GL names to live in.
    effect: ?effects.Effect,
    /// CLI name of the effect variant running (or, while released, last
    /// running). Static: comes from `Effect.cliNameOf`.
    effect_name: []const u8,
    pal: ?palette_mod.Palette,
    /// Expanded path of the loaded fragment shader, owned.
    shader_path: []const u8,
    /// Whether `egl` and `prog` are live.
    gl_live: bool,
    /// Surface size in BUFFER pixels, which on a scaled output are larger
    /// than the logical size the layer surface was configured with —
    /// glViewport, iResolution and the layout-to-surface transform all work
    /// in this one unit.
    width: f32,
    height: f32,
    scale: f32,
    /// Launch fade origin, on main's clock. Reset by every rebuild, so a
    /// rebuilt surface fades in from the background like a launch.
    fade_start: f64 = 0,
    /// The surface changed size (or was rebuilt), so window rects cached in
    /// surface space were flipped about a stale height. Consumed by main.
    rects_stale: bool = false,
    /// Bounded retries for a failed effect resize; see `resize`.
    resize_retries: u8 = 0,

    /// Build the pipeline on a configured surface with an EGL window: the
    /// context, the effect at the real buffer size, and the shader. main has
    /// already resolved and read the shader (`shader_path`, expanded; copied
    /// here) so that a bad path fails before Wayland is touched.
    pub fn init(
        allocator: std.mem.Allocator,
        cfg: *const config_mod.Config,
        wl: *wayland.WaylandState,
        pal: ?palette_mod.Palette,
        shader_path: []const u8,
        frag_source: [:0]const u8,
    ) !Renderer {
        var egl = egl_mod.EglState.init(wl.display, wl.egl_window.?) catch |err| {
            log.err("EGL init failed: {}", .{err});
            return err;
        };
        errdefer egl.deinit();

        const w: f32 = @floatFromInt(wl.buffer_width);
        const h: f32 = @floatFromInt(wl.buffer_height);
        const s = wl.scale();
        wl.resize_pending = false;
        wl.scale_changed = false;
        if (s != 1.0)
            log.info("rendering at {d}x{d} for a {d}x{d} surface (scale {d:.2})", .{
                wl.buffer_width, wl.buffer_height, wl.width, wl.height, s,
            });

        var effect = effects.Effect.init(cfg.effect, allocator, w, h, cfg) catch |err| {
            log.err("effect init failed: {}", .{err});
            return err;
        };
        errdefer effect.deinit();

        const path = try allocator.dupe(u8, shader_path);
        errdefer allocator.free(path);

        var prog = shader_mod.ShaderProgram.init(frag_source) catch |err| {
            log.err("shader compilation failed: {}", .{err});
            return err;
        };
        errdefer prog.deinit();
        if (pal) |*p| prog.setPalette(p);

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .egl = egl,
            .prog = prog,
            .effect = effect,
            .effect_name = effect.cliNameOf(),
            .pal = pal,
            .shader_path = path,
            .gl_live = true,
            .width = w,
            .height = h,
            .scale = s,
        };
    }

    /// Effect, then program, then context: each GL object is released while
    /// the context that owns it is still current.
    pub fn deinit(self: *Renderer) void {
        self.release();
        self.allocator.free(self.shader_path);
    }

    /// The running effect. Only valid while the pipeline is built, which is
    /// whenever the main loop is drawing.
    pub fn fx(self: *Renderer) *effects.Effect {
        return &self.effect.?;
    }

    pub fn palette(self: *const Renderer) ?*const palette_mod.Palette {
        return if (self.pal) |*p| p else null;
    }

    /// Drop the whole GL pipeline while its context is still current. For
    /// when the surface under the context is about to go (the output was
    /// lost, the Wayland connection died): the EGL surface sits on the
    /// wl_egl_window, so it has to be destroyed first. Idempotent; `rebuild`
    /// brings everything back.
    pub fn release(self: *Renderer) void {
        if (self.effect) |*e| e.deinit();
        self.effect = null;
        if (self.gl_live) {
            self.prog.deinit();
            self.egl.deinit();
            self.gl_live = false;
        }
    }

    /// Rebuild the pipeline on `wl`'s current surface and prime it. The one
    /// recovery path: Wayland reconnect, output return, lost context, and a
    /// wedged swap chain all come through here. `why` is for the log.
    ///
    /// Order (see the file comment): fresh effect first, then the old effect
    /// while its context is current, then context and program, then install
    /// and upload. On error nothing is half-installed: the pipeline is left
    /// released and the caller is expected to exit.
    pub fn rebuild(self: *Renderer, wl: *wayland.WaylandState, scene: Scene, now: f64, why: []const u8) !void {
        self.rebuildInner(wl) catch |err| {
            log.err("graphics rebuild failed ({s}): {}", .{ why, err });
            return err;
        };
        self.width = @floatFromInt(wl.buffer_width);
        self.height = @floatFromInt(wl.buffer_height);
        self.scale = wl.scale();
        // The flags are consumed here; the effect was just built at the new
        // size.
        wl.resize_pending = false;
        wl.scale_changed = false;
        self.rects_stale = true;
        self.resize_retries = 0;
        self.fade_start = now;
        try self.prime(wl, scene);
    }

    fn rebuildInner(self: *Renderer, wl: *wayland.WaylandState) !void {
        var fresh = effects.Effect.init(
            self.effect_name,
            self.allocator,
            @floatFromInt(wl.buffer_width),
            @floatFromInt(wl.buffer_height),
            self.cfg,
        ) catch |err| {
            // Keeping the old effect is not an option: its GL names die with
            // the context below.
            log.err("effect '{s}' could not be rebuilt: {}", .{ self.effect_name, err });
            return err;
        };
        errdefer fresh.deinit();

        self.release();

        self.egl = try egl_mod.EglState.init(wl.display, wl.egl_window.?);
        errdefer self.egl.deinit();
        self.prog = try compileShader(self.allocator, self.shader_path);
        self.gl_live = true;
        if (self.pal) |*p| self.prog.setPalette(p);

        self.effect = fresh;
        self.effect.?.upload(&self.prog);
    }

    /// First frame on a fresh surface: draw and swap BEFORE waiting on a
    /// frame callback. A compositor sends no callbacks for a surface that has
    /// never committed a buffer, so requesting one first and then waiting for
    /// it in the loop deadlocks the daemon on a surface that never draws.
    /// The frame is at time 0 into the fade: the bare background, which the
    /// fade then rises out of.
    pub fn prime(self: *Renderer, wl: *wayland.WaylandState, scene: Scene) !void {
        self.fx().upload(&self.prog);
        try wl.requestFrame();
        self.draw(scene, 0.0, transition.fadeIn(0.0, self.cfg.fade_in));
        self.egl.swapBuffers() catch |err| log.warn("first swapBuffers on a new surface failed: {}", .{err});
    }

    /// Launch-fade level at `now` on main's clock.
    pub fn fadeAt(self: *const Renderer, now: f64) f32 {
        return transition.fadeIn(now - self.fade_start, self.cfg.fade_in);
    }

    pub fn draw(self: *Renderer, scene: Scene, time: f32, fade: f32) void {
        const trans = scene.trans;
        // Resolve focused / previously-focused window indices by address —
        // reliable during motion where smoothed iWindow.xy lags behind raw
        // positions.
        var focused_index: i32 = -1;
        var prev_index: i32 = -1;
        for (0..scene.window_count) |i| {
            const addr = scene.windows[i].address;
            if (addr == 0) continue;
            if (addr == trans.focused_address) focused_index = @intCast(i);
            if (addr == trans.prev_focused_address) prev_index = @intCast(i);
        }

        self.prog.draw(.{
            .width = self.width,
            .height = self.height,
            .time = time,
            .mouse_x = trans.current_cursor[0],
            .mouse_y = trans.current_cursor[1],
            .win_x = trans.current_win.x,
            .win_y = trans.current_win.y,
            .win_w = trans.current_win.w,
            .win_h = trans.current_win.h,
            .transition = trans.transition_progress,
            .windows = scene.windows.*,
            .window_count = scene.window_count,
            .focused_index = focused_index,
            .prev_index = prev_index,
            .fade = fade,
            .fade_bg = self.fadeBg(),
        });
    }

    pub fn swap(self: *Renderer) !void {
        return self.egl.swapBuffers();
    }

    /// The color the launch fade starts from: the theme background, or a
    /// near-black when no theme is loaded.
    fn fadeBg(self: *const Renderer) [3]f32 {
        if (self.pal) |p| return .{ p.background.r, p.background.g, p.background.b };
        return .{ 0.02, 0.02, 0.02 };
    }

    /// Follow a change in the surface's buffer size or scale. Effects capture
    /// their bounds at init — milkdrop sizes its FBOs, swarm its flock layer — so
    /// any change to the buffer size rebuilds the effect, not just a scale
    /// change. Returns false when the effect rebuild failed and should be
    /// retried on a later frame (the Wayland flags are left set for that).
    pub fn resize(self: *Renderer, wl: *wayland.WaylandState) bool {
        const new_w: f32 = @floatFromInt(wl.buffer_width);
        const new_h: f32 = @floatFromInt(wl.buffer_height);
        const dims_changed = new_w != self.width or new_h != self.height;
        self.width = new_w;
        self.height = new_h;
        self.scale = wl.scale();
        // Window rects are cached in surface space, and the y-flip that
        // produced them used the OLD height. A resize emits no new watcher
        // snapshot, so without this they would stay flipped about the
        // previous surface for as long as no window happens to move.
        if (dims_changed) self.rects_stale = true;
        if (dims_changed and !self.resizeEffect()) {
            // A transient failure (an FBO allocation losing a race with
            // something else on the GPU) would otherwise strand the effect at
            // the old size for the life of the process, since nothing
            // re-raises the flag. Retry on the next frames, bounded so a
            // permanent failure does not spin.
            if (self.resize_retries < 3) {
                self.resize_retries += 1;
                return false;
            }
            log.err("effect stuck at the old size after {d} attempts", .{self.resize_retries});
        }
        self.resize_retries = 0;
        wl.resize_pending = false;
        wl.scale_changed = false;
        return true;
    }

    /// Re-init the running effect at the current size, in place. The context
    /// is live, so the old effect's GL names are released where they belong.
    ///
    /// The replacement is built from the live variant, not from
    /// `cfg.effect`: a reload that fell back to another effect leaves those
    /// two disagreeing. On failure the existing effect keeps running at the
    /// old size, which is wrong but visible, rather than taking the
    /// wallpaper down.
    fn resizeEffect(self: *Renderer) bool {
        const fresh = effects.Effect.init(self.effect_name, self.allocator, self.width, self.height, self.cfg) catch |err| {
            log.warn("effect resize to {d}x{d} failed: {} — keeping the old size", .{ self.width, self.height, err });
            return false;
        };
        self.install(fresh);
        return true;
    }

    fn install(self: *Renderer, fresh: effects.Effect) void {
        if (self.effect) |*old| old.deinit();
        self.effect = fresh;
        self.effect_name = fresh.cliNameOf();
    }

    /// Apply the renderer half of a config reload: theme, effect (always
    /// re-initialised, so per-effect params apply even when the effect name
    /// is unchanged), and shader. `old` is the config still in force, `new`
    /// the one being loaded; the caller commits `new` only on success. The
    /// new effect is built before the old one is torn down, so if it fails
    /// the running effect stays intact.
    pub fn applyConfig(self: *Renderer, old: *const config_mod.Config, new: *const config_mod.Config) !void {
        if (!strEql(old.theme, new.theme)) {
            if (new.theme) |theme_name| {
                self.pal = try palette_mod.loadTheme(self.allocator, theme_name);
                log.info("theme reloaded: {s}", .{theme_name});
            } else {
                self.pal = null;
            }
        }

        const fresh = effects.Effect.init(new.effect, self.allocator, self.width, self.height, new) catch |err| {
            log.warn("effect '{s}' failed: {} — keeping the current effect", .{ new.effect, err });
            return err;
        };
        const name_changed = !std.mem.eql(u8, old.effect, new.effect);
        self.install(fresh);
        log.info("effect {s}: {s}", .{ if (name_changed) "switched" else "reloaded", new.effect });

        // Shader — explicit config, else the effect's default.
        const desired = if (new.shader.len > 0) new.shader else self.fx().defaultShader();
        const new_path = try config_mod.expandHome(self.allocator, desired);
        if (std.mem.eql(u8, new_path, self.shader_path)) {
            self.allocator.free(new_path);
            if (self.pal) |*p| self.prog.setPalette(p);
            return;
        }
        errdefer self.allocator.free(new_path);
        var new_prog = try compileShader(self.allocator, new_path);
        if (self.pal) |*p| new_prog.setPalette(p);
        self.prog.deinit();
        self.prog = new_prog;
        log.info("shader reloaded: {s}", .{new_path});
        self.allocator.free(self.shader_path);
        self.shader_path = new_path;
    }
};

fn strEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn compileShader(allocator: std.mem.Allocator, path: []const u8) !shader_mod.ShaderProgram {
    const source = try loadShaderFile(allocator, path);
    defer allocator.free(source);
    return shader_mod.ShaderProgram.init(source);
}

/// Read a fragment shader: CWD-relative or absolute, else from the system
/// data dir (see `iohelp.resolveDataPath`).
pub fn loadShaderFile(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    var resolve_buf: [512]u8 = undefined;
    const resolved = iohelp.resolveDataPath(path, &resolve_buf) orelse path;
    return iohelp.readFileAlloc0(allocator, resolved, 1024 * 1024);
}
