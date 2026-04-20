const std = @import("std");
const wayland = @import("core/wayland.zig");
const egl_mod = @import("core/egl.zig");
const shader_mod = @import("core/shader.zig");
const hypr = @import("core/hypr.zig");
const palette_mod = @import("core/palette.zig");
const transition = @import("core/transition.zig");
const config_mod = @import("core/config.zig");
const watcher_mod = @import("core/watcher.zig");
const effects = @import("effects.zig");
const particles = @import("effects/particles/system.zig");

const c = @cImport({
    @cInclude("wayland-client.h");
});

const CliArgs = struct {
    shader_path: ?[]const u8 = null,
    theme_name: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    effect_name: ?[]const u8 = null,
    list_themes: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cli = parseCli(allocator) catch |err| {
        printUsage();
        return err;
    };
    defer {
        if (cli.shader_path) |p| allocator.free(p);
        if (cli.theme_name) |t| allocator.free(t);
        if (cli.config_path) |p| allocator.free(p);
        if (cli.effect_name) |e| allocator.free(e);
    }

    if (cli.list_themes) {
        try palette_mod.listThemes(allocator);
        return;
    }

    // Load config
    var cfg = loadConfig(allocator, &cli) catch |err| {
        printUsage();
        return err;
    };
    defer config_mod.deinit(&cfg, allocator);

    // Init effect
    var effect = effects.Effect.init(cfg.effect, allocator, 0, 0, &cfg) catch |err| {
        std.debug.print("Effect init failed: {}\n", .{err});
        return err;
    };
    defer effect.deinit();

    // Resolve shader: explicit config > effect default
    const shader_path = if (cfg.shader.len > 0) cfg.shader else effect.defaultShader();
    std.debug.print("Effect: {s}\n", .{cfg.effect});
    std.debug.print("Shader: {s}\n", .{shader_path});
    if (cfg.theme) |t| std.debug.print("Theme: {s}\n", .{t});

    var shader_path_expanded = try config_mod.expandHome(allocator, shader_path);
    defer allocator.free(shader_path_expanded);

    const frag_source = loadShaderFile(allocator, shader_path_expanded) catch |err| {
        std.debug.print("Failed to load shader '{s}': {}\n", .{ shader_path_expanded, err });
        return err;
    };
    defer allocator.free(frag_source);

    // Palette
    var pal: ?palette_mod.Palette = null;
    if (cfg.theme) |theme_name| {
        pal = palette_mod.loadTheme(allocator, theme_name) catch |err| {
            std.debug.print("Failed to load theme '{s}': {}\n", .{ theme_name, err });
            return err;
        };
        std.debug.print("Palette: {s} ({d} colors)\n", .{ pal.?.themeName(), pal.?.color_count });
    }

    // Hyprland IPC
    const ipc = hypr.HyprIpc.init() catch |err| {
        std.debug.print("Hyprland IPC init failed: {}\n", .{err});
        return err;
    };

    const mon = ipc.primaryMonitor(allocator) catch |err| {
        std.debug.print("Failed to query monitor: {}\n", .{err});
        return err;
    };
    std.debug.print("Monitor: {d}x{d} scale={d:.2}\n", .{ mon.width, mon.height, mon.scale });

    // Wayland
    var wl = wayland.WaylandState.init() catch |err| {
        std.debug.print("Wayland init failed: {}\n", .{err});
        return err;
    };
    defer wl.deinit();

    wl.createLayerSurface() catch |err| {
        std.debug.print("Layer surface creation failed: {}\n", .{err});
        return err;
    };

    if (!wl.configured) return error.NotConfigured;
    std.debug.print("Surface configured: {d}x{d}\n", .{ wl.width, wl.height });

    wl.createEglWindow() catch |err| {
        std.debug.print("EGL window creation failed: {}\n", .{err});
        return err;
    };

    var egl_state = egl_mod.EglState.init(wl.display, wl.egl_window.?) catch |err| {
        std.debug.print("EGL init failed: {}\n", .{err});
        return err;
    };
    defer egl_state.deinit();

    // Shader
    var shader_prog = shader_mod.ShaderProgram.init(frag_source) catch |err| {
        std.debug.print("Shader compilation failed: {}\n", .{err});
        return err;
    };
    defer shader_prog.deinit();

    if (pal) |*p| shader_prog.setPalette(p);

    // Re-init effect with actual dimensions
    const surf_w: f32 = @floatFromInt(wl.width);
    const surf_h: f32 = @floatFromInt(wl.height);
    effect.deinit();
    effect = try effects.Effect.init(cfg.effect, allocator, surf_w, surf_h, &cfg);

    std.debug.print("Entering render loop.\n", .{});

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
                std.debug.print("Watching config: {s}\n", .{cfg.config_path});
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
    var fps_timer = try std.time.Timer.start();
    var timer = try std.time.Timer.start();

    // Seed
    const raw0 = queryRawState(&ipc, allocator, surf_h);
    trans.seed(raw0.win, raw0.cursor, raw0.win_address);
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
    for (0..raw0.window_count) |i| {
        target_windows[i] = raw0.windows[i];
    }

    // Initial render
    effect.upload(&shader_prog);
    try wl.requestFrame();
    drawFrame(&shader_prog, &egl_state, surf_w, surf_h, 0.0, &trans, &cached_windows, cached_window_count);
    egl_state.swapBuffers();

    // Main loop
    while (!wl.should_close) {
        try wl.dispatch();

        if (config_watcher) |*cw| {
            if (cw.poll()) {
                std.debug.print("Config changed, reloading...\n", .{});
                reloadConfig(allocator, &cfg, &effect, &shader_prog, &pal, &trans, &shader_path_expanded, surf_w, surf_h) catch |err| {
                    std.debug.print("Reload failed: {}\n", .{err});
                };
            }
        }

        if (wl.frame_done) {
            const elapsed_ns = timer.read();
            const time_f64: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const time: f32 = @floatCast(time_f64);
            const dt = time - prev_time;
            prev_time = time;

            // Cursor every frame, windows every 6
            const cursor = ipc.cursorPos() catch hypr.CursorPos{ .x = 0, .y = 0 };
            const raw_cursor = [2]f32{
                @floatFromInt(cursor.x),
                surf_h - @as(f32, @floatFromInt(cursor.y)),
            };

            ipc_skip += 1;
            if (ipc_skip >= 6) {
                ipc_skip = 0;
                const raw = queryRawState(&ipc, allocator, surf_h);
                cached_raw_win = raw.win;
                cached_win_address = raw.win_address;
                // Update targets
                target_window_count = raw.window_count;
                for (0..raw.window_count) |i| {
                    target_windows[i] = raw.windows[i];
                    cached_window_info[i] = raw.window_info[i];
                }
                cached_focused_class = raw.focused_class;
                cached_focused_class_len = raw.focused_class_len;
                cached_focused_title = raw.focused_title;
                cached_focused_title_len = raw.focused_title_len;
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
                for (0..target_window_count) |i| {
                    cached_windows[i] = target_windows[i];
                }
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
            egl_state.swapBuffers();

            // FPS tracking
            frame_count += 1;
            if (fps_timer.read() >= std.time.ns_per_s) {
                std.debug.print("FPS: {d}\n", .{frame_count});
                frame_count = 0;
                fps_timer.reset();
            }
        }
    }
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
    cursor: [2]f32,
    windows: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect,
    window_count: u8,
    window_info: [hypr.max_visible_windows]effects.WindowInfo,
    focused_class: [64]u8,
    focused_class_len: u8,
    focused_title: [64]u8,
    focused_title_len: u8,
};

fn queryRawState(ipc: *const hypr.HyprIpc, allocator: std.mem.Allocator, surf_h: f32) RawState {
    const cur = ipc.cursorPos() catch hypr.CursorPos{ .x = 0, .y = 0 };
    const win = (ipc.activeWindow(allocator) catch null) orelse
        hypr.WindowGeometry{ .x = 0, .y = 0, .w = 0, .h = 0 };

    const wx: f32 = @floatFromInt(win.x);
    const wy: f32 = @floatFromInt(win.y);
    const ww: f32 = @floatFromInt(win.w);
    const wh: f32 = @floatFromInt(win.h);

    const visible = ipc.visibleWindows(allocator) catch hypr.VisibleWindows{};
    var windows: [hypr.max_visible_windows]shader_mod.ShaderProgram.WindowRect = undefined;
    var win_info: [hypr.max_visible_windows]effects.WindowInfo = undefined;
    for (0..visible.count) |i| {
        const vw = visible.windows[i];
        windows[i] = .{
            .x = @floatFromInt(vw.x),
            .y = surf_h - (@as(f32, @floatFromInt(vw.y)) + @as(f32, @floatFromInt(vw.h))),
            .w = @floatFromInt(vw.w),
            .h = @floatFromInt(vw.h),
        };
        // Copy class/title metadata
        var info = effects.WindowInfo{};
        const clen: u8 = @intCast(@min(vw.class_len, 64));
        if (clen > 0) @memcpy(info.class[0..clen], vw.class[0..clen]);
        info.class_len = clen;
        const tlen: u8 = @intCast(@min(vw.title_len, 64));
        if (tlen > 0) @memcpy(info.title[0..tlen], vw.title[0..tlen]);
        info.title_len = tlen;
        win_info[i] = info;
    }

    // Focused window metadata
    var fc: [64]u8 = [_]u8{0} ** 64;
    var fc_len: u8 = 0;
    var ft: [64]u8 = [_]u8{0} ** 64;
    var ft_len: u8 = 0;
    const fcl: u8 = @intCast(@min(win.class_len, 64));
    if (fcl > 0) @memcpy(fc[0..fcl], win.class[0..fcl]);
    fc_len = fcl;
    const ftl: u8 = @intCast(@min(win.title_len, 64));
    if (ftl > 0) @memcpy(ft[0..ftl], win.title[0..ftl]);
    ft_len = ftl;

    return .{
        .win = .{ .x = wx, .y = surf_h - (wy + wh), .w = ww, .h = wh },
        .win_address = win.address,
        .cursor = .{ @floatFromInt(cur.x), surf_h - @as(f32, @floatFromInt(cur.y)) },
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
            std.debug.print("Theme reloaded: {s}\n", .{theme_name});
        } else {
            pal.* = null;
        }
    }

    // Effect change
    if (!std.mem.eql(u8, cfg.effect, new_cfg.effect)) {
        effect.deinit();
        effect.* = effects.Effect.init(new_cfg.effect, allocator, surf_w, surf_h, &new_cfg) catch |err| {
            std.debug.print("Effect '{s}' failed: {}, falling back to windowglow\n", .{ new_cfg.effect, err });
            effect.* = effects.Effect.init("windowglow", allocator, 0, 0, &new_cfg) catch unreachable;
            config_mod.deinit(&new_cfg, allocator);
            return err;
        };
        std.debug.print("Effect switched: {s}\n", .{new_cfg.effect});
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
        std.debug.print("Shader reloaded: {s}\n", .{new_shader_path});

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

fn parseCli(allocator: std.mem.Allocator) !CliArgs {
    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();
    _ = args_iter.next();

    var result = CliArgs{};
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--shader")) {
            result.shader_path = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--theme")) {
            result.theme_name = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--config")) {
            result.config_path = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--effect")) {
            result.effect_name = try allocator.dupe(u8, args_iter.next() orelse return error.MissingArg);
        } else if (std.mem.eql(u8, arg, "--list-themes")) {
            result.list_themes = true;
        }
    }
    return result;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: hyprglaze [options]
        \\       hyprglaze --list-themes
        \\
        \\Options:
        \\  --config <path>     TOML config (default: ~/.config/hypr/hyprglaze.toml)
        \\  --effect <name>     Effect: particles, windowglow, glitch, starfield, etc.
        \\  --shader <path>     Fragment shader (overrides effect default)
        \\  --theme <name>      Gogh color scheme
        \\  --list-themes       List available themes
        \\
    , .{});
}

