#!/usr/bin/env python3
"""Independent flam meter: broadband onset peaks (the click at the front of each kick), found
separately in two aligned signals around the same beat times. Shares nothing with the aligner."""
import numpy as np
SR = 44_100
HOP = 11
RATE = SR / HOP                     # ~0.25 ms; the hop must divide SR exactly


def onset_curve(audio):
    mono = audio.mean(axis=1).astype(np.float64)
    hop = HOP
    n = len(mono) // hop
    # high-passed energy (above ~1 kHz via first difference twice) captures the click
    x = np.diff(mono, n=2, prepend=[0, 0])
    e = np.sqrt(np.mean(x[:n * hop].reshape(n, hop) ** 2, axis=1))
    k = 4
    e = np.convolve(e, np.ones(k) / k, mode="same")
    return np.maximum(0, np.diff(e, prepend=e[0]))


def peaks_near(curve, beats, window=0.06, strength=0.2):
    out = np.full(len(beats), np.nan)
    ref = np.percentile(curve, 99.5)
    w = int(window * RATE)
    for i, t in enumerate(beats):
        c = int(round(t * RATE))
        if c - w < 0 or c + w >= len(curve):
            continue
        seg = curve[c - w:c + w]
        k = int(np.argmax(seg))
        if seg[k] >= strength * ref:
            out[i] = (c - w + k) / RATE
    return out


def flam(sig_a, sig_b, beats):
    pa = peaks_near(onset_curve(sig_a), beats)
    pb = peaks_near(onset_curve(sig_b), beats)
    d = (pb - pa) * 1000
    d = d[~np.isnan(d)]
    return d
