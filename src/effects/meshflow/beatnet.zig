const std = @import("std");
const fft_mod = @import("fft.zig");
const crnn_mod = @import("crnn.zig");
const frontend_mod = @import("frontend.zig");
const iohelp = @import("../../core/io_helper.zig");

const c = @cImport({
    @cInclude("pulse/simple.h");
    @cInclude("pulse/error.h");
});

const log = std.log.scoped(.beatnet);

const Complex = fft_mod.Complex;

// BeatNet inference params (must match training):
// sample_rate=22050, win=int(0.064*22050)=1411, hop=int(0.020*22050)=441 → 50 fps.
pub const sample_rate: u32 = 22050;
pub const win_length: usize = 1411;
pub const hop_length: usize = 441;
pub const n_filters: usize = 136;
pub const feature_dim: usize = 272;

// PulseAudio fragment: one hop at a time → 50 Hz processing rate.
const frames_per_read: usize = hop_length;

/// Filterbank (built by tools/build_filterbank.py, embedded as binary).
/// Layout: i32 n_filters, i32 n_bins, then for each filter:
///   i32 start_bin, i32 stop_bin, f32 weights[stop-start].
const filterbank_blob = @embedFile("weights/filterbank.bin");

// Flat copy of filter weights, indexed by [starts[i] .. stops[i]] ranges via
// weight_offsets. Lives in BSS because the embedded blob has unaligned f32s
// mixed with i32 headers — building a contiguous f32 view avoids alignment
// hazards in the inner loop.
var fb_starts: [n_filters]u32 = undefined;
var fb_stops: [n_filters]u32 = undefined;
var fb_weight_offsets: [n_filters + 1]u32 = undefined;
var fb_weights_storage: [16384]f32 = undefined;
var fb_weights_len: usize = 0;

fn parseFilterbank() void {
    var byte_off: usize = @sizeOf(i32) * 2; // skip n_filters + n_bins header
    var weight_total: u32 = 0;
    for (0..n_filters) |i| {
        const start_ptr: *align(1) const i32 = @ptrCast(filterbank_blob.ptr + byte_off);
        const stop_ptr: *align(1) const i32 = @ptrCast(filterbank_blob.ptr + byte_off + @sizeOf(i32));
        const start_v: u32 = @intCast(start_ptr.*);
        const stop_v: u32 = @intCast(stop_ptr.*);
        fb_starts[i] = start_v;
        fb_stops[i] = stop_v;
        fb_weight_offsets[i] = weight_total;
        const w_count: u32 = stop_v - start_v;
        // Embedded blob has f32 weights at unaligned offsets; copy into aligned BSS.
        const weights_byte_off = byte_off + @sizeOf(i32) * 2;
        for (0..w_count) |k| {
            const w_ptr: *align(1) const f32 = @ptrCast(filterbank_blob.ptr + weights_byte_off + k * @sizeOf(f32));
            fb_weights_storage[weight_total + k] = w_ptr.*;
        }
        weight_total += w_count;
        byte_off += @sizeOf(i32) * 2 + w_count * @sizeOf(f32);
    }
    fb_weight_offsets[n_filters] = weight_total;
    fb_weights_len = weight_total;
}

fn applyFilterBank(mag_spec: []const f32, out: []f32) void {
    std.debug.assert(out.len == n_filters);
    for (0..n_filters) |fi| {
        const start = fb_starts[fi];
        const stop = fb_stops[fi];
        var acc: f32 = 0;
        var k: usize = start;
        var w_idx: usize = fb_weight_offsets[fi];
        while (k < stop) : ({
            k += 1;
            w_idx += 1;
        }) {
            acc += mag_spec[k] * fb_weights_storage[w_idx];
        }
        out[fi] = acc;
    }
}

