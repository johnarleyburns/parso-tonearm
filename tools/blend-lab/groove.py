#!/usr/bin/env python3
"""Groove placement (2026-10-08): replaces meter.py's fold angle for placing the incoming beat.

Why: meter.flux took an RMS over 0.5 ms hops of a 35-160 Hz signal, which is not an envelope (it
ripples at twice the bass frequency), so every cycle of a sustained bass counted as a "rise" and
the fold angle was the centroid of kick + bassline + sidechain pump, not the kick. Read from the
finished mixes, the owner's verdicts line up with this measure, not the meter: progressive-house
(the one stellar pair) was 10-20 ms apart, every pair that flammed 40-75 ms, while the meter said
<= 0.3 ms for all of them.

Method: coherent (synchronous) beat averaging. Each band of the waveform is averaged over N beats
at the exact period, so what repeats every beat (kick, hats, the groove's transients) adds up and
what changes (bass notes, chords, vocals) averages out. The averaged envelopes of four bands are
log-compressed and cross-correlated circularly between the outgoing (before the blend) and the
incoming (after it): the lag that lines up the whole groove. Each band's own onset (first 50 %
crossing before its peak) is reported too; when they disagree with the groove the reading isn't
trusted.
"""
import numpy as np
from blend import SR

BANDS = [(35, 200), (200, 1000), (1000, 4000), (4000, 12000)]
AGREE = 0.012            # s: a band onset within this of the groove lag agrees
MIN_AGREE = 3            # bands that must agree


def split(audio):
    """The track's mono signal split into BANDS (FFT brick-wall)."""
    x = audio.mean(axis=1).astype(np.float64) if audio.ndim == 2 else audio.astype(np.float64)
    X = np.fft.rfft(x); f = np.fft.rfftfreq(len(x), 1 / SR)
    out = []
    for lo, hi in BANDS:
        Y = X.copy(); Y[(f < lo) | (f > hi)] = 0
        out.append(np.fft.irfft(Y, len(x)).astype(np.float32))
    return out


def beat_average(y, t0, beats, period, offset=0.0):
    """Envelope (analytic magnitude) of y averaged over `beats` beats from mix time t0, where mix
    time t is sample (t - offset) * SR of y. None if the window leaves the signal."""
    L = int(period * SR); acc = np.zeros(L)
    for k in range(beats):
        s = (t0 + k * period - offset) * SR
        i = int(np.floor(s)); fr = s - i
        if i < 0 or i + L + 1 > len(y):
            return None
        seg = y[i:i + L + 1]
        acc += seg[:L] * (1 - fr) + seg[1:] * fr
    A = np.fft.fft(acc / beats); A[L // 2 + 1:] = 0; A[1:(L + 1) // 2] *= 2
    return np.abs(np.fft.ifft(A))


def onset(env):
    L = len(env); pk = int(np.argmax(env)); thr = 0.5 * env[pk]; i = pk
    while env[(i - 1) % L] >= thr and pk - i < L:
        i -= 1
    return (i % L) / SR


def wrap(d, period):
    return (d + period / 2) % period - period / 2


def offset(bands_a, bands_b, ta, tb, beats, period, shift_b=0.0):
    """How late the incoming groove (window from mix time tb, incoming placed at shift_b) sits
    against the outgoing one (window from ta). ta and tb must be a whole number of beats apart.
    Returns (lag seconds, per-band onset lags, bands agreeing) or None."""
    xc, onsets = 0, []
    for ya, yb in zip(bands_a, bands_b):
        ea = beat_average(ya, ta, beats, period)
        eb = beat_average(yb, tb, beats, period, shift_b)
        if ea is None or eb is None or ea.max() <= 0 or eb.max() <= 0:
            return None
        onsets.append(wrap(onset(eb) - onset(ea), period))
        la, lb = np.log1p(ea / ea.max() * 100), np.log1p(eb / eb.max() * 100)
        xc = xc + np.fft.irfft(np.conj(np.fft.rfft(la - la.mean())) * np.fft.rfft(lb - lb.mean()), len(la))
    lag = wrap(int(np.argmax(xc)) / SR, period)
    agree = sum(abs(wrap(o - lag, period)) <= AGREE for o in onsets)
    return lag, onsets, agree
