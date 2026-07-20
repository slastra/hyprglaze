//! Shared time-domain band splitter + spectral-flux beat detector.
//!
//! This is the original 6-band split grown in starfield/glitch and later
//! pasted into voltaic, fable, swarm, and moire. It slices AudioCapture's
//! TIME-DOMAIN window by sample index, so the "bands" are correlated
//! loudness envelopes, not real frequencies (spectral.zig does the FFT
//! version). Extracted verbatim; the numbers are tuned art, do not touch.

const std = @import("std");

/// Sample ranges for the 6 bands, indexing the 128-sample left channel
/// (the right channel lives at +128):
/// Band 0 (sub-bass): samples 0-10
/// Band 1 (bass): 10-25
/// Band 2 (low-mid): 25-45
/// Band 3 (mid): 45-70
/// Band 4 (high-mid): 70-95
/// Band 5 (high): 95-128
pub const ranges = [_][2]u8{ .{ 0, 10 }, .{ 10, 25 }, .{ 25, 45 }, .{ 45, 70 }, .{ 70, 95 }, .{ 95, 128 } };

/// Just the per-band envelope loop (fast attack, slow decay). Used on its
/// own by moire, which pairs it with its own beat detector.
pub fn splitBands(bands: *[6]f32, wave: *const [256]f32, dt: f32) void {
    for (0..6) |b| {
        var energy: f32 = 0;
        const lo = ranges[b][0];
        const hi = ranges[b][1];
        for (lo..hi) |i| {
            energy += @abs(wave[i]) + @abs(wave[128 + i]);
        }
        energy /= @as(f32, @floatFromInt((hi - lo) * 2));

        const raw = energy * 6.0;
        const attack = @min(1.0, 25.0 * dt);
        const decay = @min(1.0, 5.0 * dt);
        bands[b] += (raw - bands[b]) * (if (raw > bands[b]) attack else decay);
    }
}

/// GLSL-style smoothstep. Shared by several effects' CPU-side envelopes.
pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Band envelopes, aggregates, and bass-flux beat detection in one state
/// block. `update` returns true on the frame a beat fires so effects can
/// hang their own one-shot reactions (seeds, wobbles, punches) off it.
pub const Splitter = struct {
    /// Smoothed energy bands (fast attack, slow decay).
    bands: [6]f32 = [_]f32{0} ** 6,
    bass: f32 = 0,
    mid: f32 = 0,
    treble: f32 = 0,
    /// Mean of the six band envelopes.
    energy: f32 = 0,

    // Beat detection: spectral flux (energy derivative) based.
    bass_instant: f32 = 0,
    bass_smooth: f32 = 0, // slow-moving average
    bass_prev: f32 = 0, // previous frame instant
    flux: f32 = 0, // positive energy derivative
    flux_avg: f32 = 0, // running average of flux
    beat: f32 = 0, // 0-1, decays smoothly
    beat_cooldown: f32 = 0,

    pub fn update(self: *Splitter, wave: *const [256]f32, dt: f32) bool {
        splitBands(&self.bands, wave, dt);

        self.bass = (self.bands[0] + self.bands[1]) * 0.5;
        self.mid = (self.bands[2] + self.bands[3]) * 0.5;
        self.treble = (self.bands[4] + self.bands[5]) * 0.5;
        self.energy = (self.bands[0] + self.bands[1] + self.bands[2] +
            self.bands[3] + self.bands[4] + self.bands[5]) / 6.0;

        // Beat detection: spectral flux (energy derivative)
        self.bass_instant = self.bass;
        self.bass_smooth += (self.bass - self.bass_smooth) * @min(1.0, 0.8 * dt);

        // Spectral flux: only count positive energy changes (onsets, not decays)
        const flux_raw = @max(0.0, self.bass_instant - self.bass_prev);
        self.bass_prev = self.bass_instant;
        self.flux = flux_raw;
        self.flux_avg += (flux_raw - self.flux_avg) * @min(1.0, 1.5 * dt);

        // Beat triggers when flux significantly exceeds its running average
        // Higher threshold + longer cooldown to avoid false triggers
        self.beat_cooldown -= dt;
        var beat_hit = false;
        if (self.flux > self.flux_avg * 3.0 + 0.03 and self.beat_cooldown <= 0 and self.bass_instant > self.bass_smooth * 1.5) {
            self.beat = 1.0;
            self.beat_cooldown = 0.25;
            beat_hit = true;
        }
        self.beat *= @exp(-4.0 * dt);
        if (self.beat < 0.01) self.beat = 0;
        return beat_hit;
    }
};
