# DJ Phase 5 — Stems, recording & gig crates (Milestone M5)

Plan for milestone **M5** of the Platterhead iOS DJ build. Implementation is driven by this file
one commit at a time, on `main`, per handoff §8 and the working agreement in
`docs/plans/tonearm-mvp-ios/HANDOFF.md`. The plan doc is Appendix M.6's **`dj-phase-4-stems-recording.md`**
(the appendix's own filename; the milestone is M5).

**Spec:** `docs/plans/tonearm-mvp-ios/PLATTERHEAD_IOS_ARCHITECTURE.md`. Read §48.6 (goal/exit),
Appendix M.6 (manifest + commits), §4.6 (FR-ENG-7/8), §4.6b (FR-REC-1..5), §35.1 (deck as a
summed stem voice), §36 (stem separation pipeline), §37 (recording pipeline), §41.10/41.11/41.12
(stems detail / recording finish / mixes), §41.17 (gig crate), §43.6 (storage budgets), §46.2
(silent-fallback is a defect), §46.3 (RT guard), §49. **Appendix M.6's commit order is
authoritative; §49.2's implementation order (schema/migrations → pure kernels → façade/actor →
view model → view) is binding.**

## 1 · Milestone goal and exit (spec §48.6)

The stem separation pipeline (§36), the recording pipeline (§37), and gig crates (§41.17).
**Prepared stems are the specified path** (FR-ENG-3, §36.5): separation runs the night before, on
a charger, under the thermal governor, scoped to a *gig crate* (FR-ANL-9) — the "4 GB of prepared
crates" model that makes stems affordable. On-demand separation during a live set is permitted,
**deprioritized, and cancellable**, and the fallback — full-mix playback with honestly disabled
stem faders — is the normal case on iOS, never a silent degradation. The deck is four summed stem
voices (§35.1) with per-stem gain/mute/solo, and the mixer never cares whether a deck is stemmed.
Recording captures the **post-limiter master bus** (§37.1) through a lock-free tap into a
segmented M4A, journaled so a crash loses at most the final segment (NFR-REL-2). The Finish and
Mixes surfaces (§41.11, §41.12) close the milestone.

**Exit (§48.6):** AT-STEM-\* and AT-REC-\* green; a recording survives a forced termination with
at most the final segment lost (NFR-REL-2). `make test-swift` green; app builds; `xcodegen
generate` not needed (DJ-only files, handoff §2 trap). **The on-device rows of AT-STEM-\* (real
Demucs separation timing, ANE/GPU thermal behaviour during a live set) are user-owned** — they
need a device and the real model, and run in the post-M5 device pass alongside M4's deferred
AT-THERM-1/AT-MEM-1 (§2.11, plan §2.12).

## 2 · Resolved spec-vs-repo decisions (recorded up front)

