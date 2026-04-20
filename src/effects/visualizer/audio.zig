const std = @import("std");

const c = @cImport({
    @cInclude("pulse/simple.h");
    @cInclude("pulse/error.h");
});

pub const sample_count = 256;
pub const bin_count = 64;

pub const AudioCapture = struct {
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Double buffer: audio thread writes to back, main thread reads front
    bins: [2][bin_count]f32 = [_][bin_count]f32{[_]f32{0} ** bin_count} ** 2,
    back: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    has_data: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    source: [256]u8 = undefined,
    source_len: u16 = 0,

    pub fn init(sink_name: ?[]const u8) AudioCapture {
        var self = AudioCapture{};

        if (sink_name) |name| {
            // User specified a sink - append .monitor
            const monitor = std.fmt.bufPrint(&self.source, "{s}.monitor", .{name}) catch "";
            self.source_len = @intCast(monitor.len);
        } else {
            // Auto-detect: run `pactl get-default-sink` and append .monitor
            self.source_len = autoDetectMonitor(&self.source);
        }

        return self;
    }

    pub fn start(self: *AudioCapture) void {
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, captureLoop, .{self}) catch |err| {
            std.debug.print("Audio thread failed: {}\n", .{err});
            return;
        };
    }

    pub fn stop(self: *AudioCapture) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// Get current frequency bins (called from main thread)
    pub fn getBins(self: *AudioCapture) [bin_count]f32 {
        if (!self.has_data.load(.acquire)) return [_]f32{0} ** bin_count;
        const front: u8 = 1 - self.back.load(.acquire);
        return self.bins[front];
    }

    fn getSourceZ(self: *AudioCapture) ?[*:0]const u8 {
        if (self.source_len == 0) return null;
        if (self.source_len < self.source.len) {
            self.source[self.source_len] = 0;
            return @ptrCast(self.source[0..self.source_len :0]);
        }
        return null;
    }

    fn captureLoop(self: *AudioCapture) void {
        const ss = c.pa_sample_spec{
            .format = c.PA_SAMPLE_FLOAT32LE,
            .rate = 44100,
            .channels = 1,
        };

        const source_z = self.getSourceZ();

        var err: c_int = 0;
        const pa = c.pa_simple_new(
            null,
            "hyprglaze",
            c.PA_STREAM_RECORD,
            source_z,
            "visualizer",
            &ss,
            null,
            null,
            &err,
        );

        if (pa == null) {
            std.debug.print("PulseAudio connect failed: {s}\n", .{c.pa_strerror(err)});
            return;
        }
        defer c.pa_simple_free(pa);

        if (source_z) |sz| {
            std.debug.print("Audio capture started: {s}\n", .{sz});
        } else {
            std.debug.print("Audio capture started: default source\n", .{});
        }

        var samples: [sample_count]f32 = undefined;

        while (self.running.load(.acquire)) {
            const ret = c.pa_simple_read(
                pa,
                @ptrCast(&samples),
                sample_count * @sizeOf(f32),
                &err,
            );
            if (ret < 0) continue;

            // Simple DFT -> magnitude for bin_count bins
            var result: [bin_count]f32 = undefined;
            for (0..bin_count) |k| {
                var re: f32 = 0;
                var im: f32 = 0;
                for (0..sample_count) |n| {
                    const angle = -2.0 * std.math.pi * @as(f32, @floatFromInt(k + 1)) * @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(sample_count));
                    re += samples[n] * @cos(angle);
                    im += samples[n] * @sin(angle);
                }
                const mag = @sqrt(re * re + im * im) / @as(f32, @floatFromInt(sample_count));
                result[k] = @max(0, @log2(1.0 + mag * 50.0));
            }

            // Write to back buffer, flip
            const b = self.back.load(.acquire);
            self.bins[b] = result;
            self.back.store(1 - b, .release);
            self.has_data.store(true, .release);
        }

        std.debug.print("Audio capture stopped\n", .{});
    }
};

fn autoDetectMonitor(buf: *[256]u8) u16 {
    const argv = [_][]const u8{ "pactl", "get-default-sink" };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return 0;

    var read_buf: [200]u8 = undefined;
    const n = child.stdout.?.read(&read_buf) catch {
        _ = child.wait() catch {};
        return 0;
    };
    _ = child.wait() catch {};

    if (n == 0) return 0;

    // Strip trailing newline
    var sink_len = n;
    while (sink_len > 0 and (read_buf[sink_len - 1] == '\n' or read_buf[sink_len - 1] == '\r')) sink_len -= 1;
    if (sink_len == 0) return 0;

    // Copy sink name + append .monitor
    const monitor_suffix = ".monitor";
    if (sink_len + monitor_suffix.len < buf.len) {
        @memcpy(buf[0..sink_len], read_buf[0..sink_len]);
        @memcpy(buf[sink_len .. sink_len + monitor_suffix.len], monitor_suffix);
        const total: u16 = @intCast(sink_len + monitor_suffix.len);
        std.debug.print("Auto-detected monitor: {s}\n", .{buf[0..total]});
        return total;
    }
    return 0;
}
