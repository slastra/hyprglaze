const std = @import("std");
const builtin = @import("builtin");
const iohelp = @import("core/io_helper.zig");
const wayland = @import("core/wayland.zig");
const egl_mod = @import("core/egl.zig");
const shader_mod = @import("core/shader.zig");
const hypr = @import("core/hypr.zig");
const palette_mod = @import("core/palette.zig");
const transition = @import("core/transition.zig");
const geometry = @import("core/geometry.zig");
const workspace_slide = @import("core/workspace_slide.zig");
const config_mod = @import("core/config.zig");
const watcher_mod = @import("core/watcher.zig");
const hypr_events = @import("core/hypr_events.zig");
const effects = @import("effects.zig");
const particles = @import("effects/particles/system.zig");

pub const std_options: std.Options = .{ .log_level = .info };
const log = std.log.scoped(.hyprglaze);

var should_exit = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    should_exit.store(true, .release);
}

const CliArgs = struct {
    output: ?[]const u8 = null,
    shader_path: ?[]const u8 = null,
    theme_name: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    effect_name: ?[]const u8 = null,
    set_theme: ?[]const u8 = null,
    list_themes: bool = false,
    list_effects: bool = false,
    fps: bool = false,
};

pub fn main(init: std.process.Init.Minimal) !void {
    // Leak-checking allocator in Debug; lock-cheap smp_allocator in
    // release, where DebugAllocator's metadata and mutex are pure cost.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.smp_allocator;

    const sig_act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sig_act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sig_act, null);

    const cli = try parseCli(allocator, init.args.vector);
    defer {
        if (cli.shader_path) |p| allocator.free(p);
        if (cli.theme_name) |t| allocator.free(t);
        if (cli.config_path) |p| allocator.free(p);
        if (cli.effect_name) |e| allocator.free(e);
        if (cli.set_theme) |t| allocator.free(t);
        if (cli.output) |o| allocator.free(o);
    }

    if (cli.list_themes) {
        try palette_mod.listThemes(allocator);
        return;
    }
    if (cli.list_effects) {
        try effects.listEffects();
        return;
    }
    if (cli.set_theme) |name| {
        const path = config_mod.resolveConfigPath(allocator) catch |err| switch (err) {
            error.ConfigNotFound => blk: {
                const home_z = std.c.getenv("HOME") orelse return error.NoHomeDir;
                const home = std.mem.span(home_z);
                break :blk try std.fmt.allocPrint(allocator, "{s}/.config/hypr/hyprglaze.toml", .{home});
            },
            else => return err,
        };
        defer allocator.free(path);
        try config_mod.setTheme(allocator, path, name);
        log.info("theme set to '{s}' in {s}", .{ name, path });
        return;
    }

    // Load config
    var cfg = try loadConfig(allocator, &cli);
    defer config_mod.deinit(&cfg, allocator);

    // Init effect
    var effect = effects.Effect.init(cfg.effect, allocator, 0, 0, &cfg) catch |err| {
        log.err("effect init failed: {}", .{err});
        return err;
    };
    defer effect.deinit();

    // Resolve shader: explicit config > effect default
    const shader_path = if (cfg.shader.len > 0) cfg.shader else effect.defaultShader();
    log.info("effect: {s}", .{cfg.effect});
    log.info("shader: {s}", .{shader_path});
    if (cfg.theme) |t| log.info("theme: {s}", .{t});

    var shader_path_expanded = try config_mod.expandHome(allocator, shader_path);
    defer allocator.free(shader_path_expanded);

    const frag_source = loadShaderFile(allocator, shader_path_expanded) catch |err| {
        log.err("failed to load shader '{s}': {}", .{ shader_path_expanded, err });
        return err;
    };
    defer allocator.free(frag_source);

    // Palette
    var pal: ?palette_mod.Palette = null;
    if (cfg.theme) |theme_name| {
        pal = palette_mod.loadTheme(allocator, theme_name) catch |err| {
            log.err("failed to load theme '{s}': {}", .{ theme_name, err });
            return err;
        };
        log.info("palette: {s} ({d} colors)", .{ pal.?.themeName(), pal.?.color_count });
    }

    // Hyprland IPC
    const ipc = hypr.HyprIpc.init() catch |err| {
        log.err("Hyprland IPC init failed: {}", .{err});
        return err;
    };

    // `var`: an unpinned daemon that loses its output may move to another.
    var mon = ipc.monitor(allocator, cfg.output) catch |err| {
        if (err == error.MonitorNotFound) {
            log.err("no output named '{s}'", .{cfg.output.?});
            ipc.logMonitorNames(allocator);
        } else {
            log.err("failed to query monitor: {}", .{err});
        }
        return err;
    };
    log.info("output: {s} {d}x{d} @({d},{d}) scale={d:.2}", .{
        mon.outputName(), mon.width, mon.height, mon.x, mon.y, mon.scale,
    });

    // Detect Hyprland's workspace animation so switches mirror the
    // compositor's own slide (direction, duration, easing). Refreshed on
    // Hyprland config reloads; config overrides applied on top.
    var detected_anim: ?hypr.WorkspaceAnim = ipc.workspaceAnim(allocator) catch |err| blk: {
        log.warn("workspace animation detection failed: {} — using defaults", .{err});
        break :blk null;
    };

    // Subscribe to Hyprland's event stream so focus / lifecycle / workspace
    // changes are instant rather than detected via the every-100ms poll.
    var events = hypr_events.HyprEvents.init() catch |err| {
        log.err("Hyprland events init failed: {}", .{err});
        return err;
    };
    defer events.deinit();

    // Wayland. Two-phase init: `wl`'s address becomes listener userdata,
    // so it must live here, not in a temporary inside init().
    var wl: wayland.WaylandState = undefined;
    wl.init(mon.outputName()) catch |err| {
        log.err("Wayland init failed: {}", .{err});
        return err;
    };
    defer wl.deinit();

    wl.createLayerSurface() catch |err| {
        if (err == error.OutputNotFound) {
            // Hyprland knows this monitor but Wayland does not advertise a
            // matching output — the discrepancy between the two lists is the
            // diagnosis, so print both.
            log.err("Hyprland reports output '{s}' but no matching wl_output exists", .{mon.outputName()});
            wl.logOutputNames();
        } else {
            log.err("layer surface creation failed: {}", .{err});
        }
        return err;
    };

    if (!wl.configured) return error.NotConfigured;
    log.info("surface configured: {d}x{d}", .{ wl.width, wl.height });

    wl.createEglWindow() catch |err| {
        log.err("EGL window creation failed: {}", .{err});
        return err;
    };

    var egl_state = egl_mod.EglState.init(wl.display, wl.egl_window.?) catch |err| {
        log.err("EGL init failed: {}", .{err});
        return err;
    };
    defer egl_state.deinit();

    // Shader
    var shader_prog = shader_mod.ShaderProgram.init(frag_source) catch |err| {
        log.err("shader compilation failed: {}", .{err});
        return err;
    };
    defer shader_prog.deinit();

    if (pal) |*p| shader_prog.setPalette(p);

    // Re-init effect with actual dimensions. These are BUFFER pixels, which
    // on a scaled output are larger than the logical size the layer surface
    // was configured with — everything downstream (glViewport, iResolution,
    // the layout-to-surface transform) works in this one unit.
    var surf_w: f32 = @floatFromInt(wl.buffer_width);
    var surf_h: f32 = @floatFromInt(wl.buffer_height);
    var surf_scale: f32 = wl.scale();
    wl.scale_changed = false;
    if (surf_scale != 1.0)
        log.info("rendering at {d}x{d} for a {d}x{d} surface (scale {d:.2})", .{
            wl.buffer_width, wl.buffer_height, wl.width, wl.height, surf_scale,
        });
    // Via rebuildEffect rather than deinit-then-init: on a large output this
    // is the first allocation at real size and can fail, and the naive order
    // would leave `effect` holding a deinited union for the `defer` above to
    // free a second time. Effect.deinit has no idempotence guard.
    _ = rebuildEffect(allocator, &effect, &cfg, surf_w, surf_h);

    log.info("entering render loop", .{});

    // Transition
    var trans = transition.TransitionState.init();
    trans.transition_duration = cfg.transition_duration;
    trans.cursor_smoothing = cfg.cursor_smoothing;
    trans.geometry_smoothing = cfg.geometry_smoothing;

    // Workspace slide state + the outgoing window set captured at each
    // workspace switch (slides off-screen while the new set slides in).
    var slide = workspace_slide.WorkspaceSlide{};
    configureSlide(&slide, detected_anim, &cfg);
    switch (slide.ease) {
        .spring => |sp| log.info("workspace slide: {s}, spring k={d:.1} c={d:.1} m={d:.1}", .{
            @tagName(slide.axis), sp.stiffness, sp.damping, sp.mass,
        }),
        .cubic_bezier => log.info("workspace slide: {s}, bezier, {d:.0}ms", .{
            @tagName(slide.axis), slide.duration * 1000.0,
        }),
    }
    // Config watcher
    var config_watcher: ?watcher_mod.FileWatcher = null;
    if (cfg.config_path.len > 0) {
        if (config_mod.expandHome(allocator, cfg.config_path) catch null) |acp| {
            config_watcher = watcher_mod.FileWatcher.init(allocator, acp) catch |err| blk: {
                log.warn("config watcher init failed: {} — hot-reload disabled", .{err});
                break :blk null;
            };
            allocator.free(acp);
            if (config_watcher != null)
                log.info("watching config: {s}", .{cfg.config_path});
        }
    }
    defer if (config_watcher) |*w| w.deinit();

    // Frame state
    var prev_time_f64: f64 = 0.0;
    var frame_count: u32 = 0;
    var cached_windows: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect = undefined;
    var cached_collision_rects: [hypr.max_visible_windows]particles.Rect = undefined;
    var cached_window_count: u8 = 0;
    var cached_window_info: [hypr.max_visible_windows]effects.WindowInfo = undefined;
    var cached_focused_class: [64]u8 = [_]u8{0} ** 64;
    var cached_focused_class_len: u8 = 0;
    var cached_focused_title: [64]u8 = [_]u8{0} ** 64;
    var cached_focused_title_len: u8 = 0;
    var fps_timer = try iohelp.Timer.start();
    var timer = try iohelp.Timer.start();
    // Launch fade: reset whenever the surface is rebuilt, so a rebuild fades
    // in from the background like a launch instead of popping.
    var fade_start: f64 = 0.0;

    // Seed: bootstrap the focused-window address once via `j/activewindow`
    // because the event stream only carries future changes, never the
    // current state. From here on, `activewindowv2` events keep
    // `events.focused_address` in sync.
    const initial_focus = ipc.activeWindow(allocator) catch null;
    const initial_addr: u64 = if (initial_focus) |w| w.address else 0;
    events.focused_address.store(initial_addr, .release);

    // Scope the event stream to our output before the reader exists: the
    // shared watcher emits one geometry event per monitor and every other
    // monitor's is dropped. Seed the origin from the startup query so the
    // first frames are already rebased; from the first watcher event on, the
    // origin arrives with the geometry it describes.
    if (mon.name_len == 0) {
        // Without a name there is nothing to filter the shared watcher's
        // per-monitor events by, so this daemon would follow whichever
        // monitor emitted last — the very bug the filter exists to prevent.
        log.err("Hyprland reported a monitor with no name; cannot scope to an output", .{});
        return error.BadMonitorReply;
    }
    events.setMonitor(mon.outputName());
    events.snapshot.origin_x = mon.x;
    events.snapshot.origin_y = mon.y;

    // Start the reader, then install the in-compositor Lua watcher. Its
    // first tick emits cursor + geometry unconditionally, so waiting
    // briefly for the first snapshot gives us a real seed state.
    events.start() catch |err| {
        log.err("Hyprland events thread failed to start: {}", .{err});
        return err;
    };
    installWatcher(&ipc, &events) catch |err| {
        log.err("hyprglaze requires Hyprland >= 0.55 with the Lua config manager (hyprland.lua)", .{});
        return err;
    };
    var wait_ms: u32 = 0;
    while (events.snapshotGen() == 0 and wait_ms < 300) : (wait_ms += 5) {
        iohelp.sleepNs(5 * std.time.ns_per_ms);
    }
    if (events.snapshotGen() == 0)
        log.warn("no snapshot from watcher within 300ms — starting with empty state", .{});
    _ = events.takeDirty(); // clear the initial resync flag — we just installed

    // The snapshot must be read before the cursor is seeded: the cursor is
    // rebased against the monitor origin the snapshot carries.
    var cached_snapshot = hypr.VisibleWindows{};
    var last_snapshot_gen = events.snapshotGen();
    events.copySnapshot(&cached_snapshot);
    slide.seed(cached_snapshot.workspace_id);

    const initial_cursor = events.cursorPos();
    const seed_cursor = geometry.toGlPoint(
        initial_cursor.x,
        initial_cursor.y,
        cached_snapshot.origin_x,
        cached_snapshot.origin_y,
        surf_h,
        surf_scale,
    );

    const raw0 = deriveRawState(
        &cached_snapshot,
        surf_h,
        initial_addr,
        slide.axis,
        if (slide.axis == .vertical) surf_h else surf_w,
        surf_scale,
        null,
        0,
    );
    trans.seed(raw0.win, seed_cursor, raw0.win_address);
    cacheWindows(&cached_windows, &cached_collision_rects, &cached_window_count, &raw0);
    for (0..raw0.window_count) |i| cached_window_info[i] = raw0.window_info[i];
    cached_focused_class = raw0.focused_class;
    cached_focused_class_len = raw0.focused_class_len;
    cached_focused_title = raw0.focused_title;
    cached_focused_title_len = raw0.focused_title_len;
    var cached_raw_win = raw0.win;
    var cached_win_address: u64 = raw0.win_address;

    // Raw window targets for smoothing
    var target_windows: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect = undefined;
    var target_window_count: u8 = raw0.window_count;
    for (0..raw0.window_count) |i| target_windows[i] = raw0.windows[i];

    var cached_cursor: [2]f32 = seed_cursor;

    // Watcher health: reinstall when the heartbeat lapses (config reload
    // recreates the Lua state; someone may also eval it away). Attempts
    // are rate-limited so a genuinely broken install doesn't spam.
    const hb_lapse_ms: i64 = 6000;
    const reinstall_min_gap: f64 = 3.0;
    var last_install_attempt: f64 = 0;

    // Initial render: time 0 into the fade is the bare background.
    effect.upload(&shader_prog);
    try wl.requestFrame();
    drawFrame(&shader_prog, &egl_state, surf_w, surf_h, 0.0, &trans, &cached_windows, cached_window_count, transition.fadeIn(0.0, cfg.fade_in), fadeBg(pal));
    egl_state.swapBuffers() catch |err| log.warn("initial swapBuffers error: {}", .{err});

    // Bounded retries for a failed effect resize; see the resize block.
    var resize_retries: u8 = 0;
    // Set when the surface changed size, to force one re-derive of the cached
    // window rects: they hold surface-space coordinates flipped about the old
    // height, and a resize produces no watcher snapshot to trigger that.
    var surface_resized = false;
    // Workspace slide bookkeeping. `outgoing` is the window set of the
    // workspace being LEFT, captured at the switch and parked one span
    // behind the camera while the slide runs, so what slides out is what
    // Hyprland slides out. The watcher's strip parks the nearest-id
    // neighbor there instead, which is a different workspace whenever the
    // switch jumps more than one (1 → 5 with 3 in between slid 3's windows
    // out). `strip_dirty` forces one re-derive when the slide settles, so
    // the outgoing set is swapped back for the normal strip instead of
    // lingering off-screen as collision rects.
    var prev_snapshot: hypr.VisibleWindows = .{};
    var outgoing: hypr.VisibleWindows = .{};
    var slide_was_active = false;
    var strip_dirty = false;

    // Losing the output. A monitor power cycle (a TV dropping hot-plug
    // detect, a mode change) removes the wl_output and closes the layer
    // surface; the output usually comes back moments later under the same
    // name. Rather than exit, the loop drops the surface, waits for an
    // output, and rebuilds on the same connection. `surface_lost` carries
    // that state across iterations: once the surface is destroyed both
    // Wayland flags are clear again, and the blocking `dispatch` must be
    // skipped (nothing would wake it) in favour of the polled wait.
    var surface_lost = false;
    var lost_since: f64 = 0;
    var last_resurrect_try: f64 = -10;
    const pinned = cfg.output != null;
    // Consecutive eglSwapBuffers failures that were NOT a reported context
    // loss; a driver that wedges the surface without saying so looks like
    // this, and after a few the pipeline is rebuilt anyway.
    var swap_failures: u8 = 0;

    while (!should_exit.load(.acquire)) {
        // Bounded rather than blocking: a compositor that has stopped
        // painting this output (a monitor that is off, a nested session on
        // a hidden workspace) sends no frame callbacks, and a blocking
        // dispatch would then never return to notice a shutdown signal.
        if (!surface_lost) _ = wl.dispatchTimeout(1000) catch |err| {
            if (should_exit.load(.acquire)) break;
            log.warn("Wayland dispatch error: {} — reconnecting in 1s", .{err});
            iohelp.sleepNs(1 * std.time.ns_per_s);
            // Tear EGL down BEFORE reconnect, which destroys the wl_display
            // the EGL surface is built on. Leaving it until afterwards means
            // eglDestroySurface — from recreateGraphics on the way in, or from
            // this function's own `defer` if the reconnect fails — walks into
            // a freed display inside the driver's Wayland platform layer and
            // segfaults. deinit is idempotent, so the later calls are no-ops.
            egl_state.deinit();
            wl.reconnect() catch |e2| {
                log.err("Wayland reconnect failed: {} — exiting", .{e2});
                return e2;
            };
            recreateGraphics(allocator, &egl_state, &shader_prog, &effect, &cfg, &pal, &wl, shader_path_expanded) catch |e2| {
                log.err("graphics reinit failed after Wayland reconnect: {} — exiting", .{e2});
                return e2;
            };
            afterGraphicsReset(&wl, &surf_w, &surf_h, &surf_scale, &surface_resized, &resize_retries, &fade_start, &timer);
            try primeSurface(&wl, &shader_prog, &egl_state, &effect, surf_w, surf_h, &trans, &cached_windows, cached_window_count, &cfg, pal);
            continue;
        };

        if (wl.should_close or wl.target_gone or surface_lost) {
            const now_s = timerSeconds(&timer);
            if (!surface_lost) {
                surface_lost = true;
                lost_since = now_s;
                // EGL first, for the same reason as in the reconnect path:
                // the EGL surface sits on the wl_egl_window about to go.
                egl_state.deinit();
                wl.destroySurface();
                if (cfg.output_wait > 0) {
                    log.warn("output '{s}' lost — waiting up to {d:.0}s for it", .{ wl.targetName(), cfg.output_wait });
                } else {
                    log.warn("output '{s}' lost — waiting indefinitely for an output", .{wl.targetName()});
                }
            }
            const outcome = awaitOutput(&wl, &ipc, allocator, pinned, cfg.output_wait, lost_since, &timer) catch |err| switch (err) {
                // The connection itself died: let the dispatch branch above
                // run its reconnect (which fails and exits if the compositor
                // is truly gone).
                error.DispatchFailed => {
                    surface_lost = false;
                    continue;
                },
                else => return err,
            };
            switch (outcome) {
                .exit => break,
                .same => {},
                .retarget => |new_mon| {
                    mon = new_mon;
                    wl.setTarget(mon.outputName());
                    events.setMonitor(mon.outputName());
                    events.setOrigin(mon.x, mon.y);
                    log.info("moving to output '{s}'", .{mon.outputName()});
                },
            }
            // A resurrect right after a failed one hammers the compositor
            // with surface churn; space retries out a little.
            const since_try = timerSeconds(&timer) - last_resurrect_try;
            if (since_try < 0.25) iohelp.sleepNs(@intFromFloat((0.25 - since_try) * std.time.ns_per_s));
            last_resurrect_try = timerSeconds(&timer);
            wl.resurrect() catch |err| switch (err) {
                error.OutputNotFound, error.NotConfigured => {
                    log.warn("surface rebuild not possible yet ({}) — still waiting", .{err});
                    continue;
                },
                else => return err,
            };
            recreateGraphics(allocator, &egl_state, &shader_prog, &effect, &cfg, &pal, &wl, shader_path_expanded) catch |e2| {
                log.err("graphics reinit failed after the output returned: {} — exiting", .{e2});
                return e2;
            };
            // A moved daemon needs the watcher scoped to its new monitor;
            // for the same output the reinstall is idempotent and re-emits
            // the full state, which the fresh surface needs anyway.
            installWatcher(&ipc, &events) catch |err| {
                log.warn("watcher reinstall after output return failed: {} — the heartbeat check will retry", .{err});
            };
            last_install_attempt = timerSeconds(&timer);
            afterGraphicsReset(&wl, &surf_w, &surf_h, &surf_scale, &surface_resized, &resize_retries, &fade_start, &timer);
            try primeSurface(&wl, &shader_prog, &egl_state, &effect, surf_w, surf_h, &trans, &cached_windows, cached_window_count, &cfg, pal);
            surface_lost = false;
            log.info("output '{s}' is back — surface recreated at {d}x{d}", .{ wl.targetName(), wl.buffer_width, wl.buffer_height });
            continue;
        }

        if (wl.resize_pending or wl.scale_changed) {
            const new_w: f32 = @floatFromInt(wl.buffer_width);
            const new_h: f32 = @floatFromInt(wl.buffer_height);
            // Rebuild on any change to the BUFFER size, not just a scale
            // change. Effects capture their bounds at init — milkdrop sizes
            // its FBOs, swarm its canvas — so a plain resolution change with
            // the scale untouched would leave every one of them drawing at
            // the old dimensions.
            const dims_changed = new_w != surf_w or new_h != surf_h;
            surf_w = new_w;
            surf_h = new_h;
            surf_scale = wl.scale();
            // Window rects are cached in surface space, and the y-flip that
            // produced them used the OLD height. Nothing else re-derives them:
            // a resize emits no new watcher snapshot, so without this the
            // rects stay flipped about the previous surface for as long as no
            // window happens to move — every effect drawing them off by the
            // difference between the two heights.
            if (dims_changed) surface_resized = true;
            if (dims_changed and !rebuildEffect(allocator, &effect, &cfg, surf_w, surf_h)) {
                // A transient failure (an FBO allocation losing a race with
                // something else on the GPU) would otherwise strand the effect
                // at the old size for the life of the process, since nothing
                // re-raises the flag. Retry on the next frames, bounded so a
                // permanent failure does not spin.
                if (resize_retries < 3) {
                    resize_retries += 1;
                    continue;
                }
                log.err("effect stuck at the old size after {d} attempts", .{resize_retries});
            }
            resize_retries = 0;
            wl.resize_pending = false;
            wl.scale_changed = false;
        }

        if (config_watcher) |*cw| {
            if (cw.poll()) {
                log.info("config changed, reloading", .{});
                reloadConfig(allocator, &cfg, &effect, &shader_prog, &pal, &trans, &shader_path_expanded, surf_w, surf_h, mon.outputName()) catch |err| {
                    log.warn("reload failed: {}", .{err});
                };
                configureSlide(&slide, detected_anim, &cfg);
            }
        }

        if (wl.frame_done) {
            const elapsed_ns = timer.read();
            const time_f64: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const dt: f32 = @floatCast(time_f64 - prev_time_f64);
            prev_time_f64 = time_f64;
            // Wrap iTime so the f32 shader uniform never loses precision.
            // 10000s period is invisible: the shader only feeds iTime into
            // sin/cos, which are periodic.
            const time: f32 = @floatCast(@mod(time_f64, 10_000.0));

            // Cursor arrives as push (`hg:cur` events) — reading the
            // atomics is free, so sample every frame.
            const cursor = events.cursorPos();
            cached_cursor = geometry.toGlPoint(
                cursor.x,
                cursor.y,
                cached_snapshot.origin_x,
                cached_snapshot.origin_y,
                surf_h,
                surf_scale,
            );
            const raw_cursor = cached_cursor;

            // Pull focus from the event stream. A change forces an
            // immediate re-derive so geometry/metadata for the new focus
            // arrive on the same frame as the address change.
            const focused_addr = events.focusedAddress();
            const focus_changed = focused_addr != 0 and focused_addr != cached_win_address;
            if (focused_addr != 0) cached_win_address = focused_addr;

            const dirty = events.takeDirty();
            if (dirty.monitor) {
                // No re-query needed: the origin is part of the watcher's
                // change key, so a monitor appearing to our left re-emits our
                // geometry with the corrected origin within one 16ms tick,
                // window event or not.
                log.info("monitor topology changed", .{});
            }
            // Config reload recreates Hyprland's Lua state (killing the
            // watcher); a socket2 reconnect means change-only events may
            // have been missed. Both are fixed by an idempotent reinstall,
            // which re-emits the full state on its first tick. The
            // heartbeat lapse catches anything else that kills the watcher.
            const hb_stale = hypr_events.nowMs() - events.lastHeartbeatMs() > hb_lapse_ms;
            if ((dirty.config or dirty.resync or dirty.legacy or hb_stale) and time_f64 - last_install_attempt >= reinstall_min_gap) {
                last_install_attempt = time_f64;
                if (dirty.config) log.info("Hyprland reloaded its config — reinstalling watcher", .{});
                if (dirty.legacy) log.warn("an older hyprglaze replaced the watcher — reinstalling", .{});
                if (hb_stale) log.warn("watcher heartbeat lapsed — reinstalling", .{});
                installWatcher(&ipc, &events) catch |err| {
                    log.warn("watcher reinstall failed: {} — retrying in {d}s", .{ err, @as(u32, @intFromFloat(reinstall_min_gap)) });
                };
                if (dirty.config) {
                    // The reload may have changed the workspace animation.
                    detected_anim = ipc.workspaceAnim(allocator) catch detected_anim;
                    configureSlide(&slide, detected_anim, &cfg);
                }
            }

            // Re-derive window state when the watcher pushed a new
            // snapshot or focus moved. No polling: during interactive
            // drag/resize the in-compositor watcher sees geometry change
            // every 16ms tick and pushes a fresh snapshot.
            const gen = events.snapshotGen();
            var force_snap = false;
            if (focus_changed or gen != last_snapshot_gen or surface_resized or strip_dirty) {
                surface_resized = false;
                strip_dirty = false;
                if (gen != last_snapshot_gen) {
                    last_snapshot_gen = gen;
                    prev_snapshot = cached_snapshot;
                    events.copySnapshot(&cached_snapshot);
                    // Workspace switch? The strip below rebases around
                    // the new active workspace (every rel shifts by one),
                    // and the camera cancels the resulting jump. The set
                    // that slides out is the one that was active a moment
                    // ago, captured here from the previous snapshot; the
                    // strip's own -1/+1 buckets are the nearest ids, which
                    // is only the same thing for a one-step switch.
                    switch (slide.noteWorkspace(cached_snapshot.workspace_id, time_f64)) {
                        .slide => {
                            captureOutgoing(&outgoing, &prev_snapshot, slide.dir);
                            log.debug("slide: ws {d} -> {d}, {d} outgoing windows", .{ prev_snapshot.workspace_id, cached_snapshot.workspace_id, outgoing.count });
                        },
                        // Workspace changed without a slidable direction
                        // (special workspace, unknown id, slides off):
                        // snap — never glide across a workspace boundary.
                        .snap => force_snap = true,
                        .none => {},
                    }
                }
                const raw = deriveRawState(
                    &cached_snapshot,
                    surf_h,
                    cached_win_address,
                    slide.axis,
                    if (slide.axis == .vertical) surf_h else surf_w,
                    surf_scale,
                    if (slide.active) &outgoing else null,
                    if (slide.active) -@as(i8, @intFromFloat(slide.dir)) else 0,
                );
                target_window_count = raw.window_count;
                for (0..raw.window_count) |i| {
                    target_windows[i] = raw.windows[i];
                    cached_window_info[i] = raw.window_info[i];
                }
                // raw.win_address is non-zero only when the focused window
                // was found in the visible list. When 0 (focus on a
                // different monitor's workspace, or no focus), keep the
                // previous geometry so the wallpaper doesn't snap to the
                // origin.
                if (raw.win_address != 0) {
                    cached_raw_win = raw.win;
                    cached_focused_class = raw.focused_class;
                    cached_focused_class_len = raw.focused_class_len;
                    cached_focused_title = raw.focused_title;
                    cached_focused_title_len = raw.focused_title_len;
                }
            }
            // Sample the camera once per frame (it self-deactivates when
            // the easing settles); the focused-window rect and the strip
            // below reuse the same offset.
            const span: f32 = if (slide.axis == .vertical) surf_h else surf_w;
            const camera = slide.sample(time_f64, span);
            // Settled: swap the outgoing set back for the normal strip on
            // the next frame.
            if (camera == null and slide_was_active) strip_dirty = true;
            slide_was_active = camera != null;

            // While sliding, keep iWindow tracking the focused window's
            // slid-in position instead of pre-snapping to where it will
            // come to rest (focus always lives on the active workspace).
            var raw_focus_win = cached_raw_win;
            if (camera) |cam| {
                applyOffset(&raw_focus_win.x, &raw_focus_win.y, slide.axis, cam);
            }
            trans.update(time_f64, raw_focus_win, raw_cursor, cached_win_address);

            // Smooth all window positions toward targets
            const win_alpha = transition.smoothAlpha(cfg.geometry_smoothing, dt);

            if (camera) |cam| {
                // Workspace slide: the whole strip (targets already carry
                // their rel offsets) shifts by the camera. Positions are
                // analytic — per-frame smoothing is bypassed.
                for (0..target_window_count) |i| {
                    cached_windows[i] = target_windows[i];
                    applyOffset(&cached_windows[i].x, &cached_windows[i].y, slide.axis, cam);
                }
                cached_window_count = target_window_count;
            } else if (target_window_count != cached_window_count or force_snap) {
                // Window count changed or a workspace boundary without a
                // slide — snap all
                for (0..target_window_count) |i| cached_windows[i] = target_windows[i];
                cached_window_count = target_window_count;
            } else {
                // Same count — smooth each cached window toward the
                // target with the same address (Hyprland can reorder
                // windows on focus change; matching by address keeps the
                // pairing stable across the whole strip). Any mismatch
                // means the set changed — snap rather than glide
                // unrelated windows into each other. Also the landing
                // path after a slide settles: the camera's last offset is
                // ≤ 0.1% of a span, smoothed away invisibly.
                var used: [hypr.max_visible_windows]bool = [_]bool{false} ** hypr.max_visible_windows;
                var matched_targets: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect = undefined;
                var all_matched = true;

                match: for (0..target_window_count) |ti| {
                    const addr = target_windows[ti].address;
                    if (addr != 0) {
                        for (0..cached_window_count) |ci| {
                            if (!used[ci] and cached_windows[ci].address == addr) {
                                used[ci] = true;
                                matched_targets[ci] = target_windows[ti];
                                continue :match;
                            }
                        }
                    }
                    all_matched = false;
                    break;
                }

                if (all_matched) {
                    for (0..cached_window_count) |i| {
                        cached_windows[i].x += (matched_targets[i].x - cached_windows[i].x) * win_alpha;
                        cached_windows[i].y += (matched_targets[i].y - cached_windows[i].y) * win_alpha;
                        cached_windows[i].w += (matched_targets[i].w - cached_windows[i].w) * win_alpha;
                        cached_windows[i].h += (matched_targets[i].h - cached_windows[i].h) * win_alpha;
                        cached_windows[i].address = matched_targets[i].address;
                    }
                } else {
                    for (0..target_window_count) |i| cached_windows[i] = target_windows[i];
                    cached_window_count = target_window_count;
                }
            }

            for (0..cached_window_count) |i| {
                cached_collision_rects[i] = .{
                    .x = cached_windows[i].x,
                    .y = cached_windows[i].y,
                    .w = cached_windows[i].w,
                    .h = cached_windows[i].h,
                };
            }

            // Update effect
            effect.update(.{
                .dt = dt,
                .time = time,
                .cursor = trans.current_cursor,
                .focused_win = trans.current_win,
                .windows = cached_windows[0..cached_window_count],
                .collision_rects = cached_collision_rects[0..cached_window_count],
                .window_info = cached_window_info[0..cached_window_count],
                .focused_class = cached_focused_class,
                .focused_class_len = cached_focused_class_len,
                .focused_title = cached_focused_title,
                .focused_title_len = cached_focused_title_len,
                .palette = if (pal) |*p| p else null,
                .workspace_slide = slide.progress(time_f64),
            });
            effect.upload(&shader_prog);

            const fade = transition.fadeIn(time_f64 - fade_start, cfg.fade_in);
            drawFrame(&shader_prog, &egl_state, surf_w, surf_h, time, &trans, &cached_windows, cached_window_count, fade, fadeBg(pal));
            try wl.requestFrame();
            if (egl_state.swapBuffers()) |_| {
                swap_failures = 0;
            } else |err| {
                if (err == error.EglContextLost) {
                    log.warn("EGL context lost — reinitialising graphics", .{});
                    try recreateGraphics(allocator, &egl_state, &shader_prog, &effect, &cfg, &pal, &wl, shader_path_expanded);
                    afterGraphicsReset(&wl, &surf_w, &surf_h, &surf_scale, &surface_resized, &resize_retries, &fade_start, &timer);
                    swap_failures = 0;
                } else {
                    swap_failures +|= 1;
                    log.warn("eglSwapBuffers error: {}", .{err});
                    if (swap_failures >= 3) {
                        log.warn("eglSwapBuffers failed {d}x in a row — reinitialising graphics", .{swap_failures});
                        try recreateGraphics(allocator, &egl_state, &shader_prog, &effect, &cfg, &pal, &wl, shader_path_expanded);
                        afterGraphicsReset(&wl, &surf_w, &surf_h, &surf_scale, &surface_resized, &resize_retries, &fade_start, &timer);
                        swap_failures = 0;
                    }
                }
            }

            // FPS tracking
            if (cli.fps) {
                frame_count += 1;
                if (fps_timer.read() >= std.time.ns_per_s) {
                    log.info("FPS: {d}", .{frame_count});
                    frame_count = 0;
                    fps_timer.reset();
                }
            }
        }
    }
}