1. **No Demucs `.mlpackage` is committed to this repo.** §36.2's PyTorch→CoreML conversion is an
   offline developer step (Appendix D). The M2 precedent is the CLAP model: ODR delivery with an
   honest absence state (`ModelResourceService`/`ModelResourceProviding`, §27.1a, FR-SEM-6).
   `StemSeparator` runs against a **`StemModelProviding` seam** — `ModelTag` gains `.stems` and the
   existing `BundleResourceProvider` carries `DemucsStems.mlpackage`; absence is a value, never an
   error, and the deck plays the full mix (FR-ENG-3's fallback). Tests inject a deterministic
   **fake stem model** (a pure channel-split / passthrough) so the chunk/overlap-add kernel, the
   cache, and cache versioning are all testable off-device. The real model conversion + ODR tag
   registration is a user-owned step (like M2's `42cb3fd` model conversion).
2. **Separation shares the analysis job-runner discipline on a dedicated low-concurrency lane**
   (§36.3): a new `StemService` actor serializes separations (concurrency 1–2), pauses/throttles
   while a performance is live (the `AnalysisCoordinator.isPerforming` fence, FR-ANL-2), abandons
   work the instant `thermalState` reaches `.serious` (the `ThermalGovernor` decision, §43.7), and
   always yields to audio. The queue is scoped to **gig-crate tracks** (FR-ANL-9) plus explicit
   on-demand deck separation (§36.5, best-effort).
3. **Stems are a source-level swap; the deck reader stays the tempo authority.** §35.1's four
   stem voices land as a second armed slot on `DeckState`: a **`StemSet`** pure value (four
   `DeckSource`s + per-stem gain targets) boxed and ownership-transferred exactly like
   `DeckSource` (§12.2 — no ARC, no lock, no allocation on the render thread). When a stem set is
   armed the reader sums the four voices at the shared playhead with per-stem one-pole smoothed
   gains, then runs the existing EQ/filter/fader/crossfader chain. A deck with **no** stem set is
   byte-for-byte the current single-source reader, so every 4.3–4.5 frame-exact test stays valid
   and the mixer never cares whether a deck is stemmed (§35.1).
4. **Prepared stems are the specified path; full-mix is the honest normal state** (§36.5). The
   stem-fader UI (`DeckModuleSlot` STEMS, the compact `BankDrawer` STEMS, and the §41.10 focused
   surface) renders per-stem gain/mute/solo with an honest `prepared / separating / unavailable →
   full mix` status per FR-ENG-3 — never a fader that looks live and does nothing. On iPhone the
   **offered live separation lane is the two-stem split** (vocals + everything-else) per §2.1 and
   §36.5's thermal budget; the full four are always available from cache, and the engine supports
   four regardless (FR-ENG-9).
5. **The stem cache is content-addressed and model-versioned** (§36.4): four 48 kHz `.caf` files
   per track under `DJDatabase.cachesDirectory/Stems/<contentHash>/<stemsVersion>/` (backup
   excluded, §13.1), keyed by the track's `contentHash` + `AnalysisVersions.stems`, recorded in a
   new **`stem_cache`** table (the repo has no `stem_asset` table — verified in
   `DJMigrations+v1.swift`; the `gig_crate_track.stemsState/stemsBytes` columns already carry the
   per-crate roll-up). A model upgrade invalidates cleanly, like `analysis_version`.
6. **The recording tables land in `dj_v4`.** §15.5's `performance_session`, `mix`, `mix_track_event`
   and `mix_asset` DDL is **not** in the repo's `dj_v1` (verified — v1 carries `gig_crate`/
   `gig_crate_track` only), so M5 adds `DJMigrations+v4.swift` with the §15.5 DDL verbatim plus
   `stem_cache`. The `mix` journal row is the crash-recovery mechanism (§37.3): `localState =
   'recording'` at start, `complete` on finalize.
7. **The record tap is a post-limiter master-bus copy into a lock-free ring** (§37.2): `RecordTap`
   runs inside the render callback under `RTGuard`, copies the shaped master output into a
   pre-allocated ring; `EncoderActor` drains off-RT through `AVAudioConverter` (AAC) into a
   **segmented** M4A with periodic flush. The tap is read-only on the master signal and never
   blocks audio. `AudioGraph.Configuration` gains `recordTapEnabled` so the frame-exact reader
   harness stays bit-exact (the tap is idle unless recording).
8. **The timeline is written by the side-car actor, not the render thread** (§37.4). `MixTimeline`
   is fed control-side: `PerformanceEngine` (the façade) reports deck loads, cue/loop toggles and
   crossfader moves at low rate to the active `RecordingService` over a `RecordingEventSink`
   protocol, tagged with `graph.masterSample`. No timeline work crosses the RT boundary.
9. **The CloudKit half of mixes is M6.** §38.1's "Also sync" (FR-REC-2/3) is opt-in, off by
   default, and belongs to M6's sync milestone. M5 ships local-only with the honest `localOnly`
   default and the finish screen's "Keep on device" path (mockup `ipad/09`); the iCloud-quota
   readouts render the honest "not syncing yet" state. FR-REC-4's export (Files / share sheet with
   an optional cue-sheet) is in M5; FR-REC-2/3's upload is not.
10. **FR-REC-5 ("plays in the free player") is satisfied structurally in the DJ library.** The
    DJ app is a separate SPM target excluded from the app target (handoff §2 trap); the mixes are
    ordinary playable assets in the DJ `MixesView` from the moment they finalize. The free-player
    (TonearmCore NowPlaying) integration happens at the 3.0 ship when the DJ feature is wired into
    the app — recorded here so the milestone does not invent an app-target seam it does not need.
11. **Storage budget is a new service** (§43.6): `StorageBudgetService` owns the per-cache disk
    accounting with **`mixesEvictable = false` always** (recordings are user content and are never
    auto-evicted — the app asks, never chooses, §43.6) and **stem LRU by `gig_crate.lastPerformedAt`**,
    always showing what will be evicted *before* evicting it (FR-ANL-9, mockup `ipad/14`). This is
    distinct from M4's `MemoryCeiling` (RAM, NFR-REL-4); `StorageBudgetService` is disk.
