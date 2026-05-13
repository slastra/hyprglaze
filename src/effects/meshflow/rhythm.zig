const std = @import("std");
const fe = @import("frontend.zig");

// The shared AudioCapture publishes 128 mono-equivalent samples per channel at
// a 60 Hz tick rate. After averaging 5 raw 44.1 kHz samples each, the effective
// downstream sample rate of the published waveform is 7680 Hz (128 * 60).
// Nyquist = 3840 Hz, which comfortably covers everything below 3.5 kHz —
// enough for the bass, low-mid, and mid bands that carry beat energy.
// High-mid / air bands are intentionally compressed into the available range;
// when BeatNet is later wired in, it will get its own higher-rate path.
pub const effective_sample_rate: f32 = 7680.0;
pub const samples_per_tick: usize = 128;
pub const n_fft: usize = 256;
pub const n_bands: usize = 6;

const band_fmin: f32 = 30.0;
const band_fmax: f32 = 3500.0;

// Envelope follower time constants (ms).
const env_attack_ms: f32 = 3.0;
const env_release_ms: f32 = 120.0;

// Onset flash decay (ms).
const onset_decay_ms: f32 = 180.0;

// Adaptive flux threshold: median * k + small floor.
const flux_history_size: usize = 32;
const flux_threshold_k: f32 = 1.6;
const flux_floor: f32 = 0.005;

// Free-running beat clock fallback (BPM) until real tempo estimation lands.
const fallback_bpm: f32 = 120.0;

pub const RhythmState = struct {
    bands: [n_bands]f32 = [_]f32{0} ** n_bands,
    onsets: [n_bands]f32 = [_]f32{0} ** n_bands,
    beat_phase: f32 = 0.0,
    down_phase: f32 = 0.0,
    tempo: f32 = fallback_bpm,
    locked: bool = false,
};

