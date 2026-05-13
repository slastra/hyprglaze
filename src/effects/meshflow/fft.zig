const std = @import("std");

pub const Complex = struct {
    re: f32,
    im: f32,

    pub inline fn init(re: f32, im: f32) Complex {
        return .{ .re = re, .im = im };
    }

    pub inline fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub inline fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub inline fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = a.re * b.re - a.im * b.im,
            .im = a.re * b.im + a.im * b.re,
        };
    }

    pub inline fn magSq(a: Complex) f32 {
        return a.re * a.re + a.im * a.im;
    }

    pub inline fn abs(a: Complex) f32 {
        return @sqrt(a.magSq());
    }
};

pub const Fft = struct {
    n: usize,
    log2n: u6,
    twiddles: []Complex,
    bit_reverse: []u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n: usize) !Fft {
        std.debug.assert(std.math.isPowerOfTwo(n));
        const log2n: u6 = @intCast(std.math.log2_int(usize, n));

        const twiddles = try allocator.alloc(Complex, n / 2);
        const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(n));
        for (0..n / 2) |k| {
            const angle: f32 = -2.0 * std.math.pi * @as(f32, @floatFromInt(k)) * inv_n;
            twiddles[k] = Complex.init(@cos(angle), @sin(angle));
        }

        const bit_reverse = try allocator.alloc(u32, n);
        for (0..n) |i| {
            var x: u32 = @intCast(i);
            var r: u32 = 0;
            var b: u6 = 0;
            while (b < log2n) : (b += 1) {
                r = (r << 1) | (x & 1);
                x >>= 1;
            }
            bit_reverse[i] = r;
        }

        return .{
            .n = n,
            .log2n = log2n,
            .twiddles = twiddles,
            .bit_reverse = bit_reverse,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Fft) void {
        self.allocator.free(self.twiddles);
        self.allocator.free(self.bit_reverse);
    }

    pub fn forward(self: *const Fft, data: []Complex) void {
        std.debug.assert(data.len == self.n);

        for (0..self.n) |i| {
            const j = self.bit_reverse[i];
            if (j > i) std.mem.swap(Complex, &data[i], &data[j]);
        }

        var block: usize = 2;
        while (block <= self.n) : (block *= 2) {
            const half = block / 2;
            const tw_step = self.n / block;
            var start: usize = 0;
            while (start < self.n) : (start += block) {
                var j: usize = 0;
                while (j < half) : (j += 1) {
                    const tw = self.twiddles[j * tw_step];
                    const upper = data[start + j];
                    const lower = data[start + j + half].mul(tw);
                    data[start + j] = upper.add(lower);
                    data[start + j + half] = upper.sub(lower);
                }
            }
        }
    }

    pub fn forwardReal(
        self: *const Fft,
        real_in: []const f32,
        scratch: []Complex,
        out_mag: []f32,
    ) void {
        std.debug.assert(real_in.len == self.n);
        std.debug.assert(scratch.len == self.n);
        std.debug.assert(out_mag.len >= self.n / 2 + 1);
        for (0..self.n) |i| {
            scratch[i] = Complex.init(real_in[i], 0);
        }
        self.forward(scratch);
        for (0..self.n / 2 + 1) |k| {
            out_mag[k] = scratch[k].abs();
        }
    }

    /// Inverse FFT via `ifft(X) = conj(fft(conj(X))) / N`.
    /// In-place. `data.len` must equal `self.n`.
    pub fn inverse(self: *const Fft, data: []Complex) void {
        std.debug.assert(data.len == self.n);
        for (data) |*x| x.im = -x.im;
        self.forward(data);
        const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(self.n));
        for (data) |*x| {
            x.re = x.re * inv_n;
            x.im = -x.im * inv_n;
        }
    }
};