12. **The on-device numbers are user-owned and deferred to a post-M5 pass.** Real Demucs
    separation time, ANE/GPU thermal behaviour during a live set, and the physical route
    interruption during a recording run on a device with the real model (plan §2.12). The
    milestone's automated proxies are: chunk/overlap-add reconstruction, cache versioning, budget
    + LRU accounting, stem-voice summing (frame-exact), record-tap → encode → read-back, and
    crash-recovery finalize.
13. **No new network host, no new dependency.** CoreML / Accelerate / AVFoundation / Metal are
    already linked in `TonearmDJ`; ODR tags are the sanctioned M2 path. `Sources/DJ` stays excluded
    from the app target, so DJ-only additions need **no `xcodegen generate`**.
14. **The mixer column's record button lives in the workspace** (§41.9's centre column: "record
    button with elapsed time"). `WorkspaceModel` gains the recording state (`isRecording`,
    `elapsed`), the record toggle forwards `startRecording/stopRecording`, and the record/elapsed
    chip is shared across every performance surface — it is session VM state, not a view's.

## 3 · File manifest (Appendix M.6, paths indicative per handoff §6.4)

New directories: `Sources/DJ/Stems/`, `Sources/DJ/Recording/`. Tests under `Tests/DJTests/`.
`Sources/DJ` stays excluded from the app target (handoff §2 trap), so DJ-only file additions need
**no `xcodegen generate`**.

| File | Purpose |
|---|---|
| `Stems/StemModel.swift` | `StemModelProviding` seam (availability / URL / run) + `StemVoice`/`StemOutput` pure values + the deterministic fake model |
| `Stems/StemSeparator.swift` | Demucs chunk / overlap-add reconstruction kernel (§36.2), pure, vDSP |
| `Stems/StemCache.swift` | content-addressed, versioned `.caf` cache (§36.4) |
| `Stems/StemService.swift` | actor — serialized lane, thermal/performance fences, on-demand + crate-scoped queue (§36.3) |
| `Engine/StemVoices.swift` | `StemSet` pure value (four `DeckSource`s + per-stem gains); reader-side summing (§35.1) |
| `Engine/RTCommand.swift` (edit) | `setStemGain` / `setStemMute` / `setStemSolo` / `armStemSet` tags |
| `Recording/RecordTap.swift` | RT-safe master-bus copy into a lock-free ring (§37.2) |
| `Recording/Encoder.swift` | encoder actor — `AVAudioConverter` AAC, segmented writer with periodic flush (§37.2) |
| `Recording/RecordingService.swift` | journal, finalize, recovery; `RecordingEventSink` (§37, §37.3) |
| `Recording/MixTimeline.swift` | control-side event log → `mix_track_event` (§37.4) |
| `Data/DJMigrations+v4.swift` | §15.5 DDL verbatim + `stem_cache` |
| `Data/DJRecords.swift` (edit) | `StemCacheRow`, `DJMix`, `DJMixTrackEvent`, `DJMixAsset`, `GigCrate`, `GigCrateTrack` records |
| `Data/GigCrateRepository.swift` | promotion from a playlist, per-crate readiness, budget + LRU queries |
| `Perf/StorageBudgetService.swift` | pure disk-budget + LRU-eviction accounting, mixes never evicted (§43.6) |
| `Features/Stems/StemsFXView.swift` + model | mockup `ipad/08-dj-stems-fx.html` — per-stem gain/mute/solo, separation queue, GPU/ANE budget (§41.10) |
| `Features/GigCrate/GigCrateView.swift` + model | mockup `ipad/14-gig-crate.html` — promotion, readiness, storage vs budget, eviction preview (§41.17) |
| `Features/Recording/RecordingFinishView.swift` + model | mockup `ipad/09-recording-finish.html` — title/notes, timeline, export/cue-sheet (§41.11) |
| `Features/Mixes/MixesView.swift` + model | mockup `ipad/10-mixes.html` — local storage, playable mixes (§41.12, FR-REC-5) |
| `Features/Workspace/DeckModuleSlot.swift` (edit) | STEMS module faders become live when prepared (honest otherwise) |
| `Features/Workspace/BankDrawer.swift` (edit) | iPhone STEMS bank — two live faders (§2.1) |
| `Features/Workspace/WorkspaceModel.swift` (edit) | recording state + record toggle; per-deck stem gain/mute/solo state |
| `Tests/DJTests/{StemSeparatorTests,StemCacheTests,StemServiceTests,RecordingRecoveryTests,StorageBudgetTests,GigCrateTests,MixTimelineTests}.swift` | the §9 audit rows |

