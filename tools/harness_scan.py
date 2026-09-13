#!/usr/bin/env python3
"""Bounding box of a marker colour in a harness screenshot.

    harness_scan.py <shot.png> <green|red|blue|white|magenta>
    harness_scan.py <shot.png> mean <x> <y> <w> <h>

Prints "x_min y_min x_max y_max pixel_count" in PNG coordinates (y down from
the top-left), or "none" when the colour is absent. The `mean` form prints
"r g b", the average colour of the given patch, for checks on flat areas
such as the launch fade.

The harness shader (tools/harness_probe.frag) paints in pure primaries, so a
generous per-channel tolerance still cannot confuse one marker for another.

Coordinate note: the daemon flips into GL space (y up) and grim writes PNG rows
top-down, so the two flips cancel. A window at monitor-local (wx, wy, w, h)
must therefore produce a green ring whose bbox is exactly
(wx-14, wy-14) .. (wx+w+14, wy+h+14) -- PAD 12 + TH 2 from the shader.
"""

import sys

import numpy as np
from PIL import Image

KEYS = {
    "green": (0, 255, 0),
    "red": (255, 0, 0),
    "blue": (0, 0, 255),
    "white": (255, 255, 255),
    "magenta": (255, 0, 255),
}


def main() -> int:
    if len(sys.argv) == 7 and sys.argv[2] == "mean":
        img = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
        x, y, w, h = (int(v) for v in sys.argv[3:7])
        patch = img[y : y + h, x : x + w].reshape(-1, 3)
        r, g, b = patch.mean(axis=0)
        print(f"{r:.0f} {g:.0f} {b:.0f}")
        return 0
    if len(sys.argv) != 3 or sys.argv[2] not in KEYS:
        print(f"usage: {sys.argv[0]} <shot.png> <{'|'.join(KEYS)}> | <shot.png> mean x y w h", file=sys.stderr)
        return 2

    img = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(int)
    mask = (np.abs(img - np.array(KEYS[sys.argv[2]])) < 40).all(axis=2)

    if not mask.any():
        print("none")
        return 0

    # Largest connected component, not the global bounding box. Layers above
    # the background one -- Hyprland's error overlay, notifications -- also
    # land in the screenshot, and a few stray pixels near the top edge would
    # otherwise stretch the box and quietly turn a passing measurement into a
    # failing one.
    ys, xs = largest_component(mask)
    print(f"{xs.min()} {ys.min()} {xs.max()} {ys.max()} {len(xs)}")
    return 0


def largest_component(mask):
    """Coordinates of the biggest 4-connected blob in a boolean mask.

    Hand-rolled rather than scipy.ndimage.label so the harness needs nothing
    beyond numpy and Pillow.
    """
    h, w = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    best: tuple[np.ndarray, np.ndarray] | None = None
    best_size = 0

    for sy, sx in zip(*np.nonzero(mask)):
        if seen[sy, sx]:
            continue
        stack = [(int(sy), int(sx))]
        seen[sy, sx] = True
        pts = []
        while stack:
            y, x = stack.pop()
            pts.append((y, x))
            for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    stack.append((ny, nx))
        if len(pts) > best_size:
            best_size = len(pts)
            arr = np.array(pts)
            best = (arr[:, 0], arr[:, 1])

    assert best is not None
    return best


if __name__ == "__main__":
    sys.exit(main())