/// Bluestein chirp-z algorithm: arbitrary-length N DFT via radix-2 FFT(M)
/// where M = next_pow2(2N - 1). Used by the BeatNet frontend for the 1411-pt
/// transform madmom does natively but our radix-2 FFT can't handle directly.
pub const Bluestein = struct {
    n: usize,
    m: usize, // padded FFT size (power of 2, ≥ 2N-1)
    fft: Fft, // size m
    chirp: []Complex, // length n: c[k] = exp(-iπk²/N)
    kernel_fft: []Complex, // length m: FFT of the conjugate-chirp kernel
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, n: usize) !Bluestein {
        std.debug.assert(n >= 2);
        var m: usize = 1;
        while (m < 2 * n - 1) m *= 2;

        const fft = try Fft.init(allocator, m);
        errdefer {
            var f = fft;
            f.deinit();
        }

        const chirp = try allocator.alloc(Complex, n);
        errdefer allocator.free(chirp);
        const inv_n: f64 = 1.0 / @as(f64, @floatFromInt(n));
        for (0..n) |k| {
            const kk: f64 = @floatFromInt(k);
            // angle = -π k² / N
            const angle: f64 = -std.math.pi * kk * kk * inv_n;
            chirp[k] = Complex.init(@floatCast(@cos(angle)), @floatCast(@sin(angle)));
        }

        // Build the convolution kernel b in time domain (length m):
        //   b[0..n)            = conj(chirp[0..n])
        //   b[m-n+1..m)        = conj(chirp[m-k]) — mirror of the same chirp
        //   b[n..m-n+1)        = 0
        // Equivalently: b[k] = exp(+i π k² / N) for k near 0 or m, with the wraparound
        // pattern that makes the M-point cyclic convolution produce the correct (n-length)
        // linear convolution.
        const kernel = try allocator.alloc(Complex, m);
        defer allocator.free(kernel);
        for (kernel) |*k| k.* = Complex.init(0, 0);
        kernel[0] = Complex.init(chirp[0].re, -chirp[0].im);
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const c = chirp[i];
            const conj = Complex.init(c.re, -c.im);
            kernel[i] = conj;
            kernel[m - i] = conj;
        }

        const kernel_fft = try allocator.alloc(Complex, m);
        errdefer allocator.free(kernel_fft);
        @memcpy(kernel_fft, kernel);
        fft.forward(kernel_fft);

        return .{
            .n = n,
            .m = m,
            .fft = fft,
            .chirp = chirp,
            .kernel_fft = kernel_fft,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Bluestein) void {
        self.fft.deinit();
        self.allocator.free(self.chirp);
        self.allocator.free(self.kernel_fft);
    }

    /// Compute N-point DFT of `real_in` (length N) and write magnitudes to
    /// `out_mag` (length N/2 + 1, matching the real-input convention).
    /// `scratch` must have length m (the padded FFT size).
    pub fn forwardRealMag(
        self: *const Bluestein,
        real_in: []const f32,
        scratch: []Complex,
        out_mag: []f32,
    ) void {
        std.debug.assert(real_in.len == self.n);
        std.debug.assert(scratch.len == self.m);
        std.debug.assert(out_mag.len >= self.n / 2 + 1);

        // y[k] = x[k] * chirp[k] for k=0..n; rest zero
        for (0..self.n) |k| {
            const ch = self.chirp[k];
            scratch[k] = Complex.init(real_in[k] * ch.re, real_in[k] * ch.im);
        }
        for (self.n..self.m) |k| scratch[k] = Complex.init(0, 0);

        self.fft.forward(scratch);
        // pointwise multiply by precomputed kernel FFT
        for (0..self.m) |k| scratch[k] = scratch[k].mul(self.kernel_fft[k]);
        self.fft.inverse(scratch);

        // X[k] = z[k] * chirp[k] for k=0..n; magnitude only
        for (0..self.n / 2 + 1) |k| {
            const ch = self.chirp[k];
            const out = scratch[k].mul(ch);
            out_mag[k] = @sqrt(out.re * out.re + out.im * out.im);
        }
    }
};

