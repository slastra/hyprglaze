const std = @import("std");
const iohelp = @import("core/io_helper.zig");
const wayland = @import("core/wayland.zig");
const egl_mod = @import("core/egl.zig");
const shader_mod = @import("core/shader.zig");
const hypr = @import("core/hypr.zig");
const palette_mod = @import("core/palette.zig");
const transition = @import("core/transition.zig");
const config_mod = @import("core/config.zig");
const watcher_mod = @import("core/watcher.zig");
const hypr_events = @import("core/hypr_events.zig");
const effects = @import("effects.zig");
const particles = @import("effects/particles/system.zig");

const c = @cImport({
    @cInclude("wayland-client.h");
});

pub const std_options: std.Options = .{ .log_level = .info };
const log = std.log.scoped(.hyprglaze);

var should_exit = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    should_exit.store(true, .release);
}

const CliArgs = struct {
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
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    const mon = ipc.primaryMonitor(allocator) catch |err| {
        log.err("failed to query monitor: {}", .{err});
        return err;
    };
    log.info("monitor: {d}x{d} scale={d:.2}", .{ mon.width, mon.height, mon.scale });

    // Subscribe to Hyprland's event stream so focus / lifecycle / workspace
    // changes are instant rather than detected via the every-100ms poll.
    var events = hypr_events.HyprEvents.init() catch |err| {
        log.err("Hyprland events init failed: {}", .{err});
        return err;
    };
    defer events.deinit();

    // Wayland
    var wl = wayland.WaylandState.init() catch |err| {
        log.err("Wayland init failed: {}", .{err});
        return err;
    };
    defer wl.deinit();

    wl.createLayerSurface() catch |err| {
        log.err("layer surface creation failed: {}", .{err});
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

    // Re-init effect with actual dimensions
    var surf_w: f32 = @floatFromInt(wl.width);
    var surf_h: f32 = @floatFromInt(wl.height);
    effect.deinit();
    effect = try effects.Effect.init(cfg.effect, allocator, surf_w, surf_h, &cfg);

    log.info("entering render loop", .{});

    // Transition
    var trans = transition.TransitionState.init();
    trans.transition_duration = cfg.transition_duration;
    trans.cursor_smoothing = cfg.cursor_smoothing;
    trans.geometry_smoothing = cfg.geometry_smoothing;

    // Config watcher
    var config_watcher: ?watcher_mod.FileWatcher = null;
    if (cfg.config_path.len > 0) {
        if (config_mod.expandHome(allocator, cfg.config_path) catch null) |acp| {
            config_watcher = watcher_mod.FileWatcher.init(allocator, acp) catch null;
            allocator.free(acp);
            if (config_watcher != null)
                log.info("watching config: {s}", .{cfg.config_path});
        }
    }
    defer if (config_watcher) |*w| w.deinit();

    // Frame state
    var prev_time: f32 = 0.0;
    var frame_count: u32 = 0;
    var ipc_skip: u32 = 0;
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

    // Seed: bootstrap the focused-window address once via `j/activewindow`
    // because the event stream only carries future changes, never the
    // current state. From here on, `activewindowv2` events keep
    // `events.focused_address` in sync.
    const initial_focus = ipc.activeWindow(allocator) catch null;
    const initial_addr: u64 = if (initial_focus) |w| w.address else 0;
    events.focused_address.store(initial_addr, .release);

    const initial_cursor = ipc.cursorPos() catch hypr.CursorPos{ .x = 0, .y = 0 };
    const seed_cursor = [2]f32{
        @floatFromInt(initial_cursor.x),
        surf_h - @as(f32, @floatFromInt(initial_cursor.y)),
    };

    const raw0 = queryRawState(&ipc, allocator, surf_h, initial_addr);
    trans.seed(raw0.win, seed_cursor, raw0.win_address);
    cacheWindows(&cached_windows, &cached_collision_rects, &cached_window_count, &raw0);
    for (0..raw0.window_count) |i| cached_window_info[i] = raw0.window_info[i];
    cached_focused_class = raw0.focused_class;
    cached_focused_class_len = raw0.focused_class_len;
    cached_focused_title = raw0.focused_title;
    cached_focused_title_len = raw0.focused_title_len;
    var cached_raw_win = raw0.win;
    var cached_win_address: u64 = raw0.win_address;

    // Start the event reader after bootstrap so the initial dirty flag
    // doesn't trigger a redundant first-iteration re-poll.
    _ = events.takeDirty();
    events.start() catch |err| {
        log.warn("Hyprland events thread failed to start: {} — falling back to polling only", .{err});
    };

    // Raw window targets for smoothing
    var target_windows: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect = undefined;
    var target_window_count: u8 = raw0.window_count;
    for (0..raw0.window_count) |i| target_windows[i] = raw0.windows[i];

    // Cursor target — refreshed at most once per `cursor_query_period`. The
    // smoothing in transition.zig is frame-rate independent and effects don't
    // visibly react faster than the display, so polling above 60 Hz is pure
    // IPC waste on high-refresh monitors.
    var cached_cursor: [2]f32 = seed_cursor;
    var last_cursor_query_time: f64 = 0;
    const cursor_query_period: f64 = 1.0 / 60.0;

    // Initial render
    effect.upload(&shader_prog);
    try wl.requestFrame();
    drawFrame(&shader_prog, &egl_state, surf_w, surf_h, 0.0, &trans, &cached_windows, cached_window_count);
    egl_state.swapBuffers() catch |err| log.warn("initial swapBuffers error: {}", .{err});

    // Main loop
    while (!wl.should_close and !should_exit.load(.acquire)) {
        wl.dispatch() catch |err| {
            if (should_exit.load(.acquire)) break;
            log.warn("Wayland dispatch error: {} — reconnecting in 1s", .{err});
            iohelp.sleepNs(1 * std.time.ns_per_s);
            wl.reconnect() catch |e2| {
                log.err("Wayland reconnect failed: {} — exiting", .{e2});
                return e2;
            };
            recreateGraphics(allocator, &egl_state, &shader_prog, &effect, &pal, &wl, shader_path_expanded) catch |e2| {
                log.err("graphics reinit failed after Wayland reconnect: {} — exiting", .{e2});
                return e2;
            };
            surf_w = @floatFromInt(wl.width);
            surf_h = @floatFromInt(wl.height);
            wl.resize_pending = false;
            try wl.requestFrame();
            continue;
        };

        if (wl.resize_pending) {
            surf_w = @floatFromInt(wl.width);
            surf_h = @floatFromInt(wl.height);
            wl.resize_pending = false;
        }

        if (config_watcher) |*cw| {
            if (cw.poll()) {
                log.info("config changed, reloading", .{});
                reloadConfig(allocator, &cfg, &effect, &shader_prog, &pal, &trans, &shader_path_expanded, surf_w, surf_h) catch |err| {
                    log.warn("reload failed: {}", .{err});
                };
            }
        }

        if (wl.frame_done) {
            const elapsed_ns = timer.read();
            const time_f64: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const time: f32 = @floatCast(time_f64);
            const dt = time - prev_time;
            prev_time = time;

            // Cursor: Hyprland emits no cursor events on socket2, so we poll.
            // Capped at 60 Hz — finer sampling buys nothing visible because
            // the smoothing in transition.zig is frame-rate independent.
            if (time_f64 - last_cursor_query_time >= cursor_query_period) {
                const cursor = ipc.cursorPos() catch hypr.CursorPos{ .x = 0, .y = 0 };
                cached_cursor[0] = @floatFromInt(cursor.x);
                cached_cursor[1] = surf_h - @as(f32, @floatFromInt(cursor.y));
                last_cursor_query_time = time_f64;
            }
            const raw_cursor = cached_cursor;

            // Pull focus from the event stream. A change forces an
            // immediate re-poll so geometry/metadata for the new focus
            // arrive on the same frame as the address change.
            const focused_addr = events.focusedAddress();
            const focus_changed = focused_addr != 0 and focused_addr != cached_win_address;
            if (focused_addr != 0) cached_win_address = focused_addr;

            const dirty = events.takeDirty();
            if (dirty.monitor) {
                log.info("monitor topology changed — restart hyprglaze if displays are reconfigured", .{});
            }
            if (dirty.config) {
                log.info("Hyprland reloaded its config", .{});
            }

            // Re-query `j/clients` when an event signals the visible-windows
            // list may have changed, OR every 6 frames as a backstop —
            // Hyprland is silent during interactive drag/resize, so polling
            // is the only way to track in-progress geometry changes.
            ipc_skip += 1;
            if (focus_changed or dirty.windows or dirty.workspace or ipc_skip >= 6) {
                ipc_skip = 0;
                const raw = queryRawState(&ipc, allocator, surf_h, cached_win_address);
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
            trans.update(time_f64, cached_raw_win, raw_cursor, cached_win_address);

            // Smooth all window positions toward targets
            const gs = @max(cfg.geometry_smoothing, @as(f32, 0.001));
            const win_speed = -@log(gs) * 30.0;
            const win_alpha = 1.0 - @exp(-win_speed * dt);

            // Match target windows to cached windows by nearest position
            // (Hyprland can reorder windows on focus change)
            if (target_window_count != cached_window_count) {
                // Window count changed — snap all
                for (0..target_window_count) |i| cached_windows[i] = target_windows[i];
                cached_window_count = target_window_count;
            } else {
                // Same count — match each target to nearest cached window
                var used: [hypr.max_visible_windows]bool = [_]bool{false} ** hypr.max_visible_windows;
                var matched_targets: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect = undefined;

                for (0..target_window_count) |ti| {
                    var best: u8 = 0;
                    var best_dist: f32 = std.math.inf(f32);
                    for (0..cached_window_count) |ci| {
                        if (used[ci]) continue;
                        const dx = cached_windows[ci].x - target_windows[ti].x;
                        const dy = cached_windows[ci].y - target_windows[ti].y;
                        const dw = cached_windows[ci].w - target_windows[ti].w;
                        const dh = cached_windows[ci].h - target_windows[ti].h;
                        const d = dx * dx + dy * dy + dw * dw + dh * dh;
                        if (d < best_dist) {
                            best_dist = d;
                            best = @intCast(ci);
                        }
                    }
                    used[best] = true;
                    matched_targets[best] = target_windows[ti];
                }

                for (0..cached_window_count) |i| {
                    cached_windows[i].x += (matched_targets[i].x - cached_windows[i].x) * win_alpha;
                    cached_windows[i].y += (matched_targets[i].y - cached_windows[i].y) * win_alpha;
                    cached_windows[i].w += (matched_targets[i].w - cached_windows[i].w) * win_alpha;
                    cached_windows[i].h += (matched_targets[i].h - cached_windows[i].h) * win_alpha;
                    cached_windows[i].address = matched_targets[i].address;
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
            });
            effect.upload(&shader_prog);

            drawFrame(&shader_prog, &egl_state, surf_w, surf_h, time, &trans, &cached_windows, cached_window_count);
            try wl.requestFrame();
            egl_state.swapBuffers() catch |err| {
                if (err == error.EglContextLost) {
                    log.warn("EGL context lost — reinitialising graphics", .{});
                    try recreateGraphics(allocator, &egl_state, &shader_prog, &effect, &pal, &wl, shader_path_expanded);
                } else {
                    log.warn("eglSwapBuffers error: {}", .{err});
                }
            };

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

/// Tear down and rebuild the GL pipeline: EGL state, shader program, and
/// re-upload the effect's uniforms. Used after a Wayland reconnect or an
/// `EglContextLost`. The palette pointer is re-bound if present. Caller is
/// responsible for any post-reinit work (surface dimensions, requestFrame).
fn recreateGraphics(
    allocator: std.mem.Allocator,
    egl_state: *egl_mod.EglState,
    shader_prog: *shader_mod.ShaderProgram,
    effect: *effects.Effect,
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

/// Query the visible-windows list and derive the focused window's geometry
/// + metadata by looking up `focused_address` in the result. The address
/// comes from the event stream (or a one-time bootstrap query at startup),
/// so we no longer need separate `j/activewindow` and `j/cursorpos` calls
/// here — caller handles those.
///
/// `win_address` in the result is 0 when the focused window is not present
/// in the visible list (e.g. focus is on another monitor's workspace).
fn queryRawState(ipc: *const hypr.HyprIpc, allocator: std.mem.Allocator, surf_h: f32, focused_address: u64) RawState {
    const visible = ipc.visibleWindows(allocator) catch hypr.VisibleWindows{};
    var windows: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect = undefined;
    var win_info: [hypr.max_visible_windows]effects.WindowInfo = undefined;
    var focused_idx: ?usize = null;

    for (0..visible.count) |i| {
        const vw = visible.windows[i];
        windows[i] = .{
            .x = @floatFromInt(vw.x),
            .y = surf_h - (@as(f32, @floatFromInt(vw.y)) + @as(f32, @floatFromInt(vw.h))),
            .w = @floatFromInt(vw.w),
            .h = @floatFromInt(vw.h),
            .address = vw.address,
        };
        var info = effects.WindowInfo{};
        const clen: u8 = @intCast(@min(vw.class_len, 64));
        if (clen > 0) @memcpy(info.class[0..clen], vw.class[0..clen]);
        info.class_len = clen;
        const tlen: u8 = @intCast(@min(vw.title_len, 64));
        if (tlen > 0) @memcpy(info.title[0..tlen], vw.title[0..tlen]);
        info.title_len = tlen;
        win_info[i] = info;

        if (focused_address != 0 and vw.address == focused_address) {
            focused_idx = i;
        }
    }

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
        .window_count = visible.count,
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
            return .{
                .effect = try allocator.dupe(u8, cli.effect_name orelse "particles"),
                .shader = try allocator.dupe(u8, cli.shader_path orelse ""),
                .theme = if (cli.theme_name) |t| try allocator.dupe(u8, t) else null,
                .transition_duration = 0.3,
                .cursor_smoothing = 0.15,
                .geometry_smoothing = 0.12,
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
) !void {
    var new_cfg = try config_mod.load(allocator, cfg.config_path);

    trans.transition_duration = new_cfg.transition_duration;
    trans.cursor_smoothing = new_cfg.cursor_smoothing;
    trans.geometry_smoothing = new_cfg.geometry_smoothing;

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

const CliFlags = struct {
    pub const description = "Wayland shader wallpaper daemon for Hyprland with window-aware effects.";

    pub const descriptions = .{
        .config = "TOML config path (default: ~/.config/hypr/hyprglaze.toml)",
        .effect = "Effect: particles, windowglow, glitch, starfield, visualizer, milkdrop, tide, fire, etc.",
        .shader = "Fragment shader path (overrides effect default)",
        .theme = "Gogh color scheme name",
        .set_theme = "Persist a theme to the config file and exit (hot-reloads in a running daemon)",
        .list_themes = "List available themes and exit",
        .list_effects = "List available effects and exit",
        .fps = "Log frames-per-second every second",
    };

    config: ?[]const u8 = null,
    effect: ?[]const u8 = null,
    shader: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    set_theme: ?[]const u8 = null,
    list_themes: bool = false,
    list_effects: bool = false,
    fps: bool = false,
};

/// Minimal in-tree CLI parser. Supports `--key value`, `--key=value`, and
/// bool flags. Unknown args → error.
fn parseCli(allocator: std.mem.Allocator, raw_argv: []const [*:0]const u8) !CliArgs {
    var out = CliArgs{};

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

        const StrField = enum { config, effect, shader, theme, set_theme };
        const BoolField = enum { list_themes, list_effects, fps, help };

        const str_kind: ?StrField = if (std.mem.eql(u8, key, "--config")) .config
            else if (std.mem.eql(u8, key, "--effect")) .effect
            else if (std.mem.eql(u8, key, "--shader")) .shader
            else if (std.mem.eql(u8, key, "--theme")) .theme
            else if (std.mem.eql(u8, key, "--set-theme")) .set_theme
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
                std.log.info("hyprglaze [--config PATH] [--effect NAME] [--shader PATH] [--theme NAME] [--set-theme NAME] [--list-themes] [--list-effects] [--fps]", .{});
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

