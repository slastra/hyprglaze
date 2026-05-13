const std = @import("std");

const c = @cImport({
    @cInclude("pulse/simple.h");
    @cInclude("pulse/error.h");
});

const log = std.log.scoped(.audio);

pub const samples_per_channel = 128;

const sample_rate = 44100;
const channels = 2;
const frames_per_read = sample_rate / 60;
const read_floats = frames_per_read * channels;

pub const AudioCapture = struct {
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    waveform: [3][256]f32 = [_][256]f32{[_]f32{0} ** 256} ** 3,
    write_idx: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    read_idx: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),

    source: [256]u8 = undefined,
    source_len: u16 = 0,

    pub fn init(sink_name: ?[]const u8) AudioCapture {
        var self = AudioCapture{};
        if (sink_name) |name| {
            const monitor = std.fmt.bufPrint(&self.source, "{s}.monitor", .{name}) catch "";
            self.source_len = @intCast(monitor.len);
        } else {
            self.source_len = autoDetectMonitor(&self.source);
        }
        return self;
    }

    pub fn start(self: *AudioCapture) void {
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, captureLoop, .{self}) catch |err| {
            log.err("audio thread failed: {}", .{err});
            return;
        };
    }

    pub fn stop(self: *AudioCapture) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn getWaveform(self: *AudioCapture) [256]f32 {
        return self.waveform[self.read_idx.load(.acquire)];
    }

    fn getSourceZ(self: *AudioCapture) ?[*:0]const u8 {
        if (self.source_len == 0) return null;
        self.source[self.source_len] = 0;
        return @ptrCast(self.source[0..self.source_len :0]);
    }

    fn captureLoop(self: *AudioCapture) void {
        const ss = c.pa_sample_spec{
            .format = c.PA_SAMPLE_FLOAT32LE,
            .rate = sample_rate,
            .channels = channels,
        };
        const ba = c.pa_buffer_attr{
            .maxlength = @intCast(read_floats * @sizeOf(f32) * 2),
            .tlength = std.math.maxInt(u32),
            .prebuf = std.math.maxInt(u32),
            .minreq = std.math.maxInt(u32),
            .fragsize = @intCast(read_floats * @sizeOf(f32)),
        };

        const source_z = self.getSourceZ();
        const step = frames_per_read / samples_per_channel;
        var raw: [read_floats]f32 = undefined;

        outer: while (self.running.load(.acquire)) {
            var err: c_int = 0;
            const pa = c.pa_simple_new(
                null, "hyprglaze", c.PA_STREAM_RECORD,
                source_z, "visualizer", &ss, null, &ba, &err,
            ) orelse {
                log.warn("PulseAudio connect failed: {s} — retry in 2s", .{c.pa_strerror(err)});
                _ = nanosleep(&.{ .sec = 2, .nsec = 0 }, null);
                continue :outer;
            };

            log.info("audio capture started: {s}", .{
                if (source_z) |sz| std.mem.sliceTo(sz, 0) else "default",
            });

            while (self.running.load(.acquire)) {
                if (c.pa_simple_read(pa, @ptrCast(&raw), read_floats * @sizeOf(f32), &err) < 0) {
                    log.warn("PulseAudio read failed: {s} — reconnecting", .{c.pa_strerror(err)});
                    c.pa_simple_free(pa);
                    continue :outer;
                }

                // Downsample to 128 samples per channel, averaging each step
                const wi = self.write_idx.load(.acquire);
                for (0..samples_per_channel) |i| {
                    var left: f32 = 0;
                    var right: f32 = 0;
                    for (0..step) |j| {
                        const src = (i * step + j) * channels;
                        left += raw[src];
                        right += raw[src + 1];
                    }
                    const inv = 1.0 / @as(f32, @floatFromInt(step));
                    self.waveform[wi][i] = left * inv;
                    self.waveform[wi][128 + i] = right * inv;
                }

                // Publish
                const old_read = self.read_idx.load(.acquire);
                self.read_idx.store(wi, .release);
                self.write_idx.store(old_read, .release);
            }

            c.pa_simple_free(pa);
        }
    }
};

// libc popen/pclose — std.process.Child.init was removed in Zig 0.16 and the
// replacement async-Io spawn() is overkill for one-shot synchronous capture.
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(stream: *anyopaque) c_int;
extern "c" fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *anyopaque) usize;
const Timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;

fn autoDetectMonitor(buf: *[256]u8) u16 {
    const stream = popen("pactl get-default-sink 2>/dev/null", "r") orelse return 0;
    defer _ = pclose(stream);

    var read_buf: [200]u8 = undefined;
    const n = fread(@ptrCast(&read_buf), 1, read_buf.len, stream);
    if (n == 0) return 0;

    // Strip trailing whitespace
    var len = n;
    while (len > 0 and (read_buf[len - 1] == '\n' or read_buf[len - 1] == '\r')) len -= 1;
    if (len == 0) return 0;

    const suffix = ".monitor";
    if (len + suffix.len >= buf.len) return 0;

    @memcpy(buf[0..len], read_buf[0..len]);
    @memcpy(buf[len .. len + suffix.len], suffix);
    const total: u16 = @intCast(len + suffix.len);
    log.info("auto-detected monitor: {s}", .{buf[0..total]});
    return total;
}
