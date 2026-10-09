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

1. **WITHDRAWN 2026-10-08: this was a lab bug, not an analyser bug (see below).** ~~The analyser's time base is off by exactly 441/440.~~ On every track measured, the analysed
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

1. ~~Fix the time base in `ParsoAudioAnalysis`~~ Not needed: the analyser's time base is correct.
2. Plan exits and entries on a fitted regular grid.
3. Then the iOS executor: schedule once, sample-accurately, with no periodic rate nudging, and
   ramp the gain with an audio-mix ramp instead of stepping `AVPlayer.volume`.

## Findings (2026-10-08): the beat-locked method

`lock.py` follows the owner's method: tempo matched once with keylock and kept for the rest of
the mix, phase matched at the blend, and a slow nudge. Research notes are in `RESEARCH.md`.

1. **The time-stretch was a flam source on its own.** ffmpeg `atempo` (used by `blend.py`) moved
   74 % of kicks by more than 2 ms, with a spread of about ±8 ms and up to ±20 ms. Rubber Band's
   R2 engine with `-c 6` keeps kick timing within the measurement noise of an exact-timing
   resample (21 % of kicks over 2 ms, against 13 % for a plain resample). Its R3 engine and an
   offline AVAudioUnitTimePitch render were worse. **For iOS:** the stretcher must be chosen and
   measured the same way. Rubber Band is GPL or commercially licensed, so this needs a licensing
   decision before it ships in the app.
2. **Tempo comes from the audio.** Folding the kick onsets over the track and keeping the
   sharpest period gives a tempo accurate to better than 0.01 %. It agrees with the analyser
   (140.000 vs 139.99, 124.001 vs 124.00, …).
3. **Phrase-aligned blends.** The blend starts on an 8-bar phrase start, chosen where each
   track's energy changes (drops and breakdowns), so the bass swap lands on a phrase downbeat.
4. **Phase: two candidates, decided by ear.** A aligns the audio-measured grids. B aligns each
   track's measured kick position, its timing map. They differ by 8–35 ms per pair. The automatic
   flam meters built so far (attack picking, own-kick template matching, cross-track shape
   correlation, broadband onset peaks) disagree with each other. Hats, bass notes and intros
   without a kick fool them, so none can be trusted to say which is right. The owner's A/B
   verdict is the ground truth used to calibrate a meter.

`out/ab/` holds the A/B renders and `out/ab/LISTENING-GUIDE.md` the full paths and times.

## Correction (2026-10-08): the 441/440 "analyser bug" was the lab's own clock

Every lab envelope used an integer hop of `SR // rate` samples (`44100 // 2000 = 22`,
`44100 // 200 = 220`, `44100 // 1000 = 44`) and then treated one hop as exactly 0.5, 5 or 1 ms.
22 samples is 0.4989 ms, so every time the lab measured was stretched by 44100/44000 = 441/440.
That is the "0.227 % fast" analyser tempo, and it is why folding on period × 441/440 looked
sharper. With exact hops (`ENV_RATE = SR / HOP`), every audio-measured tempo is a whole number
(140.000, 138.001, 124.001, 130.0, 120.000 BPM) and agrees with the analyser, and the analyser's
raw grid folds sharply on its own period.

Consequences:
- **The analyser, the Mood Starter pack and the iOS app need no time-base fix.**
- The 2026-10-04 "corrected grid" renders applied a wrong 0.227 % scale. Their exits drift off
  the beat by roughly 0.23 % of the exit time (about 300 ms at 2:20), which explains bad beats at
  the drops in `out/full/`.
- The first `out/ab/` renders were 90–210 ms off for the same reason. The tempo match was
  right; only the phase was wrong, because the error grows with each track's position.
- Re-rendered with exact clocks. A correct-clock check (fold the low band before the blend on
  the outgoing track and after it on the incoming one) measures trance A +3…+8 ms (B +40),
  house B +5 (A +16), deep-house A −3 (B +16), eurodance B +7 (A +30). Techno's incoming
  track has no steady low-band kick, so it can't be measured this way, and progressive-house
  measures about −85 ms in both A and B. Both need checking by ear.
