//! Shared spectral front-end for audio-reactive effects.
//!
//! AudioCapture ships TIME-DOMAIN samples (128/channel, box-averaged from
//! a 1/60s window — effective rate ~7.7kHz, Nyquist ~3.8kHz). The older
//! 6-band split used by glitch/voltaic slices that window by TIME, so its
//! "bands" are correlated loudness envelopes, not frequencies. This module
//! does the real thing: Hann window + 128-point FFT + log-spaced bands
//! with per-band auto-gain. Grown in whorl, extracted for reuse.

const std = @import("std");

pub const fft_n = 128;
pub const n_bins = fft_n / 2 + 1;

pub const hann: [fft_n]f32 = blk: {
    @setEvalBranchQuota(10000);
    var w: [fft_n]f32 = undefined;
    for (0..fft_n) |i| {
        const x = @as(f32, i) / @as(f32, fft_n - 1);
        w[i] = 0.5 - 0.5 * @cos(2.0 * std.math.pi * x);
    }
    break :blk w;
};

/// Log-spaced band edges in FFT bins (~60Hz each): sub, bass, low-mid,
/// mid, high-mid, treble. The capture's box-averaging shaves real treble;
/// the per-band AGC in `Bands` compensates for the level differences.
pub const band_edges = [7]usize{ 1, 3, 5, 9, 17, 33, 64 };

/// In-place radix-2 FFT.
pub fn fftInPlace(re: *[fft_n]f32, im: *[fft_n]f32) void {
    var j: usize = 0;
    for (1..fft_n) |i| {
        var bit: usize = fft_n >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j) {
            std.mem.swap(f32, &re[i], &re[j]);
            std.mem.swap(f32, &im[i], &im[j]);
        }
    }
    var len: usize = 2;
    while (len <= fft_n) : (len <<= 1) {
        const ang = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        const wr = @cos(ang);
        const wi = @sin(ang);
        var i: usize = 0;
        while (i < fft_n) : (i += len) {
            var cr: f32 = 1.0;
            var ci: f32 = 0.0;
            for (0..len / 2) |k| {
                const ur = re[i + k];
                const ui = im[i + k];
                const vr = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
                const vi = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
                re[i + k] = ur + vr;
                im[i + k] = ui + vi;
                re[i + k + len / 2] = ur - vr;
                im[i + k + len / 2] = ui - vi;
                const nr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = nr;
            }
        }
    }
}

/// Mono-mix, Hann-window, FFT, magnitude spectrum — one capture frame in,
/// 65 bin magnitudes out (bin width ~60Hz).
pub fn magnitudes(wave: *const [256]f32) [n_bins]f32 {
    var re: [fft_n]f32 = undefined;
    var im = [_]f32{0} ** fft_n;
    for (0..fft_n) |i| re[i] = (wave[i] + wave[fft_n + i]) * 0.5 * hann[i];
    fftInPlace(&re, &im);
    var mags: [n_bins]f32 = undefined;
    for (0..n_bins) |k| mags[k] = @sqrt(re[k] * re[k] + im[k] * im[k]);
    return mags;
}

/// Kick onset detector (whorl's design, generalized): log-compressed
/// positive spectral flux over the kick bins (60-180Hz full weight,
/// 180-300Hz half), fired on a rising edge that clears both an adaptive
/// mean + 2*sigma threshold over the trailing ~1.6s and a 1.5x-mean
/// relative floor (immune to sigma collapse in steady loud passages).
/// `beat` snaps to 1 on a hit and decays ~200ms — zero in silence.
pub const Onset = struct {
    spec_prev: [n_bins]f32 = [_]f32{0} ** n_bins,
    hist: [96]f32 = [_]f32{0} ** 96,
    pos: usize = 0,
    flux_last: f32 = 0,
    cooldown: f32 = 0,
    beat: f32 = 0,

    pub fn update(self: *Onset, mags: *const [n_bins]f32, dt: f32, sub_level: f32) void {
        var flux: f32 = 0;
        for (1..5) |k| {
            const d = std.math.log1p(mags[k]) - std.math.log1p(self.spec_prev[k]);
            if (d > 0) flux += d * (if (k < 3) @as(f32, 1.0) else 0.5);
        }
        for (0..n_bins) |k| self.spec_prev[k] = mags[k];

        var mean: f32 = 0;
        for (self.hist) |v| mean += v;
        mean /= @as(f32, self.hist.len);
        var variance: f32 = 0;
        for (self.hist) |v| variance += (v - mean) * (v - mean);
        const sigma = @sqrt(variance / @as(f32, self.hist.len));
        self.hist[self.pos] = flux;
        self.pos = (self.pos + 1) % self.hist.len;

        self.cooldown -= dt;
        const rising = flux > self.flux_last;
        self.flux_last = flux;
        if (self.cooldown <= 0 and rising and
            flux > mean + 2.0 * sigma and
            flux > mean * 1.5 and
            flux > 0.015 and sub_level > 0.25)
        {
            self.cooldown = 0.18;
            self.beat = 1.0;
        }
        self.beat *= @exp(-5.0 * dt);
        if (self.beat < 0.01) self.beat = 0;
    }
};

/// Six auto-gained bands plus common aggregates. Silence-safe: with no
/// signal every value decays to zero, so effects gating their music
/// response on these fall back to their exact no-music look.
pub const Bands = struct {
    bands: [6]f32 = [_]f32{0} ** 6,
    smooth: [6]f32 = [_]f32{0} ** 6,
    peak: [6]f32 = [_]f32{0} ** 6,
    bass: f32 = 0,
    treble: f32 = 0,
    energy_ema: f32 = 0,

    pub fn update(self: *Bands, mags: *const [n_bins]f32, dt: f32) void {
        for (0..6) |b| {
            var p: f32 = 0;
            for (band_edges[b]..band_edges[b + 1]) |k| p += mags[k];
            p /= @as(f32, @floatFromInt(band_edges[b + 1] - band_edges[b]));
            self.peak[b] = @max(self.peak[b] * @exp(-dt / 4.0), p);
            const raw = if (self.peak[b] > 0.003) p / self.peak[b] else 0.0;
            const attack = @min(1.0, 25.0 * dt);
            const decay = @min(1.0, 5.0 * dt);
            self.bands[b] += (raw - self.bands[b]) * (if (raw > self.bands[b]) attack else decay);
            self.smooth[b] += (self.bands[b] - self.smooth[b]) * @min(1.0, 8.0 * dt);
        }
        self.bass = (self.bands[0] + self.bands[1]) * 0.5;
        self.treble = (self.bands[4] + self.bands[5]) * 0.5;
        const energy = (self.bands[0] + self.bands[1] + self.bands[2] +
            self.bands[3] + self.bands[4] + self.bands[5]) / 6.0;
        self.energy_ema += (energy - self.energy_ema) * @min(1.0, 2.0 * dt);
    }
};
