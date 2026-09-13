const std = @import("std");

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("viewporter-client-protocol.h");
    @cInclude("fractional-scale-v1-client-protocol.h");
});

const log = std.log.scoped(.wayland);

/// Plenty for any real desk, and small enough to live inline. A fixed array
/// rather than an ArrayList because the registry callback is `callconv(.c)`
/// and has nowhere to report an allocation failure — and because it keeps
/// `deinit` heap-free, as it has always been.
const max_outputs = 16;
const max_output_name = 32;

const OutputEntry = struct {
    proxy: *c.wl_output,
    /// Registry name, needed to match the `global_remove` event.
    global: u32,
    /// Copied, never borrowed: the `name` event's string argument lives in
    /// libwayland's message buffer and is reused the moment the callback
    /// returns.
    name: [max_output_name]u8 = undefined,
    name_len: u8 = 0,

    fn outputName(self: *const OutputEntry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const WaylandState = struct {
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*c.wl_compositor = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    surface: ?*c.wl_surface = null,
    layer_surface: ?*c.zwlr_layer_surface_v1 = null,
    egl_window: ?*c.wl_egl_window = null,

    // --- HiDPI ---
    //
    // The layer surface is configured in *logical* pixels. Rendering a buffer
    // of that size and letting the compositor upscale costs real resolution:
    // a 3840x2160 monitor at scale 1.25 is configured 3072x1728, so a third of
    // the pixels never get drawn. Instead we render at
    // `logical * scale` and hand the surface a viewport whose destination is
    // the logical size.
    viewporter: ?*c.wp_viewporter = null,
    fractional_manager: ?*c.wp_fractional_scale_manager_v1 = null,
    viewport: ?*c.wp_viewport = null,
    fractional_scale: ?*c.wp_fractional_scale_v1 = null,
    /// Compositor's preferred scale in 120ths (150 = 1.25). 0 until the
    /// first `preferred_scale`; falls back to `output_scale`.
    scale_120: u32 = 0,
    /// Integer scale from wl_output, the pre-fractional-scale fallback.
    output_scale: i32 = 1,
    /// Buffer dimensions actually rendered. Equal to width/height when no
    /// scaling applies.
    buffer_width: u31 = 0,
    buffer_height: u31 = 0,
    /// Set when the effective scale changed, so the caller can re-init
    /// effects that captured their dimensions at construction.
    scale_changed: bool = false,

    /// True only while this struct owns a live display and registry.
    /// `display`/`registry` are non-optional, so there is no null to fall
    /// back on: without this flag a failed `connect` would leave them
    /// dangling and `deinit` would free them a second time.
    connected: bool = false,

    /// Output the layer surface is pinned to, copied inline. Empty = let the
    /// compositor choose. Must survive `reconnect`, so it is carried through
    /// the struct literal in `connect` rather than defaulted.
    target_name: [max_output_name]u8 = undefined,
    target_len: u8 = 0,

    outputs: [max_outputs]OutputEntry = undefined,
    output_count: u8 = 0,
    /// Our target output was removed from the registry. The compositor
    /// usually closes the layer surface too, but not always, so main watches
    /// both: either one means the surface is gone and has to be rebuilt once
    /// the output is back (`resurrect`). Cleared when an output with the
    /// target name is announced again.
    target_gone: bool = false,

    configured: bool = false,
    width: u31 = 0,
    height: u31 = 0,
    /// The compositor closed the layer surface. One-shot: `destroySurface`
    /// clears it, and a new surface gets its own `closed`.
    should_close: bool = false,
    frame_done: bool = true,
    /// The pending frame callback, so a surface teardown can destroy it: a
    /// callback for a destroyed surface never fires, and without this
    /// `frame_done` would stay false forever after a resurrect.
    frame_callback: ?*c.wl_callback = null,
    resize_pending: bool = false,

    pub fn targetName(self: *const WaylandState) []const u8 {
        return self.target_name[0..self.target_len];
    }

    /// Logical-to-buffer pixel ratio currently in force.
    pub fn scale(self: *const WaylandState) f32 {
        if (self.scale_120 != 0) return @as(f32, @floatFromInt(self.scale_120)) / 120.0;
        return @floatFromInt(self.output_scale);
    }

    /// Recompute the buffer size from the configured logical size and the
    /// effective scale, resizing the EGL window and the viewport to match.
    /// Idempotent; sets `scale_changed` when the buffer dimensions moved.
    fn applyScale(self: *WaylandState) void {
        if (self.width == 0 or self.height == 0) return;

        const s = self.scale();
        const bw: u31 = @intFromFloat(@round(@as(f32, @floatFromInt(self.width)) * s));
        const bh: u31 = @intFromFloat(@round(@as(f32, @floatFromInt(self.height)) * s));
        if (bw == self.buffer_width and bh == self.buffer_height) return;

        self.buffer_width = bw;
        self.buffer_height = bh;
        self.scale_changed = true;

        if (self.egl_window) |win| c.wl_egl_window_resize(win, bw, bh, 0, 0);

        if (self.viewport) |vp| {
            // Map the (possibly larger) buffer back onto the surface's logical
            // extent. Without this the compositor would treat the buffer as
            // 1:1 and the surface would overhang the output.
            c.wp_viewport_set_destination(vp, self.width, self.height);
        } else if (self.scale_120 == 0) {
            // No viewporter: integer buffer scale is the only lever, and it
            // only expresses whole numbers. Set unconditionally rather than
            // only when > 1 — dropping a monitor from scale 2 back to 1 would
            // otherwise resize the buffer while the surface still declared 2x,
            // leaving the wallpaper on a quarter of the screen or tripping a
            // size protocol error.
            if (self.surface) |surf| c.wl_surface_set_buffer_scale(surf, self.output_scale);
        }
    }

    /// Connect, bind globals, and learn every output's name. Shared by `init`
    /// and `reconnect` so the two can never drift — the pin was previously
    /// lost on reconnect because only the initial path did the second
    /// roundtrip.
    fn connect(self: *WaylandState) !void {
        const display = c.wl_display_connect(null) orelse return error.DisplayConnectFailed;
        errdefer c.wl_display_disconnect(display);
        const registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;
        errdefer c.wl_registry_destroy(registry);

        // Whole-struct reset: every field NOT named here reverts to its
        // default. Anything that must outlive a reconnect belongs in this
        // literal — which is why the target is here and not restored around
        // the assignment.
        self.* = .{
            .display = display,
            .registry = registry,
            .target_name = self.target_name,
            .target_len = self.target_len,
        };

        if (c.wl_registry_add_listener(registry, &registry_listener, self) != 0)
            return error.RegistryListenerFailed;

        // First roundtrip: the globals arrive and wl_output proxies get bound.
        if (c.wl_display_roundtrip(display) == -1) return error.RoundtripFailed;
        // Second roundtrip: wl_output.name (v4) is only sent in response to
        // the bind above, so it cannot have arrived during the first. Without
        // this the output table holds proxies with empty names and every match
        // fails.
        if (c.wl_display_roundtrip(display) == -1) return error.RoundtripFailed;

        if (self.compositor == null) return error.NoCompositor;
        if (self.layer_shell == null) return error.NoLayerShell;

        // Claim ownership only once every failure path above is behind us.
        // Until this line the errdefers above own the display and registry,
        // and `teardown` must not touch them.
        self.connected = true;
    }

    /// Two-phase init: `self` must be caller-owned storage that outlives
    /// the connection, because its address is registered as listener
    /// userdata — registry events (e.g. monitor hotplug) arrive through
    /// that pointer for the lifetime of the display.
    ///
    /// `output_name` is empty to let the compositor pick.
    pub fn init(self: *WaylandState, output_name: []const u8) !void {
        self.setTarget(output_name);
        try self.connect();
    }

    /// Point the daemon at a different output. Only meaningful before the
    /// next `createLayerSurface`/`resurrect`; the live surface stays where
    /// it is. Clears `target_gone`, since the loss was of the old target.
    pub fn setTarget(self: *WaylandState, output_name: []const u8) void {
        self.target_len = @intCast(@min(output_name.len, max_output_name));
        @memcpy(self.target_name[0..self.target_len], output_name[0..self.target_len]);
        self.target_gone = false;
    }

    /// Whether the target output is currently advertised by the compositor.
    pub fn hasTarget(self: *const WaylandState) bool {
        return self.targetOutput() != null;
    }

    /// Whether any advertised output carries this name.
    pub fn hasOutput(self: *const WaylandState, name: []const u8) bool {
        for (self.outputs[0..self.output_count]) |*e| {
            if (std.mem.eql(u8, e.outputName(), name)) return true;
        }
        return false;
    }

    fn targetOutput(self: *const WaylandState) ?*c.wl_output {
        if (self.target_len == 0) return null;
        for (self.outputs[0..self.output_count]) |*e| {
            if (std.mem.eql(u8, e.outputName(), self.targetName())) return e.proxy;
        }
        return null;
    }

    /// Names of every output the compositor advertises, for diagnostics.
    pub fn logOutputNames(self: *const WaylandState) void {
        for (self.outputs[0..self.output_count]) |*e|
            log.info("  wayland output: {s}", .{e.outputName()});
    }

    pub fn createLayerSurface(self: *WaylandState) !void {
        const out = self.targetOutput();
        // A requested output that no longer exists must fail loudly. Falling
        // through to the compositor's choice would put the wallpaper on one
        // monitor while every coordinate was rebased against another.
        if (self.target_len != 0 and out == null) return error.OutputNotFound;

        self.surface = c.wl_compositor_create_surface(self.compositor) orelse
            return error.SurfaceCreateFailed;

        self.layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell,
            self.surface,
            out, // null only when no output was requested
            c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
            "hyprglaze",
        ) orelse return error.LayerSurfaceCreateFailed;

        // Anchor to all four edges = fullscreen
        c.zwlr_layer_surface_v1_set_anchor(self.layer_surface, c.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT |
            c.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT);

        // Exclusive zone -1: ignore other exclusive zones
        c.zwlr_layer_surface_v1_set_exclusive_zone(self.layer_surface, -1);

        // No keyboard interactivity
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(self.layer_surface, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE);

        if (c.zwlr_layer_surface_v1_add_listener(self.layer_surface, &layer_surface_listener, self) != 0)
            return error.LayerSurfaceListenerFailed;

        // Ask for the compositor's preferred scale and get a viewport to map
        // the scaled buffer back onto the surface's logical size. Both are
        // optional: without them the surface renders at logical resolution,
        // which is what it always did.
        if (self.viewporter) |vp_mgr| {
            self.viewport = c.wp_viewporter_get_viewport(vp_mgr, self.surface);
            // Only ask for a fractional scale when there is a viewport to map
            // the resulting buffer back onto the surface's logical size.
            // Without one, a 1.25 scale would commit a buffer 25% larger than
            // the configured size with buffer_scale still 1 — the compositor
            // clips it or kills the client on a protocol error.
            if (self.fractional_manager) |fs_mgr| {
                self.fractional_scale = c.wp_fractional_scale_manager_v1_get_fractional_scale(fs_mgr, self.surface);
                if (self.fractional_scale) |fs|
                    _ = c.wp_fractional_scale_v1_add_listener(fs, &fractional_scale_listener, self);
            }
        }

        // Initial commit to trigger configure
        c.wl_surface_commit(self.surface);

        // Round-trip to get configure event
        if (c.wl_display_roundtrip(self.display) == -1) return error.RoundtripFailed;
    }

    pub fn createEglWindow(self: *WaylandState) !void {
        if (self.width == 0 or self.height == 0) return error.NotConfigured;

        // Buffer dimensions, not logical ones: everything downstream —
        // glViewport, iResolution, the coordinate transform — works in buffer
        // pixels so there is exactly one unit in play.
        if (self.buffer_width == 0 or self.buffer_height == 0) self.applyScale();
        const bw = if (self.buffer_width != 0) self.buffer_width else self.width;
        const bh = if (self.buffer_height != 0) self.buffer_height else self.height;

        if (self.egl_window) |win| {
            c.wl_egl_window_resize(win, bw, bh, 0, 0);
        } else {
            self.egl_window = c.wl_egl_window_create(self.surface, bw, bh) orelse
                return error.EglWindowCreateFailed;
        }
        if (self.viewport) |vp| c.wp_viewport_set_destination(vp, self.width, self.height);
    }

    pub fn requestFrame(self: *WaylandState) !void {
        const callback = c.wl_surface_frame(self.surface) orelse return error.FrameCallbackFailed;
        if (c.wl_callback_add_listener(callback, &frame_listener, self) != 0)
            return error.FrameListenerFailed;
        self.frame_callback = callback;
        self.frame_done = false;
    }

    pub fn dispatch(self: *WaylandState) !void {
        if (c.wl_display_dispatch(self.display) == -1) return error.DispatchFailed;
    }

    /// Dispatch with a timeout, for the waiting state where no surface
    /// exists and `dispatch` would block until the compositor happened to
    /// say something. libwayland's read protocol: prepare, flush, poll the
    /// fd, then read (or cancel) and dispatch what arrived. Returns whether
    /// any events arrived. `timeout_ms` is bounded by the caller's need to
    /// notice a shutdown signal, so keep it at a second or less.
    pub fn dispatchTimeout(self: *WaylandState, timeout_ms: i32) !bool {
        while (c.wl_display_prepare_read(self.display) != 0) {
            if (c.wl_display_dispatch_pending(self.display) == -1) return error.DispatchFailed;
        }
        _ = c.wl_display_flush(self.display);
        var fds = [_]std.posix.pollfd{.{
            .fd = c.wl_display_get_fd(self.display),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, timeout_ms) catch 0;
        if (ready > 0) {
            if (c.wl_display_read_events(self.display) == -1) return error.DispatchFailed;
        } else {
            c.wl_display_cancel_read(self.display);
        }
        if (c.wl_display_dispatch_pending(self.display) == -1) return error.DispatchFailed;
        return ready > 0;
    }

    /// True once the pinned output has gone away. Losing it does not always
    /// close the layer surface, so this is what the main loop watches to know
    /// it has nothing left to draw on.
    pub fn targetGone(self: *const WaylandState) bool {
        return self.target_gone;
    }

    /// Tear down Wayland-side resources and reconnect to the compositor.
    /// On success, a fresh display/registry/compositor/layer_shell/surface/egl_window
    /// is live. Caller must recreate EGL state and re-upload GL resources since the
    /// EGL display was bound to the previous wl_display pointer.
    pub fn reconnect(self: *WaylandState) !void {
        self.teardown();
        try self.connect();
        try self.createLayerSurface();
        if (!self.configured) return error.NotConfigured;
        try self.createEglWindow();
    }

    /// Rebuild the layer surface on the SAME connection: the display never
    /// went away, only the output under the surface did. Cheaper than
    /// `reconnect`, and it keeps the registry (and the output table) that
    /// told us the output is back. Caller must destroy the EGL surface
    /// first and recreate graphics after, exactly as for `reconnect`.
    /// `error.OutputNotFound` means the target is not (yet) advertised,
    /// `error.NotConfigured` that the compositor did not configure the new
    /// surface; both are "not now", not "never".
    pub fn resurrect(self: *WaylandState) !void {
        self.destroySurface();
        try self.createLayerSurface();
        if (!self.configured) return error.NotConfigured;
        try self.createEglWindow();
    }

    /// Destroy the surface and everything scoped to it, leaving the
    /// connection and the output table alive, and reset every field that
    /// describes the surface so a later `createLayerSurface` starts clean.
    /// Idempotent. Safe against a surface the compositor already closed:
    /// destroying a closed layer surface is a normal request.
    pub fn destroySurface(self: *WaylandState) void {
        if (self.connected) {
            if (self.frame_callback) |cb| c.wl_callback_destroy(cb);
            if (self.fractional_scale) |fs| c.wp_fractional_scale_v1_destroy(fs);
            if (self.viewport) |vp| c.wp_viewport_destroy(vp);
            if (self.egl_window) |win| c.wl_egl_window_destroy(win);
            if (self.layer_surface) |ls| c.zwlr_layer_surface_v1_destroy(ls);
            if (self.surface) |sf| c.wl_surface_destroy(sf);
        }
        self.frame_callback = null;
        self.fractional_scale = null;
        self.viewport = null;
        self.egl_window = null;
        self.layer_surface = null;
        self.surface = null;
        self.configured = false;
        self.width = 0;
        self.height = 0;
        self.buffer_width = 0;
        self.buffer_height = 0;
        self.scale_120 = 0;
        self.should_close = false;
        // No surface, no pending callback: let the first post-resurrect
        // frame draw without waiting on a `done` that will never come.
        self.frame_done = true;
        self.resize_pending = false;
        self.scale_changed = false;
    }

    fn releaseOutputs(self: *WaylandState) void {
        for (self.outputs[0..self.output_count]) |*e| releaseOutput(e.proxy);
        self.output_count = 0;
    }

    /// Destroy everything this struct owns and leave no field pointing at
    /// freed memory. Idempotent, which is what makes it safe both as
    /// `reconnect`'s first step and as `deinit` — `reconnect` can fail
    /// anywhere in `connect`, after which main's `defer deinit` still runs.
    fn teardown(self: *WaylandState) void {
        // EVERY destroy below marshals a request through the display, so all
        // of them belong inside this guard, not just the display and registry
        // themselves. After a failed `connect` its errdefers have already run
        // `wl_display_disconnect`, and touching any proxy that was bound on
        // that display — the wl_outputs from the first roundtrip, in
        // particular — dereferences freed memory.
        self.destroySurface();
        if (self.connected) {
            // Before the display goes: they belong to the connection being
            // torn down, and `connect` rebuilds the table from the new
            // registry.
            self.releaseOutputs();
            c.wl_registry_destroy(self.registry);
            c.wl_display_disconnect(self.display);
        }
        // Whether or not we destroyed them, drop every reference: the fields
        // must not survive as dangling pointers for a second teardown.
        self.output_count = 0;

        self.compositor = null;
        self.layer_shell = null;
        self.viewporter = null;
        self.fractional_manager = null;
        self.configured = false;
        self.connected = false;
    }

    pub fn deinit(self: *WaylandState) void {
        self.teardown();
    }
};

/// wl_output.release is a v3 destructor; below that only destroy exists.
fn releaseOutput(proxy: *c.wl_output) void {
    if (c.wl_output_get_version(proxy) >= 3) c.wl_output_release(proxy) else c.wl_output_destroy(proxy);
}

// --- Registry listener ---

const registry_listener = c.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data));
    const iface = std.mem.span(interface orelse return);

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        state.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, iface, "zwlr_layer_shell_v1")) {
        state.layer_shell = @ptrCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, @min(version, 1)));
    } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
        state.viewporter = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_viewporter_interface, 1));
    } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
        state.fractional_manager = @ptrCast(c.wl_registry_bind(registry, name, &c.wp_fractional_scale_manager_v1_interface, 1));
    } else if (std.mem.eql(u8, iface, "wl_output")) {
        // The connector name (DP-1, HDMI-A-1) only exists from v4. Below that
        // there is nothing to match --output against.
        if (version < 4) {
            log.warn("compositor offers wl_output v{d}; --output needs v4 for the name event", .{version});
            return;
        }
        if (state.output_count >= max_outputs) {
            log.warn("more than {d} outputs; ignoring the rest", .{max_outputs});
            return;
        }
        const proxy_opt: ?*c.wl_output = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_output_interface, 4));
        const proxy = proxy_opt orelse return;
        state.outputs[state.output_count] = .{ .proxy = proxy, .global = name };
        state.output_count += 1;
        _ = c.wl_output_add_listener(proxy, &output_listener, state);
    }
}

