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

        // Create window surface
        const surface = c.eglCreateWindowSurface(display, config, @intFromPtr(wl_egl_window), null);
        if (surface == c.EGL_NO_SURFACE) return error.EglCreateSurfaceFailed;

        // Make current
        if (c.eglMakeCurrent(display, surface, surface, context) != c.EGL_TRUE)
            return error.EglMakeCurrentFailed;

        return .{
            .display = display,
            .context = context,
            .surface = surface,
            .config = config,
        };
    }

    pub fn swapBuffers(self: *const EglState) void {
        _ = c.eglSwapBuffers(self.display, self.surface);
    }

    pub fn deinit(self: *EglState) void {
        _ = c.eglMakeCurrent(self.display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        _ = c.eglDestroySurface(self.display, self.surface);
        _ = c.eglDestroyContext(self.display, self.context);
        _ = c.eglTerminate(self.display);
    }
};