## 4 · Data layer — one new migration (`dj_v4`)

`DJMigrations+v4.swift` (append-only; no existing table changes, the M1–M3 convention):

- `stem_cache` — `(trackID, modelVersion)` unique key, `bytes`, per-stem relative paths, `createdAt`;
  the §36.4 content-addressed presence record.
- `performance_session`, `mix`, `mix_track_event`, `mix_asset` — §15.5 DDL **verbatim**
  (`mix.localState` default `complete`, `syncPolicy` default `localOnly`; `mix_asset` PK is
  `mixID`; `mix_track_event` carries the title/artist snapshot so it survives track deletion).
- `DJSchema.migrationOrder` gains `"dj_v4"`.

`gig_crate`/`gig_crate_track` already exist in `dj_v1` (§14.3) — M5 only *uses* them.

## 5 · Commit sequence (Appendix M.6)

### Commit 5.1 — Demucs ODR + separation + cache + version stamp

- `ModelTag.stems` + `StemModelProviding` (availability / `url(for:)` / `run(_:)`), production
  `DemucsModelProvider` over the `DemucsStems.mlpackage` URL from `BundleResourceProvider` (§2.1),
  and the deterministic **fake model** (channel-split / passthrough) used by every test.
- `Stems/StemSeparator.swift` (§36.2): fixed-length chunk + window + overlap-add reconstruction at
  the seams (pure, vDSP; chunk length and overlap are constants in the module), output four stereo
  streams at the model rate, resampled to the 48 kHz working rate.
- `Stems/StemCache.swift` (§36.4): four `.caf` files per track under
  `cachesDirectory/Stems/<contentHash>/<AnalysisVersions.stems>/`, `stem_cache` row written in one
  transaction with `DJLibraryStore`; a model-version bump invalidates cleanly.
- `AnalysisVersions.stems` = 1; `DJLibraryStore` gains `stemCache`/`writeStemCache`/
  `evictStemCache` (one GRDB transaction each, NFR-REL-1).
- Tests: `StemSeparatorTests` (chunk/overlap-add reconstruction golden — a known signal
  reconstructs within tolerance across chunk boundaries), `StemCacheTests` (content-addressing,
  version invalidation, eviction removes the directory + row).
- **FR-ENG-3 (pipeline), §36; the AT-STEM cache/version rows.**

### Commit 5.2 — stem voices live on decks, honest disabled state when unprepared

- `Engine/StemVoices.swift` (§35.1): `StemSet` — a pure value holding four `DeckSource`s + per-stem
  gain targets — boxed and ownership-transferred exactly like `DeckSource` (§2.3). `DeckState`
  gains `stemSetPointer`, per-stem one-pole smoothed gains, mute/solo state; the reader, when a
  stem set is armed, sums the four voices at the shared playhead before the existing
  EQ/filter/fader chain. **A deck with no stem set is byte-for-byte the current single-source
  reader** (the 4.3–4.5 frame-exact tests stay valid, §2.3).
- `RTCommand` gains `armStemSet`/`setStemGain`/`setStemMute`/`setStemSolo`; `PerformanceEngine`
  gains `loadStemSet(deck:stemSet:)` + `setStemGain`/`setStemMute`/`setStemSolo` (all lock-free
  enqueues); `SourceBoxRegistry` gains the stem slot.
- `WorkspaceModel` gains per-deck stem state (`stemGains`, mutes, solos, the honest
  `prepared/separating/unavailable → full mix` status from the loaded track's `stemState`);
  `DeckModuleSlot`'s STEMS faders and the compact `BankDrawer` STEMS bank become **live** when the
  loaded deck's stems are prepared, and stay honestly disabled with the "stems not prepared"
  label otherwise (§36.5). On iPhone the bank shows the two live faders (§2.4). The workspace
  record toggle is **5.4**.
- Tests: `EngineOfflineTests` — a stem set sums frame-exact (per-stem gain, mute, solo against a
  known signal); full-mix fallback is bit-identical to the single-source reader; `setStemGain`
  doesn't move the playhead. Model tests for the honest state machine (prepared faders live /
  unavailable faders disabled with the FR-ENG-3 message).
- **FR-ENG-3, §36.5, §35.1; AT-STEM-* (engine rows).**

### Commit 5.3 — gig crates: promotion, budgeted separation, LRU eviction