fn registryGlobalRemove(data: ?*anyopaque, _: ?*c.wl_registry, name: u32) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data));
    var i: u8 = 0;
    while (i < state.output_count) : (i += 1) {
        if (state.outputs[i].global != name) continue;
        const gone = state.outputs[i];
        if (state.target_len != 0 and std.mem.eql(u8, gone.outputName(), state.targetName()))
            state.target_gone = true;
        releaseOutput(gone.proxy);
        state.outputs[i] = state.outputs[state.output_count - 1]; // swap-remove
        state.output_count -= 1;
        return;
    }
}

// --- Output listener ---
//
// Only the name is kept. Every geometric quantity comes from `j/monitors`
// (logical layout coords) or from the layer-surface configure; wl_output's
// geometry/mode are *physical* pixels, so storing them would only invite
// someone to mix the two units later.
//
// libwayland dispatches through this table unconditionally, so every member
// must be non-null even when we ignore the event.

fn outputGeometry(_: ?*anyopaque, _: ?*c.wl_output, _: i32, _: i32, _: i32, _: i32, _: i32, _: [*c]const u8, _: [*c]const u8, _: i32) callconv(.c) void {}
fn outputMode(_: ?*anyopaque, _: ?*c.wl_output, _: u32, _: i32, _: i32, _: i32) callconv(.c) void {}
fn outputDone(_: ?*anyopaque, _: ?*c.wl_output) callconv(.c) void {}
fn outputDescription(_: ?*anyopaque, _: ?*c.wl_output, _: [*c]const u8) callconv(.c) void {}