/// State the BeatNet subsystem publishes for the render thread to read.
pub const BeatNetState = struct {
    beat_phase: f32 = 0, // [0,1) — interpolated between detected beats
    down_phase: f32 = 0, // [0,1) — every 4 beats by default
    tempo: f32 = 120.0,
    locked: bool = false,
    p_beat: f32 = 0,
    p_down: f32 = 0,
};

// ---------------------------------------------------------------------------
// Peak-pick + phase-locked oscillator
// ---------------------------------------------------------------------------

const plo_history: usize = 64;

const Plo = struct {
    // Beat activation history (sigmoid-of-logit) for adaptive threshold.
    p_hist: [plo_history]f32 = [_]f32{0} ** plo_history,
    p_hist_idx: usize = 0,

    // Recent inter-onset intervals (frames). Used to estimate tempo.
    ibi_hist: [12]f32 = [_]f32{0} ** 12,
    ibi_count: usize = 0,
    ibi_idx: usize = 0,

    last_beat_frame: i64 = -10_000,
    frame_idx: i64 = 0,

    // Smoothed estimate, in frames-per-beat. Clamped to [60, 200] BPM at 50 fps
    // → [15, 50] frames per beat.
    period_frames: f32 = 25.0, // = 120 BPM at 50 fps
    locked: bool = false,
    consecutive_beats: u8 = 0,
    downbeat_counter: u8 = 0,

    /// Smooth phase between detected beats.
    phase: f32 = 0,
    down_phase: f32 = 0,

    /// Process one CRNN frame; returns updated BeatNet state.
    fn step(self: *Plo, beat_logit: f32, down_logit: f32) BeatNetState {
        const p_beat = crnn_mod.sigmoid(beat_logit);
        const p_down = crnn_mod.sigmoid(down_logit);

        // Update activation history and compute adaptive threshold (median + MAD-ish).
        self.p_hist[self.p_hist_idx] = p_beat;
        self.p_hist_idx = (self.p_hist_idx + 1) % plo_history;
        var sorted: [plo_history]f32 = self.p_hist;
        std.mem.sort(f32, &sorted, {}, comptime std.sort.asc(f32));
        const median = sorted[plo_history / 2];
        // Use a simple multiplicative threshold over the median, with floor.
        const threshold = @max(0.18, median * 2.0);

        // Frame counter (always advance).
        self.frame_idx += 1;

        // Detect a beat: activation crosses threshold, refractory of 12 frames.
        const refractory_frames: i64 = 12; // ~240 ms at 50 fps
        const is_peak = p_beat > threshold and
            (self.frame_idx - self.last_beat_frame) > refractory_frames;

        if (is_peak) {
            // Inter-onset interval since the last beat.
            const ibi: f32 = @floatFromInt(self.frame_idx - self.last_beat_frame);

            // Only update tempo when IBI is plausible (60..200 BPM).
            if (ibi >= 15.0 and ibi <= 50.0) {
                self.ibi_hist[self.ibi_idx] = ibi;
                self.ibi_idx = (self.ibi_idx + 1) % self.ibi_hist.len;
                if (self.ibi_count < self.ibi_hist.len) self.ibi_count += 1;

                // Smoothed period = median over recent IBIs.
                var copy: [12]f32 = undefined;
                @memcpy(copy[0..self.ibi_count], self.ibi_hist[0..self.ibi_count]);
                std.mem.sort(f32, copy[0..self.ibi_count], {}, comptime std.sort.asc(f32));
                const median_ibi = copy[self.ibi_count / 2];
                // Lightly smooth toward the new median.
                self.period_frames = 0.7 * self.period_frames + 0.3 * median_ibi;

                self.consecutive_beats = @min(self.consecutive_beats + 1, 10);
            } else {
                // Implausible interval — likely false positive or restart.
                self.consecutive_beats = 0;
            }

            self.last_beat_frame = self.frame_idx;

            // Snap phase to 0 on a confirmed beat. Slightly smoothed so a
            // jittery few-millisecond detection error doesn't snap visibly.
            self.phase = 0.0;

            // Downbeat counter — assume 4/4 by default. Hard-rein with
            // BeatNet's own downbeat probability: if p_down very high vs
            // p_beat, treat this as a downbeat directly.
            const is_downbeat = p_down > 0.5 and p_down > p_beat * 0.8;
            if (is_downbeat) {
                self.downbeat_counter = 0;
                self.down_phase = 0.0;
            } else {
                self.downbeat_counter = (self.downbeat_counter + 1) % 4;
                self.down_phase = @as(f32, @floatFromInt(self.downbeat_counter)) / 4.0;
            }
        } else {
            // Free-wheel phase between detected beats.
            const dphase = 1.0 / self.period_frames;
            self.phase += dphase;
            if (self.phase >= 1.0) self.phase -= 1.0;
            const ddown = dphase / 4.0;
            self.down_phase += ddown;
            if (self.down_phase >= 1.0) self.down_phase -= 1.0;
        }

        // Lock state: locked after 4 consecutive plausible beats; unlocks if
        // no beat for >2 s (100 frames at 50 fps).
        if (self.consecutive_beats >= 4) self.locked = true;
        if (self.frame_idx - self.last_beat_frame > 100) {
            self.locked = false;
            self.consecutive_beats = 0;
        }

        const tempo_bpm = 60.0 * 50.0 / self.period_frames; // 50 fps

        return .{
            .beat_phase = self.phase,
            .down_phase = self.down_phase,
            .tempo = tempo_bpm,
            .locked = self.locked,
            .p_beat = p_beat,
            .p_down = p_down,
        };
    }
};