const system_data_dir = "/usr/share/hyprglaze";

/// Resolve a data file path: try relative, then absolute, then /usr/share/hyprglaze/
fn resolveDataPath(path: []const u8, buf: *[512]u8) ?[]const u8 {
    // 1. Relative to CWD
    if (std.fs.cwd().access(path, .{})) |_| return path else |_| {}
    // 2. Absolute path
    if (path.len > 0 and path[0] == '/') {
        if (std.fs.accessAbsolute(path, .{})) |_| return path else |_| {}
    }
    // 3. System data dir fallback
    const full = std.fmt.bufPrint(buf, "{s}/{s}", .{ system_data_dir, path }) catch return null;
    if (std.fs.accessAbsolute(full, .{})) |_| return full else |_| {}
    return null;
}

fn loadShaderFile(allocator: std.mem.Allocator, path: []const u8) ![:0]const u8 {
    var resolve_buf: [512]u8 = undefined;
    const resolved = resolveDataPath(path, &resolve_buf) orelse path;

    const file = std.fs.cwd().openFile(resolved, .{}) catch |err| {
        const abs_file = std.fs.openFileAbsolute(resolved, .{}) catch return err;
        defer abs_file.close();
        const source = try abs_file.readToEndAlloc(allocator, 1024 * 1024);
        const with_sentinel = try allocator.realloc(source, source.len + 1);
        with_sentinel[source.len] = 0;
        return with_sentinel[0..source.len :0];
    };
    defer file.close();
    const source = try file.readToEndAlloc(allocator, 1024 * 1024);
    const with_sentinel = try allocator.realloc(source, source.len + 1);
    with_sentinel[source.len] = 0;
    return with_sentinel[0..source.len :0];
}