/// Integer output scale — the fallback when the compositor has no
/// fractional-scale protocol. Only our target output's scale is of interest.
fn outputScale(data: ?*anyopaque, output: ?*c.wl_output, s: i32) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data));
    const proxy = output orelse return;
    if (state.targetOutput()) |target| {
        if (target != proxy) return;
    }
    if (s <= 0 or s == state.output_scale) return;
    state.output_scale = s;
    // Same as fractionalPreferredScale: without this the buffer keeps its old
    // size while scale() already reports the new one, and the next unrelated
    // resize would resize the buffer against a stale surf_scale in main.
    state.applyScale();
}

// --- Fractional scale listener ---

fn fractionalPreferredScale(data: ?*anyopaque, _: ?*c.wp_fractional_scale_v1, scale_120: u32) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data));
    if (scale_120 == 0) return;
    state.scale_120 = scale_120;
    state.applyScale();
}

const fractional_scale_listener = c.wp_fractional_scale_v1_listener{
    .preferred_scale = fractionalPreferredScale,
};

fn outputName(data: ?*anyopaque, output: ?*c.wl_output, name: [*c]const u8) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data));
    const proxy = output orelse return;
    // Valid only for the duration of this call — copy, never retain.
    const s = std.mem.span(name orelse return);
    for (state.outputs[0..state.output_count]) |*e| {
        if (e.proxy != proxy) continue;
        e.name_len = @intCast(@min(s.len, max_output_name));
        @memcpy(e.name[0..e.name_len], s[0..e.name_len]);
        // Our output came back. A mode or monitor-rule change destroys and
        // re-creates the global, often inside one dispatch batch, and without
        // clearing the flag here the daemon would exit reporting a monitor
        // that is present and healthy. Cleared on the name rather than on the
        // bind, so an unrelated output appearing cannot mask a real loss.
        if (state.target_len != 0 and std.mem.eql(u8, e.outputName(), state.targetName()))
            state.target_gone = false;
        return;
    }
}