- `Data/GigCrateRepository.swift` (§41.17): promote a `DJPlaylist` (or a generated playlist —
  FR-PLIST-9) to a `gig_crate` with `storageBudgetBytes`; `gig_crate_track` rows in order; per-track
  readiness (`audioCached` — the FR-LIB-8 gate; `stemsState` pending/running/ready/failed/evicted;
  `stemsBytes`); promote/demote, `lastPerformedAt` update.
- `Perf/StorageBudgetService.swift` (§43.6, pure): budget accounting per crate, **LRU by
  `lastPerformedAt`**, "what will be evicted to make room" computed before any eviction
  (FR-ANL-9), and **`mixesEvictable = false` always** — recordings are never evicted (§2.11).
- `StemService` gains the crate-scoped queue: serialized lane (concurrency 1–2), paused while a
  performance is live, abandoned at `.serious` (reusing `ThermalGovernor`, §2.2); per-track state
  and queue position surface on the gig-crate screen.
- `Features/GigCrate/GigCrateView.swift` + model (mockup `ipad/14`): the four headline readouts
  (audio cached / analyzed / stems separated / storage vs budget), the per-track table (stems +
  audio + size), the honest deck-disabled state for a not-fully-cached remote track (FR-LIB-8), and
  the "Making room" eviction preview before anything is evicted.
- Tests: `GigCrateTests` (promotion from a playlist, demotion, per-track readiness transitions),
  `StorageBudgetTests` (budget accounting, LRU order by `lastPerformedAt`, eviction preview
  selects the oldest crate, mixes never evictable), `StemServiceTests` (serialization, performing
  fence, thermal abandon, queue order).
- **FR-PLIST-9, FR-ANL-9, FR-LIB-8 (gate); AT-STEM-* (crate/budget/eviction rows).**

### Commit 5.4 — record tap + encoder + segmented file

- `Recording/RecordTap.swift` (§37.2): the RT-safe post-limiter master-bus copy into a
  pre-allocated lock-free ring, inside the render callback under `RTGuard` — no encoding, no file
  I/O on the audio thread. `AudioGraph.Configuration.recordTapEnabled` (default false) keeps the
  frame-exact reader harness bit-exact (§2.7).
- `Recording/Encoder.swift`: the encoder actor drains the ring off-RT through `AVAudioConverter`
  (AAC 256 kbps) into a **segmented M4A** with periodic flush; the ring is sized to absorb
  scheduling jitter (§37.2).
- `PerformanceEngine.startRecording/stopRecording` + the record/elapsed state on `WorkspaceModel`
  (§2.14); the workspace's centre-column record button (mockup `ipad/07`'s "record button with
  elapsed time").
- Tests: `EngineOfflineTests` — record tap → drain → finalize yields an M4A whose decoded content
  matches the rendered master buffer (sample-accurate modulo the encoder); tap idle leaves the
  reader bit-exact; the ring absorbs a dropped drain without stalling audio.
- **FR-ENG-7, §37.2; AT-REC-* (capture rows).**

### Commit 5.5 — journal + crash/interruption recovery + finalize

- `Recording/RecordingService.swift` (§37, §37.3): the `mix` journal row (`localState =
  'recording'`, output URL, start time) written at start; periodic segment flush; `reconcile()`
  on launch finds stale `recording` rows, finalizes/repairs the last segment and marks `complete`
  — **a crash loses at most the final segment** (NFR-REL-2). Interruption handling rides the §34A.4
  session path (flush the segment, wait, open a new one — never auto-play, never a lost set;
  FR-ENG-8). `finalize()` computes duration/size and writes the `mix`/`mix_asset` rows (§37.5).
- Tests: `RecordingRecoveryTests` — simulate a crash mid-segment, reconcile, assert a playable,
  near-complete file with at most one segment lost; interruption → new segment; finalize writes
  the correct `mix`/`mix_asset` rows.
- **FR-REC-1/3, FR-ENG-8, NFR-REL-2; AT-REC-* (recovery rows).**

### Commit 5.6 — Finish + Mixes screens + timeline + export

- `Recording/MixTimeline.swift` (§37.4): the control-side event log (deck loads, cue/loop toggles,
  crossfader moves at low rate) fed by `PerformanceEngine` to the active `RecordingService` over
  `RecordingEventSink`, tagged with `graph.masterSample` — no RT work (§2.8).
