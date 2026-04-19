const std = @import("std");
const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
});

pub const WaylandState = struct {
    display: *c.wl_display,
    registry: *c.wl_registry,
    compositor: ?*c.wl_compositor = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    surface: ?*c.wl_surface = null,
    layer_surface: ?*c.zwlr_layer_surface_v1 = null,
    egl_window: ?*c.wl_egl_window = null,

    configured: bool = false,
    width: u31 = 0,
    height: u31 = 0,
    should_close: bool = false,
    frame_done: bool = true,

    pub fn init() !WaylandState {
        const display = c.wl_display_connect(null) orelse return error.DisplayConnectFailed;
        const registry = c.wl_display_get_registry(display) orelse return error.RegistryFailed;

        var state = WaylandState{
            .display = display,
            .registry = registry,
        };

        if (c.wl_registry_add_listener(registry, &registry_listener, &state) != 0)
            return error.RegistryListenerFailed;

        // Round-trip to get globals
        if (c.wl_display_roundtrip(display) == -1) return error.RoundtripFailed;

        if (state.compositor == null) return error.NoCompositor;
        if (state.layer_shell == null) return error.NoLayerShell;

        return state;
    }

    pub fn createLayerSurface(self: *WaylandState) !void {
        self.surface = c.wl_compositor_create_surface(self.compositor) orelse
            return error.SurfaceCreateFailed;

        self.layer_surface = c.zwlr_layer_shell_v1_get_layer_surface(
            self.layer_shell,
            self.surface,
            null, // output — null = compositor chooses
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

        // Initial commit to trigger configure
        c.wl_surface_commit(self.surface);

        // Round-trip to get configure event
        if (c.wl_display_roundtrip(self.display) == -1) return error.RoundtripFailed;
    }

    pub fn createEglWindow(self: *WaylandState) !void {
        if (self.width == 0 or self.height == 0) return error.NotConfigured;

        if (self.egl_window) |win| {
            c.wl_egl_window_resize(win, self.width, self.height, 0, 0);
        } else {
            self.egl_window = c.wl_egl_window_create(self.surface, self.width, self.height) orelse
                return error.EglWindowCreateFailed;
        }
    }

    pub fn requestFrame(self: *WaylandState) !void {
        const callback = c.wl_surface_frame(self.surface) orelse return error.FrameCallbackFailed;
        if (c.wl_callback_add_listener(callback, &frame_listener, self) != 0)
            return error.FrameListenerFailed;
        self.frame_done = false;
    }

    pub fn dispatch(self: *WaylandState) !void {
        if (c.wl_display_dispatch(self.display) == -1) return error.DispatchFailed;
    }

    pub fn deinit(self: *WaylandState) void {
        if (self.egl_window) |win| c.wl_egl_window_destroy(win);
        if (self.layer_surface) |ls| c.zwlr_layer_surface_v1_destroy(ls);
        if (self.surface) |s| c.wl_surface_destroy(s);
        c.wl_registry_destroy(self.registry);
        c.wl_display_disconnect(self.display);
    }
};

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
    }
}

fn registryGlobalRemove(_: ?*anyopaque, _: ?*c.wl_registry, _: u32) callconv(.c) void {}

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

    state.width = @intCast(width);
    state.height = @intCast(height);
    state.configured = true;

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
    if (callback) |cb| c.wl_callback_destroy(cb);
}
