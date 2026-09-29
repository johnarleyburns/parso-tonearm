# DJ Phase 1 — Analysis stages 1–2 and the thermal governor (Milestone M1)

Plan for milestone **M1** of the Platterhead iOS DJ build. Implementation is driven by this file
one commit at a time, on `main`, per handoff §8 and the working agreement in
`docs/plans/tonearm-mvp-ios/HANDOFF.md`.

**Spec:** `docs/plans/tonearm-mvp-ios/PLATTERHEAD_IOS_ARCHITECTURE.md`. Read §48.2 (goal/exit),
Appendix M.2 (manifest), and the sections each commit names. **Appendix M.2's commit order is
authoritative; §49.2's implementation order (schema → pure kernels → façade → view model → view)
is binding.**

## 1 · Milestone goal and exit (spec §48.2)

Every imported track passes through an immutable, staged, versioned analysis pipeline exactly once
per analysis version. This milestone builds stages 1–2 DSP plus the thermal/power governor that
everything after it depends on, and the Analysis screen as a visible activity.

**Exit (§48.2):** a 4,000-track library analyzes to stage 1 overnight on a charger without the
device becoming unpleasant to hold; golden-file regression green (Appendix R.2); NFR-DET-3
(deterministic, cross-silicon-identical analysis output) verified against fixtures. `make test-swift`
green; app builds; `xcodegen generate` committed after any file add/remove.

## 2 · Resolved spec-vs-repo decisions (recorded up front)

1. **Working sample rate = 48 kHz.** Spec §19.2 and §21.1 say 44.1 kHz; Appendix C's normative
   table (line 5910), Appendix F, H.1, and the M.2 manifest all say 48 kHz, and the engine
   (M4, §34A) works at 48 kHz. **Resolution: 48 kHz**, so beat-grid sample positions map 1:1 onto
   engine samples and the golden fixtures are computed at the same rate. The `STFTConfig.sampleRate`
   default in §21.1 is treated as stale and set to 48 000. (Noted for owner review; nothing is
   gated on it.)
2. **BLOB layouts follow Appendix C** (the normative tables), not the older §15.7 sketch — both
   exist; Appendix C is labelled normative and is what the golden-file reader must parse.
3. **Loudness reuses the existing `TonearmCore.ReplayGain` tag parser** (`Sources/Audio/ReplayGain.swift`)
   for stored-tag reading and records the `replayGainDB` computed from integrated LUFS targeting
   −18 LUFS, per §20.1. A test cross-checks the computed value against `ReplayGain.appliedGain`
   so the player and the DJ agree.
4. **No new network host, no new dependency.** Everything below is vDSP/AVFoundation/GRDB, all
   already linked. Golden fixtures are **synthetic audio generated in code** (Appendix R.1) so no
   copyrighted material or network fetch enters the repo.

## 3 · File manifest (Appendix M.2)

All paths under `Sources/DJ/` (already excluded from the app target's `project.yml` sources —
handoff §2 trap: do not re-include). New directories: `Sources/DJ/Analysis/` and
`Sources/DJ/Features/Ingestion/`. Tests under `Tests/DJTests/`.

| File | Purpose |
|---|---|
| `Data/DJMigrations+v2.swift` | `dj_v2` DDL (analysis tables, §15.1–15.3) |
| `Analysis/AudioDecode.swift` | decode → 48k mono/stereo `PCMBuffer` (§19.3) |
| `Analysis/Loudness.swift` | BS.1770 / R128 integrated LUFS, true peak, DR (§20) |
| `Analysis/STFT.swift` | vDSP real FFT, Hann window, reused setup (App. F.1) |
| `Analysis/SpectralFeatures.swift` | per-frame centroid/rolloff/flux/rms/zcr/bands (App. F.2) |
| `Analysis/Onsets.swift` | multi-band flux novelty + peak-pick (App. F.3, §22) |
| `Analysis/Tempo.swift` | autocorrelation/comb tempo, octave resolution (App. F.4, §22.3–22.4) |
| `Analysis/Beats.swift` | DP beat grid + downbeats (App. F.5, §23) |
| `Analysis/Key.swift` | chroma (HPCP) + template key correlation + Camelot (App. F.6, §24) |
| `Analysis/Phrase.swift` | self-similarity/energy phrase segmentation (§25) |
| `Analysis/Energy.swift` | per-beat energy curve (App. F.7, §25.2) |
| `Analysis/Waveform.swift` | multi-resolution min/max/RMS pyramid (§26) |
| `Analysis/AnalysisCoordinator.swift` | job runner, concurrency limits, progress stream, thermal governor integration (§19) |
| `Analysis/AnalysisVersions.swift` | per-stage version constants + `analysis_version` seeding (§17.2) |
| `Features/Ingestion/AnalysisView.swift` + `AnalysisModel.swift` | mockups `ipad/02-library.html` + `ipad/03-analysis.html` progress (§41.3) |
| `Tests/DJTests/DSPTests.swift` + `Tests/DJTests/Golden/*` | kernel unit tests + golden regression fixtures (Appendix R) |

