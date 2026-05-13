#!/usr/bin/env python3
"""Dump a deterministic test fixture for the Zig BeatNet CRNN forward pass.

Loads BeatNet's PyTorch model, feeds it a fixed pseudo-random feature
sequence, and writes inputs + outputs to a single flat binary that the
Zig test loads via @embedFile and replays.

Layout (all f32, native endian):
    n_frames  (i32)      # = 16
    n_in      (i32)      # = 272
    n_out     (i32)      # = 3
    inputs    f32[n_frames, n_in]
    outputs   f32[n_frames, n_out]   (post-softmax probabilities,
                                       order matches model.py:
                                       beat / downbeat / no-beat)

Usage:
    python tools/dump_beatnet_fixture.py
"""

import os
import sys
import struct
import numpy as np
import torch

# Make `BeatNet.model.BDA` importable from the cloned upstream repo.
sys.path.insert(0, "/tmp/beatnet-repo/src")
from BeatNet.model import BDA  # noqa: E402


def main():
    np.random.seed(0xBEA7)
    n_frames = 16
    n_in = 272

    model = BDA(n_in, 150, 2, "cpu")
    model.load_state_dict(
        torch.load(
            "/tmp/beatnet-repo/src/BeatNet/models/model_1_weights.pt",
            map_location="cpu",
            weights_only=True,
        ),
        strict=False,
    )
    model.eval()

    inputs = np.random.randn(n_frames, n_in).astype(np.float32)
    # Model expects (batch, time, features). We dump raw pre-softmax logits —
    # easier to compare bit-for-bit against the Zig forward pass than chasing
    # softmax-dimension nuances. The downstream PLO operates on raw logits or
    # sigmoid'd beat activation anyway.
    with torch.no_grad():
        x = torch.from_numpy(inputs).unsqueeze(0)  # (1, T, 272)
        out = model(x)  # (1, 3, T) raw logits
        logits = out.transpose(1, 2).squeeze(0).numpy()  # (T, 3)

    print("input  shape:", inputs.shape, "dtype:", inputs.dtype)
    print("logits shape:", logits.shape, "dtype:", logits.dtype)
    print("logits[0]:", logits[0])
    print("logits[-1]:", logits[-1])

    out_path = "src/effects/meshflow/weights/beatnet_fixture.bin"
    with open(out_path, "wb") as f:
        f.write(struct.pack("iii", n_frames, n_in, 3))
        f.write(inputs.tobytes())
        f.write(logits.astype(np.float32).tobytes())
    print(f"wrote {out_path}")


if __name__ == "__main__":
    main()
