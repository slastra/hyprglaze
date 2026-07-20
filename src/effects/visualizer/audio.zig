const std = @import("std");
const iohelp = @import("../../core/io_helper.zig");
const config_mod = @import("../../core/config.zig");

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

/// Heap-allocate an AudioCapture, resolve the monitor source from the
/// effect's `sink` config param, and start the capture thread. Pair with
/// `shutdown` in deinit (and errdefer during multi-step init).
pub fn spawn(allocator: std.mem.Allocator, params: config_mod.EffectParams) !*AudioCapture {
    const cap = try allocator.create(AudioCapture);
    cap.* = AudioCapture.init(params.getString("sink", null));
    cap.start();
    return cap;
}

/// Stop-join the capture thread, then free the AudioCapture.
pub fn shutdown(cap: *AudioCapture, allocator: std.mem.Allocator) void {
    cap.stop();
    allocator.destroy(cap);
}

pub const AudioCapture = struct {
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Triple buffer: the three slots are always partitioned between the
    // writer (being filled), `ready` (latest complete frame), and the
    // reader (being copied). Publishing and taking are both single atomic
    // exchanges on `ready`, so neither side can ever touch a slot the
    // other holds. The high bit on `ready` marks unread data; the reader
    // leaves it clear so it keeps re-reading its own slot until the next
    // publish.
    waveform: [3][256]f32 = [_][256]f32{[_]f32{0} ** 256} ** 3,
    ready: std.atomic.Value(u8) = std.atomic.Value(u8).init(1),
    write_slot: u8 = 0, // owned by the capture thread
    read_slot: u8 = 2, // owned by the render thread

    source: [256]u8 = undefined,
    source_len: u16 = 0,

    const fresh_bit: u8 = 0x80;

    pub fn init(sink_name: ?[]const u8) AudioCapture {
        var self = AudioCapture{};
        if (sink_name) |name| {
            const monitor = std.fmt.bufPrint(&self.source, "{s}.monitor", .{name}) catch "";
            self.source_len = @intCast(monitor.len);
        } else {
            self.source_len = iohelp.autoDetectPulseMonitor(&self.source);
        }
        // Keep one byte free so getSourceZ can always NUL-terminate.
        if (self.source_len > self.source.len - 1) self.source_len = self.source.len - 1;
        if (sink_name == null and self.source_len > 0) {
            log.info("auto-detected monitor: {s}", .{self.source[0..self.source_len]});
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
        // Take the ready slot only when it holds unread data; hand back the
        // slot we were reading. Otherwise keep re-reading our own slot, which
        // the writer can never claim.
        if (self.ready.load(.acquire) & fresh_bit != 0) {
            const taken = self.ready.swap(self.read_slot, .acq_rel);
            self.read_slot = taken & ~fresh_bit;
        }
        return self.waveform[self.read_slot];
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
                const wi = self.write_slot;
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

                // Publish: exchange the filled slot into ready and reclaim
                // whatever was there (an old frame the reader never claimed,
                // or the slot the reader just handed back).
                const old = self.ready.swap(wi | fresh_bit, .acq_rel);
                self.write_slot = old & ~fresh_bit;
            }

            c.pa_simple_free(pa);
        }
    }
};