## 4 · Data layer — `dj_v2` migration (commit 1.1, schema first per §49.2)

Append `"dj_v2"` to `DJSchema.migrationOrder` and register it in `DJMigrations.registerV2`.
New tables, all per §15.1–15.3 (snake_case tables, camelCase columns, matching the v1 style):

- `analysis_version` (stage, version, descriptor, introducedAt — PK `(stage, version)`)
- `analysis_run` (trackID→track, stage, version, state, attempts, lastError, startedAt, finishedAt,
  durationMS) + indexes
- `loudness` (trackID PK, integratedLUFS, truePeakDBTP, replayGainDB, dynamicRangeDB,
  loudnessRangeLU, version)
- `frame_features` (trackID PK, frameCount, hopSize, fftSize, sampleRate, featureMask, blob, version)
- `onset_envelope` (trackID PK, sampleRate, count, blob, version)
- `tempo_candidate` (id, trackID, bpm, confidence, rank) + index
- `beat_grid` (trackID PK, syncID UNIQUE, bpm, firstBeatSample, beatCount, isConstantTempo,
  source, confidence, version, updatedAt)
- `beat_blob` (trackID PK, blob)
- `downbeat` (id, trackID, beatIndex, samplePosition, barNumber, confidence) + index
- `key_estimate` (id, trackID, scope, startSample, endSample, camelot, tonic, mode, confidence,
  version) + index
- `phrase` (id, syncID UNIQUE, trackID, startSample, endSample, startBeat, lengthBeats, type,
  energy, confidence, version) + index
- `energy_curve` (trackID PK, resolution, count, blob, version)
- `waveform_pyramid` (trackID PK, levels, baseSamplesPerBin, channelLayout, blob, version)

`DJMigrations+v2.swift` mirrors the existing `DJMigrations+v1.swift` file. BLOB column semantics
are plain `Data`; the typed decoders live with the analysis module (Appendix C layouts).

## 5 · Commit sequence (Appendix M.2)

### Commit 1.1 — decode + loudness (`dj_v2` DDL lands here)

- `DJMigrations+v2.swift` (§4) + `DJSchema.migrationOrder` → `["dj_v1", "dj_v2"]`.
- `AudioDecode.swift`: `PCMBuffer` (48 kHz, Float32, mono + stereo views, `@unchecked Sendable`
  uniquely-owned per §19.3); `AudioDecoder` shell using `AVAudioFile`/`AVAudioConverter` reusing
  the repo's existing AVFoundation decode; memory-mapped scratch for very long tracks.
- `Loudness.swift`: `LoudnessAnalyzer.integratedLUFS`, true peak (4× oversample), LRA/DR;
  R128 gating; `replayGainDB` = −18 − integratedLUFS. Pure, vDSP (`vDSP_biquad`, `vDSP_measqv`).
- `AnalysisVersions.swift` with `loudness = 1` seeded into `analysis_version`.
- Tests: `LoudnessTests` (synthetic sine ramp → known LUFS; silence → −inf handled; true peak
  ≥ RMS), `PCMBufferTests` (mono/stereo views, ownership), `MigrationV2Tests` (append-only order,
  tables created, round-trip a `loudness` row), `ReplayGainCrossCheckTests`.
- Acceptance IDs named: **FR-ANL-1**, **AT-ING-\***, **NFR-DET-3**.
- `xcodegen generate` (new files) + commit.

### Commit 1.2 — STFT + spectral features + onsets

- `STFT.swift` (App. F.1): `vDSP.FFT<DSPSplitComplex>`, periodic Hann precomputed, zero per-frame
  allocation, `Spectrum` (power + magnitude).
