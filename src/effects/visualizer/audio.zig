const std = @import("std");
const iohelp = @import("../../core/io_helper.zig");

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
            self.source_len = iohelp.autoDetectPulseMonitor(&self.source);
            if (self.source_len > 0) {
                log.info("auto-detected monitor: {s}", .{self.source[0..self.source_len]});
            }
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
                iohelp.sleepNs(2 * std.time.ns_per_s);
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

