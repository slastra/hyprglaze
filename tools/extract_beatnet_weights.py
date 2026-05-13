#!/usr/bin/env python3
"""Extract BeatNet (Heydari et al., ISMIR 2021) CRNN weights into a flat
float32 binary that the Zig forward-pass loads via @embedFile.

Usage:
    python tools/extract_beatnet_weights.py <path/to/model_1_weights.pt> <out.bin>

Layout (all f32, native endian, no padding):
    conv1.weight       (2, 1, 10)              = 20 floats
    conv1.bias         (2,)                    = 2
    linear0.weight     (150, 262)              = 39 300
    linear0.bias       (150,)                  = 150
    lstm L0 weight_ih  (600, 150)              = 90 000
    lstm L0 weight_hh  (600, 150)              = 90 000
    lstm L0 bias_ih    (600,)                  = 600
    lstm L0 bias_hh    (600,)                  = 600
    lstm L1 weight_ih  (600, 150)              = 90 000
    lstm L1 weight_hh  (600, 150)              = 90 000
    lstm L1 bias_ih    (600,)                  = 600
    lstm L1 bias_hh    (600,)                  = 600
    linear.weight      (3, 150)                = 450
    linear.bias        (3,)                    = 3
                                              -------
                              total            = 402 325 floats = 1 609 300 bytes

LSTM gate order is PyTorch native: i, f, g, o (each gate is 150 rows in the
600-row stacked tensors). The Zig forward pass MUST use the same order.
"""

import sys
import numpy as np
import torch


EXPECTED = [
    ("conv1.weight", (2, 1, 10)),
    ("conv1.bias", (2,)),
    ("linear0.weight", (150, 262)),
    ("linear0.bias", (150,)),
    ("lstm.weight_ih_l0", (600, 150)),
    ("lstm.weight_hh_l0", (600, 150)),
    ("lstm.bias_ih_l0", (600,)),
    ("lstm.bias_hh_l0", (600,)),
    ("lstm.weight_ih_l1", (600, 150)),
    ("lstm.weight_hh_l1", (600, 150)),
    ("lstm.bias_ih_l1", (600,)),
    ("lstm.bias_hh_l1", (600,)),
    ("linear.weight", (3, 150)),
    ("linear.bias", (3,)),
]


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    src = sys.argv[1]
    dst = sys.argv[2]

    sd = torch.load(src, map_location="cpu", weights_only=True)

    out = bytearray()
    total_floats = 0
    for name, shape in EXPECTED:
        if name not in sd:
            print(f"!! missing tensor: {name}", file=sys.stderr)
            sys.exit(1)
        t = sd[name]
        if tuple(t.shape) != shape:
            print(
                f"!! shape mismatch {name}: got {tuple(t.shape)}, expected {shape}",
                file=sys.stderr,
            )
            sys.exit(1)
        arr = t.detach().cpu().numpy().astype(np.float32, copy=False)
        out += arr.tobytes()
        total_floats += arr.size
        print(f"  {name:30s} {tuple(arr.shape)}  +{arr.size} floats")

    print(f"\ntotal: {total_floats} floats = {len(out)} bytes")
    with open(dst, "wb") as f:
        f.write(out)
    print(f"wrote {dst}")


if __name__ == "__main__":
    main()
