#!/usr/bin/env python3
"""Reproduce madmom's LogarithmicFilterbank for BeatNet without needing
madmom installed. Reads the construction from upstream's source (BSD-3) and
applies the exact same algorithm in pure numpy.

BeatNet inference uses:
    sample_rate = 22050
    win_length  = 1411 samples (~64 ms)
    hop_length  =  441 samples (~20 ms, → 50 fps)
    n_bands     = 24 bands / octave
    fmin = 30 Hz   fmax = 17000 Hz
    norm_filters = True
    mul=1, add=1  (log(1 + x))
    diff stacks original + first-order positive diff  →  feature_dim = 2*N

For Zig we use a power-of-2 FFT (radix-2 in `fft.zig`). We pad the 1411-sample
windowed frame to 2048 before transforming → 1025 magnitude bins. The
filterbank is constructed for THESE bin frequencies; the trained CRNN may see
slightly different values than madmom's native 706-bin filterbank, but the
log-spaced perceptual layout is preserved.

Output `weights/filterbank.bin` layout:
    i32 n_filters
    i32 n_bins                 (1025 for FFT 2048)
    Per filter (n_filters of them):
        i32 start_bin
        i32 stop_bin           (exclusive)
        f32 weights[stop-start]
"""

import os
import struct
import numpy as np


# Madmom defaults (BeatNet uses these).
A4 = 440.0
SAMPLE_RATE = 22050
# Madmom's STFT uses fft_size = win_length (no power-of-2 padding). BeatNet's
# win_length = int(64ms * 22050) = 1411. We match that exactly so the trained
# CRNN sees the same input distribution. The Zig side handles the non-pow2
# transform via the Bluestein algorithm in fft.zig.
FFT_SIZE = 1411
FMIN = 30.0
FMAX = 17000.0
BANDS_PER_OCTAVE = 24
NORM_FILTERS = True


def log_frequencies(bands_per_octave, fmin, fmax, fref=A4):
    """Verbatim port of madmom.audio.filters.log_frequencies."""
    left = np.floor(np.log2(float(fmin) / fref) * bands_per_octave)
    right = np.ceil(np.log2(float(fmax) / fref) * bands_per_octave)
    frequencies = fref * 2.0 ** (np.arange(left, right) / float(bands_per_octave))
    frequencies = frequencies[np.searchsorted(frequencies, fmin):]
    frequencies = frequencies[: np.searchsorted(frequencies, fmax, "right")]
    return frequencies


def frequencies2bins(frequencies, bin_frequencies, unique_bins=False):
    """Verbatim port of madmom.audio.filters.frequencies2bins."""
    frequencies = np.asarray(frequencies)
    bin_frequencies = np.asarray(bin_frequencies)
    indices = bin_frequencies.searchsorted(frequencies)
    indices = np.clip(indices, 1, len(bin_frequencies) - 1)
    left = bin_frequencies[indices - 1]
    right = bin_frequencies[indices]
    indices -= frequencies - left < right - frequencies
    if unique_bins:
        indices = np.unique(indices)
    return indices


def triangular_filter(start, center, stop):
    """Build a triangular filter from (start, center, stop) bin indices,
    matching madmom.audio.filters.TriangularFilter.__new__."""
    center = int(center)
    start = int(start)
    stop = int(stop)
    rel_center = center - start
    length = stop - start
    data = np.zeros(length, dtype=np.float64)
    # ascending leg: 0..rel_center exclusive
    if rel_center > 0:
        data[:rel_center] = np.linspace(0, 1, rel_center, endpoint=False)
    # descending leg: rel_center..length exclusive of endpoint
    if length - rel_center > 0:
        data[rel_center:] = np.linspace(1, 0, length - rel_center, endpoint=False)
    return data


def band_bins(bins, overlap=True):
    """Verbatim port of madmom.audio.filters.TriangularFilter.band_bins."""
    if len(bins) < 3:
        raise ValueError("not enough bins for a triangular filter")
    out = []
    for index in range(len(bins) - 2):
        start, center, stop = bins[index : index + 3]
        if not overlap:
            start = int(np.floor((center + start) / 2.0))
            stop = int(np.ceil((center + stop) / 2.0))
        if stop - start < 2:
            center = start
            stop = start + 1
        out.append((int(start), int(center), int(stop)))
    return out


def main():
    n_bins = FFT_SIZE // 2 + 1
    bin_freqs = np.arange(n_bins) * (SAMPLE_RATE / FFT_SIZE)

    centers_hz = log_frequencies(BANDS_PER_OCTAVE, FMIN, FMAX, A4)
    # madmom's LogarithmicFilterbank passes unique_bins=unique_filters; default True.
    centers_bins = frequencies2bins(centers_hz, bin_freqs, unique_bins=True)

    triples = band_bins(centers_bins, overlap=True)

    filters = []
    for start, center, stop in triples:
        tri = triangular_filter(start, center, stop)
        if NORM_FILTERS:
            s = tri.sum()
            if s > 0:
                tri = tri / s
        filters.append((start, stop, tri.astype(np.float32)))

    print(f"FFT size:   {FFT_SIZE}")
    print(f"n_bins:     {n_bins}")
    print(f"sample_rate:{SAMPLE_RATE}")
    print(f"filters:    {len(filters)}   (feature_dim = {2*len(filters)})")
    print(f"first filter: start={filters[0][0]}  stop={filters[0][1]}  len={len(filters[0][2])}")
    print(f"last filter:  start={filters[-1][0]} stop={filters[-1][1]} len={len(filters[-1][2])}")

    out = bytearray()
    out += struct.pack("ii", len(filters), n_bins)
    for start, stop, weights in filters:
        out += struct.pack("ii", start, stop)
        out += weights.tobytes()
    out_path = "src/effects/meshflow/weights/filterbank.bin"
    with open(out_path, "wb") as f:
        f.write(out)
    print(f"\nwrote {out_path}  ({len(out)} bytes)")


if __name__ == "__main__":
    main()
