#!/usr/bin/env python3
"""Song structure for DJ-style blends (2026-10-08): drops and bass exits on the beat grid.

A drop is the beat where the bass comes back: the mean kick-band level over the next 8 beats is at
least DROP_DB above the previous 8, and it is the sharpest such jump nearby (the true downbeat
gives the sharpest step). A bass exit is the reverse (a breakdown or the outro starting).
Dance music changes on bar and phrase lines, so these land on downbeats without a bar tracker.

Usage: structure.py <tracks.json> <cache> <track-id> ...   (prints each track's map)
"""
import json, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from blend import SR, decode, fetch, mmss  # noqa: E402
from lock import low_env, audio_period, regular_grid  # noqa: E402

DROP_DB = 6.0
SPAN = 8                 # beats compared on each side


def bass_db(audio, grid):
    """Kick-band (35–160 Hz) level per beat, dB."""
    x = audio.mean(axis=1).astype(np.float64)
    X = np.fft.rfft(x); f = np.fft.rfftfreq(len(x), 1 / SR)
    X[(f < 35) | (f > 160)] = 0
    y = np.fft.irfft(X, len(x))
    idx = (grid * SR).astype(int)
    return np.array([10 * np.log10(np.mean(y[a:b] ** 2) + 1e-12) for a, b in zip(idx[:-1], idx[1:])])


def events(db, sign):
    """Beat indices of drops (sign +1) or bass exits (sign -1): local maxima of the 8-beat step."""
    n = len(db)
    step = np.full(n, 0.0)
    for i in range(SPAN, n - SPAN):
        step[i] = sign * (db[i:i + SPAN].mean() - db[i - SPAN:i].mean())
    out = []
    for i in range(SPAN, n - SPAN):
        if step[i] >= DROP_DB and step[i] == step[max(0, i - SPAN):i + SPAN].max():
            out.append(i)
    return out, step


class Structure:
    def __init__(self, audio, grid):
        self.grid = grid
        self.db = bass_db(audio, grid)
        self.drops, self.drop_step = events(self.db, +1)
        self.exits, self.exit_step = events(self.db, -1)

    def describe(self):
        d = ", ".join(f"{mmss(self.grid[i])} (beat {i}, +{self.drop_step[i]:.0f} dB)" for i in self.drops)
        e = ", ".join(f"{mmss(self.grid[i])} (beat {i}, -{self.exit_step[i]:.0f} dB)" for i in self.exits)
        return f"  drops: {d or 'none'}\n  bass exits: {e or 'none'}"


def main():
    tracks = json.load(open(sys.argv[1])); cache = sys.argv[2]
    for tid in sys.argv[3:]:
        T = tracks[tid]
        a = decode(fetch(T, cache, tid))
        p, ph, _ = audio_period(low_env(a), T["bpm"])
        s = Structure(a, regular_grid(p, ph, len(a) / SR))
        print(f"{T['title']} ({60 / p:.2f} BPM, {mmss(len(a) / SR)})\n{s.describe()}")


if __name__ == "__main__":
    main()