/// First frame on a fresh surface: draw and swap BEFORE waiting on a
/// frame callback. A compositor sends no callbacks for a surface that has
/// never committed a buffer, so requesting one first and then waiting for
/// it in the loop deadlocks the daemon on a surface that never draws.
/// Same order as the initial render at startup; the frame is the bare
/// background (fade 0), which the fade then rises out of.
fn primeSurface(
    wl: *wayland.WaylandState,
    shader_prog: *shader_mod.ShaderProgram,
    egl_state: *egl_mod.EglState,
    effect: *effects.Effect,
    surf_w: f32,
    surf_h: f32,
    trans: *transition.TransitionState,
    windows: *const [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect,
    window_count: u8,
    cfg: *const config_mod.Config,
    pal: ?palette_mod.Palette,
) !void {
    effect.upload(shader_prog);
    try wl.requestFrame();
    drawFrame(shader_prog, egl_state, surf_w, surf_h, 0.0, trans, windows, window_count, transition.fadeIn(0.0, cfg.fade_in), fadeBg(pal));
    egl_state.swapBuffers() catch |err| log.warn("first swapBuffers on the rebuilt surface failed: {}", .{err});
}

fn timerSeconds(timer: *iohelp.Timer) f64 {
    return @as(f64, @floatFromInt(timer.read())) / 1_000_000_000.0;
}

/// The color the launch fade starts from: the theme background, or a
/// near-black when no theme is loaded.
fn fadeBg(pal: ?palette_mod.Palette) [3]f32 {
    if (pal) |p| return .{ p.background.r, p.background.g, p.background.b };
    return .{ 0.02, 0.02, 0.02 };
}

/// Bookkeeping every graphics rebuild needs, whichever path triggered it:
/// the surface may have new dimensions, the cached window rects are flipped
/// about the old height, and the fresh pipeline fades in like a launch.
fn afterGraphicsReset(
    wl: *wayland.WaylandState,
    surf_w: *f32,
    surf_h: *f32,
    surf_scale: *f32,
    surface_resized: *bool,
    resize_retries: *u8,
    fade_start: *f64,
    timer: *iohelp.Timer,
) void {
    surf_w.* = @floatFromInt(wl.buffer_width);
    surf_h.* = @floatFromInt(wl.buffer_height);
    surf_scale.* = wl.scale();
    // The flags are consumed here; the effect was already rebuilt at the
    // new size by recreateGraphics.
    wl.resize_pending = false;
    wl.scale_changed = false;
    surface_resized.* = true;
    resize_retries.* = 0;
    fade_start.* = timerSeconds(timer);
}

const AwaitOutcome = union(enum) {
    /// A shutdown signal arrived while waiting.
    exit,
    /// The target output is advertised again.
    same,
    /// Unpinned daemon: the target never returned, but another output is
    /// there; move to it.
    retarget: hypr.MonitorInfo,
};

/// Wait, with the surface gone, until there is an output to rebuild it on.
/// Polls the display with a timeout (nothing else would wake a blocking
/// dispatch) with a little backoff, and for an unpinned daemon also asks
/// Hyprland now and then which monitor is focused, adopting it once it
/// shows up in the Wayland registry. A pinned daemon only ever waits for
/// its own name: instances are one per monitor and must not double up.
///
/// `deadline_s` <= 0 waits forever; otherwise expiry exits non-zero via
/// `error.OutputRemoved`, so a supervisor's `Restart=on-failure` fires.
fn awaitOutput(
    wl: *wayland.WaylandState,
    ipc: *const hypr.HyprIpc,
    allocator: std.mem.Allocator,
    pinned: bool,
    deadline_s: f32,
    lost_since: f64,
    timer: *iohelp.Timer,
) !AwaitOutcome {
    var poll_ms: i32 = 250;
    var next_probe: f64 = timerSeconds(timer);
    var probe_gap: f64 = 1.0;
    while (true) {
        if (should_exit.load(.acquire)) return .exit;
        if (wl.hasTarget()) return .same;

        const now = timerSeconds(timer);
        if (!pinned and now >= next_probe) {
            next_probe = now + probe_gap;
            probe_gap = @min(probe_gap * 2.0, 8.0);
            if (ipc.monitor(allocator, null)) |m| {
                const name = m.outputName();
                // Hyprland's placeholder while no real monitor exists is
                // not somewhere to move to.
                if (!std.mem.eql(u8, name, "FALLBACK") and wl.hasOutput(name)) return .{ .retarget = m };
            } else |err| {
                log.debug("monitor probe while waiting failed: {}", .{err});
            }
        }
        if (deadline_s > 0 and now - lost_since >= deadline_s) {
            log.err("output '{s}' was removed", .{wl.targetName()});
            return error.OutputRemoved;
        }

        const got_events = try wl.dispatchTimeout(poll_ms);
        // Events reset the backoff: a hotplug tends to come as a burst.
        poll_ms = if (got_events) 250 else @min(poll_ms * 2, 1000);
    }
}

/// Re-init the active effect at new dimensions, in place.
///
/// Never leaves `effect` holding a deinited value: the old context is only
/// released once a replacement exists, so an error here cannot set up a
/// double-deinit through main's `defer effect.deinit()`. On failure the
/// existing effect keeps running at the old size, which is wrong but visible,
/// rather than taking the wallpaper down.
///
/// The replacement is built from the LIVE union tag, not from `cfg.effect`:
/// a `reloadConfig` that swapped the effect and then bailed before committing
/// the config leaves those two disagreeing, and resolving by name would
/// silently swap the running effect for a different one on the next resize.
fn rebuildEffect(
    allocator: std.mem.Allocator,
    effect: *effects.Effect,
    cfg: *const config_mod.Config,
    w: f32,
    h: f32,
) bool {
    const fresh = effects.Effect.init(effect.cliNameOf(), allocator, w, h, cfg) catch |err| {
        log.warn("effect resize to {d}x{d} failed: {} — keeping the old size", .{ w, h, err });
        return false;
    };
    effect.deinit();
    effect.* = fresh;
    return true;
}

/// Tear down and rebuild the GL pipeline: EGL state, shader program, and the
/// effect. Used after a Wayland reconnect or an `EglContextLost`. The palette
/// pointer is re-bound if present. Caller is responsible for any post-reinit
/// work (surface dimensions, requestFrame).
fn recreateGraphics(
    allocator: std.mem.Allocator,
    egl_state: *egl_mod.EglState,
    shader_prog: *shader_mod.ShaderProgram,
    effect: *effects.Effect,
    cfg: *const config_mod.Config,
    pal: *?palette_mod.Palette,
    wl: *const wayland.WaylandState,
    shader_path_expanded: []const u8,
) !void {
    egl_state.deinit();
    shader_prog.deinit();
    egl_state.* = try egl_mod.EglState.init(wl.display, wl.egl_window.?);
    const new_frag = try loadShaderFile(allocator, shader_path_expanded);
    defer allocator.free(new_frag);
    shader_prog.* = try shader_mod.ShaderProgram.init(new_frag);
    if (pal.*) |*p| shader_prog.setPalette(p);
    // eglDestroyContext above invalidated every GL name, including the ones
    // effects own themselves — milkdrop's FBO and textures, swarm's program.
    // Re-uploading uniforms is not enough; those objects have to be rebuilt or
    // the effect draws nothing until the daemon is restarted.
    _ = rebuildEffect(allocator, effect, cfg, @floatFromInt(wl.buffer_width), @floatFromInt(wl.buffer_height));
    effect.upload(shader_prog);
}

fn drawFrame(
    prog: *shader_mod.ShaderProgram,
    _: *egl_mod.EglState,
    w: f32,
    h: f32,
    time: f32,
    trans: *transition.TransitionState,
    windows: *const [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect,
    window_count: u8,
    fade: f32,
    fade_bg: [3]f32,
) void {
    // Resolve focused / previously-focused window indices by address — reliable
    // during motion where smoothed iWindow.xy lags behind raw positions.
    var focused_index: i32 = -1;
    var prev_index: i32 = -1;
    for (0..window_count) |i| {
        const addr = windows[i].address;
        if (addr == 0) continue;
        if (addr == trans.focused_address) focused_index = @intCast(i);
        if (addr == trans.prev_focused_address) prev_index = @intCast(i);
    }

    prog.draw(.{
        .width = w,
        .height = h,
        .time = time,
        .mouse_x = trans.current_cursor[0],
        .mouse_y = trans.current_cursor[1],
        .win_x = trans.current_win.x,
        .win_y = trans.current_win.y,
        .win_w = trans.current_win.w,
        .win_h = trans.current_win.h,
        .transition = trans.transition_progress,
        .windows = windows.*,
        .window_count = window_count,
        .focused_index = focused_index,
        .prev_index = prev_index,
        .fade = fade,
        .fade_bg = fade_bg,
    });
}

fn cacheWindows(
    cached: *[hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect,
    collision: *[hypr.max_visible_windows]particles.Rect,
    count: *u8,
    raw: *const RawState,
) void {
    count.* = raw.window_count;
    for (0..raw.window_count) |i| {
        cached[i] = raw.windows[i];
        collision[i] = .{
            .x = raw.windows[i].x,
            .y = raw.windows[i].y,
            .w = raw.windows[i].w,
            .h = raw.windows[i].h,
        };
    }
}

/// Resolve the effective slide behavior: what Hyprland's animation
/// config dictates, overridden by `[transition]` settings. Called at
/// startup, on Hyprland config reloads (fresh detection), and on TOML
/// hot-reloads (fresh overrides).
fn configureSlide(
    slide: *workspace_slide.WorkspaceSlide,
    detected: ?hypr.WorkspaceAnim,
    cfg: *const config_mod.Config,
) void {
    if (detected) |d| {
        slide.axis = d.axis;
        slide.duration = d.duration;
        slide.ease = d.ease;
    } else {
        slide.* = .{ .last_ws_id = slide.last_ws_id };
    }
    switch (cfg.workspace_slide) {
        .auto => {},
        .horizontal => slide.axis = .horizontal,
        .vertical => slide.axis = .vertical,
        .none => slide.axis = .none,
    }
    if (cfg.workspace_duration > 0) slide.duration = cfg.workspace_duration;
    if (cfg.workspace_spring) |sp| slide.ease = .{ .spring = sp };
}

/// Apply a slide offset to a rect position in GL space. Offsets are in
/// layout space (y down); the GL y-axis points up, so vertical offsets
/// flip sign.
fn applyOffset(x: *f32, y: *f32, axis: workspace_slide.Axis, amount: f32) void {
    switch (axis) {
        .horizontal => x.* += amount,
        .vertical => y.* -= amount,
        .none => {},
    }
}

const RawState = struct {
    win: transition.Rect,
    win_address: u64,
    windows: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect,
    window_count: u8,
    window_info: [hypr.max_visible_windows]effects.WindowInfo,
    focused_class: [64]u8,
    focused_class_len: u8,
    focused_title: [64]u8,
    focused_title_len: u8,
};

/// The in-compositor Lua watcher, installed into Hyprland's config Lua
/// state. Pushes `custom>>hg:*` events on socket2 (see hypr_events.zig).
const watcher_lua = @embedFile("core/watcher.lua");

comptime {
    // An over-budget chunk is otherwise a runtime error.CodeTooLong,
    // discovered only against a live compositor.
    if (watcher_lua.len > hypr.HyprIpc.max_eval_chunk)
        @compileError("watcher.lua exceeds HyprIpc.eval's command buffer");
}

/// (Re)install the watcher. Idempotent — the chunk disables any previous
/// timer first, and its first tick re-emits cursor + geometry
/// unconditionally. Seeds the heartbeat clock so the lapse detector
/// measures from now.
fn installWatcher(ipc: *const hypr.HyprIpc, events: *hypr_events.HyprEvents) !void {
    try ipc.eval(watcher_lua);
    events.noteHeartbeat();
    log.info("lua watcher installed", .{});
}

/// Derive window rects + metadata from the latest watcher snapshot,
/// looking up the focused window by `focused_address` (the address comes
/// from the event stream, or a one-time bootstrap query at startup).
/// Strip windows (rel ±1) are parked one `span` off-screen along the
/// slide axis; with sliding disabled they are dropped entirely.
///
/// `win_address` in the result is 0 when the focused window is not present
/// in the visible list (e.g. focus is on another monitor's workspace).
/// Copy the active-workspace windows of `from` into `out`, parked at
/// `rel = -dir`: the set the camera will slide out. Same monitor, same
/// origin, so the coordinates carry over untouched.
fn captureOutgoing(out: *hypr.VisibleWindows, from: *const hypr.VisibleWindows, dir: f32) void {
    out.* = .{ .workspace_id = from.workspace_id, .origin_x = from.origin_x, .origin_y = from.origin_y };
    const rel: i8 = if (dir > 0) -1 else 1;
    for (from.windows[0..from.count]) |vw| {
        if (vw.rel != 0) continue;
        out.windows[out.count] = vw;
        out.windows[out.count].rel = rel;
        out.count += 1;
    }
}

/// Accumulates strip windows in GL surface space with their rel offsets
/// applied, in the order the caller emits them, capped at the uniform
/// array size.
const StripBuilder = struct {
    windows: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect = undefined,
    win_info: [hypr.max_visible_windows]effects.WindowInfo = undefined,
    focused_idx: ?usize = null,
    count: u8 = 0,
    surf_h: f32,
    focused_address: u64,
    axis: workspace_slide.Axis,
    span: f32,
    scale: f32,

    fn add(self: *StripBuilder, vw: *const hypr.WindowGeometry, origin_x: i32, origin_y: i32) void {
        if (self.count >= hypr.max_visible_windows) return;
        const out = self.count;
        const r = geometry.toGl(vw.x, vw.y, vw.w, vw.h, origin_x, origin_y, self.surf_h, self.scale);
        self.windows[out] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h, .address = vw.address };
        applyOffset(&self.windows[out].x, &self.windows[out].y, self.axis, @as(f32, @floatFromInt(vw.rel)) * self.span);
        var info = effects.WindowInfo{};
        const clen: u8 = @intCast(@min(vw.class_len, 64));
        if (clen > 0) @memcpy(info.class[0..clen], vw.class[0..clen]);
        info.class_len = clen;
        const tlen: u8 = @intCast(@min(vw.title_len, 64));
        if (tlen > 0) @memcpy(info.title[0..tlen], vw.title[0..tlen]);
        info.title_len = tlen;
        self.win_info[out] = info;
        self.count += 1;
        if (self.focused_address != 0 and vw.address == self.focused_address) self.focused_idx = out;
    }
};

/// Build the window strip from a snapshot. With `outgoing` set (a slide is
/// running), the snapshot's `skip_rel` bucket is replaced by it: the
/// workspace being left slides out, not whichever workspace happens to
/// have the nearest id. Emission order is active, outgoing, far side, so
/// the cap drops what is off-screen anyway.
fn deriveRawState(
    visible: *const hypr.VisibleWindows,
    surf_h: f32,
    focused_address: u64,
    axis: workspace_slide.Axis,
    span: f32,
    scale: f32,
    outgoing: ?*const hypr.VisibleWindows,
    skip_rel: i8,
) RawState {
    var b = StripBuilder{
        .surf_h = surf_h,
        .focused_address = focused_address,
        .axis = axis,
        .span = span,
        .scale = scale,
    };

    for (visible.windows[0..visible.count]) |*vw| {
        if (vw.rel == 0) b.add(vw, visible.origin_x, visible.origin_y);
    }
    if (axis != .none) {
        if (outgoing) |og| {
            for (og.windows[0..og.count]) |*vw| b.add(vw, og.origin_x, og.origin_y);
        }
        for (visible.windows[0..visible.count]) |*vw| {
            if (vw.rel == 0) continue;
            if (outgoing != null and vw.rel == skip_rel) continue;
            b.add(vw, visible.origin_x, visible.origin_y);
        }
    }

    const windows = b.windows;
    const win_info = b.win_info;
    const focused_idx = b.focused_idx;
    const count = b.count;

    var fc: [64]u8 = [_]u8{0} ** 64;
    var fc_len: u8 = 0;
    var ft: [64]u8 = [_]u8{0} ** 64;
    var ft_len: u8 = 0;
    var win_rect = transition.Rect{};
    var win_addr: u64 = 0;
    if (focused_idx) |fi| {
        const wf = windows[fi];
        win_rect = .{ .x = wf.x, .y = wf.y, .w = wf.w, .h = wf.h };
        win_addr = wf.address;
        fc = win_info[fi].class;
        fc_len = win_info[fi].class_len;
        ft = win_info[fi].title;
        ft_len = win_info[fi].title_len;
    }

    return .{
        .win = win_rect,
        .win_address = win_addr,
        .windows = windows,
        .window_count = count,
        .window_info = win_info,
        .focused_class = fc,
        .focused_class_len = fc_len,
        .focused_title = ft,
        .focused_title_len = ft_len,
    };
}

fn loadConfig(allocator: std.mem.Allocator, cli: *const CliArgs) !config_mod.Config {
    var cfg: config_mod.Config = undefined;

    if (cli.config_path) |path| {
        cfg = try config_mod.load(allocator, path);
    } else {
        const default_path = config_mod.resolveConfigPath(allocator) catch {
            const effect_dup = try allocator.dupe(u8, cli.effect_name orelse "particles");
            errdefer allocator.free(effect_dup);
            const shader_dup = try allocator.dupe(u8, cli.shader_path orelse "");
            errdefer allocator.free(shader_dup);
            const theme_dup = if (cli.theme_name) |t| try allocator.dupe(u8, t) else null;
            errdefer if (theme_dup) |td| allocator.free(td);
            const output_dup = if (cli.output) |o| try allocator.dupe(u8, o) else null;
            errdefer if (output_dup) |od| allocator.free(od);
            return .{
                .effect = effect_dup,
                .shader = shader_dup,
                .theme = theme_dup,
                .output = output_dup,
                .output_wait = config_mod.defaultOutputWait(cli.output),
                .output_wait_set = false,
                .transition_duration = 0.3,
                .fade_in = 1.0,
                .cursor_smoothing = 0.15,
                .geometry_smoothing = 0.12,
                .workspace_slide = .auto,
                .workspace_duration = 0,
                .workspace_spring = null,
                .config_path = try allocator.dupe(u8, ""),
            };
        };
        defer allocator.free(default_path);
        cfg = try config_mod.load(allocator, default_path);
    }

    // CLI overrides
    if (cli.effect_name) |e| {
        allocator.free(cfg.effect);
        cfg.effect = try allocator.dupe(u8, e);
    }
    if (cli.shader_path) |sp| {
        if (cfg.shader.len > 0) allocator.free(cfg.shader);
        cfg.shader = try allocator.dupe(u8, sp);
    }
    if (cli.theme_name) |tn| {
        if (cfg.theme) |old| allocator.free(old);
        cfg.theme = try allocator.dupe(u8, tn);
    }
    if (cli.output) |o| {
        if (cfg.output) |old| allocator.free(old);
        cfg.output = try allocator.dupe(u8, o);
        // Pinning from the command line changes the wait default too.
        if (!cfg.output_wait_set) cfg.output_wait = config_mod.defaultOutputWait(cfg.output);
    }

    return cfg;
}

fn reloadConfig(
    allocator: std.mem.Allocator,
    cfg: *config_mod.Config,
    effect: *effects.Effect,
    shader_prog: *shader_mod.ShaderProgram,
    pal: *?palette_mod.Palette,
    trans: *transition.TransitionState,
    current_shader_path: *[]const u8,
    surf_w: f32,
    surf_h: f32,
    active_output: []const u8,
) !void {
    var new_cfg = try config_mod.load(allocator, cfg.config_path);

    trans.transition_duration = new_cfg.transition_duration;
    trans.cursor_smoothing = new_cfg.cursor_smoothing;
    trans.geometry_smoothing = new_cfg.geometry_smoothing;

    // The layer surface is bound to its output when it is created, so this
    // one cannot hot-apply. Compare against the output actually in use rather
    // than against cfg.output: a reload re-reads the file without re-applying
    // CLI overrides, so cfg.output would report the file's value even when
    // --output won at startup.
    if (new_cfg.output) |want| {
        if (!std.mem.eql(u8, want, active_output))
            log.warn("output changed to '{s}' — restart hyprglaze to apply", .{want});
    }

    // Theme change
    if (!strEql(cfg.theme, new_cfg.theme)) {
        if (new_cfg.theme) |theme_name| {
            pal.* = palette_mod.loadTheme(allocator, theme_name) catch |err| {
                config_mod.deinit(&new_cfg, allocator);
                return err;
            };
            log.info("theme reloaded: {s}", .{theme_name});
        } else {
            pal.* = null;
        }
    }

    // Reinit effect every reload so per-effect params ([particles], [buddy], etc.)
    // pick up config changes even when the effect name itself is unchanged.
    const effect_name_changed = !std.mem.eql(u8, cfg.effect, new_cfg.effect);
    effect.deinit();
    effect.* = effects.Effect.init(new_cfg.effect, allocator, surf_w, surf_h, &new_cfg) catch |err| {
        log.warn("effect '{s}' failed: {}, falling back to windowglow", .{ new_cfg.effect, err });
        effect.* = effects.Effect.init("windowglow", allocator, 0, 0, &new_cfg) catch |fb_err| {
            log.err("fallback effect init failed: {}", .{fb_err});
            config_mod.deinit(&new_cfg, allocator);
            return fb_err;
        };
        config_mod.deinit(&new_cfg, allocator);
        return err;
    };
    if (effect_name_changed) {
        log.info("effect switched: {s}", .{new_cfg.effect});
    } else {
        log.info("effect reloaded: {s}", .{new_cfg.effect});
    }

    // Shader — resolve from explicit config or effect default
    const desired_shader = if (new_cfg.shader.len > 0) new_cfg.shader else effect.defaultShader();
    const new_shader_path = config_mod.expandHome(allocator, desired_shader) catch |err| {
        config_mod.deinit(&new_cfg, allocator);
        return err;
    };

    if (!std.mem.eql(u8, new_shader_path, current_shader_path.*)) {
        const new_source = loadShaderFile(allocator, new_shader_path) catch |err| {
            allocator.free(new_shader_path);
            config_mod.deinit(&new_cfg, allocator);
            return err;
        };
        defer allocator.free(new_source);

        var new_prog = shader_mod.ShaderProgram.init(new_source) catch |err| {
            allocator.free(new_shader_path);
            config_mod.deinit(&new_cfg, allocator);
            return err;
        };

        if (pal.*) |*p| new_prog.setPalette(p);
        shader_prog.deinit();
        shader_prog.* = new_prog;
        log.info("shader reloaded: {s}", .{new_shader_path});

        allocator.free(current_shader_path.*);
        current_shader_path.* = new_shader_path;
    } else {
        allocator.free(new_shader_path);
        if (pal.*) |*p| shader_prog.setPalette(p);
    }

    config_mod.deinit(cfg, allocator);
    cfg.* = new_cfg;
}

fn strEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

const usage_text =
    \\Wayland shader wallpaper daemon for Hyprland with window-aware effects.
    \\
    \\Usage: hyprglaze [options]
    \\
    \\  --output NAME      Monitor to render on, per `hyprctl monitors`
    \\                     (default: the focused monitor at startup)
    \\  --config PATH      TOML config path (default: ~/.config/hypr/hyprglaze.toml)
    \\  --effect NAME      Effect to render (see --list-effects)
    \\  --shader PATH      Fragment shader path (overrides effect default)
    \\  --theme NAME       Gogh color scheme name
    \\  --set-theme NAME   Persist a theme to the config file and exit (hot-reloads)
    \\  --list-themes      List available themes and exit
    \\  --list-effects     List available effects and exit
    \\  --fps              Log frames-per-second every second
    \\  --help, -h         Show this help
    \\
;

/// Minimal in-tree CLI parser. Supports `--key value`, `--key=value`, and
/// bool flags. Unknown args → error.
fn parseCli(allocator: std.mem.Allocator, raw_argv: []const [*:0]const u8) !CliArgs {
    var out = CliArgs{};
    errdefer {
        if (out.config_path) |p| allocator.free(p);
        if (out.effect_name) |p| allocator.free(p);
        if (out.shader_path) |p| allocator.free(p);
        if (out.theme_name) |p| allocator.free(p);
        if (out.set_theme) |p| allocator.free(p);
        if (out.output) |p| allocator.free(p);
    }

    // Skip argv[0] (the program path).
    var i: usize = 1;
    while (i < raw_argv.len) : (i += 1) {
        const arg = std.mem.span(raw_argv[i]);
        // Split "--key=value" → key, value.
        var key: []const u8 = arg;
        var value: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            key = arg[0..eq];
            value = arg[eq + 1 ..];
        }

        const StrField = enum { config, effect, shader, theme, set_theme, output };
        const BoolField = enum { list_themes, list_effects, fps, help };

        const str_kind: ?StrField = if (std.mem.eql(u8, key, "--config")) .config
            else if (std.mem.eql(u8, key, "--effect")) .effect
            else if (std.mem.eql(u8, key, "--shader")) .shader
            else if (std.mem.eql(u8, key, "--theme")) .theme
            else if (std.mem.eql(u8, key, "--set-theme")) .set_theme
            else if (std.mem.eql(u8, key, "--output")) .output
            else null;

        if (str_kind) |sk| {
            const v = value orelse blk: {
                i += 1;
                if (i >= raw_argv.len) {
                    std.log.err("missing value for {s}", .{key});
                    return error.MissingArgValue;
                }
                break :blk std.mem.span(raw_argv[i]);
            };
            const dup = try allocator.dupe(u8, v);
            switch (sk) {
                .config => out.config_path = dup,
                .effect => out.effect_name = dup,
                .shader => out.shader_path = dup,
                .theme => out.theme_name = dup,
                .set_theme => out.set_theme = dup,
                .output => out.output = dup,
            }
            continue;
        }

        const bool_kind: ?BoolField = if (std.mem.eql(u8, key, "--list-themes")) .list_themes
            else if (std.mem.eql(u8, key, "--list-effects")) .list_effects
            else if (std.mem.eql(u8, key, "--fps")) .fps
            else if (std.mem.eql(u8, key, "--help") or std.mem.eql(u8, key, "-h")) .help
            else null;

        if (bool_kind) |bk| switch (bk) {
            .list_themes => out.list_themes = true,
            .list_effects => out.list_effects = true,
            .fps => out.fps = true,
            .help => {
                // Plain stdout, not the log: help is program output.
                const io = std.Io.Threaded.global_single_threaded.io();
                var stdout_buf: [1024]u8 = undefined;
                var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
                stdout_writer.interface.writeAll(usage_text) catch {};
                stdout_writer.interface.flush() catch {};
                std.process.exit(0);
            },
        } else {
            std.log.err("unknown argument: {s}", .{arg});
            return error.UnknownArg;
        }
    }
    return out;
}

const system_data_dir = "/usr/share/hyprglaze";

/// Resolve a data file path: try relative, then absolute, then /usr/share/hyprglaze/
fn resolveDataPath(path: []const u8, buf: *[512]u8) ?[]const u8 {
    // 1. Relative to CWD
    if (iohelp.accessRelative(path)) return path;
    // 2. Absolute path
    if (path.len > 0 and path[0] == '/') {
        if (iohelp.accessAbsolute(path)) return path;
    }
    // 3. System data dir fallback
    const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ system_data_dir, path }) catch return null;
    if (iohelp.accessAbsolute(full)) return full;
    return null;
}

fn loadShaderFile(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    var resolve_buf: [512]u8 = undefined;
    const resolved = resolveDataPath(path, &resolve_buf) orelse path;

    if (iohelp.readFileRelative0(allocator, resolved, 1024 * 1024)) |source| {
        return source;
    } else |_| {}
    return try iohelp.readFileAlloc0(allocator, resolved, 1024 * 1024);
}