pub const RhythmEngine = struct {
    allocator: std.mem.Allocator,

    stft: fe.Stft,
    fb: fe.FilterBank,

    prev_mono: [samples_per_tick]f32 = [_]f32{0} ** samples_per_tick,
    fft_frame: [n_fft]f32 = [_]f32{0} ** n_fft,

    band_env: [n_bands]f32 = [_]f32{0} ** n_bands,
    band_prev_log: [n_bands]f32 = [_]f32{0} ** n_bands,
    onset_flash: [n_bands]f32 = [_]f32{0} ** n_bands,

    // Per-band flux history for adaptive thresholding.
    flux_hist: [n_bands][flux_history_size]f32 = [_][flux_history_size]f32{[_]f32{0} ** flux_history_size} ** n_bands,
    flux_hist_idx: usize = 0,

    // Free-running beat clock for now; real tempo lock comes with BeatNet.
    beat_phase: f32 = 0.0,
    down_phase: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator) !RhythmEngine {
        const stft = try fe.Stft.init(allocator, n_fft);
        errdefer {
            var s = stft;
            s.deinit();
        }
        const fb = try fe.FilterBank.initTriangularLog(
            allocator,
            n_bands,
            band_fmin,
            band_fmax,
            n_fft,
            effective_sample_rate,
        );
        return .{
            .allocator = allocator,
            .stft = stft,
            .fb = fb,
        };
    }

    pub fn deinit(self: *RhythmEngine) void {
        self.stft.deinit();
        self.fb.deinit();
    }

    /// Process one 60 Hz audio buffer. `stereo_waveform.len == 256` (128 L + 128 R).
    /// `dt` is the time since the last call, in seconds (typically ~0.0167).
    pub fn tick(self: *RhythmEngine, stereo_waveform: []const f32, dt: f32) RhythmState {
        std.debug.assert(stereo_waveform.len == samples_per_tick * 2);

        // Build a 256-sample mono frame: 128 from the previous tick, 128 new.
        @memcpy(self.fft_frame[0..samples_per_tick], &self.prev_mono);
        for (0..samples_per_tick) |i| {
            const mono = 0.5 * (stereo_waveform[i] + stereo_waveform[samples_per_tick + i]);
            self.fft_frame[samples_per_tick + i] = mono;
            self.prev_mono[i] = mono;
        }

        // STFT magnitude → 6 log-spaced band energies.
        const mag = self.stft.process(&self.fft_frame);
        var bands: [n_bands]f32 = undefined;
        self.fb.apply(mag, &bands);

        // Log-compress for perceptual scale.
        var log_bands: [n_bands]f32 = undefined;
        for (bands, 0..) |b, i| log_bands[i] = @log(1.0 + b);

        // Per-band envelopes (fast attack, slow release).
        const a_attack = 1.0 - @exp(-dt * 1000.0 / env_attack_ms);
        const a_release = 1.0 - @exp(-dt * 1000.0 / env_release_ms);
        for (log_bands, 0..) |lb, i| {
            const target = lb;
            const a = if (target > self.band_env[i]) a_attack else a_release;
            self.band_env[i] += a * (target - self.band_env[i]);
        }

        // Per-band spectral flux + adaptive threshold → onsets.
        const onset_decay = @exp(-dt * 1000.0 / onset_decay_ms);
        for (log_bands, 0..) |lb, i| {
            const flux = @max(0.0, lb - self.band_prev_log[i]);
            self.band_prev_log[i] = lb;
            self.flux_hist[i][self.flux_hist_idx] = flux;

            // Running median over the history ring (insertion sort over flux_history_size).
            var buf: [flux_history_size]f32 = self.flux_hist[i];
            std.mem.sort(f32, &buf, {}, comptime std.sort.asc(f32));
            const median = buf[flux_history_size / 2];

            const threshold = @max(flux_floor, median * flux_threshold_k);
            self.onset_flash[i] *= onset_decay;
            if (flux > threshold) {
                self.onset_flash[i] = @max(self.onset_flash[i], @min(1.0, flux / (threshold + 1e-6)));
            }
        }
        self.flux_hist_idx = (self.flux_hist_idx + 1) % flux_history_size;

        // Free-running beat clock at fallback BPM until tempo estimation is in.
        const beat_period: f32 = 60.0 / fallback_bpm;
        self.beat_phase += dt / beat_period;
        if (self.beat_phase >= 1.0) self.beat_phase -= @floor(self.beat_phase);
        self.down_phase += dt / (beat_period * 4.0);
        if (self.down_phase >= 1.0) self.down_phase -= @floor(self.down_phase);

        // Normalize envelopes for shader consumption: clip and scale to ~[0,1].
        // Empirical scale; tune live. log_bands typical max ≈ 4-5 for loud music.
        const env_scale: f32 = 0.25;
        var bands_out: [n_bands]f32 = undefined;
        for (self.band_env, 0..) |e, i| bands_out[i] = @min(1.0, e * env_scale);

        return .{
            .bands = bands_out,
            .onsets = self.onset_flash,
            .beat_phase = self.beat_phase,
            .down_phase = self.down_phase,
            .tempo = fallback_bpm,
            .locked = false,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "rhythm engine: silent input yields zero bands and zero onsets" {
    var eng = try RhythmEngine.init(std.testing.allocator);
    defer eng.deinit();

    var silence: [samples_per_tick * 2]f32 = [_]f32{0} ** (samples_per_tick * 2);
    var state: RhythmState = undefined;
    // Run for many ticks to let envelopes settle.
    for (0..120) |_| {
        state = eng.tick(&silence, 1.0 / 60.0);
    }
    for (state.bands) |b| try std.testing.expect(b < 1e-3);
    for (state.onsets) |o| try std.testing.expect(o < 1e-3);
}

test "rhythm engine: sine tone in the bass band lights up that band" {
    var eng = try RhythmEngine.init(std.testing.allocator);
    defer eng.deinit();

    // 120 Hz sine in stereo → should excite band 1 (bass).
    const f_hz: f32 = 120.0;
    var buf: [samples_per_tick * 2]f32 = undefined;
    var t: f32 = 0;
    var state: RhythmState = undefined;
    for (0..60) |_| {
        for (0..samples_per_tick) |i| {
            const s = @sin(2.0 * std.math.pi * f_hz * t);
            buf[i] = s;
            buf[samples_per_tick + i] = s;
            t += 1.0 / effective_sample_rate;
        }
        state = eng.tick(&buf, 1.0 / 60.0);
    }

    // Band 0 is sub-bass (30-~70Hz), band 1 is bass (~70-180Hz) for 6-band
    // log-spaced 30..3500. 120 Hz lands in band 1.
    var max_band: usize = 0;
    var max_val: f32 = 0;
    for (state.bands, 0..) |b, i| {
        if (b > max_val) {
            max_val = b;
            max_band = i;
        }
    }
    try std.testing.expect(max_band == 0 or max_band == 1);
    try std.testing.expect(max_val > 0.01);
}

test "rhythm engine: sudden burst triggers an onset" {
    var eng = try RhythmEngine.init(std.testing.allocator);
    defer eng.deinit();

    var silence: [samples_per_tick * 2]f32 = [_]f32{0} ** (samples_per_tick * 2);
    var burst: [samples_per_tick * 2]f32 = undefined;
    var t: f32 = 0;
    const f_hz: f32 = 200.0;
    for (0..samples_per_tick) |i| {
        const s = @sin(2.0 * std.math.pi * f_hz * t);
        burst[i] = s;
        burst[samples_per_tick + i] = s;
        t += 1.0 / effective_sample_rate;
    }

    // Settle on silence first.
    for (0..40) |_| _ = eng.tick(&silence, 1.0 / 60.0);
    const state = eng.tick(&burst, 1.0 / 60.0);

    // Some band's onset should have fired.
    var any: f32 = 0;
    for (state.onsets) |o| any = @max(any, o);
    try std.testing.expect(any > 0.1);
}

test "rhythm engine: beat_phase wraps once per beat at fallback BPM" {
    var eng = try RhythmEngine.init(std.testing.allocator);
    defer eng.deinit();
    var silence: [samples_per_tick * 2]f32 = [_]f32{0} ** (samples_per_tick * 2);

    const beat_period: f32 = 60.0 / fallback_bpm; // 0.5 s @ 120 BPM
    const dt: f32 = 1.0 / 60.0;
    const ticks_per_beat: usize = @intFromFloat(@round(beat_period / dt));

    // Run for exactly one beat.
    var state: RhythmState = undefined;
    for (0..ticks_per_beat) |_| state = eng.tick(&silence, dt);

    // beat_phase should have wrapped, landing near 0 again.
    try std.testing.expect(state.beat_phase < 0.05 or state.beat_phase > 0.95);
}