- `SpectralFeatures.swift` (App. F.2): centroid, rolloff, flux, rms, zcr, 8 band energies.
- `Onsets.swift` (App. F.3 + §22.1–22.2): multi-band flux novelty envelope, adaptive mean/std
  threshold peak-picking, min-gap. Writes `frame_features` + `onset_envelope` BLOBs (Appendix C).
- Tests: `STFTTests` (pure tone → correct bin peak; Hann window), `SpectralFeatureTests`
  (chirp centroid monotonic, rolloff threshold, flux response to transient), `OnsetTests`
  (click track → peaks at impulse times; noise → no false peaks), `BlobRoundTripTests` (encode
  → decode Appendix C layout byte-exact).
- Acceptance IDs: **FR-ANL-1**, **AT-ING-\***, **NFR-DET-3**.

### Commit 1.3 — tempo + beats + downbeats (goldens start here)

- `Tempo.swift` (App. F.4 + §22.3–22.4): novelty autocorrelation (vDSP_conv), comb scoring with
  decaying harmonics, octave folding + tempo prior; top-K `tempo_candidate` rows; rank 0 →
  `track.detectedBPM`.
- `Beats.swift` (App. F.5 + §23): Ellis-style DP beat tracker over the envelope (log-Gaussian
  period penalty), per-beat onset refinement within `refineWindowMS`, `beat_grid` +
  `beat_blob`; `downbeats` by bar-level accent correlation (kick + harmonic-change weighting),
  `downbeat` rows.
- **Golden fixtures begin here** (Appendix R.1/R.2): code-generated synthetic click/chirp tracks
  checked in as WAV under `Tests/DJTests/Fixtures/audio/` with sibling golden JSON under
  `Fixtures/golden/`. A `GoldenTestRunner` compares computed BPM/downbeat times within the
  stated tolerances.
- Tests: `TempoTests` (click track at 124 BPM → 124.0 ± 0.2; octave error resolution; tempo
  prior), `BeatTests` (grid lands on impulses within 25 ms; confidence > 0; constant tempo),
  `DownbeatTests` (4/4 accent pattern → correct offset), `GoldenTempoBeatTests`.
- Acceptance IDs: **FR-ANL-1/4**, **AT-GRID-\***, **NFR-DET-3**.

### Commit 1.4 — key + phrase + energy + waveform

- `Key.swift` (App. F.6 + §24): per-frame HPCP chroma via CQT (sparse kernel over the reused
  STFT spectrum), track-mean 12-vector, correlation against 24 major/minor profiles
  (Krumhansl/Temperley), tonic+mode → Camelot via fixed table, `key_estimate` rows +
  `track.camelot`/`track.musicalKey`.
- `Phrase.swift` (§25): beat-synchronous feature averaging, self-similarity + Foote checkerboard
  novelty, energy-contour change points, snap to downbeats, quantize lengths (16/32 beats),
  type labels (intro/build/drop/chorus/breakdown/outro) → `phrase` rows.
- `Energy.swift` (App. F.7 + §25.2): per-beat energy in [0,1] blend of RMS + HF flux,
  normalized + smoothed → `energy_curve` BLOB; scalar `track.energy` (0–10) as robust median.
- `Waveform.swift` (§26): pyramid levels (base 256 samples/bin × 8), min/max/RMS with optional
  band split, packed per Appendix C → `waveform_pyramid`.
- Tests: `KeyTests` (pure tone → correct pitch class; two-tone major chord → correct key;
  confidence ordering), `CamelotTests` (tonic×mode table exact; compatibility set), `PhraseTests`
  (synthetic intro→drop→outro → boundaries at downbeats, quantized lengths), `EnergyTests`
  (amplitude ramp → rising curve), `WaveformTests` (silence → flat; sine → symmetric min/max),
  `GoldenKeyPhraseWaveformTests`.
- Acceptance IDs: **FR-ANL-1**, **AT-ING-\***, **NFR-DET-3**.

### Commit 1.5 — coordinator + screens + thermal governor + health

- `AnalysisCoordinator.swift` (§19): actor job runner over `analysis_run` rows; `reconcileVersions()`
  (only stale stages re-run, §17.2); bounded concurrency (`performanceCoreCount − 1`, min 1,
  `.background` priority); progress `AsyncStream`; crash-safe resume (stale `running` → `pending`);
  single-transaction persist + roll-up `track.analysisState`; **priority-fenced** (paused entirely
  while the performance engine is live, FR-ANL-2).
