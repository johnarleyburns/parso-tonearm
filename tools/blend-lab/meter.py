#!/usr/bin/env python3
"""The beat-phase meter the owner's ears validated (2026-10-08): fold a band envelope's rise
onto the beat period; the angle of the first harmonic is where the beat sits, its magnitude
(0..1) how steady it is. Small measured offsets sounded clean, large or unreadable ones flammed.

Every clock here is exact: one envelope sample is HOP / SR seconds, never a rounded millisecond.
"""
import numpy as np
from blend import SR

HOP = 22
RATE = SR / HOP

# Bands tried for the beat: the kick's body, its upper thump and its click. The same band is
# used on both tracks of a pair, because each band's envelope rises at a slightly different time.
BANDS = {"kick": (35, 160), "thump": (160, 400), "click": (2000, 6000)}


def flux(audio, band):
    """Rectified rise of the band's RMS envelope at RATE (FFT band-limit, ~4.5 ms smoothing)."""
    lo, hi = BANDS[band]
    mono = audio.mean(axis=1).astype(np.float64) if audio.ndim == 2 else audio.astype(np.float64)
    spec = np.fft.rfft(mono)
    f = np.fft.rfftfreq(len(mono), 1 / SR)
    spec[(f < lo) | (f > hi)] = 0
    x = np.fft.irfft(spec, len(mono))
    n = len(x) // HOP
    e = np.sqrt(np.mean(x[:n * HOP].reshape(n, HOP) ** 2, axis=1))
    e = np.convolve(e, np.ones(9) / 9, mode="same")
    return np.maximum(0, np.diff(e, prepend=e[0]))


def fold(fl, t0, t1, period):
    """(phase seconds in [0, period), steadiness 0..1) of the beat between t0 and t1 (seconds)."""
    a, b = max(0, int(t0 * RATE)), min(len(fl), int(t1 * RATE))
    if b - a < RATE * 2:
        return np.nan, 0.0
    t = np.arange(a, b) / RATE
    w = fl[a:b]
    z = np.sum(w * np.exp(2j * np.pi * t / period))
    s = np.sum(w)
    if s <= 0:
        return np.nan, 0.0
    return (np.angle(z) / (2 * np.pi) * period) % period, float(abs(z) / s)


def stability(fl, t0, t1, period, parts=4):
    """Spread (seconds, circular) of the phase across `parts` sub-windows, and the minimum
    steadiness among them. A readable beat has a small spread in every part."""
    edges = np.linspace(t0, t1, parts + 1)
    ph, st = [], []
    for a, b in zip(edges[:-1], edges[1:]):
        p, s = fold(fl, a, b, period)
        ph.append(p); st.append(s)
    if np.any(np.isnan(ph)):
        return np.inf, 0.0
    z = np.exp(2j * np.pi * np.array(ph) / period)
    R = abs(z.mean())
    spread = np.sqrt(-2 * np.log(max(R, 1e-12))) / (2 * np.pi) * period
    return float(spread), float(min(st))


def wrap(d, period):
    return (d + period / 2) % period - period / 2
