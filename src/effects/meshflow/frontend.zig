const std = @import("std");
const fft_mod = @import("fft.zig");

const Complex = fft_mod.Complex;
const Fft = fft_mod.Fft;

/// Hann-windowed magnitude STFT producer. Owns FFT tables, window, and scratch.
/// Caller feeds a frame of length `n_fft` per call; module returns |X[k]| for k=0..n_fft/2.
pub const Stft = struct {
    n_fft: usize,
    fft: Fft,
    window: []f32,
    scratch: []Complex,
    mag: []f32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n_fft: usize) !Stft {
        std.debug.assert(std.math.isPowerOfTwo(n_fft));

        const fft = try Fft.init(allocator, n_fft);
        errdefer {
            var f = fft;
            f.deinit();
        }

        const window = try allocator.alloc(f32, n_fft);
        errdefer allocator.free(window);
        const inv_nm1: f32 = 1.0 / @as(f32, @floatFromInt(n_fft - 1));
        for (0..n_fft) |i| {
            const phase: f32 = 2.0 * std.math.pi * @as(f32, @floatFromInt(i)) * inv_nm1;
            window[i] = 0.5 - 0.5 * @cos(phase);
        }

        const scratch = try allocator.alloc(Complex, n_fft);
        errdefer allocator.free(scratch);
        const mag = try allocator.alloc(f32, n_fft / 2 + 1);

        return .{
            .n_fft = n_fft,
            .fft = fft,
            .window = window,
            .scratch = scratch,
            .mag = mag,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stft) void {
        self.fft.deinit();
        self.allocator.free(self.window);
        self.allocator.free(self.scratch);
        self.allocator.free(self.mag);
    }

    /// Compute magnitude spectrum of one windowed frame.
    /// Returns a slice of length n_fft/2 + 1 valid until the next call.
    pub fn process(self: *Stft, frame: []const f32) []const f32 {
        std.debug.assert(frame.len == self.n_fft);
        for (0..self.n_fft) |i| {
            self.scratch[i] = Complex.init(frame[i] * self.window[i], 0);
        }
        self.fft.forward(self.scratch);
        for (0..self.n_fft / 2 + 1) |k| {
            self.mag[k] = self.scratch[k].abs();
        }
        return self.mag;
    }
};

