const std = @import("std");
const c = @cImport({
    @cInclude("GLES3/gl3.h");
    @cInclude("stb/stb_image.h");
});

const log = std.log.scoped(.texture);

pub const Texture = struct {
    id: c.GLuint,
    width: i32,
    height: i32,

    const system_data_dir = "/usr/share/hyprglaze";

    pub fn loadFromFile(path: []const u8) !Texture {
        // Resolve path: relative, absolute, then system data dir
        var resolved = path;
        var sys_buf: [512]u8 = undefined;
        if (std.fs.cwd().access(path, .{})) |_| {} else |_| {
            const sys_path = std.fmt.bufPrint(&sys_buf, "{s}/{s}", .{ system_data_dir, path }) catch path;
            if (std.fs.accessAbsolute(sys_path, .{})) |_| {
                resolved = sys_path;
            } else |_| {}
        }

        // Need null-terminated path for stb
        var path_buf: [512]u8 = undefined;
        if (resolved.len >= path_buf.len) return error.PathTooLong;
        @memcpy(path_buf[0..resolved.len], resolved);
        path_buf[resolved.len] = 0;

        var w: c_int = 0;
        var h: c_int = 0;
        var channels: c_int = 0;

        c.stbi_set_flip_vertically_on_load(0); // handle flip in shader
        const data = c.stbi_load(&path_buf, &w, &h, &channels, 4); // force RGBA
        if (data == null) {
            log.err("failed to load texture: {s}", .{path});
            return error.TextureLoadFailed;
        }
        defer c.stbi_image_free(data);

        var tex_id: c.GLuint = 0;
        c.glGenTextures(1, &tex_id);
        c.glBindTexture(c.GL_TEXTURE_2D, tex_id);

        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_NEAREST);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
        c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

        c.glTexImage2D(
            c.GL_TEXTURE_2D,
            0,
            c.GL_RGBA,
            w,
            h,
            0,
            c.GL_RGBA,
            c.GL_UNSIGNED_BYTE,
            data,
        );

        log.info("texture loaded: {s} ({d}x{d})", .{ path, w, h });

        return .{
            .id = tex_id,
            .width = w,
            .height = h,
        };
    }

    pub fn bind(self: *const Texture, unit: c.GLuint) void {
        c.glActiveTexture(@as(c.GLenum, c.GL_TEXTURE0) + unit);
        c.glBindTexture(c.GL_TEXTURE_2D, self.id);
    }

    pub fn deinit(self: *Texture) void {
        c.glDeleteTextures(1, &self.id);
    }
};
