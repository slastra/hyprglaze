const std = @import("std");
const c = @cImport({
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("GLES3/gl3.h");
    @cInclude("wayland-egl.h");
});

pub const EglState = struct {
    display: c.EGLDisplay,
    context: c.EGLContext,
    surface: c.EGLSurface,
    config: c.EGLConfig,

    pub fn init(wl_display: *anyopaque, wl_egl_window: *anyopaque) !EglState {
        const display = c.eglGetDisplay(@ptrCast(wl_display));
        if (display == c.EGL_NO_DISPLAY) return error.EglNoDisplay;

        var major: c.EGLint = 0;
        var minor: c.EGLint = 0;
        if (c.eglInitialize(display, &major, &minor) != c.EGL_TRUE)
            return error.EglInitFailed;
        errdefer _ = c.eglTerminate(display);

        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) != c.EGL_TRUE)
            return error.EglBindApiFailed;

        // Choose config: GLES 3.0, window surface, RGBA8
        const config_attribs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      8,
            c.EGL_NONE,
        };

        var config: c.EGLConfig = null;
        var num_configs: c.EGLint = 0;
        if (c.eglChooseConfig(display, &config_attribs, &config, 1, &num_configs) != c.EGL_TRUE)
            return error.EglChooseConfigFailed;
        if (num_configs == 0) return error.EglNoConfig;

        // Create GLES 3.0 context
        const context_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_MAJOR_VERSION, 3,
            c.EGL_CONTEXT_MINOR_VERSION, 0,
            c.EGL_NONE,
        };

        const context = c.eglCreateContext(display, config, c.EGL_NO_CONTEXT, &context_attribs);
        if (context == c.EGL_NO_CONTEXT) return error.EglCreateContextFailed;
        errdefer _ = c.eglDestroyContext(display, context);

        // Create window surface
        const surface = c.eglCreateWindowSurface(display, config, @intFromPtr(wl_egl_window), null);
        if (surface == c.EGL_NO_SURFACE) return error.EglCreateSurfaceFailed;
        errdefer _ = c.eglDestroySurface(display, surface);

        // Make current
        if (c.eglMakeCurrent(display, surface, surface, context) != c.EGL_TRUE)
            return error.EglMakeCurrentFailed;

        // Swap interval 0: the main loop already paces itself on its own
        // wl_surface.frame callback. At the default of 1, egl-wayland makes
        // eglSwapBuffers block on a second, private frame callback with no
        // timeout, and if the output vanishes mid-swap (a TV sleeping) the
        // compositor never answers it: the daemon hung there for good on
        // 2026-09-23, alive enough that the wake script's pgrep never
        // respawned it. Non-fatal; a driver that refuses keeps the old risk.
        _ = c.eglSwapInterval(display, 0);

        return .{
            .display = display,
            .context = context,
            .surface = surface,
            .config = config,
        };
    }

    pub fn swapBuffers(self: *const EglState) !void {
        if (c.eglSwapBuffers(self.display, self.surface) == c.EGL_TRUE) return;
        const err = c.eglGetError();
        return switch (err) {
            0x300E => error.EglContextLost, // EGL_CONTEXT_LOST
            else => error.EglSwapFailed,
        };
    }

    /// Idempotent: a second call is a no-op. recreateGraphics relies on
    /// this — it tears down before rebuilding, and if the rebuild fails
    /// the deferred deinit in main() runs against the same struct.
    pub fn deinit(self: *EglState) void {
        if (self.display == c.EGL_NO_DISPLAY) return;
        _ = c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        _ = c.eglDestroySurface(self.display, self.surface);
        _ = c.eglDestroyContext(self.display, self.context);
        _ = c.eglTerminate(self.display);
        self.display = c.EGL_NO_DISPLAY;
    }
};