- **Thermal governor** (§43.7, FR-ANL-7/8): a pure decision function per lane ×
  `ProcessInfo.thermalState` (the §43.7 table verbatim); stage 1 half concurrency at `.serious`,
  paused at `.critical`; stage 2 paused at `.serious`; bulk analysis requires mains or explicit
  override and never below 20% battery; **hysteretic** recovery (resume one state below where shed);
  current decision exposed as words for the UI (NFR-THERM-4). Tested as a decision table, one test
  per row.
- `AnalysisModel.swift` + `AnalysisView.swift` (§41.3, mockups `ipad/02-library.html` +
  `ipad/03-analysis.html`): per-stage progress with honest ETAs; governor's current decision
  stated in words; controls (Analyze now · Only while charging · Pause · Re-analyze at new
  version); storage breakdown by cache with the vector tier/size. Wired as a section reachable
  from the DJ library screen.
- Tests: `CoordinatorTests` (idempotent re-run, resume from crash, concurrency ≤ limit, version
  reconcile enqueues only stale stages, single-transaction persist), `ThermalGovernorTests`
  (decision table per §43.7 row + hysteresis), `AnalysisModelTests` (progress mapping, governor
  text), `GoldenDeterminismTests` (same fixture analyzed twice → byte-identical outputs, NFR-DET-3).
- Acceptance IDs: **FR-ANL-2/3/7/8**, **FR-ANL-1**, **AT-ING-\***, **AT-GRID-\***, **NFR-DET-3**,
  **NFR-THERM-2/4**.

## 6 · Testing strategy (spec §47, Appendix R)

- **Kernels (pure):** synthetic signals from Appendix R.1 (click track, pure tone, chirp, ramp,
  silence/dc, two-tone chord) generated in code — exact within tolerance, never drift.
- **Golden regression (Appendix R.2):** small synthetic corpus (8–12 fixtures, few seconds each,
  license-clean because generated) checked in under `Tests/DJTests/Fixtures/`; numeric fields
  asserted within stated tolerances. The determinism gate: a golden diff without a version bump
  fails.
- **Shell:** decode and the coordinator are exercised through `DJLibraryStore`-style tests with
  temp databases (mirroring `DJLibraryStoreTests` conventions); no device required.
- UI regression lanes (§53) are **not** extended in M1 — this milestone has no Part X defect;
  the Analysis screen is covered by `AnalysisModelTests` and the app-smoke lane unchanged.

## 7 · Definition of done (per commit, §49.4)

Tests green · acceptance IDs named in the message · no new dependency without an Appendix Q entry
(there are none) · no new network host (there are none) · mockup coverage contract satisfied ·
`xcodegen generate` committed whenever a file is added · CHANGELOG entry noting the tier (free).

## 8 · Session protocol

One commit per numbered task (1.1–1.5), each a fresh session reading this plan + the spec
sections the commit names. Commit on `main`, allow ~5 min for the pre-commit suite. **Ask before
pushing** (push triggers CI + TestFlight). No `Co-Authored-By` trailer is added (owner preference).

## 9 · Implementation Audit

_To be filled in as commits land: files changed, tests run, intentional deviations._

| Commit | Status | Notes |
|---|---|---|
| Plan doc | done | `dd9cc35` |
| 1.1 decode+loudness | done | `4c27407` — 769 tests green |
| 1.2 STFT+features+onsets | done | `b5f2270` — 781 tests green |
| 1.3 tempo+beats+downbeats | done | `753f2a3` — 793 tests green; comb now interpolates fractional lags; rigid rephase + half-period onset snap |
| 1.4 key+phrase+energy+waveform | done | `feat(dj): key detection…` — 812 tests green; chroma folds FFT bins directly (F.6), Foote checkerboard sign corrected, plateau-aware peak-pick |
| 1.5 coordinator+governor+screens | done | `feat(dj): analysis coordinator…` — 833 tests green |

**Intentional deviations:** (a) onset `thresholdWindow` 16 → 8 frames (0.68 s exceeded
0.5 s beat spacing at DJ tempos); (b) beat refine window widened to half the beat period
for the rigid constant-tempo grid; (c) chroma uses direct bin→pitch-class folding per
App. F.6 rather than a separate CQT kernel; (d) `AnalysisModel`/`AnalysisView` live under
`Features/Ingest/` (the app target) and are covered by model-level + smoke tests, not the
UI-regression lanes (unchanged in M1).
