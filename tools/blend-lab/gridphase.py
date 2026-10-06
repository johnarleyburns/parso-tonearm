#!/usr/bin/env python3
"""For each track: where its own kicks sit relative to its beat grid (raw and fitted).
Folds the low-band onset envelope onto the grid: the lag with most onset energy is the grid's
phase error. 0 ms = grid on the kicks."""
import json, sys, numpy as np
sys.path.insert(0, ".")
from blend import decode, fetch, raw_grid, fitted_grid, onset_env, SR

tracks = json.load(open(sys.argv[1])); cache = sys.argv[2]
for tid in sys.argv[3:]:
    T = tracks[tid]
    audio = decode(fetch(T, cache, tid)); dur = len(audio) / SR
    env = onset_env(audio)                      # 5 ms hops
    for g in (raw_grid(T), fitted_grid(T, dur)):
        lags = np.arange(-30, 31)               # ±150 ms
        idx = np.round(g.beats * 200).astype(int)
        scores = []
        for l in lags:
            j = idx + l; j = j[(j >= 0) & (j < len(env))]
            scores.append(env[j].mean())
        scores = np.array(scores); best = int(np.argmax(scores))
        # per-beat spread: for each beat, the lag of the strongest onset within ±60 ms
        per = []
        for i in idx:
            w = env[max(0, i - 12):i + 13]
            if len(w) == 25 and w.max() > 0.1: per.append((np.argmax(w) - 12) * 5)
        print(f"{tid} {T['title'][:26]:26s} {g.kind:6s} phase error {lags[best]*5:+4d} ms "
              f"(peak x{scores[best]/np.median(scores):.1f}); per-beat kick spread p90 {np.percentile(np.abs(per),90) if per else float('nan'):.0f} ms")
