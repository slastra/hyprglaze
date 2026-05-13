const std = @import("std");

/// BeatNet (ISMIR 2021) CRNN forward pass — single-timestep streaming.
///
/// Architecture (per the upstream `model.py` BDA class):
///     in[272] -> Conv1d(1,2,k=10) -> ReLU -> MaxPool1d(2)  (-> 262)
///             -> Linear(262, 150) -> 2x stateful LSTM(150, 150)
///             -> Linear(150, 3) -> raw logits[3]
///
/// Logit indices match the trained label order: [beat, downbeat, no-beat].
/// Each call advances the LSTM state by one timestep — call `reset()` between
/// independent audio streams.

const weights_blob = @embedFile("weights/beatnet.bin");

// Layout in weights/beatnet.bin (matches tools/extract_beatnet_weights.py).
const conv1_w_len: usize = 2 * 1 * 10;
const conv1_b_len: usize = 2;
const linear0_w_len: usize = 150 * 262;
const linear0_b_len: usize = 150;
const lstm_w_ih_len: usize = 600 * 150;
const lstm_w_hh_len: usize = 600 * 150;
const lstm_b_ih_len: usize = 600;
const lstm_b_hh_len: usize = 600;
const linear_w_len: usize = 3 * 150;
const linear_b_len: usize = 3;

pub const Crnn = struct {
    // Pointers into the embedded weight blob (row-major f32).
    conv1_w: []const f32,
    conv1_b: []const f32,
    linear0_w: []const f32,
    linear0_b: []const f32,
    lstm_w_ih: [2][]const f32,
    lstm_w_hh: [2][]const f32,
    lstm_b_ih: [2][]const f32,
    lstm_b_hh: [2][]const f32,
    linear_w: []const f32,
    linear_b: []const f32,

    // Mutable LSTM state, persisted across forward() calls.
    h: [2][150]f32 = .{[_]f32{0} ** 150} ** 2,
    c: [2][150]f32 = .{[_]f32{0} ** 150} ** 2,

    pub fn init() Crnn {
        const aligned: [*]align(@alignOf(f32)) const u8 = @alignCast(@ptrCast(weights_blob.ptr));
        const f32s: []const f32 = std.mem.bytesAsSlice(f32, aligned[0..weights_blob.len]);

        var off: usize = 0;
        const conv1_w = f32s[off..][0..conv1_w_len];
        off += conv1_w_len;
        const conv1_b = f32s[off..][0..conv1_b_len];
        off += conv1_b_len;
        const linear0_w = f32s[off..][0..linear0_w_len];
        off += linear0_w_len;
        const linear0_b = f32s[off..][0..linear0_b_len];
        off += linear0_b_len;
        const w_ih_0 = f32s[off..][0..lstm_w_ih_len];
        off += lstm_w_ih_len;
        const w_hh_0 = f32s[off..][0..lstm_w_hh_len];
        off += lstm_w_hh_len;
        const b_ih_0 = f32s[off..][0..lstm_b_ih_len];
        off += lstm_b_ih_len;
        const b_hh_0 = f32s[off..][0..lstm_b_hh_len];
        off += lstm_b_hh_len;
        const w_ih_1 = f32s[off..][0..lstm_w_ih_len];
        off += lstm_w_ih_len;
        const w_hh_1 = f32s[off..][0..lstm_w_hh_len];
        off += lstm_w_hh_len;
        const b_ih_1 = f32s[off..][0..lstm_b_ih_len];
        off += lstm_b_ih_len;
        const b_hh_1 = f32s[off..][0..lstm_b_hh_len];
        off += lstm_b_hh_len;
        const linear_w = f32s[off..][0..linear_w_len];
        off += linear_w_len;
        const linear_b = f32s[off..][0..linear_b_len];
        off += linear_b_len;
        std.debug.assert(off == f32s.len);

        return .{
            .conv1_w = conv1_w,
            .conv1_b = conv1_b,
            .linear0_w = linear0_w,
            .linear0_b = linear0_b,
            .lstm_w_ih = .{ w_ih_0, w_ih_1 },
            .lstm_w_hh = .{ w_hh_0, w_hh_1 },
            .lstm_b_ih = .{ b_ih_0, b_ih_1 },
            .lstm_b_hh = .{ b_hh_0, b_hh_1 },
            .linear_w = linear_w,
            .linear_b = linear_b,
        };
    }

    pub fn reset(self: *Crnn) void {
        self.h = .{[_]f32{0} ** 150} ** 2;
        self.c = .{[_]f32{0} ** 150} ** 2;
    }

    /// One streaming step: 272-D feature vector -> 3 raw logits [beat, down, none].
    pub fn forward(self: *Crnn, x_in: *const [272]f32, logits_out: *[3]f32) void {
        // ---- Conv1d(1,2,k=10) + ReLU + MaxPool1d(2)  --> 262 flat features.
        // Conv1d output is 272-10+1 = 263 timesteps per channel; pool by 2 → 131.
        var pool: [262]f32 = undefined;
        for (0..2) |oc| {
            const kernel = self.conv1_w[oc * 10 ..][0..10];
            const bias = self.conv1_b[oc];
            for (0..131) |t| {
                var a: f32 = bias;
                var b: f32 = bias;
                inline for (0..10) |k| {
                    a += x_in[2 * t + k] * kernel[k];
                    b += x_in[2 * t + 1 + k] * kernel[k];
                }
                if (a < 0) a = 0;
                if (b < 0) b = 0;
                pool[oc * 131 + t] = if (a > b) a else b;
            }
        }

        // ---- Linear(262, 150) --> 150 features per timestep.
        var lin0_out: [150]f32 = undefined;
        for (0..150) |i| {
            var sum = self.linear0_b[i];
            const row = self.linear0_w[i * 262 ..][0..262];
            for (0..262) |j| sum += row[j] * pool[j];
            lin0_out[i] = sum;
        }

        // ---- 2x stateful LSTM(150, 150)
        var layer_in: [150]f32 = lin0_out;
        var gates: [600]f32 = undefined;
        for (0..2) |layer| {
            const w_ih = self.lstm_w_ih[layer];
            const w_hh = self.lstm_w_hh[layer];
            const b_ih = self.lstm_b_ih[layer];
            const b_hh = self.lstm_b_hh[layer];
            const h_prev = &self.h[layer];
            const c_prev = &self.c[layer];

            // gates = W_ih @ x + b_ih + W_hh @ h_{t-1} + b_hh
            for (0..600) |i| {
                var sum = b_ih[i] + b_hh[i];
                const row_ih = w_ih[i * 150 ..][0..150];
                const row_hh = w_hh[i * 150 ..][0..150];
                for (0..150) |j| {
                    sum += row_ih[j] * layer_in[j];
                    sum += row_hh[j] * h_prev[j];
                }
                gates[i] = sum;
            }

            // PyTorch LSTM gate order: (i, f, g, o).
            for (0..150) |k| {
                const ig = sigmoid(gates[k]);
                const fg = sigmoid(gates[150 + k]);
                const gg = std.math.tanh(gates[300 + k]);
                const og = sigmoid(gates[450 + k]);
                const c_new = fg * c_prev[k] + ig * gg;
                const h_new = og * std.math.tanh(c_new);
                c_prev[k] = c_new;
                h_prev[k] = h_new;
                layer_in[k] = h_new;
            }
        }

        // ---- Linear(150, 3) --> raw logits.
        for (0..3) |i| {
            var sum = self.linear_b[i];
            const row = self.linear_w[i * 150 ..][0..150];
            for (0..150) |j| sum += row[j] * layer_in[j];
            logits_out[i] = sum;
        }
    }
};