/// Triangular log-spaced filter bank.
///
/// Builds `n_filters` triangular filters whose centers are log-spaced between
/// `fmin` and `fmax`. Each filter is normalized to unit sum so different bandwidths
/// produce comparable per-band energies (madmom's `norm_filters=True` convention).
pub const FilterBank = struct {
    n_filters: usize,
    n_fft: usize,
    /// Flat storage of (bin_idx, weight) pairs grouped per filter.
    bin_index: []u16,
    bin_weight: []f32,
    /// For filter i: pairs are at bin_index[filter_offset[i] .. filter_offset[i+1]]
    filter_offset: []u32,
    allocator: std.mem.Allocator,

    pub fn initTriangularLog(
        allocator: std.mem.Allocator,
        n_filters: usize,
        fmin: f32,
        fmax: f32,
        n_fft: usize,
        sample_rate: f32,
    ) !FilterBank {
        std.debug.assert(fmin > 0 and fmax > fmin);
        std.debug.assert(n_filters >= 1);

        // log-spaced edges: n_filters + 2 points (low, peaks..., high)
        var edges = try allocator.alloc(f32, n_filters + 2);
        defer allocator.free(edges);
        const log_lo: f32 = @log(fmin);
        const log_hi: f32 = @log(fmax);
        const step: f32 = (log_hi - log_lo) / @as(f32, @floatFromInt(n_filters + 1));
        for (0..n_filters + 2) |i| {
            edges[i] = @exp(log_lo + step * @as(f32, @floatFromInt(i)));
        }

        const bin_hz: f32 = sample_rate / @as(f32, @floatFromInt(n_fft));
        const n_bins = n_fft / 2 + 1;

        // First pass: count entries per filter
        var counts = try allocator.alloc(u32, n_filters);
        defer allocator.free(counts);
        @memset(counts, 0);

        // Worst-case storage: assume every bin contributes to every overlapping filter (~2 filters typically).
        // We'll size exactly after counting.
        for (0..n_filters) |fi| {
            const lo = edges[fi];
            const peak = edges[fi + 1];
            const hi = edges[fi + 2];
            const k_lo: usize = @intFromFloat(@max(0.0, @floor(lo / bin_hz)));
            const k_hi: usize = @min(n_bins - 1, @as(usize, @intFromFloat(@ceil(hi / bin_hz))));
            var k = k_lo;
            while (k <= k_hi) : (k += 1) {
                const f_hz: f32 = @as(f32, @floatFromInt(k)) * bin_hz;
                if (f_hz <= lo or f_hz >= hi) continue;
                const w: f32 = if (f_hz <= peak)
                    (f_hz - lo) / (peak - lo)
                else
                    (hi - f_hz) / (hi - peak);
                if (w > 0) counts[fi] += 1;
            }
        }

        var total: u32 = 0;
        for (counts) |c| total += c;

        const bin_index = try allocator.alloc(u16, total);
        errdefer allocator.free(bin_index);
        const bin_weight = try allocator.alloc(f32, total);
        errdefer allocator.free(bin_weight);
        const filter_offset = try allocator.alloc(u32, n_filters + 1);
        errdefer allocator.free(filter_offset);

        // Second pass: write entries and compute normalizing sums per filter
        var write: u32 = 0;
        for (0..n_filters) |fi| {
            filter_offset[fi] = write;
            const lo = edges[fi];
            const peak = edges[fi + 1];
            const hi = edges[fi + 2];
            const k_lo: usize = @intFromFloat(@max(0.0, @floor(lo / bin_hz)));
            const k_hi: usize = @min(n_bins - 1, @as(usize, @intFromFloat(@ceil(hi / bin_hz))));
            var sum: f32 = 0;
            const start = write;
            var k = k_lo;
            while (k <= k_hi) : (k += 1) {
                const f_hz: f32 = @as(f32, @floatFromInt(k)) * bin_hz;
                if (f_hz <= lo or f_hz >= hi) continue;
                const w: f32 = if (f_hz <= peak)
                    (f_hz - lo) / (peak - lo)
                else
                    (hi - f_hz) / (hi - peak);
                if (w > 0) {
                    bin_index[write] = @intCast(k);
                    bin_weight[write] = w;
                    sum += w;
                    write += 1;
                }
            }
            // Normalize to unit sum
            if (sum > 0) {
                const inv = 1.0 / sum;
                for (start..write) |idx| bin_weight[idx] *= inv;
            }
        }
        filter_offset[n_filters] = write;

        return .{
            .n_filters = n_filters,
            .n_fft = n_fft,
            .bin_index = bin_index,
            .bin_weight = bin_weight,
            .filter_offset = filter_offset,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FilterBank) void {
        self.allocator.free(self.bin_index);
        self.allocator.free(self.bin_weight);
        self.allocator.free(self.filter_offset);
    }

    /// Apply the filter bank to a magnitude spectrum. `out` length must equal n_filters.
    pub fn apply(self: *const FilterBank, mag_spec: []const f32, out: []f32) void {
        std.debug.assert(mag_spec.len == self.n_fft / 2 + 1);
        std.debug.assert(out.len == self.n_filters);
        for (0..self.n_filters) |fi| {
            const start = self.filter_offset[fi];
            const end = self.filter_offset[fi + 1];
            var acc: f32 = 0;
            var i = start;
            while (i < end) : (i += 1) {
                acc += mag_spec[self.bin_index[i]] * self.bin_weight[i];
            }
            out[fi] = acc;
        }
    }
};

/// Apply log compression in-place: x -> log(1 + x).
pub inline fn logCompress(buf: []f32) void {
    for (buf) |*x| x.* = @log(1.0 + x.*);
}

/// First-order positive difference: out[i] = max(0, cur[i] - prev[i]).
pub fn positiveDiff(cur: []const f32, prev: []const f32, out: []f32) void {
    std.debug.assert(cur.len == prev.len and prev.len == out.len);
    for (cur, prev, out) |c, p, *o| {
        const d = c - p;
        o.* = if (d > 0) d else 0;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stft single sine peak lands in correct band" {
    const n_fft: usize = 1024;
    const sample_rate: f32 = 22050.0;
    var stft = try Stft.init(std.testing.allocator, n_fft);
    defer stft.deinit();

    var frame: [n_fft]f32 = undefined;
    // Pure sine at 1000 Hz
    const f_hz: f32 = 1000.0;
    for (0..n_fft) |i| {
        const phase: f32 = 2.0 * std.math.pi * f_hz * @as(f32, @floatFromInt(i)) / sample_rate;
        frame[i] = @sin(phase);
    }
    const mag = stft.process(&frame);

    const bin_hz: f32 = sample_rate / @as(f32, @floatFromInt(n_fft));
    const expected_bin: usize = @intFromFloat(@round(f_hz / bin_hz));

    // Peak should be within ±2 bins of the expected one.
    var max_bin: usize = 0;
    var max_val: f32 = 0;
    for (mag, 0..) |m, k| {
        if (m > max_val) {
            max_val = m;
            max_bin = k;
        }
    }
    try std.testing.expect(@as(i32, @intCast(max_bin)) >=
        @as(i32, @intCast(expected_bin)) - 2);
    try std.testing.expect(@as(i32, @intCast(max_bin)) <=
        @as(i32, @intCast(expected_bin)) + 2);
}

test "filter bank: 6 perceptual bands, sine in mid band has highest energy" {
    const n_fft: usize = 1024;
    const sample_rate: f32 = 22050.0;
    var stft = try Stft.init(std.testing.allocator, n_fft);
    defer stft.deinit();
    var fb = try FilterBank.initTriangularLog(
        std.testing.allocator,
        6, // n_filters
        30.0, // fmin
        12000.0, // fmax
        n_fft,
        sample_rate,
    );
    defer fb.deinit();

    // 1000 Hz sine -> roughly mid band (band index ~3 in log-spaced 30..12000 / 6).
    var frame: [n_fft]f32 = undefined;
    const f_hz: f32 = 1000.0;
    for (0..n_fft) |i| {
        const phase: f32 = 2.0 * std.math.pi * f_hz * @as(f32, @floatFromInt(i)) / sample_rate;
        frame[i] = @sin(phase);
    }
    const mag = stft.process(&frame);

    var bands: [6]f32 = undefined;
    fb.apply(mag, &bands);

    // Find the band with max energy
    var max_band: usize = 0;
    var max_val: f32 = 0;
    for (bands, 0..) |b, i| {
        if (b > max_val) {
            max_val = b;
            max_band = i;
        }
    }

    // For 30..12000 Hz log-spaced into 6 triangles, 1 kHz peak lands in band 2 or 3.
    try std.testing.expect(max_band == 2 or max_band == 3);
    try std.testing.expect(max_val > 0);
}

test "filter bank: unit-sum normalization" {
    const n_fft: usize = 1024;
    const sample_rate: f32 = 22050.0;
    var fb = try FilterBank.initTriangularLog(
        std.testing.allocator,
        8,
        50.0,
        10000.0,
        n_fft,
        sample_rate,
    );
    defer fb.deinit();

    for (0..fb.n_filters) |fi| {
        const start = fb.filter_offset[fi];
        const end = fb.filter_offset[fi + 1];
        var sum: f32 = 0;
        var i = start;
        while (i < end) : (i += 1) sum += fb.bin_weight[i];
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), sum, 1e-4);
    }
}

test "positive diff: only positive deltas survive" {
    const cur = [_]f32{ 1.0, 0.5, 2.0, 3.0 };
    const prev = [_]f32{ 0.5, 1.0, 2.0, 1.0 };
    var out: [4]f32 = undefined;
    positiveDiff(&cur, &prev, &out);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), out[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), out[3], 1e-6);
}

test "log compression: log(1 + x)" {
    var buf = [_]f32{ 0.0, 1.0, @exp(@as(f32, 1.0)) - 1.0 };
    logCompress(&buf);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), buf[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, @log(@as(f32, 2.0))), buf[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), buf[2], 1e-5);
}