test "fft inverse roundtrip" {
    var fft = try Fft.init(std.testing.allocator, 32);
    defer fft.deinit();

    var data: [32]Complex = undefined;
    for (0..32) |i| {
        data[i] = Complex.init(@floatFromInt(i), @floatFromInt(i * 2));
    }
    const orig: [32]Complex = data;

    fft.forward(&data);
    fft.inverse(&data);

    for (0..32) |i| {
        try std.testing.expectApproxEqAbs(orig[i].re, data[i].re, 1e-3);
        try std.testing.expectApproxEqAbs(orig[i].im, data[i].im, 1e-3);
    }
}

test "bluestein matches direct DFT for arbitrary N" {
    const n: usize = 17; // small prime, hardest case for our radix-2 FFT to handle
    var bl = try Bluestein.init(std.testing.allocator, n);
    defer bl.deinit();

    // Pure sine at bin 3 → peak at bin 3
    var real_in: [n]f32 = undefined;
    const k_target: usize = 3;
    for (0..n) |i| {
        const phase: f32 = 2.0 * std.math.pi * @as(f32, @floatFromInt(k_target)) *
            @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        real_in[i] = @cos(phase);
    }

    var scratch_buf: [64]Complex = undefined; // m=64 for n=17
    var mag: [n / 2 + 1]f32 = undefined;
    bl.forwardRealMag(&real_in, &scratch_buf, &mag);

    const expected: f32 = @as(f32, @floatFromInt(n)) / 2.0;
    try std.testing.expectApproxEqAbs(expected, mag[k_target], 0.05);
    for (mag, 0..) |val, kk| {
        if (kk == k_target) continue;
        try std.testing.expect(val < 0.1);
    }
}

test "fft DC bin" {
    var fft = try Fft.init(std.testing.allocator, 16);
    defer fft.deinit();

    var data: [16]Complex = undefined;
    for (0..16) |i| data[i] = Complex.init(1.0, 0.0);

    fft.forward(&data);

    try std.testing.expectApproxEqAbs(@as(f32, 16.0), data[0].re, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), data[0].im, 1e-5);
    for (1..16) |k| {
        try std.testing.expectApproxEqAbs(@as(f32, 0.0), data[k].abs(), 1e-4);
    }
}

test "fft single sine bin" {
    const n: usize = 64;
    const k_target: usize = 5;
    var fft = try Fft.init(std.testing.allocator, n);
    defer fft.deinit();

    var data: [n]Complex = undefined;
    for (0..n) |i| {
        const phase: f32 = 2.0 * std.math.pi * @as(f32, @floatFromInt(k_target)) *
            @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        data[i] = Complex.init(@cos(phase), 0);
    }

    fft.forward(&data);

    const expected: f32 = @as(f32, @floatFromInt(n)) / 2.0;
    try std.testing.expectApproxEqAbs(expected, data[k_target].abs(), 1e-3);
    try std.testing.expectApproxEqAbs(expected, data[n - k_target].abs(), 1e-3);

    for (1..n) |kk| {
        if (kk == k_target or kk == n - k_target) continue;
        try std.testing.expect(data[kk].abs() < 1e-3);
    }
}

test "fft real-input magnitude helper" {
    const n: usize = 32;
    var fft = try Fft.init(std.testing.allocator, n);
    defer fft.deinit();

    var real_in: [n]f32 = undefined;
    const k_target: usize = 3;
    for (0..n) |i| {
        const phase: f32 = 2.0 * std.math.pi * @as(f32, @floatFromInt(k_target)) *
            @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
        real_in[i] = @cos(phase);
    }

    var scratch: [n]Complex = undefined;
    var mag: [n / 2 + 1]f32 = undefined;
    fft.forwardReal(&real_in, &scratch, &mag);

    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(n)) / 2.0, mag[k_target], 1e-3);
    for (mag, 0..) |m, kk| {
        if (kk == k_target) continue;
        try std.testing.expect(m < 1e-3);
    }
}