pub inline fn sigmoid(x: f32) f32 {
    return 1.0 / (1.0 + @exp(-x));
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture_blob = @embedFile("weights/beatnet_fixture.bin");

test "crnn matches PyTorch fixture (16 frames)" {
    // Fixture layout: i32 n_frames, n_in, n_out; then f32 inputs[n*n_in]; then f32 logits[n*n_out].
    const hdr: [*]const i32 = @ptrCast(@alignCast(fixture_blob.ptr));
    const n_frames: usize = @intCast(hdr[0]);
    const n_in: usize = @intCast(hdr[1]);
    const n_out: usize = @intCast(hdr[2]);
    try std.testing.expectEqual(@as(usize, 16), n_frames);
    try std.testing.expectEqual(@as(usize, 272), n_in);
    try std.testing.expectEqual(@as(usize, 3), n_out);

    const data_start = @sizeOf(i32) * 3;
    const inputs_bytes = fixture_blob[data_start..][0 .. n_frames * n_in * @sizeOf(f32)];
    const logits_bytes = fixture_blob[data_start + inputs_bytes.len ..][0 .. n_frames * n_out * @sizeOf(f32)];

    const inputs_aligned: [*]align(@alignOf(f32)) const u8 = @alignCast(inputs_bytes.ptr);
    const logits_aligned: [*]align(@alignOf(f32)) const u8 = @alignCast(logits_bytes.ptr);
    const inputs = std.mem.bytesAsSlice(f32, inputs_aligned[0..inputs_bytes.len]);
    const expected = std.mem.bytesAsSlice(f32, logits_aligned[0..logits_bytes.len]);

    var crnn = Crnn.init();
    crnn.reset();

    var max_abs_err: f32 = 0;
    for (0..n_frames) |t| {
        const x: *const [272]f32 = @ptrCast(inputs[t * 272 ..][0..272].ptr);
        var got: [3]f32 = undefined;
        crnn.forward(x, &got);
        for (0..3) |k| {
            const e = @abs(got[k] - expected[t * 3 + k]);
            if (e > max_abs_err) max_abs_err = e;
        }
    }
    std.debug.print("crnn fixture max abs error: {d:.6}\n", .{max_abs_err});
    try std.testing.expect(max_abs_err < 1e-4);
}
