const std = @import("std");
const builtin = @import("builtin");
const iohelp = @import("core/io_helper.zig");
const wayland = @import("core/wayland.zig");
const shader_mod = @import("core/shader.zig");
const hypr = @import("core/hypr.zig");
const palette_mod = @import("core/palette.zig");
const transition = @import("core/transition.zig");
const geometry = @import("core/geometry.zig");
const workspace_slide = @import("core/workspace_slide.zig");
const window_anim = @import("core/window_anim.zig");
const config_mod = @import("core/config.zig");
const watcher_mod = @import("core/watcher.zig");
const hypr_events = @import("core/hypr_events.zig");
const effects = @import("effects.zig");
const cli_mod = @import("cli.zig");
const strip = @import("strip.zig");
const renderer_mod = @import("renderer.zig");

pub const std_options: std.Options = .{ .log_level = .info };
const log = std.log.scoped(.hyprglaze);

var should_exit = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    should_exit.store(true, .release);
}

pub fn main(init: std.process.Init.Minimal) !void {
    // Leak-checking allocator in Debug; lock-cheap smp_allocator in
    // release, where DebugAllocator's metadata and mutex are pure cost.
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .debug) gpa.allocator() else std.heap.smp_allocator;

    const sig_act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sig_act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sig_act, null);

    const cli = try cli_mod.parse(init.args.vector);

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

    // Resolve shader: explicit config > effect default. Checked here, before
    // Wayland, so a bad effect name or shader path fails fast. The effect
    // itself is built by the Renderer once the surface exists and its real
    // size is known (audio effects also start capture in init).
    const default_shader = effects.Effect.defaultShaderFor(cfg.effect) orelse {
        log.err("unknown effect: '{s}'. Available: {s}", .{ cfg.effect, effects.effect_names_csv });
        return error.UnknownEffect;
    };
    const shader_path = if (cfg.shader.len > 0) cfg.shader else default_shader;
    log.info("effect: {s}", .{cfg.effect});
    log.info("shader: {s}", .{shader_path});
    if (cfg.theme) |t| log.info("theme: {s}", .{t});

    const shader_path_expanded = try config_mod.expandHome(allocator, shader_path);
    defer allocator.free(shader_path_expanded);

    const frag_source = renderer_mod.loadShaderFile(allocator, shader_path_expanded) catch |err| {
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

    // Detect Hyprland's animations: workspace switches mirror the
    // compositor's own slide (direction, duration, easing), and since the
    // watcher reports window goal rects, the daemon replays the
    // compositor's move curve toward them. Refreshed on Hyprland config
    // reloads; config overrides applied on top.
    var detected = detectAnimations(&ipc, allocator, .{ .workspace = null, .window = null });

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

    var r = try renderer_mod.Renderer.init(allocator, &cfg, &wl, pal, shader_path_expanded, frag_source);
    defer r.deinit();

    log.info("entering render loop", .{});

    // Transition
    var trans = transition.TransitionState.init();
    trans.transition_duration = cfg.transition_duration;
    trans.cursor_smoothing = cfg.cursor_smoothing;
    trans.geometry_smoothing = cfg.geometry_smoothing;

    // Workspace slide state + the outgoing window set captured at each
    // workspace switch (slides off-screen while the new set slides in).
    var slide = workspace_slide.WorkspaceSlide{};
    configureSlide(&slide, detected.workspace, &cfg);
    var win_anims = window_anim.Tracker{};
    // Recent frame period. A frame drawn now reaches the screen on the
    // compositor's next refresh, so window animations are sampled that far
    // ahead to line up with the window as it will be displayed.
    var frame_period: f64 = 1.0 / 60.0;
    configureWindowAnim(&win_anims, detected.window, &cfg);
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
    var cached_window_count: u8 = 0;
    var cached_window_info: [hypr.max_visible_windows]effects.WindowInfo = undefined;
    var cached_focused_class: [64]u8 = @splat(0);
    var cached_focused_class_len: u8 = 0;
    var cached_focused_title: [64]u8 = @splat(0);
    var cached_focused_title_len: u8 = 0;
    var fps_timer = try iohelp.Timer.start();
    var timer = try iohelp.Timer.start();

    // Seed: bootstrap the focused-window address once via `j/activewindow`
    // because the event stream only carries future changes, never the
    // current state. From here on, `activewindowv2` events keep
    // `events.focused_address` in sync.
    const initial_addr: u64 = ipc.activeAddress(allocator) catch 0;
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
    var closed_tail = events.closedHead();
    var closed_buf: [hypr_events.HyprEvents.closed_ring_len]u64 = undefined;
    var workspace_switches: u32 = 0;
    events.copySnapshot(&cached_snapshot);
    // Seed the move-animation tracker, so a window's first move after
    // startup animates rather than reading as a newly seen window.
    strip.noteWindowGoals(&win_anims, &cached_snapshot, 0);
    slide.seed(cached_snapshot.workspace_id);

    const initial_cursor = events.cursorPos();
    const seed_cursor = geometry.toGlPoint(
        initial_cursor.x,
        initial_cursor.y,
        cached_snapshot.origin_x,
        cached_snapshot.origin_y,
        r.height,
        r.scale,
    );

    const raw0 = strip.deriveRawState(
        &cached_snapshot,
        strip.View.init(r.width, r.height, r.scale, slide.axis),
        initial_addr,
        null,
        0,
    );
    trans.seed(raw0.win, seed_cursor, raw0.win_address);
    cacheWindows(&cached_windows, &cached_window_count, &raw0);
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
    try r.prime(&wl, sceneOf(&trans, &cached_windows, cached_window_count));
    // Workspace slide bookkeeping. `outgoing` is the window set of the
    // workspace being LEFT, captured at the switch and parked one span
    // behind the camera while the slide runs, so what slides out is what
    // Hyprland slides out. The watcher's strip parks the nearest-id
    // neighbor there instead, which is a different workspace whenever the
    // switch jumps more than one (1 → 5 with 3 in between slid 3's windows
    // out). `strip_dirty` forces one re-derive when the slide settles, so
    // the outgoing set is swapped back for the normal strip instead of
    // lingering off-screen as window rects.
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
            // Tear the GL pipeline down BEFORE reconnect, which destroys the
            // wl_display the EGL surface is built on. Leaving it until
            // afterwards means eglDestroySurface — from the rebuild on the way
            // in, or from this function's own `defer` if the reconnect fails —
            // walks into a freed display inside the driver's Wayland platform
            // layer and segfaults. release is idempotent.
            r.release();
            wl.reconnect() catch |e2| {
                log.err("Wayland reconnect failed: {} — exiting", .{e2});
                return e2;
            };
            try r.rebuild(&wl, sceneOf(&trans, &cached_windows, cached_window_count), timerSeconds(&timer), "Wayland reconnect");
            continue;
        };

        if (wl.should_close or wl.target_gone or surface_lost) {
            const now_s = timerSeconds(&timer);
            if (!surface_lost) {
                surface_lost = true;
                lost_since = now_s;
                // GL first, for the same reason as in the reconnect path:
                // the EGL surface sits on the wl_egl_window about to go.
                r.release();
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
                    events.retarget(mon.outputName(), mon.x, mon.y);
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
            try r.rebuild(&wl, sceneOf(&trans, &cached_windows, cached_window_count), timerSeconds(&timer), "output returned");
            // A moved daemon needs the watcher scoped to its new monitor;
            // for the same output the reinstall is idempotent and re-emits
            // the full state, which the fresh surface needs anyway.
            installWatcher(&ipc, &events) catch |err| {
                log.warn("watcher reinstall after output return failed: {} — the heartbeat check will retry", .{err});
            };
            last_install_attempt = timerSeconds(&timer);
            surface_lost = false;
            log.info("output '{s}' is back — surface recreated at {d}x{d}", .{ wl.targetName(), wl.buffer_width, wl.buffer_height });
            continue;
        }

        if (wl.resize_pending or wl.scale_changed) {
            if (!r.resize(&wl)) continue;
        }

        if (config_watcher) |*cw| {
            if (cw.poll()) {
                log.info("config changed, reloading", .{});
                reloadConfig(allocator, &cfg, &r, &trans, mon.outputName()) catch |err| {
                    log.warn("reload failed: {}", .{err});
                };
                configureSlide(&slide, detected.workspace, &cfg);
                configureWindowAnim(&win_anims, detected.window, &cfg);
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

            // Sample the pointer as this frame renders: asked of Hyprland
            // directly, falling back to the watcher's last `hg:cur` push
            // (16ms tick) if the query fails.
            const cursor = ipc.cursorPos() catch events.cursorPos();
            cached_cursor = geometry.toGlPoint(
                cursor.x,
                cursor.y,
                cached_snapshot.origin_x,
                cached_snapshot.origin_y,
                r.height,
                r.scale,
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
                    // The reload may have changed the animations.
                    detected = detectAnimations(&ipc, allocator, detected);
                    configureSlide(&slide, detected.workspace, &cfg);
                    configureWindowAnim(&win_anims, detected.window, &cfg);
                }
            }

            // Re-derive window state when the watcher pushed a new
            // snapshot or focus moved. No polling: during interactive
            // drag/resize the in-compositor watcher sees geometry change
            // every 16ms tick and pushes a fresh snapshot.
            const gen = events.snapshotGen();
            var force_snap = false;
            if (focus_changed or gen != last_snapshot_gen or r.rects_stale or strip_dirty) {
                r.rects_stale = false;
                strip_dirty = false;
                if (gen != last_snapshot_gen) {
                    last_snapshot_gen = gen;
                    prev_snapshot = cached_snapshot;
                    events.copySnapshot(&cached_snapshot);
                    strip.noteWindowGoals(&win_anims, &cached_snapshot, time_f64);
                    // Workspace switch? The strip below rebases around
                    // the new active workspace (every rel shifts by one),
                    // and the camera cancels the resulting jump. The set
                    // that slides out is the one that was active a moment
                    // ago, captured here from the previous snapshot; the
                    // strip's own -1/+1 buckets are the nearest ids, which
                    // is only the same thing for a one-step switch.
                    const ws_change = slide.noteWorkspace(cached_snapshot.workspace_id, time_f64);
                    if (ws_change != .none) workspace_switches +%= 1;
                    switch (ws_change) {
                        .slide => {
                            strip.captureOutgoing(&outgoing, &prev_snapshot, slide.dir);
                            log.debug("slide: ws {d} -> {d}, {d} outgoing windows", .{ prev_snapshot.workspace_id, cached_snapshot.workspace_id, outgoing.count });
                        },
                        // Workspace changed without a slidable direction
                        // (special workspace, unknown id, slides off):
                        // snap — never glide across a workspace boundary.
                        .snap => force_snap = true,
                        .none => {},
                    }
                }
                const raw = strip.deriveRawState(
                    &cached_snapshot,
                    strip.View.init(r.width, r.height, r.scale, slide.axis),
                    cached_win_address,
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
            const span: f32 = if (slide.axis == .vertical) r.height else r.width;
            const camera = slide.sample(time_f64, span);
            // Settled: swap the outgoing set back for the normal strip on
            // the next frame.
            if (camera == null and slide_was_active) strip_dirty = true;
            slide_was_active = camera != null;

            // While sliding, keep iWindow tracking the focused window's
            // slid-in position instead of pre-snapping to where it will
            // come to rest (focus always lives on the active workspace).
            // A frame drawn now is shown on the compositor's next refresh:
            // sample window animations for that moment.
            if (dt > 0 and dt < 0.1) frame_period += (@as(f64, dt) - frame_period) * 0.1;
            const present_time = time_f64 + frame_period;

            var raw_focus_win = cached_raw_win;
            {
                const d = strip.animOffsetGl(&win_anims, cached_win_address, present_time, r.scale);
                raw_focus_win.x += d.x;
                raw_focus_win.y += d.y;
                raw_focus_win.w += d.w;
                raw_focus_win.h += d.h;
            }
            if (camera) |cam| {
                strip.applyOffset(&raw_focus_win.x, &raw_focus_win.y, slide.axis, cam);
            }
            trans.update(time_f64, raw_focus_win, raw_cursor, cached_win_address);

            // Where each window will be on screen when this frame is shown:
            // its goal plus the part of Hyprland's move animation still to
            // play at present_time.
            var anim_targets: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect = undefined;
            for (0..target_window_count) |i| {
                anim_targets[i] = strip.animated(&win_anims, target_windows[i], present_time, r.scale);
            }

            strip.follow(
                &cached_windows,
                &cached_window_count,
                anim_targets[0..target_window_count],
                camera,
                slide.axis,
                force_snap,
                // Optional extra smoothing (off by default).
                transition.smoothAlpha(cfg.geometry_smoothing, dt),
            );

            // Update effect
            r.fx().update(.{
                .dt = dt,
                .time = time,
                .cursor = trans.current_cursor,
                .focused_win = trans.current_win,
                .windows = cached_windows[0..cached_window_count],
                .window_info = cached_window_info[0..cached_window_count],
                .focused_class = cached_focused_class,
                .focused_class_len = cached_focused_class_len,
                .focused_title = cached_focused_title,
                .focused_title_len = cached_focused_title_len,
                .palette = r.palette(),
                .workspace_slide = slide.progress(time_f64),
                .workspace_switches = workspace_switches,
                .closed_windows = events.drainClosed(&closed_tail, &closed_buf),
            });
            r.fx().upload(&r.prog);

            const frame_scene = sceneOf(&trans, &cached_windows, cached_window_count);
            r.draw(frame_scene, time, r.fadeAt(time_f64));
            try wl.requestFrame();
            if (r.swap()) |_| {
                swap_failures = 0;
            } else |err| {
                // A failed swap commits no buffer, so the frame callback just
                // requested never fires: every rebuild path primes the new
                // surface, which commits one.
                const lost = err == error.EglContextLost;
                if (!lost) {
                    swap_failures +|= 1;
                    log.warn("eglSwapBuffers error: {}", .{err});
                }
                if (lost or swap_failures >= 3) {
                    if (lost)
                        log.warn("EGL context lost — reinitialising graphics", .{})
                    else
                        log.warn("eglSwapBuffers failed {d}x in a row — reinitialising graphics", .{swap_failures});
                    try r.rebuild(&wl, frame_scene, timerSeconds(&timer), if (lost) "context lost" else "swap failures");
                    swap_failures = 0;
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

fn timerSeconds(timer: *iohelp.Timer) f64 {
    return @as(f64, @floatFromInt(timer.read())) / 1_000_000_000.0;
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

fn cacheWindows(
    cached: *[hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect,
    count: *u8,
    raw: *const strip.RawState,
) void {
    count.* = raw.window_count;
    for (0..raw.window_count) |i| {
        cached[i] = raw.windows[i];
    }
}

/// Query Hyprland's animations. Whatever cannot be detected keeps its
/// `prev` value: the last detection, or null (the defaults) at startup.
fn detectAnimations(ipc: *const hypr.HyprIpc, allocator: std.mem.Allocator, prev: hypr.Animations) hypr.Animations {
    const got = ipc.animations(allocator) catch |err| {
        log.warn("animation detection failed: {} — keeping the previous settings", .{err});
        return prev;
    };
    if (got.workspace == null) log.warn("no workspace animation in Hyprland's reply — keeping the previous one", .{});
    if (got.window == null) log.warn("no window animation in Hyprland's reply — keeping the previous one", .{});
    return .{
        .workspace = got.workspace orelse prev.workspace,
        .window = got.window orelse prev.window,
    };
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

fn configureWindowAnim(
    tracker: *window_anim.Tracker,
    detected: ?window_anim.Anim,
    cfg: *const config_mod.Config,
) void {
    tracker.anim = detected orelse .{};
    if (cfg.window_spring) |sp| {
        if (tracker.anim.ease == .spring) tracker.anim.ease = .{ .spring = sp };
    }
}

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

fn loadConfig(allocator: std.mem.Allocator, cli: *const cli_mod.CliArgs) !config_mod.Config {
    const cfg = if (cli.config_path) |path| try config_mod.load(allocator, path) else blk: {
        // No config file: the same defaults an empty file gets.
        const default_path = config_mod.resolveConfigPath(allocator) catch
            break :blk try config_mod.parse(allocator, "", "");
        defer allocator.free(default_path);
        break :blk try config_mod.load(allocator, default_path);
    };
    return applyCliOverrides(allocator, cfg, cli);
}

/// Each override is duplicated before the old value is freed, so a failed
/// allocation leaves `cfg` whole for the errdefer to release.
fn applyCliOverrides(allocator: std.mem.Allocator, loaded: config_mod.Config, cli: *const cli_mod.CliArgs) !config_mod.Config {
    var cfg = loaded;
    errdefer config_mod.deinit(&cfg, allocator);
    if (cli.effect_name) |e| {
        const v = try allocator.dupe(u8, e);
        allocator.free(cfg.effect);
        cfg.effect = v;
    }
    if (cli.shader_path) |sp| {
        const v = try allocator.dupe(u8, sp);
        allocator.free(cfg.shader);
        cfg.shader = v;
    }
    if (cli.theme_name) |tn| {
        const v = try allocator.dupe(u8, tn);
        if (cfg.theme) |old| allocator.free(old);
        cfg.theme = v;
    }
    if (cli.output) |o| {
        const v = try allocator.dupe(u8, o);
        if (cfg.output) |old| allocator.free(old);
        cfg.output = v;
        // Pinning from the command line changes the wait default too.
        if (!cfg.output_wait_set) cfg.output_wait = config_mod.defaultOutputWait(cfg.output);
    }
    return cfg;
}

/// Hot-reload the TOML config. The renderer applies theme, effect and shader;
/// the transition settings apply here. `cfg` is replaced only on success.
fn reloadConfig(
    allocator: std.mem.Allocator,
    cfg: *config_mod.Config,
    r: *renderer_mod.Renderer,
    trans: *transition.TransitionState,
    active_output: []const u8,
) !void {
    var new_cfg = try config_mod.load(allocator, cfg.config_path);
    errdefer config_mod.deinit(&new_cfg, allocator);

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

    try r.applyConfig(cfg, &new_cfg);

    config_mod.deinit(cfg, allocator);
    cfg.* = new_cfg;
}

fn sceneOf(
    trans: *const transition.TransitionState,
    windows: *const [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect,
    count: u8,
) renderer_mod.Scene {
    return .{ .trans = trans, .windows = windows, .window_count = count };
}