- Separately, with the correct clock the analyser's raw grid sits 125–145 ms after the kick on
  some tracks (Loathe, call me) and on it on others (Bell Trance). Grid phase must still come
  from the audio, never from the analyser alone.

## Meter-locked blends and an App Store stretcher (2026-10-08)

The owner's A/B verdicts matched the correct-clock meter on every file (`meter.py`: fold a band
envelope's rise onto the beat period; first-harmonic angle = beat phase, magnitude = steadiness).
`align.py` now uses it to place the incoming track:

- **Where the beat is read:** the outgoing track over the 60–120 s before the blend and the
  incoming one over the 60–120 s after it. Their steady bodies, not the sparse outro and intro
  inside the overlap. Dance tracks are quantised to one tempo, so the phase holds through the blend.
- **Band:** the kick band (35–160 Hz) whenever both tracks are readable in it (phase spread ≤ 8 ms
  across the window's quarters). Thump (160–400 Hz) or click only otherwise. Bands disagree by
  a constant 60–200 ms, because a bassline or snare can read as the beat, so both tracks must use one band
  and the kick band wins.
- **Keep it there:** one tempo and one placement. A per-8-beat nudge was tried and removed; local
  readings across two different tracks swing ±10 ms with the music, so following them added flam.
- **Gate:** no readable region on both tracks → low confidence. Rendered both as a grid-only
  blend and as a phrase cut (no overlapping kicks), for the owner to choose the app's fallback.

### Stretchers that can ship (Rubber Band can't: App Store licensing)

`stretchbench.py` measures kick timing against an exact-timing resample, in 8-beat windows:

| Stretcher | Licence | worst p90 / max jitter |
|---|---|---|
| Rubber Band R2 `-c 6` (reference only) | GPL / commercial | 4.4 / 10.1 ms |
| **Apple AVAudioUnitTimePitch at n/512 + AVAudioUnitVarispeed** | built in | 6.4 / 10.2 ms, drift < 0.005 ms/s |
| Signalsmith Stretch (60 ms blocks) | MIT | 6.6 / 11.3 ms |
| Bungee (short grain) | MPL-2.0 | 6.8 / 14.5 ms |
| Apple AVAudioUnitTimePitch, rate as requested | built in | drifts 0.6–0.8 ms per second |

**AVAudioUnitTimePitch truncates `rate` to a multiple of 1/512.** x1.01641 plays at 520/512,
x1.01450 at 519/512, x1.00839 at 516/512, x1.02223 at 523/512. Over a 64-beat blend that is up to
25 ms of drift, so any phone blend that relied on it flammed. The fix: give the time-pitch unit
floor(rate × 512) / 512 and an AVAudioUnitVarispeed after it the remainder (< 0.2 %, ≤ 3.4 cents).
Within ±0.2 % of 1.0 skip the time-pitch unit (bypass): varispeed alone, because the phase
vocoder smeared the kicks of x1.0000 tracks enough to make them unreadable. (AVPlayer's
time-pitch algorithms likely quantise the same way; untested.)

`out/locked-apple/` renders all six pairs through that Apple chain (`BLEND_STRETCHER=apple`);
`out/locked2/` is the same with Rubber Band, for comparison.

Open: `phrase_phase` picked entry beats 4 apart between the Rubber Band and Apple renders of
the same tracks (near-tied scores). Flam doesn't depend on it, but where the bass swap lands does.

## Owner's verdict and fixes (2026-10-08, Apple chain)

- Progressive-house: "stellar". Trance, house, eurodance: okay, bass swap generally better.
  Techno (placed by its 160–400 Hz band) and deep-house (unreadable, grid-only): flam, unusable.
  → **Only the kick band may place a blend.** No readable kick on both tracks → phrase cut.
  → **Bass swap is the default style.**
- **Click at the blend start (bass swap):** the outgoing track switched from its plain signal to
  its crossover band sum at the blend sample. A Linkwitz-Riley sum is an all-pass, so it is
  phase-shifted, and the switch was a step 2–8× the track's sharpest transient. Fixed by running the
  outgoing through the crossover from its first sample. **For iOS:** the EQ/crossover must be in
  both decks' paths from the start of playback, never inserted when a blend begins.
- **Phrase cut:** it added the incoming's intro under the outgoing's last bar and started
  without a fade. Now the incoming starts on its downbeat with a 3 ms fade-in.
- Click check: second-difference peak at every transition mark against the tracks' own 99.99th
  percentile; all pass.

## DJ-planned blends: the bass swap on the drop (2026-10-08)

The old plan swapped the basses 8 bars after an energy-guessed "phrase start", never on a drop:
in every pair the incoming drop happened with its bass cut, or after the swap. `djmix.py` plans
by structure (`structure.py`):

- **Drops / bass exits:** the beat where the kick-band level over the next 8 beats rises
  (falls) ≥ 6 dB against the previous 8, at the sharpest step, snapped to the track's bar phase.
- **Incoming swap point:** its first drop (the incoming starts 8 bars before; with a shorter intro
  it starts a little into the blend), or a phrase line 8 bars in when its bass is in from the start.
- **Outgoing swap point,** best first: **double drop** (an outgoing drop in its second half: both
  drop together), **bass exit** (its breakdown/outro starts as the incoming bass arrives), then
  phrase lines, latest first.
- Every ranked candidate is tried until both kicks are readable (30/60/120 s just outside the
  blend). The swap now completes **on** the downbeat (a quarter-beat ramp before it). It used to
  ramp over the beat after, which half-swapped the drop's first kick.
- **Deep house and techno:** their kick band is buried (a sustained deep bassline; techno rumble).
  Proper HPSS (Fitzgerald: median along time = harmonic, along frequency = percussive; scipy)
  makes much of them readable (Pink Cocktail 89→6 ms, INSIDE ROOM 51→3 ms). Its reading sits at a
  track-dependent offset from the plain one (−103…+7 ms), so both tracks of a pair must use it, and
  it is only used when the plain kick reading fails (`--perc`). Not yet validated by ear.
  Readability also comes and goes in 30 s stretches in these tracks, so searching all structural
  candidates, not just the last phrase, matters as much as the reading.

`out/dj/` has the renders (Apple chain); its `LISTENING-GUIDE.md` lists each swap's reasons.

## The meter was wrong: groove placement (2026-10-08)

**Owner's verdict on `out/dj/`:** progressive-house (both, especially the double drop) "straight
outta Tomorrowland"; every other pair a train wreck: obvious flam and phasing.

**Cause:** `meter.flux` took an RMS over 0.5 ms hops of the 35–160 Hz signal. That is not an
envelope: it ripples at twice the bass frequency, so every cycle of a sustained bass or
sidechain-pumped synth counted as a "rise", and the fold angle was the centroid of kick + bassline
+ pump, not the kick. It said ≤ 0.3 ms for every pair. Progressive-house worked because its
outgoing kick is short and dry. `djmix.py` made it worse by reading inside drops and bodies
(bass-heavy) instead of outros and intros. The HPSS "fix" for deep house and techno inherited the
same fault.

**Measure that matches the ears (`groove.py`):** coherent beat averaging. Each of four bands
(35–200, 200–1k, 1k–4k, 4k–12k Hz) of the waveform is averaged over N beats at the exact period:
what repeats every beat (kick, hats, the groove's transients) adds up, while bass notes, chords
and vocals average out. Then the log envelopes of the outgoing (before the blend) and the
incoming (after it) are cross-correlated. Read from the finished mixes:

| Renders | progressive-house | trance | house | eurodance | owner |
|---|---|---|---|---|---|
| `locked-apple` | +14 ms | unreadable | +51 ms | +54…70 ms | "okay", not tight |
| `dj` | +11…16 ms | +43 ms | +50 ms | +56…70 ms | prog stellar, rest train wrecks |
| `dj2` (groove-placed) | 0…2 ms | 0…3 ms | 0…3 ms | +2…3 ms | — |

Stable across 16/32/64/128-beat windows for house and progressive-house. Gate: at least 3 of the 4
bands' own onsets within 12 ms of the groove lag. Techno and deep house fail it at every
structural candidate (bands disagree by 100–250 ms: different instruments carry the beat in
different bands). They get a phrase cut until something reads them reliably.
`meter.py`, `align.py` and the HPSS path are kept only for history.