const output_listener = c.wl_output_listener{
    .geometry = outputGeometry,
    .mode = outputMode,
    .done = outputDone,
    .scale = outputScale,
    .name = outputName,
    .description = outputDescription,
};

// --- Layer surface listener ---

const layer_surface_listener = c.zwlr_layer_surface_v1_listener{
    .configure = layerSurfaceConfigure,
    .closed = layerSurfaceClosed,
};

fn layerSurfaceConfigure(
    data: ?*anyopaque,
    surface: ?*c.zwlr_layer_surface_v1,
    serial: u32,
    width: u32,
    height: u32,
) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data));

    // Logical pixels. The buffer we render is `logical * scale`; applyScale
    // derives it and resizes the EGL window and viewport to match.
    const new_w: u31 = @intCast(width);
    const new_h: u31 = @intCast(height);
    const changed = state.configured and (new_w != state.width or new_h != state.height);
    state.width = new_w;
    state.height = new_h;
    state.configured = true;
    state.applyScale();
    if (changed) state.resize_pending = true;

    c.zwlr_layer_surface_v1_ack_configure(surface, serial);
}

fn layerSurfaceClosed(data: ?*anyopaque, _: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data));
    state.should_close = true;
}

// --- Frame callback listener ---

const frame_listener = c.wl_callback_listener{
    .done = frameDone,
};

fn frameDone(data: ?*anyopaque, callback: ?*c.wl_callback, _: u32) callconv(.c) void {
    const state: *WaylandState = @ptrCast(@alignCast(data));
    state.frame_done = true;
    state.frame_callback = null;
    if (callback) |cb| c.wl_callback_destroy(cb);
}