// ---------------------------------------------------------------------------
// PulseAudio capture + DSP thread
// ---------------------------------------------------------------------------

pub const BeatNet = struct {
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Triple-buffered state for lock-free atomic publish.
    states: [3]BeatNetState = [_]BeatNetState{.{}} ** 3,
    write_idx: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    read_idx: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),

    source: [256]u8 = undefined,
    source_len: u16 = 0,

    pub fn init(sink_name: ?[]const u8) BeatNet {
        // Build the filterbank lookup tables once on the calling thread so the
        // capture worker can start producing features without a lazy-init race.
        parseFilterbank();

        var self = BeatNet{};
        if (sink_name) |name| {
            const monitor = std.fmt.bufPrint(&self.source, "{s}.monitor", .{name}) catch "";
            self.source_len = @intCast(monitor.len);
        } else {
            self.source_len = iohelp.autoDetectPulseMonitor(&self.source);
        }
        return self;
    }

    pub fn start(self: *BeatNet) void {
        self.running.store(true, .release);
        self.thread = std.Thread.spawn(.{}, captureLoop, .{self}) catch |err| {
            log.err("beatnet thread failed: {}", .{err});
            return;
        };
    }

    pub fn stop(self: *BeatNet) void {
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    pub fn getState(self: *BeatNet) BeatNetState {
        return self.states[self.read_idx.load(.acquire)];
    }

    fn getSourceZ(self: *BeatNet) ?[*:0]const u8 {
        if (self.source_len == 0) return null;
        self.source[self.source_len] = 0;
        return @ptrCast(self.source[0..self.source_len :0]);
    }

    fn captureLoop(self: *BeatNet) void {
        var bl = fft_mod.Bluestein.init(std.heap.page_allocator, win_length) catch |err| {
            log.err("bluestein init failed: {}", .{err});
            return;
        };
        defer bl.deinit();

        var hann: [win_length]f32 = undefined;
        frontend_mod.fillHann(&hann);

        const scratch = std.heap.page_allocator.alloc(Complex, bl.m) catch |err| {
            log.err("scratch alloc failed: {}", .{err});
            return;
        };
        defer std.heap.page_allocator.free(scratch);
        var mag_spec: [win_length / 2 + 1]f32 = undefined; // = 706
        var bands: [n_filters]f32 = undefined;
        var log_bands: [n_filters]f32 = undefined;
        var prev_log_bands: [n_filters]f32 = [_]f32{0} ** n_filters;
        var feature: [feature_dim]f32 = undefined;
        var windowed: [win_length]f32 = undefined;
        var ring: [win_length * 2]f32 = [_]f32{0} ** (win_length * 2);
        var ring_write: usize = 0;
        var samples_since_hop: usize = 0;

        var crnn = crnn_mod.Crnn.init();
        var plo = Plo{};

        const ss = c.pa_sample_spec{
            .format = c.PA_SAMPLE_FLOAT32LE,
            .rate = sample_rate,
            .channels = 1,
        };
        const ba = c.pa_buffer_attr{
            .maxlength = @intCast(frames_per_read * @sizeOf(f32) * 4),
            .tlength = std.math.maxInt(u32),
            .prebuf = std.math.maxInt(u32),
            .minreq = std.math.maxInt(u32),
            .fragsize = @intCast(frames_per_read * @sizeOf(f32)),
        };
        const source_z = self.getSourceZ();

        var raw: [frames_per_read]f32 = undefined;

        outer: while (self.running.load(.acquire)) {
            var err: c_int = 0;
            const pa = c.pa_simple_new(
                null,
                "hyprglaze",
                c.PA_STREAM_RECORD,
                source_z,
                "beatnet",
                &ss,
                null,
                &ba,
                &err,
            ) orelse {
                log.warn("BeatNet PulseAudio connect failed: {s} — retry in 2s", .{c.pa_strerror(err)});
                iohelp.sleepNs(2 * std.time.ns_per_s);
                continue :outer;
            };
            log.info("BeatNet audio @ 22050Hz mono started: {s}", .{
                if (source_z) |sz| std.mem.sliceTo(sz, 0) else "default",
            });

            while (self.running.load(.acquire)) {
                if (c.pa_simple_read(pa, @ptrCast(&raw), frames_per_read * @sizeOf(f32), &err) < 0) {
                    log.warn("BeatNet read failed: {s} — reconnect", .{c.pa_strerror(err)});
                    c.pa_simple_free(pa);
                    continue :outer;
                }

                // Append the new mono samples to the ring.
                for (raw) |s| {
                    ring[ring_write] = s;
                    ring_write = (ring_write + 1) % ring.len;
                    samples_since_hop += 1;
                }

                // Produce one or more hops (usually exactly one per read).
                while (samples_since_hop >= hop_length) {
                    samples_since_hop -= hop_length;

                    // Extract the latest 1411 samples (most recent samples
                    // up to and including the current ring head).
                    var idx = (ring_write + ring.len - win_length) % ring.len;
                    for (0..win_length) |i| {
                        windowed[i] = ring[idx] * hann[i];
                        idx = (idx + 1) % ring.len;
                    }

                    bl.forwardRealMag(&windowed, scratch, &mag_spec);
                    applyFilterBank(&mag_spec, &bands);

                    // log(1 + x)
                    for (bands, 0..) |b, i| log_bands[i] = @log(1.0 + b);

                    // Stacked feature = [log_bands | positive_diff(log_bands)]
                    // Stack order matches np.hstack in madmom: [original, diff].
                    @memcpy(feature[0..n_filters], log_bands[0..]);
                    for (0..n_filters) |i| {
                        const d = log_bands[i] - prev_log_bands[i];
                        feature[n_filters + i] = if (d > 0) d else 0;
                    }
                    @memcpy(prev_log_bands[0..], log_bands[0..]);

                    var logits: [3]f32 = undefined;
                    crnn.forward(&feature, &logits);

                    const state = plo.step(logits[0], logits[1]);

                    // Publish via triple-buffer swap (single producer).
                    const wi = self.write_idx.load(.acquire);
                    self.states[wi] = state;
                    const old_read = self.read_idx.load(.acquire);
                    self.read_idx.store(wi, .release);
                    self.write_idx.store(old_read, .release);
                }
            }

            c.pa_simple_free(pa);
        }
    }
};
