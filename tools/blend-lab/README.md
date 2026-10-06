# Blend lab

Renders Platterhead transitions offline to WAV, so blends can be judged by ear and fixed before the
iOS executor changes. It uses the app's own beat grids (the Mood Starter prep records, the same
`TrackGridAnalyzer` output the phone uses) and the real tracks, and it mixes sample-accurately. What
you hear is the **plan** (grid, exit/entry, tempo match, gain curve) with none of AVPlayer's timing.
If a blend sounds right here and wrong on the phone, the executor is at fault. If it sounds wrong
here, the plan or the analysis is.

```sh
tools/blend-lab/run.sh          # needs ffmpeg and python3 + numpy; writes out/*.wav
```

`out/` and `cache/` are git-ignored (downloaded MP3s and renders).

## What the files are

Each pair has four blends. Every file has 24 s of the outgoing track, then the blend, then 24 s
of the incoming track; the blend always starts at **0:24**.

| File | What it is |
|---|---|
| `…__shipped-linear__raw-grid__96beats` | The plan as shipped: the analyser's grid, a 96-beat overlap, both tracks at full level in the middle phrase. |
| `…__equal-power__corrected-grid__96beats` | The grid fixed (see below), the same 96 beats, an equal-power curve (both at −3 dB in the middle). |
| `…__equal-power__corrected-grid__32beats` | The same, as a short 8-bar blend. |
| `…__bass-swap__corrected-grid__64beats` | Grid fixed, DJ-style 16-bar blend: the incoming track comes in without its bass, the basses swap on a downbeat at bar 9, then the outgoing highs fade. |
| `gridcheck__<track>__raw` / `__corrected` | 30 s from the middle of a track with clicks on the grid (downbeats higher). Raw clicks wander off the kick; corrected clicks sit on it. |

Pairs: `1-clean-grids` (Akirhode (House Mix) → Dance with Mister Eurobeat, 122 → 124 BPM),
`2-typical-grids` (zou78 bass → CLUBING BABY 2, 132 → 130), `3-tempo-gap-4.6pct`
(Hyper Threading → Cassian, 130 → 124).

## Findings (2026-10-04)

1. **The analyser's time base is off by exactly 441/440.** On every track measured, the analysed
   BPM is 0.227 % too fast and every beat time is scaled by 440/441. Folding a track's kicks onto
   the analysed period gives a flat profile (contrast ×1.1); folding onto period × 441/440 gives a
   sharp one (×3–5). Scaling the beat times by 441/440 makes the kick-to-grid offset constant from
   the first beat to the last. Without the correction the grid drifts by up to ~0.7 s over a
   6-minute track, so the exit "downbeat" in the outro is nowhere near a downbeat. Most likely a
   sample-rate/hop mix-up in `ParsoAudioAnalysis` (it resamples to 48 kHz with a 2048-sample hop).
   This is the main reason blends sounded like a train wreck, and it affects all ~4,000 prepared
   Mood Starter tracks as well as the phone's own analysis.
2. **Beat positions are coarse and jittery.** A 2048-sample hop at 48 kHz is 42.7 ms, and 190 of
   264 candidate tracks have doubled or missing beats. A regular grid fitted to the BPM and the
   detected beats (`fitted_grid`) removes the jitter. Exits and entries must come from that grid,
   never from a single detected beat.
3. **The shipped curve doubled the level** (both tracks at full for 32 beats, then a drop), and on
   the phone the volume changed in 0.5 s steps. On top of that, the 2026-10-04 executor nudges the
   incoming rate every 0.5 s. With the grid off by up to a beat, those nudges chase a wrong target
   and are a likely source of the "volume up and down every second" you heard.

Measured kick alignment (incoming relative to outgoing, from each track's own kicks):

| Pair | Shipped plan | Corrected grid |
|---|---|---|
| 1-clean-grids | +220 ms | +3 ms |
| 2-typical-grids | +166 ms | −5 ms (96 beats); about +65 ms at the 32/64-beat exits, where the measurement is noisier |
| 3-tempo-gap | +117 ms | +140–155 ms measured, but the outgoing track's outro changes its drum pattern, which throws the measurement off (its corrected grid is +34 ms everywhere else). Judge this one by ear. |

## Next steps once the blends sound right

1. Fix the time base in `ParsoAudioAnalysis` (with a synthetic 120 BPM click test at 44.1 kHz),
   re-analyse the Mood Starter pack, and invalidate cached phone analyses (bump the algorithm ID).
2. Plan exits and entries on a fitted regular grid.
3. Then the iOS executor: schedule once, sample-accurately, with no periodic rate nudging, and
   ramp the gain with an audio-mix ramp instead of stepping `AVPlayer.volume`.