- `Features/Recording/RecordingFinishView.swift` + model (mockup `ipad/09`): title/notes, the
  generated artwork, the timeline (from `mix_track_event`, interruptions shown, not patched), the
  stats pills (duration / format / size / peak / LUFS), Keep on device (done, default), the honest
  "sync is M6" state (§2.9), **Export** — Save to Files / Share with an optional tracklist
  cue-sheet (FR-REC-4).
- `Features/Mixes/MixesView.swift` + model (mockup `ipad/10`): the mix library — cards + table,
  local storage used, per-mix state, **playable from the DJ library** (FR-REC-5, §2.10), and the
  "mixes are never auto-evicted" statement.
- `Features/Stems/StemsFXView.swift` + model (mockup `ipad/08`, §41.10): the focused per-deck
  stem surface — gain/mute/solo with cached-stem status, the visible separation queue + GPU/ANE
  budget, and the honest FR-ENG-3 fallback card; a "Open gig crate" route into `GigCrateView`.
- Tests: `MixTimelineTests` (deck loads → ordered `mix_track_event` rows with positions; cue/loop/
  crossfader events; interruption marker), model tests (finish title/notes flow, export payload
  with cue-sheet, mixes list + play).
- **FR-REC-1/4/5, §41.11/41.12; AT-REC-* (timeline/export/free-play rows).**

## 6 · Testing strategy (spec §47, Appendix R)

- **Pure kernels:** `StemSeparator` chunk/overlap-add (golden reconstruction), `StemCache`
  versioning/eviction, `StorageBudgetService` budget + LRU accounting, `MixTimeline` ordering,
  `RecordingService` recovery state machine — deterministic, no device.
- **Engine (integration, deterministic):** the M4 offline harness — stem-set summing frame-exact,
  full-mix fallback bit-identical to the single-source reader, record-tap → drain → M4A read-back
  matching the rendered master buffer. The tap's `recordTapEnabled` configuration keeps the 4.3–4.5
  reader tests untouched.
- **Façade/actor:** `PerformanceEngine` stem/recording members through the ring; `StemService`
  queue via injected fake model + fake clock/thermal; `RecordingService` reconcile/finalize via a
  temp-directory pool.
- **View models:** `GigCrateModel`, `RecordingModel`, `MixesModel`, the stem-fader state on
  `WorkspaceModel` with fake engine/repository seams; views are thin and covered by model tests +
  the app-smoke lane (the M2/M3 convention). UI regression lanes (§53) are **not** extended in M5.
- **User-owned, post-M5:** real Demucs separation time and ANE/GPU thermal behaviour during a live
  set (the AT-STEM on-device rows), and a physical route interruption mid-recording (AT-SESS-2's
  hardware half) — deferred to the device pass (§2.12).

## 7 · Definition of done (per commit, §49.4)

Tests green · acceptance IDs named in the message · no new dependency without an Appendix Q entry
(none) · no new network host (none) · mockup coverage contract satisfied (mockups `ipad/08, 09,
10, 14` already exist; `ipad/07` gains the live record control) · no `xcodegen generate` needed
for DJ-only files (§3) · `#if os` confined to `Sources/DJ/Session/` (§2.3 of the M4 plan) ·
StoreKit boundary intact · the free tier keeps everything it has (§2.4) · recordings are never
auto-evicted (§43.6) · no silent fallback — the honest `prepared / separating / unavailable → full
mix` state is explicit (FR-ENG-3, §46.2). **Ask before pushing** (push triggers CI + TestFlight).

## 8 · Session protocol

One commit per numbered task (5.1–5.6), each a fresh session reading this plan + the spec sections
the commit names. Commit on `main`, allow ~5 min for the pre-commit suite. **Ask before pushing.**
No `Co-Authored-By` trailer (owner preference).

## 9 · Implementation Audit

_To be filled in as commits land: files changed, tests run, intentional deviations._

| Commit | Status | Notes |
|---|---|---|
| Plan doc | in progress | M5 plan (Appendix M.6). Baseline recorded: `make test-swift` = **1224 tests, 0 failures** (8 skipped). Decisions: no committed `.mlpackage` (ODR seam + fake model, §2.1); stems are a source-level swap with the reader byte-identical when unstemmed (§2.3); recording tables + `stem_cache` land in `dj_v4` (§2.6); CloudKit mix-sync is M6 (§2.9); `current_status.md` moved to M5. |
| 5.1 | pending | |
| 5.2 | pending | |
| 5.3 | pending | |
| 5.4 | pending | |
| 5.5 | pending | |
| 5.6 | pending | |
