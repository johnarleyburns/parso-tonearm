# DJ Phase 5 — the milestone where it becomes a DJ app (Milestone M5)

Plan for milestone **M5** of the Platterhead iOS DJ build. Implementation is driven by this file
one commit at a time, on `main`, per handoff §8 and the working agreement in
`docs/plans/tonearm-mvp-ios/HANDOFF.md`. The plan doc is Appendix M.6's **`dj-phase-4-stems-recording.md`**
(the appendix's own filename; the milestone is M5, and its scope is now wider than that filename
suggests — see §1).

**Spec:** `docs/plans/tonearm-mvp-ios/PLATTERHEAD_IOS_ARCHITECTURE.md`. Read **§48.6 (goal/exit —
rewritten)**, **Appendix M.6 (manifest + commits — rewritten)**, and then, per commit:
**§49.3a** (reachability), **§19.4** (persisted analysis artifacts), **§26A** (waveform display),
**§41.9b / §42.7c** (club ergonomics), **§35A** (Beat FX echo), **§35B** (the five transitions),
**§18A** (genre libraries), **§41.1a** (genre picker), **§41.18** (transition coach), plus the
original scope: §4.6 (FR-REC), §35.1, §36, §37, §41.10/41.11/41.12, §41.17, §43.6, §46.2, §46.3,
§49. **Appendix M.6's commit order is authoritative; §49.2's implementation order
(schema/migrations → pure kernels → façade/actor → view model → view) is binding within each
commit.**

## 1 · Milestone goal and exit (spec §48.6 — re-scoped)

M5 was scoped as "stems, recording, gig crates" — three subsystems. It is **re-scoped as an
outcome**, because those three were on track to land without the product becoming usable. After
M4 the engine is complete and correct, and yet: nothing in the shipping app opens a performance
surface, no library track can reach a deck, and every waveform is placeholder geometry because the
analysis pipeline computes phrases and the waveform pyramid and then throws them away.

**The milestone is complete when the owner can perform this end to end, on a device:**

> Open the app → pick a genre (say **electronic → techno**) → get a library of current, legally
> usable tracks ordered by interest → build a Deck A playlist and a Deck B playlist → open the
> workspace → mix, using all five beginner transitions (Bass Swap, Filter, Echo Out, Fader Cut,
> Blend) with the controls where a club-trained hand expects them → record a 20-minute set →
> **listen to it immediately, in the app** → share it with a friend as a file that plays.

**Exit (§48.6):**

1. **AT-STEM-\*** and **AT-REC-\*** green; a recording survives forced termination losing at most
   the final segment (NFR-REL-2).
2. **AT-WAVE-\*** green — waveforms render from persisted analysis, not placeholders.
3. **AT-TRANS-1..5** green — each transition asserted in the offline render *and* as a layout
   assertion on both surfaces.
4. **AT-GENRE-\*** green — a genre subscribes, caches, analyses, reaches a deck, with no account.
5. **AT-MIX-1..8 green** — `make test-ui-regression LANES=djmix`, the narrative above driven
   through the real UI and proved in the recorded artifact (§53.7–53.12, commit 5.14), including
   one `MIX_MINUTES=20` soak. This is the machine-checkable form of step 6 and the difference
   between "every part was tested" and "the thing works".
6. **The narrative above, performed on a device by the owner** — one 20-minute recorded set using
   all five transitions, played back in-app, exported and played elsewhere. **User-owned shipping
   gate**, run in the post-M5 device pass alongside M4's deferred AT-THERM-1 / AT-MEM-1.

`make test-swift` green; app builds; `xcodegen generate` **is** needed this milestone (5.1 and 5.6
touch app-target and `Sources/Domain`/`Sources/Remote` files — see decision 25).

## 2 · Resolved decisions (recorded up front)

Decisions 1–14 were recorded when M5 was scoped as stems + recording, and **still stand**.
Decisions 15–24 are new with the re-scope.

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
    ordinary playable assets in the DJ `MixesView` from the moment they finalize. *(Amended by
    decision 15 — M5 now adds the app-side entry point, so this is no longer deferred to the 3.0
    ship.)*
11. **Storage budget is a new service** (§43.6): `StorageBudgetService` owns the per-cache disk
    accounting with **`mixesEvictable = false` always** (recordings are user content and are never
    auto-evicted — the app asks, never chooses, §43.6) and **stem LRU by `gig_crate.lastPerformedAt`**,
    always showing what will be evicted *before* evicting it (FR-ANL-9, mockup `ipad/14`). This is
    distinct from M4's `MemoryCeiling` (RAM, NFR-REL-4); `StorageBudgetService` is disk.
12. **The on-device numbers are user-owned and deferred to a post-M5 pass.** Real Demucs
    separation time, ANE/GPU thermal behaviour during a live set, and the physical route
    interruption during a recording run on a device with the real model (§12).
13. **~~No new network host, no new dependency.~~ Amended by decision 20** — M5 adds exactly one
    new host (the Jamendo API), authorised by the owner under handoff §9. Still **no new
    dependency**: CoreML / Accelerate / AVFoundation / Metal are already linked.
14. **The mixer column's record button lives in the workspace** (§41.9's centre column).
    `WorkspaceModel` gains the recording state (`isRecording`, `elapsed`), the record toggle
    forwards `startRecording/stopRecording`, and the record/elapsed chip is shared across every
    performance surface — it is session VM state, not a view's.

**New with the re-scope:**

15. **Reachability is commit 5.1, not a follow-up (§49.3a).** Verified on `main` at M4 exit: no
    file outside `Sources/DJ/` references `CompactPerformanceView`, `WorkspaceView`,
    `SoloDeckView`, `TwinDeckView` or `TrackPrepView`; the only app-side `import TonearmDJ` is
    `Sources/Features/Ingest/AnalysisView.swift` + `AnalysisModel.swift`; `RootView.swift` has no
    DJ route; and no app-side file references `ProCapability`. The whole DJ feature set is dead
    code in the shipped binary. 5.1 adds a real navigable route, Pro-gated via
    `ProCapability.isEnabled(.decks)` with the §40.4 dimmed-surface treatment for free users.
16. **The library → deck seam is also 5.1.** `WorkspaceModel` holds no reference to
    `DJLibraryStore`, `DJTrack`, or any asset resolver — verified. `WorkspaceEngine.load(_:source:)`
    takes a `DeckSource` (raw PCM) and nothing constructs one from a library row. A new
    `DeckLoader` owns: resolve track → **enforce the FR-LIB-8 fully-cached gate** → decode to
    `DeckSource` off the main actor → hand over with the §12.2 ownership transfer. The crate sheet
    deferred in 4.7 ("the workspace has no library data seam yet") gets its real rows here.
17. **Analysis persistence is a standalone commit (5.2) and precedes any render work.**
    `AnalyzePipeline.AnalyzeResult` currently carries `phraseCount: Int` and `waveformLevels: Int`
    — the `[Phrase]` array and `WaveformPyramid` are computed at `AnalysisCoordinator.swift:123`
    and `:132` and dropped. `persist` writes loudness, `beat_grid`, `key_estimate`, the `track`
    rollup and `analysis_run`, and **nothing** to `phrase`, `waveform_pyramid` or `downbeat`;
    `beat_grid` is written with `firstBeatSample: 0, beatCount: 0` hardcoded. 5.2 widens the result
    type and the transaction per §19.4. **Re-analysis of existing libraries is required** to
    backfill — surfaced as an ordinary re-analysis prompt, not a silent migration.
18. **The waveform renderer is pure-input, `Canvas`-based, and not Metal in M5.** §26A.1's
    `WaveformRenderModel` is assembled control-side from memory-mapped BLOB slices; the renderer
    is a SwiftUI `Canvas` drawing from that value. Metal is the escape hatch **only if** the §43.3
    budget measurement (5.3's own test, and the §50.3 device row) says `Canvas` cannot hold two
    detail waveforms plus two jogs. Choosing Metal up front would be speculative; choosing it
    after a measurement is engineering.
19. **The §41.9b relayout updates shipped geometry tests rather than deleting them.**
    `WorkspaceModelTests`' column-budget assertions and `ModuleGeometry.jogModuleWidth` are written
    against `1fr 268px 1fr`. 5.4 rewrites them against `1fr 320px 1fr` and the ~416 pt deck column,
    keeping every assertion — the budget is still asserted, against new numbers. Deleting a
    geometry test to make a relayout pass is the failure mode to avoid.
20. **The music source is the Jamendo API, not the Free Music Archive.** FMA's app-developers page
    states they shut down their API and prohibits both hotlinked playback and scraped browsing —
    the two things this feature needs. Jamendo publishes a documented read API over a CC catalogue
    with genre/tag filtering and popularity ordering, which is exactly FR-LIB-9's shape.
    **Endpoint shapes, parameter names and paging MUST be verified against
    `developer.jamendo.com/v3.0` at implementation time**, not assumed from the spec.
    Owner-authorised under handoff §9 as a new network host.
21. **`client_id` is an application credential and a user-owned registration step.** It is not a
    user login (FR-LIB-9's "no account" holds). It goes on the user-owned checklist beside the
    Plex claim token and the App Store Connect products. Until it exists, the provider's tests run
    against **recorded fixtures** (Appendix R convention) — no live network in CI, per the standing
    rule. `.test-credentials` carries the real value and is never committed.
22. **The export format is AAC in M4A; MP3 is deferred to M6** (§37.6, FR-REC-7). The platform
    ships no system MP3 *encoder*; producing `.mp3` requires vendoring LAME — a new dependency and
    an LGPL review. Owner-decided. The UI names the format it produces and never promises MP3.
23. **Beat FX ships exactly one effect.** The §35A post-fader beat-synced echo, because it is the
    one the five transitions require. The FX module's other pads stay honestly unavailable (§36.5's
    convention) rather than shipping a filter-sweep pad that duplicates the CFX knob. More Beat FX
    are M6.
24. **AT-TRANS-\* has two halves and both are automated.** The audio half is a scripted command
    sequence against the M4 offline render with buffer assertions. The **layout half** is a model
    -level assertion that every control a transition needs is present, ≥ 44 pt, and un-occluded on
    both the tablet and compact surfaces — the same technique as 4.10's `drawerXRange` vs
    `mixerXRange` non-intersection test. Neither half needs a device.
25. **`xcodegen generate` is required this milestone, in commits 5.1 and 5.6 only.** The handoff's
    "DJ-only files need no regen" trap holds for everything under `Sources/DJ/**` (the app target
    excludes it). It does **not** hold for 5.1's app-side entry point under `Sources/Features/`,
    or 5.6's edits to `Sources/Domain/Entities.swift` and
    `Sources/Remote/Providers/JamendoGenreProvider.swift`. Both commits run `xcodegen generate`
    and commit the regenerated project. Every other commit (5.2–5.5, 5.7–5.13) is DJ-only and
    needs no regen. **5.14 DOES need one.** The "directory `sources` entry means no regen" intuition
    is wrong for Xcode targets: XcodeGen enumerates the directory at *generation* time and writes
    explicit file references into `project.pbxproj` (verified — the existing regression lane files
    each appear there individually). The no-regen shortcut holds only for `Sources/DJ/**`, which is
    an SPM target that globs at build time. New `UIRegressionTests/*.swift` files are invisible to
    `xcodebuild` until `xcodegen generate` runs.
26. **The app has no real-time audio pump, and that is commit 5.4a.** `AudioGraph` enables manual
    `.offline` rendering unconditionally and only unit tests call `render()`, so the shipped app
    dispatches commands into a graph nobody pulls: **PLAY makes no sound and advances no clock.**
    Found while designing the regression suite. It is not a regression in anything committed — 5.1
    delivered reachability of the *surface* — but it sits underneath the entire exit gate. Lettered
    `5.4a` rather than renumbered so the recorded 5.5–5.13 sequence in Appendix M.6 and the audit
    table stay stable. **One render-closure body, two drivers**; the `.offline` path is preserved
    exactly so every existing acceptance test keeps its meaning.
27. **Accessibility identifiers are a product contract, not test scaffolding**, and they land in
    5.4 with the controls. VoiceOver needs them (NFR-A11Y) and the regression suite is unwritable
    without them. Retrofitting identifiers in 5.14 would mean touching every performance view in a
    commit that is supposed to be tests only.
28. **The regression oracle is the recorded artifact, not the UI.** `XCUITest` cannot hear;
    asserting on UI state reproduces the D-10 false green. The suite pulls the exported M4A off the
    simulator and proves the transitions acoustically, on the host (§53.8). Engine telemetry via
    accessibility corroborates and drives gesture timing, but is never the sole evidence.
29. **The gating lane uses synthetic tone-identity fixtures, not Jamendo tracks.** Real music makes
    every transition assertion mush — both decks have broadband low end and "did the bass swap?"
    has no crisp answer. Per-deck tones in each EQ band make band energy *attributable to a deck*
    (§53.8). The live-Jamendo lane exists too, with weaker assertions, and **informs rather than
    gates** — it depends on a third party (§53.12).
30. **Assertions are ratio-based and bar-tolerant, never sample-exact.** Sample precision is layer
    1's job against the deterministic offline render. Layer 3 runs in real time on a simulator that
    can underrun; demanding precision there produces a suite that is red for reasons nobody can fix,
    which §53.4 exists to prevent (§53.10).

## 3 · File manifest (Appendix M.6, paths indicative per handoff §6.4)

New directories: `Sources/DJ/Features/Waveform/`, `Sources/DJ/Features/Onboarding/`,
`Sources/DJ/Features/Coach/`, `Sources/DJ/Stems/`, `Sources/DJ/Recording/`. Tests under
`Tests/DJTests/`.

**Files outside `Sources/DJ/` — these need `xcodegen generate`** (decision 25): the app-side entry point
under `Sources/Features/`, `Sources/Domain/Entities.swift` (`SourceKind`), and
`Sources/Remote/Providers/JamendoGenreProvider.swift`.

**Commit 5.14 adds files outside both** — `UIRegressionTests/`, `scripts/ui-regression/`,
`docker-compose.ui-regression.yml`, `.test-credentials.example`, `Makefile`, `.gitignore` — and
**does** need `xcodegen generate`, because XcodeGen writes explicit file references for Xcode
targets (decision 25). Its manifest is in [`dj-regression-suite.md`](dj-regression-suite.md) §10.1.

| File | Purpose |
|---|---|
| `Sources/Features/…` (edit) | **DJ entry point** — navigable route from the app root, Pro-gated (§49.3a, decision 15) |
| `Sources/DJ/Features/Workspace/DeckLoader.swift` | library row → cached-audio gate → decode → `DeckSource` (decision 16) |
| `Sources/DJ/Analysis/AnalysisCoordinator.swift` (edit) | persist phrases, downbeats, real beat grid + `beat_blob`, band-split pyramid (§19.4) |
| `Sources/DJ/Data/WaveformRepository.swift` | read side — pyramid slice + grid + phrases + cues → `WaveformRenderModel` (§26A.1) |
| `Sources/DJ/Features/Waveform/WaveformRenderer.swift` | frequency-coloured, beat-gridded `Canvas`; level selection + thermal degradation (§26A.2/.7) |
| `Sources/DJ/Features/Waveform/PhraseRibbon.swift` | labelled spans, bar counts, low-confidence marking (§26A.4) |
| `Sources/DJ/Features/Waveform/OverviewStrip.swift` | full-track overview + position cursor (§26A.5 view 1) |
| `Sources/DJ/Engine/BeatEcho.swift` | pure post-fader beat-synced delay kernel (§35A.2) |
| `Sources/DJ/Engine/RTCommand.swift` (edit) | `setEcho*` tags; `armStemSet` / `setStemGain` / `setStemMute` / `setStemSolo` |
| `Sources/Domain/Entities.swift` (edit) | `SourceKind.jamendoGenre` (§18A.3) |
| `Sources/Remote/Providers/JamendoGenreProvider.swift` | genre listing, popularity ordering, licence passthrough (§18A) |
| `Sources/DJ/Features/Onboarding/GenrePickerView.swift` + model | mockup `ipad/15-genre-picker.html` (§41.1a) |
| `Sources/DJ/Features/Coach/TransitionCoachView.swift` + model | mockup `ipad/16-transitions.html` (§41.18) |
| `Sources/DJ/Stems/{StemModel,StemSeparator,StemCache,StemService}.swift` | §36 pipeline, seam + fake model (decisions 1–2, 5) |
| `Sources/DJ/Engine/StemVoices.swift` | `StemSet` pure value; reader-side summing (§35.1, decision 3) |
| `Sources/DJ/Recording/{RecordTap,Encoder,RecordingService,MixTimeline}.swift` | §37 pipeline (decisions 7–8) |
| `Sources/DJ/Data/DJMigrations+v4.swift` | §15.5 DDL verbatim + `stem_cache` (decision 6) |
| `Sources/DJ/Data/GigCrateRepository.swift` | promotion, readiness, budget + LRU queries |
| `Sources/DJ/Perf/StorageBudgetService.swift` | pure disk-budget + LRU accounting, mixes never evicted (§43.6) |
| `Sources/DJ/Features/{Stems,GigCrate,Recording,Mixes}/…` + models | mockups `ipad/08, 14, 09, 10` |
| `Sources/DJ/Features/Workspace/*` (edit) | §41.9b relayout, §42.7c compact, live stem faders, record toggle |
| `Tests/DJTests/{WaveformPersistenceTests,WaveformRenderTests,DeckLoaderTests,BeatEchoTests,TransitionTests,GenreLibraryTests,StemSeparatorTests,StemCacheTests,StemServiceTests,RecordingRecoveryTests,StorageBudgetTests,GigCrateTests,MixTimelineTests}.swift` | the §9 audit rows |

## 4 · Data layer — one new migration (`dj_v4`)

`DJMigrations+v4.swift` (append-only; no existing table changes, the M1–M3 convention):

- `stem_cache` — `(trackID, modelVersion)` unique key, `bytes`, per-stem relative paths, `createdAt`.
- `performance_session`, `mix`, `mix_track_event`, `mix_asset` — §15.5 DDL **verbatim**
  (`mix.localState` default `complete`, `syncPolicy` default `localOnly`; `mix_asset` PK is
  `mixID`; `mix_track_event` carries the title/artist snapshot so it survives track deletion).
- `DJSchema.migrationOrder` gains `"dj_v4"`.

`gig_crate`/`gig_crate_track` already exist in `dj_v1` (§14.3) — M5 only *uses* them.
`phrase`, `downbeat`, `waveform_pyramid`, `beat_blob` and `energy_curve` **already exist** in
`dj_v2` and need no migration — 5.2 simply starts writing them (decision 17).

## 5 · Commit sequence (Appendix M.6)

**5.1–5.3 are the unblockers.** Until they land, no other commit in this milestone can be verified
against a real track, which is why they come first despite the original scope's ordering.

### Commit 5.1 — reachability + the deck load seam

- App-side **DJ entry point**: a navigable route from `RootView` to the performance surface,
  Pro-gated via `ProCapability.isEnabled(.decks)` with §40.4's real-dimmed-surface + lock-chip
  treatment for free users. `xcodegen generate` **required** and committed.
- `Features/Workspace/DeckLoader.swift`: resolve a library track → **FR-LIB-8 fully-cached gate**
  (a partially cached remote track is never deck-ready and says so) → decode off the main actor →
  `DeckSource` handed over per §12.2. `WorkspaceModel` gains the loader seam and the crate-sheet
  rows deferred in 4.7 become real.
- **Per-deck queues (§41.9c, FR-ENG-13)** — the mechanism behind the milestone's "Deck A playlist
  and Deck B playlist". **No new entity:** a deck's queue is an ordinary `playlist` /
  `smart_crate` / `gig_crate` row, and a genre library is browsable as a list directly. Each
  deck's browse surface gains a **source picker at its head**, and the two decks may point at
  **different** playlists at once. Loading is one gesture through `DeckLoader`. §28A.2's
  transition ranking re-orders *within* the selected playlist — it advises, never picks, never
  auto-advances. **There is no auto-play-next on a deck.**
- Tests: `DeckLoaderTests` — the cached gate refuses an incomplete asset, a decode failure is an
  honest state not a crash, ownership transfer releases the box; a navigation test asserting the
  performance surface is reachable from the app root (the §49.3a invariant, as a test); **per-deck
  queue independence** — setting deck A's playlist leaves deck B's untouched, and neither ever
  advances on its own.
- **§49.3a, §41.9c, FR-LIB-8, FR-ENG-9, FR-ENG-13.**

### Commit 5.2 — analysis persistence (§19.4)

- Widen `AnalyzePipeline.AnalyzeResult` to carry `[Phrase]`, `WaveformPyramid`, the beat sample
  positions and the downbeat indices. Extend `AnalysisCoordinator.persist` to write `phrase`,
  `downbeat`, `waveform_pyramid`, `beat_blob` and `energy_curve`, and to write **real**
  `beat_grid.firstBeatSample` / `beatCount` — in the one existing transaction (NFR-REL-1).
- `DJLibraryStore` gains the §11-specified `savePhrases(_:for:)` and the sibling artifact writers
  (never implemented through M4), plus the read accessors `WaveformRepository` needs.
- Re-analysis backfills existing libraries; surfaced as an ordinary re-analysis prompt.
- Tests: `WaveformPersistenceTests` — **AT-WAVE-1**: analyse a synthetic track, re-read, assert
  all five artifacts present with real values; `beat_grid` never carries placeholder zeros;
  re-analysis is idempotent per version; `grid_correction` still overrides without mutating the
  immutable rows.
- **FR-WAVE-1, §19.4, AT-WAVE-1; invariant §49.3 rule 9.**

### Commit 5.3 — the waveform render (§26A)

- `Data/WaveformRepository.swift` → `WaveformRenderModel` (§26A.1): pyramid-level selection,
  grid composed with `grid_correction`, phrase spans, cues, active loop, playhead.
- `Features/Waveform/`: `WaveformRenderer` (band-split colour per §26A.2 — **the same 200 Hz /
  2 kHz crossovers as the EQ**, beat ticks with heavy downbeats + bar numbers per §26A.3),
  `PhraseRibbon` (§26A.4 — labels, **bar counts not seconds**, dashed low-confidence edges),
  `OverviewStrip` (§26A.5 view 1). Stacked twin waveforms share **one** playhead (§26A.5).
- Honest empty state for an unanalysed track — never synthetic geometry (§26A.1).
- Thermal degradation: one pyramid level coarser at `.serious`, halved label density (§26A.7).
- Wire into `TrackPrepView`, `WorkspaceView`, `SoloDeckView`, `TwinDeckView`, replacing the
  placeholder strips left in 4.7/4.9.
- Tests: `WaveformRenderTests` — **AT-WAVE-2..7**: band colour split for synthesised bass/mid/treble
  signals; grid positions match what the engine quantises to; ribbon spans equal persisted rows;
  low-confidence marked not hidden; empty state for unanalysed; markers land on sample positions at
  every zoom; level selection picks the coarsest ≤ 1 px/bin and steps coarser at `.serious`.
- **FR-WAVE-1..7, §26A, AT-WAVE-\*.**

### Commit 5.4 — club-standard control ergonomics (§41.9b, §42.7c)

- `WorkspaceView` relayout to the §41.9b arrangement: **per-channel vertical strips**
  (TRIM → HI → MID → LOW → FILTER above a vertical channel fader and a CUE button), crossfader
  horizontal bottom-centre, **CUE left of PLAY** at each deck's inner base, jog centred with the
  **tempo fader on the outer edge**, **eight** performance pads under a `HOT CUE · PAD FX ·
  BEAT JUMP · SAMPLER` mode selector. Mixer column 268 → **320 pt**; deck column → ~416 pt.
- `TwinDeckView` / `SoloDeckView`: the §42.7c compact adaptation — the transferable core stays
  always-visible (crossfader, channel faders, edge filters, CUE-left-of-PLAY, jog), EQ moves into
  the momentary bank drawer, ECHO gets an always-visible button + release-to-commit flyout.
- **Geometry tests updated, not deleted** (decision 19): the `1fr 320px 1fr` budget, the new deck
  column decomposition, `jogModuleWidth` against 416, and the §42.7a compact budget re-asserted.
- Mockup `ipad/07-dj-workspace.html` is already revised to this layout and is the reference.
- **Accessibility identifiers on every performance control**, to the §53.11 convention:
  `dj.deck.<a|b>.<play|cue|filter|fader>`, `dj.deck.<a|b>.eq.<low|mid|high>`,
  `dj.mixer.crossfader`, `dj.fx.echo`, plus `dj.master.bar` exposing `bar:beat`. These are part of
  each control's contract, not test scaffolding — VoiceOver needs them and so does the DJ
  regression suite, which cannot be written without them (decision 27).
- **FR-TRANS-1/2, §41.9b, §42.7c; NFR-A11Y-6 (no target shrunk to fit).**

### Commit 5.4a — the real-time render pump (§53.11)

**A prerequisite discovered while designing the regression suite, not new scope.** Through 5.2,
`AudioGraph.init` enables manual `.offline` rendering *unconditionally*
(`Sources/DJ/Engine/AudioGraph.swift:199`), and the only callers of `render()` are unit tests. The
app builds a real engine (`DJEntryModel.swift:58`) and its commands reach the ring — but **nothing
pulls the graph, so pressing PLAY advances no clock and emits no audio.** Every M4/M5 acceptance
test is honest about running offline; this is the gap underneath them.

- `AudioGraph.Configuration` gains a `rendering` mode: `.offline` (today's behaviour, unchanged,
  still the test default) and `.realtime`.
- `.realtime` skips manual rendering and connects the existing source nodes through
  `mainMixerNode → outputNode`; the master clock advances inside the render callback instead of in
  `render(_:)`.
- **One render-closure body, two drivers.** The closures are not duplicated — if the realtime path
  grows its own copy, every layer-1 offline test stops proving anything about what ships.
- `AudioSessionCoordinator` is entered before the engine starts, in the §34A.2 normative order.
- Acceptance: **the existing suite stays green unchanged, and the app makes sound.** A topology
  switch, not a rewrite — do not let this commit expand.

### Commit 5.5 — Beat FX echo + the five transitions (§35A, §35B)

- `Engine/BeatEcho.swift` (pure, §35A.2): fixed-capacity ring allocated at graph construction,
  delay time derived from the master clock (`beats × 60/BPM × sampleRate`), **read-pointer
  crossfade on beat-length change** (a pointer jump clicks), feedback hard-clamped below unity,
  and `enabled = false` **continues reading the tail** until it decays then bypasses at zero cost.
- Graph placement is **post-fader, pre-crossfader, per channel** (§35A.1) — this is the whole
  design; a pre-fader echo dies with the fader and Echo Out collapses into Fader Cut.
- `RTCommand` gains `setEchoEnabled` / `setEchoBeats` / `setEchoDepth` / `setEchoFeedback`;
  `PerformanceEngine` façade methods; the mixer column's Beat FX block and the compact ECHO button.
- Tests: `BeatEchoTests` (pure — delay length against BPM, crossfade on change produces no
  discontinuity, feedback always decays, tail-then-bypass) and `TransitionTests` —
  **AT-TRANS-1..5**, each in both halves per decision 24: the offline-render audio assertion *and*
  the layout assertion on both surfaces.
- **FR-TRANS-3/4/5, §35A, §35B, AT-TRANS-1..5.**

### Commit 5.6 — genre libraries (§18A, §41.1a)

- `SourceKind.jamendoGenre` (`Sources/Domain`); `JamendoGenreProvider` behind the existing
  `RemoteLibraryProvider` seam, registered in `RemoteConnectorCatalog`; genre → `Source` identity,
  popularity-descending ordering stored as source configuration, licence carried to the track row.
- **Free tier** — the provider joins the free-tier registry (FR-LIB-7, AT-FREE-\*).
- `GenrePickerView` + model (mockup `ipad/15`): top-level genres, sub-genres, multi-select,
  **skip equally weighted**, optional-credentials checkbox collapsed and gating nothing.
- Failure honesty per §18A.6 — an unreachable catalogue says so; it never renders as an empty library.
- Tests: `GenreLibraryTests` — **AT-GENRE-\***, against **recorded fixtures** (decision 21), no
  live network in CI. Genre → source identity, sub-genres are distinct libraries, ordering,
  no-account path, licence passthrough, FR-LIB-8 gate, failure surfacing, free-tier registry.
- `xcodegen generate` **required** (touches `Sources/Domain` + `Sources/Remote`).
- **FR-LIB-9/10, §18A, §41.1a, AT-GENRE-\*.**

### Commit 5.7 — Demucs ODR + separation + cache + version stamp

*(unchanged from the original plan — decisions 1, 5)* `ModelTag.stems` + `StemModelProviding` +
deterministic fake model; `StemSeparator` chunk/overlap-add (pure, vDSP); `StemCache`
content-addressed under `<contentHash>/<AnalysisVersions.stems>/`; `stem_cache` row in one
transaction. Tests: `StemSeparatorTests` (reconstruction golden across chunk boundaries),
`StemCacheTests` (content-addressing, version invalidation, eviction). **FR-ENG-3, §36.**

### Commit 5.8 — stem voices live on decks, honest disabled state

*(unchanged — decisions 3, 4)* `StemSet` armed as a second slot on `DeckState`; reader sums four
voices at the shared playhead with smoothed gains; **a deck with no stem set is byte-for-byte the
current reader**. `WorkspaceModel` per-deck stem state with the honest
`prepared / separating / unavailable → full mix` status; `DeckModuleSlot` and the compact
`BankDrawer` STEMS faders become live when prepared. Tests: frame-exact summing, bit-identical
fallback, honest state machine. **FR-ENG-3, §35.1, §36.5, AT-STEM-\* (engine rows).**

### Commit 5.9 — gig crates: promotion, budgeted separation, LRU eviction

*(unchanged — decision 11)* `GigCrateRepository` promotion from a playlist with per-track
readiness; `StorageBudgetService` (pure) budget + **LRU by `lastPerformedAt`**, eviction preview
before any eviction, **mixes never evictable**; `StemService` crate-scoped queue with the
performing fence and thermal abandon; `GigCrateView` (mockup `ipad/14`). Tests: `GigCrateTests`,
`StorageBudgetTests`, `StemServiceTests`. **FR-PLIST-9, FR-ANL-9, FR-LIB-8.**

### Commit 5.10 — record tap + encoder + segmented file

*(unchanged — decision 7)* `RecordTap` RT-safe post-limiter copy into a pre-allocated ring under
`RTGuard`; `Encoder` actor drains off-RT through `AVAudioConverter` (AAC 256 kbps) into a
segmented M4A with periodic flush; `AudioGraph.Configuration.recordTapEnabled` default false keeps
the reader harness bit-exact; `PerformanceEngine.startRecording/stopRecording` + the workspace
record toggle (decision 14). Tests: tap → drain → finalize matches the rendered master buffer;
tap idle leaves the reader bit-exact; the ring absorbs a dropped drain. **FR-ENG-7, §37.2.**

### Commit 5.11 — journal + crash/interruption recovery + finalize

*(unchanged)* `RecordingService` journal (`localState = 'recording'`), periodic segment flush,
`reconcile()` on launch finalizing stale rows — **a crash loses at most the final segment**
(NFR-REL-2). Interruption rides the §34A.4 session path (flush, wait, new segment; never auto-play).
`finalize()` writes `mix`/`mix_asset`. Tests: `RecordingRecoveryTests`. **FR-REC-1/3, FR-ENG-8.**

### Commit 5.12 — Finish + Mixes + timeline + export + the review listen

- `MixTimeline` (§37.4) control-side event log → `mix_track_event` (decision 8).
- `RecordingFinishView` (mockup `ipad/09`): title/notes, timeline, export to Files / share sheet
  with the optional cue-sheet (FR-REC-4).
- **The review listen (FR-REC-6)** — the finished mix is **playable in place, on this screen, the
  moment it finalises**: transport, seekable waveform, transition markers to jump to. No export
  step, no re-encode, no hunting in Mixes. This closes the loop the milestone narrative depends on.
- **Attribution (§18A.5)** — genre-library tracks contribute artist + licence to the finish screen
  and the exported cue-sheet, included in the share by default.
- **Format honesty (FR-REC-7)** — the screen names M4A/AAC and never implies MP3 (decision 22).
- `MixesView` (mockup `ipad/10`), local storage, FR-REC-5.
- **FR-REC-1/4/5/6/7, §37.4, §41.11, §41.12, AT-REC-\*.**

### Commit 5.13 — the transition coach

`TransitionCoachView` + model (mockup `ipad/16`): the §35B five, each with description, when to
use it, and **highlighting of the real controls in place**. Non-modal, decks keep playing, **no
auto-mix affordance anywhere**, free tier. Tests: model-level — the control set each transition
names matches §35B's table, and the panel changes no engine state (the 4.10 drawer precedent).
**FR-TRANS-6, §41.18.**

### Commit 5.14 — the DJ regression suite (§53.7–53.12)

**Full coder brief: [`dj-regression-suite.md`](dj-regression-suite.md).** That document is
normative for this commit; what follows is the summary.

The M5 exit narrative driven through the real UI and asserted against **the recording the app
produces** — because `XCUITest` cannot hear, and a lane that asserts "the deck row says Playing" is
the D-10 false green exactly (§53.5, §53.8).

- `UIRegressionTests/DJPerformanceDriver.swift` — the gesture driver: bar-aware waits polling
  `dj.master.bar`, knob/fader drags, the shared launch configuration.
- `UIRegressionTests/DJMixRegressionUITests.swift` — `AT-MIX-1..8`, the five transitions performed
  **inside one continuous recording**.
- `UIRegressionTests/DJLiveMixRegressionUITests.swift` — `AT-MIX-9..10` against live Jamendo,
  deliberately weaker assertions; skips when the API or the `client_id` is absent.
- `scripts/ui-regression/make-dj-fixture-media.py` — the §53.8 tone-identity fixtures (deck A
  55/611/5300 Hz, deck B 87/1290/8900 Hz, 122.000 BPM, 16-bar phrases). This is what makes
  "did the bass swap?" a question with a crisp answer.
- `scripts/ui-regression/verify-mix.py` — the **host-side** analyzer: §53.9 signatures
  cross-checked against the exported `mix-journal.json`.
- `scripts/ui-regression/jamendo-mock/` + a compose service; `LANES=djmix|djlive` in the runner;
  `[jamendo]` in `.test-credentials.example` (**key name only**).
- Scaffold every lane with its acceptance ID and an `XCTSkip("TODO(AT-MIX-n)")` body, exactly as
  §53.6 staged the original suite — "the lane is green" is what closes the ID.
- **Same target and scheme**, so "never in CI, never in a hook" stays structural (§53.2).

## 6 · Testing strategy (spec §47, Appendix R)

- **Pure kernels:** `BeatEcho` (delay maths, crossfade continuity, decay), `PhraseRibbon` span
  maths, pyramid-level selection, `StemSeparator` overlap-add, `StemCache` versioning,
  `StorageBudgetService` LRU, `MixTimeline` ordering, `RecordingService` recovery state machine —
  deterministic, no device.
- **Persistence:** `WaveformPersistenceTests` round-trips every §19.4 artifact through a temp pool.
- **Engine (integration, deterministic):** the M4 offline harness — stem-set summing frame-exact,
  full-mix fallback bit-identical, record-tap → drain → M4A read-back, and **AT-TRANS-1..5's audio
  half** as scripted command sequences with buffer assertions.
- **Layout:** AT-TRANS's layout half plus the §41.9b/§42.7c geometry budgets, as pure model
  assertions (the 4.10 `drawerXRange` precedent). No snapshot testing, no device.
- **Remote:** `GenreLibraryTests` against **recorded fixtures** — no live network in CI (decision 21).
- **View models:** fake engine/repository seams throughout; views stay thin.
- **UI regression (§53.7–53.12, by hand, never CI):** the **DJ lanes are added in M5** — commit
  5.14, `AT-MIX-1..10`. This reverses this plan's original "UI regression lanes are not extended in
  M5": that line was written before the reachability audit, and the milestone whose whole point is
  that the parts finally come together is exactly the one that needs an end-to-end guard.
  See [`dj-regression-suite.md`](dj-regression-suite.md).
- **User-owned, post-M5:** real Demucs timing and ANE/GPU thermals during a live set; a physical
  route interruption mid-recording; the §50.3 device rows (two coloured waveforms + two jogs inside
  the §43.3 budget; the club-controller transfer test with three trained users); the catalogue
  depth check; and **the milestone's own end-to-end narrative** (§1 exit row 5).

## 7 · Definition of done (per commit, §49.4)

Tests green · acceptance IDs named in the message · **no new dependency** (still none — decision 22
keeps MP3 out) · **one new network host, owner-authorised** (decision 20; already recorded in the
spec at **Appendix Q.1a** with the FMA rejection, the CC attribution obligation and the
fixtures-not-live-network rule) · mockup coverage contract satisfied (`ipad/15`, `ipad/16` created;
`ipad/07` and `ipad/09` revised; §40.5/40.6 inventory updated) · `xcodegen generate` committed for
5.1 and 5.6 (decision 25) · `#if os` confined to `Sources/DJ/Session/` · StoreKit boundary intact · the
free tier keeps everything it has, and gains the genre connector and the coach · recordings never
auto-evicted (§43.6) · **no silent fallback and no compute-then-discard** (§46.2, §49.3 rules 9–10) ·
**the DJ regression suite is never wired into CI, `make test-swift`, or a git hook** (§53.2 — it now
additionally needs a real-time audio device and up to 20 minutes, so the temptation to "just add it to
the nightly" is stronger and the answer is still no) · **no credential outside `.test-credentials`**,
the Jamendo `client_id` included · **no third-party audio committed**, CC included (§54.6).
**Ask before pushing** (push triggers CI + TestFlight).

## 8 · Session protocol

One commit per numbered task (5.1–5.13, plus **5.4a** and **5.14**), each a fresh session reading
this plan + the spec sections the commit names. Commit on `main`, allow ~5 min for the pre-commit suite. **Ask before pushing.**
No `Co-Authored-By` trailer (owner preference).

## 9 · Implementation Audit

_To be filled in as commits land: files changed, tests run, intentional deviations._

| Commit | Status | Notes |
|---|---|---|
| Plan doc | in progress | M5 plan (Appendix M.6), **re-scoped** per §48.6. Baseline: `make test-swift` = **1224 tests, 0 failures** (8 skipped). New decisions 15–24: reachability + deck seam are 5.1 (§49.3a); analysis persistence is 5.2 (§19.4); `Canvas` renderer with Metal as a measured escape hatch; geometry tests updated not deleted; **Jamendo not FMA** (FMA API shut down + terms prohibit the use case); `client_id` is user-owned; **AAC not MP3** (no system encoder); one Beat FX; AT-TRANS has an audio half and a layout half. |
| 5.1 | complete (`69814f6`) | reachability + deck load seam. `.dj` tab from the app root to the performance surface, Pro-gated (`ProCapability.isEnabled(.decks)`, §40.4 dimmed + lock chip); the §49.3a route table is `DJEntryModel.reachableDestinations` as a test; `DeckLoader` (FR-LIB-8 gate → decode off the main actor → `DeckSourceBox`, §12.2) + the authoritative grid composed at the 48 kHz decode space; `WorkspaceModel` per-deck queues (source picker at each browse surface's head, independent decks, one-gesture load, no auto-advance) with the 4.7 crate-sheet rows real; compact crate sheet + iPad per-deck queue panel. `xcodegen generate` committed. Tests: 8 `DeckLoaderTests` + 3 `DJEntryTests` + 6 `WorkspaceModelTests` queue rows. Suite 1224 → **1241 green**; Swift 6 guard OK; smoke tests pass. |
| 5.2 | complete (`f8f9db1`) | analysis persistence (§19.4). `AnalyzeResult` widened from counts to the full render contract — `BeatGrid`, downbeat indices, `[Phrase]`, `WaveformPyramid`, `energyCurve` + hopSeconds — and `persist` writes every §19.4 destination table in the one existing transaction (NFR-REL-1). New `Data/AnalysisArtifacts.swift`: the shared SQL writers (single source of row shapes) used by both the coordinator's single-transaction persist and the `DJLibraryStore` façade — `phrase`/`downbeat` are DELETE-then-INSERT, `beat_grid`/`beat_blob`/`waveform_pyramid`/`energy_curve` are INSERT OR REPLACE, so re-analysis is idempotent per version and `grid_correction` never touches these rows (§19.4 rules 2–3). **Real** `beat_grid.firstBeatSample`/`beatCount` + mean confidence (the placeholder-zero defect is gone); per-beat `beat_blob` (new `BEAT` layout — i64 samples + f32 confidences, §15.7 kind=0x03); `downbeat` rows anchor bar numbers; the band-split pyramid BLOB is FR-WAVE-2's only source. `Phrase` gains `startSample`/`endSample` so phrase rows are the §25 spans the ribbon draws. `DJLibraryStore` gains `savePhrases` + the sibling artifact writers (the §10.1 façade, never implemented through M4) and the read accessors `WaveformRepository` needs (`phrases`/`beatGrid`/`downbeats`/`waveformPyramid`/`energyCurve`). Tests: 3 `WaveformPersistenceTests` — **AT-WAVE-1** (a real click-track WAV is analysed and re-read: all five artifacts present with values equal to the deterministic pipeline output, `beat_grid` never carries placeholder zeros), re-analysis idempotence per version, and grid corrections still override without mutating the immutable rows. DJ-only — no `xcodegen generate` (decision 25). Suite 1241 → **1244 green**; Swift 6 guard OK. |
| 5.3 | complete (`9bd2db6`) | waveform render (§26A) — band-split colour, composed grid, phrase ribbon, overview |
| 5.4 | complete (`a6d59f3`) | club ergonomics (§41.9b, §42.7c) + the §53.11 accessibility identifiers. `WorkspaceView` relaid out to the §41.9b arrangement (mockup `ipad/07` is the reference): the two decks' waveforms stack on **one shared playhead** at the top (§26A.5 view 2), and below each deck column carries the club block — **tempo fader on the outer edge** (rule 4, ±8% `ClubGeometry.tempoFaderRange`, `setTempo` → `setRate`) beside the **jog centred**, the `HOT CUE · PAD FX · BEAT JUMP · SAMPLER` **mode selector** above **eight pads** (rule 5), **CUE left of PLAY** at the inner base (rule 3); the mixer column is the two **per-channel vertical strips** (rule 1: TRIM → HI → MID → LOW → FILTER → fader → CUE, `ClubGeometry.channelStripOrder`) with the crossfader **horizontal bottom-centre** (rule 2) and the §35A Beat FX block below (rule 7, honest-unavailable until 5.5). The per-deck queue moves into a browse sheet from the deck header so the column keeps its club geometry; the module slot stays (STEMS is 5.8's surface) with slimmed content; the jog sensitivity faders ride under the pads (the mixer is now the strips). **Compact (§42.7c):** the transferable core was already always-visible; **ECHO** gets an always-visible button + `dj.fx.echo` on both compact surfaces (honest-unavailable until 5.5); EQ stays in the bank drawer. **Geometry tests updated, not deleted** (decision 19): `1fr 320px 1fr`, deck column 416, `jogModuleWidth` ≤ both the derived and the normative column. New model: `masterBarBeat` pure math for `dj.master.bar` (§53.11), tempo state. **§53.11 identifiers on every performance control** across all three surfaces (`dj.deck.<a|b>.<play|cue|filter|fader>`, `dj.deck.<a|b>.eq.<low|mid|high>`, `dj.mixer.crossfader`, `dj.fx.echo`, `dj.master.bar`). Tests: 8 new `WorkspaceModelTests` (club budget, strip order, CUE-left-of-PLAY, 8-pad geometry, tempo range + clamp + rate forwarding, echo beat set, master bar:beat math) + 4 updated geometry tests. Suite 1244 → **1262 green**; Swift 6 guard OK; app builds; smoke tests pass. No `xcodegen generate` (DJ-only, decision 25). **FR-TRANS-1/2, §41.9b, §42.7c, NFR-A11Y-6, §53.11.** |
| 5.4a | complete (`495780f`) | **real-time render pump** (§53.11, decision 26). `AudioGraph.Configuration` gains `rendering: .offline` (today's behaviour, unchanged, still the test default) / `.realtime`. `.realtime` skips manual rendering and connects the existing source nodes through `mainMixerNode → outputNode`; the **one render-closure body** runs on the device output — the direct topology already advances the master clock inside `renderDecks`; the time-pitch topology's deck-B node advances it once per callback in realtime (offline keeps the advance in `render`, unchanged). `render(_:)` refuses in realtime with a dedicated error. `DJWorkspaceAssembly.makeModel` (now async) enters the `AudioSessionCoordinator` in the §34A.2 normative order — category → preferences → activate → read back → build the graph — then builds a `.realtime` engine (128-frame maximumFrameCount, matching the §34A.1 performing buffer); `WorkspaceModel` retains the coordinator so its route/interruption marshalling survives (responses consumed in 5.10/5.11). `DJPerformanceSurface` gains an honest loading/unavailable split for the async assembly. Tests: `testRealtimeModeRefusesOfflineRender` (deterministic) + the existing suite green unchanged; app target builds; realtime pull verified on the macOS host (master clock advanced 1024 → 13312 in 0.25 s with audio on the bus — the "app makes sound" proxy). Full-suite run: 1262/1263 green, the one failure the documented `SequencerTests` environmental gate (machine clock-capped; passed on re-run at 3.33 s). DJ-only — no `xcodegen generate` (decision 25). **§53.11, decision 26.** |
| 5.5 | complete (`559b23a`) | Beat FX echo + AT-TRANS-1..5 (§35A, §35B). `Engine/BeatEcho.swift` — the pure §35A.2 control value (`BeatEcho`: enabled/beats/depth/feedback, feedback **hard-clamped at 0.85** so the tail always decays, delay math `beats × 60/BPM × sampleRate` with a nominal-tempo fallback) + the render-thread `BeatEchoLine` (fixed-capacity ring allocated at graph construction, **read-pointer crossfade on beat-length change**, `enabled = false` continues the tail until it decays below the floor then bypasses at zero cost). Graph placement is **post-fader, pre-crossfader, per channel** (§35A.1) — the whole design; a pre-fader echo dies with the fader and Echo Out collapses into Fader Cut. `RTCommand` gains `setEchoEnabled/Beats/Depth/Feedback`; `PerformanceEngine` façade methods; `DeckState` applies the control value into every channel's line and retunes the delay once per callback from the master clock's effective tempo (`applyEchoMasterBPM`). Surfaces: the mixer column's **Beat FX block is live** (channel selector + the five beat lengths + a drag depth track + the `dj.fx.echo` ON toggle), the iPad FX module slot's **ECHO pad is live**, and the compact surfaces swap the honest-unavailable `EchoButton` for `EchoReleaseToCommitButton` — a single always-visible button with a **release-to-commit flyout** for channel/beats/depth (§42.7b idiom 3, Echo Out is a two-control transition so both controls are reachable without a drawer). The flyout's frames and `releasedAction(at:)` are pure on `WorkspaceModel.EchoFlyout` — the engine is touched only on a release inside a commit target, nothing changes on the way out. Tests: 8 `BeatEchoTests` (delay vs BPM, crossfade continuity, monotonic decay, tail-then-bypass bit-exact, re-enable) + 7 `TransitionTests` (**AT-TRANS-1..5** in both halves per decision 24: the offline-render audio half — Goertzel-attributed band kills, the filter sweep, the **post-fader-cut echo tail ringing at the beat interval and decaying to silence**, the sample-accurate no-zipper sharp cut, the limiter-ceiling blend — plus the layout half asserting every transition's controls are always-visible/reachable on both surfaces, Echo Out's two controls never behind a drawer) + 4 `WorkspaceModelTests` (echo forwarding per deck, §35A clamping, flyout release resolution incl. cancel paths, flyout geometry fits the twin mixer column). Suite 1262 → **1289 green**; Swift 6 guard OK; app builds; smoke tests pass in the pre-commit hook. DJ-only — no `xcodegen generate`. **FR-TRANS-3/4/5, §35A, §35B, AT-TRANS-1..5.** |
| 5.6 | complete (`dee6a57`) | genre libraries (§18A, §41.1a). `SourceKind.jamendoGenre` (`Sources/Domain`); `JamendoGenreProvider` + `JamendoAPI` + the curated `JamendoGenreTree` behind the existing `RemoteLibraryProvider` seam, registered in `RemoteConnectorCatalog` (`jamendoGenre`, guided, no credentials). **Verified against the live API** (decision 20): Jamendo v3.0 has **no `/genres` method** — the read methods are albums/artists/autocomplete/feeds/playlists/radios/reviews/tracks/users and `GET /v3.0/genres` returns code 7 — so the hierarchy is curated here and each node filters the catalogue through `tags=` with `order=popularity_total`, `fullcount=true`, `include=musicinfo`, `audioformat=mp32`. A genre is an ordinary `Source(kind: .jamendoGenre, iaIdentifier: <path>)` row; sub-genres are distinct libraries; a track row flows through `RemoteTrackRowFactory` so FR-LIB-8/cache/analysis/decks all work with no special-casing (§18A.3/.4). Licence travels at the source level (the existing IA/built-in pattern — the schema has no per-track licence column; per-track artist/album/genre travel in each row; recorded as a deviation). `client_id` is an application credential read from Info.plist (`JamendoClientID`/`TONEARM_JAMENDO_CLIENT_ID`, added to `project.yml`); an unconfigured build is an honest `.notConfigured` state, never an empty library (§18A.6). **Free tier** — joined the free-tier registry (`remoteLibraryJamendo`). `GenrePickerModel` + `GenrePickerView` (mockup `ipad/15`): curated top-level genres with expandable sub-genres, multi-select, lazily-fetched `fullcount` counts, an equally-weighted Skip/Cancel, the collapsed gating-nothing account checkbox, and the one-line licence/attribution note. Two doors: a first-run onboarding page and the **Add source** flow (AddServerSheet presents the picker sheet). `AppState.addGenreLibrary` validates reachability before inserting. Tests: 16 `GenreLibraryTests` — **AT-GENRE-1..7** against **recorded fixtures** (decision 21: `Fixtures/jamendo/{techno,house,electronic,api-error}.json`, served by a tag-keyed URLProtocol stub, no live network): genre→source identity, sub-genre distinctness, popularity-descending ordering + request assertion, metadata/artwork/resolve, no-account request shape, unconfigured honest unavailable, licence/row passthrough, the standard-row-factory path to a deck, API-envelope + transport failure honesty, fullcount counts, free-tier registry + catalog, plus picker-model selection/add/probe/toggle tests. Suite 1289 → **1305 green**; Swift 6 guard OK; app builds (xcodebuild); smoke tests pass in the pre-commit hook. **`xcodegen generate` committed** (project.yml + `Sources/Domain` + `Sources/Remote` — decision 25; the regenerated pbxproj also carries the sitting 5.14 lane references, consistent with the documented scaffold state). **FR-LIB-9/10, §18A, §41.1a, AT-GENRE-\*, AT-FREE-\*.** |
| 5.7 | complete | Demucs ODR + separation + cache + version stamp (§36, FR-ENG-3, plan decisions 1, 5). `ModelTag.stems` + the existing `BundleResourceProvider` now carries `DemucsStems.mlpackage`; `AnalysisVersions.stems = 1`. New `Sources/DJ/Stems/` module: **`StemModel.swift`** — `StemKind`, `StemChunk` (stereo Float32 pair), the four-voice `StemSeparation`, the `StemModelProviding` seam (version / `isAvailable` / `separate(chunk:)` — absence is a value, FR-SEM-6), and the ODR `DemucsStemModel` shell that is honestly absent until the `.mlpackage` is registered and throws an explicit `conversionPending` for a present-but-unwired file (ADR-10, the owner's post-M5 step). **`StemSeparator.swift`** — the pure `StemChunking` kernel (fixed chunk 2<sup>17</sup> / 50% overlap; **periodic Hann** generated here because `vDSP_HANN_NORM` is energy-normalized and does NOT satisfy first-power COLA; exact `w[i]+w[i+hop] == 1`; vDSP multiply/accumulate) + the pipeline `separate(pcm:)` (slice → model → window → overlap-add → four full-length voices; nil when absent; empty-input / length-mismatch / mid-run-disappearance are loud). **`StemCache.swift`** — content-addressed four-`.caf` sets under `Caches/TonearmDJ/Stems/<contentHash>/<modelVersion>/`, `stem_cache` row in **one transaction** (INSERT OR REPLACE, idempotent), `load` resolves from the row's recorded relative paths and returns nil when a file is gone (row-without-files = absence, never corruption), refcount-aware `evict` (a shared content-hash directory survives while another row references it). **`DJMigrations+v4.swift`** — `stem_cache` + §15.5 recording DDL **verbatim** (decision 6), `dj_v4` registered in the migration order. Tests: 11 `StemSeparatorTests` (**the reconstruction golden across chunk boundaries** — a passthrough model reconstructs its input exactly in the interior; pipeline is bit-for-bit the pure kernel; absence → nil; wrong-length and mid-run disappearance throw) + 9 `StemCacheTests` (content-addressing incl. distinct-hash isolation, exact 9600-frame voice round-trip through the CAF files — AVAudioFile writes drop a trailing partial block, so the writer chunks into ≤ 4096-frame calls, verified on host — idempotent re-store, **version invalidation**, row-without-files, eviction incl. the shared-directory refcount) + 2 new `DJSchemaTests` (v4 tables/indexes + the composite PK). Suite 1305 → **1327 green** (8 skipped); Swift 6 guard OK; app builds (xcodebuild verified). DJ-only — no `xcodegen generate` (decision 25). **FR-ENG-3, §36.** |
| 5.8 | complete (`118320d`) | stem voices live on decks (§35.1, §36.5, FR-ENG-3, plan decisions 3–4). **Engine:** `Engine/StemVoices.swift` — the pure `StemSet` (four `DeckSource`s of one track at the shared playhead, one shared grid; `@unchecked Sendable` like `DeckSource`, §12.2). `DeckState` gains the **second armed slot** (`stemSetPointer`), per-voice smoothed gains + mute/solo state (fixed arrays, `StemKind.index`), and a pre-allocated `stemScratch` so the render thread never allocates (§12.3). `RTCommand` gains `armStemSet` / `setStemGain` / `setStemMute` / `setStemSolo`; `PerformanceEngine` façade + `StemSetRegistry` (ownership-transfer boxes like `SourceBoxRegistry`). `renderDeck` branches: a deck with **no** stem set is byte-for-byte the current reader (`readChunk`); an armed set sums the four voices through `readStemChunk` (per-voice one-pole gains advance once per sample shared across channels, then the EQ/filter/fader/echo/crossfader chain runs **once** over the sum — §35.1). `referenceSource()`/`referenceGrid()` fall back to the stem set, so the master clock, sync and echo read the armed set's grid when no full-mix source is present. **Model:** `DeckStemStatus` (`unavailable / separating / prepared` with honest `label`s) + `StemControlState` (gains/mute/solo, `maxGain` 1.5); `WorkspaceEngine` gains the four stem methods; `resolveStems` on load arms a cached version-matched set → `.prepared` (faders live), else disarms → `.unavailable` (full mix, §36.5); **fader setters are inert unless `.prepared`** — a disabled fader neither forwards nor moves (§36.5's "never a fader that looks live and does nothing"). `markStemSeparation` renders `.separating` (driven by 5.9's service). **Seam:** `StemProviding` + `StemLoader` (StemCache → decode each `.caf` to mono → `StemSetBox`, §12.2) + injectable `stemProvider`. **Views:** the iPad STEMS module (`StemFaderRow`: drag gain, tap-to-mute; `dj.deck.<a|b>.stem.<voice>`) and the compact bank drawer's STEMS (the §2.1 two-fader budget) become **live when prepared**, honest disabled rows otherwise. Tests: 7 `StemVoiceTests` (bit-identical fallback + arming/disarming is sample-transparent, stems-only deck reads, four-voice frame-exact summing, gain/mute/solo after the ramp, armed-set grid drives the master clock) + 6 new `WorkspaceModelTests` (prepared arms + live faders, unavailable keeps full mix + inert faders, separating state, status labels, unity defaults, gain clamp). Suite 1327 → **1340 green** (8 skipped); Swift 6 guard OK; app builds (xcodebuild); smoke tests pass in the pre-commit hook. DJ-only — no `xcodegen generate` (decision 25). **FR-ENG-3, §35.1, §36.5, AT-STEM-\* (engine rows).** |
| 5.9 | complete (`6dc5f80`) | gig crates + storage budget (§41.17, §43.6, FR-PLIST-9, FR-ANL-9, FR-LIB-8, plan decisions 2, 11). **`Data/GigCrateRepository.swift`** — `GigCrate`/`GigCrateTrack` records + `GigCrateRow`/`GigCrateDetail`/`GigCrateTrackRow` read models (list roll-up, detail roll-up, per-track readiness). **Promotion from a playlist (FR-PLIST-9)** — one transaction: create the `gig_crate` row and copy the playlist's ordered items into `gig_crate_track`, stamping each track's **FR-LIB-8 `audioCached` flag** at promotion time (the `DeckLoader` gate's file-exists probe — a partially-cached remote track is never ready). `markPerformed` stamps `lastPerformedAt` (the LRU clock); `setStemsState`/`setAudioCached`/`refreshAudioCached`; `cratesByLRU` (oldest-performed first, never-performed = oldest) and `evictableCrates` for the budget. **`Perf/StorageBudgetService.swift`** — the pure §43.6 policy (no I/O): per-device-class stem budgets (iPhone 4 GB / iPad 12 GB) + waveform budgets (300/600 MB), the ~13 MB/track projection, **`mixesEvictable = false` always**, and `plan(addingBytes:budget:currentStemsBytes:usages:protectedIDs:)` → a `StemPlan` whose `evictions` list is the **preview shown before any eviction** (LRU by `lastPerformedAt`, protected crates — the crate being prepared, crates backing a loaded deck — never candidates). **`Stems/StemService.swift`** — the §36.3 actor lane: `planPreparation` (the preview), `evict(crateID:)` (removes cache sets + marks tracks `evicted`), **`runCrateLane`** (budget → evict LRU crates to make room → serialize pending tracks; pauses under the FR-ANL-2 performing fence, abandons the instant the `.stems` governor lane is shed §43.7, mid-run abandonment leaves the rest `pending`; each track `running` → decode → separate → cache.store → `ready` + bytes in one transaction, failure → `failed`, **model absence → stays `pending`** — never a fake failure), and `separateOnDemand` (§36.5, best-effort, cached, never blocks the deck). Newest-1 `observeProgress()` stream + `StemProgress`. **`Features/GigCrate/GigCrateModel.swift` + `GigCrateView.swift`** (mockup `ipad/14`): the crate list, the four header stat cards (audio cached / analyzed / stems / storage), the governor panel, the track table (stems state pill, FR-LIB-8 Local/Caching pill), the amber FR-LIB-8 "one track can't go on a deck yet" notice, and the **"Making room" card that shows the eviction preview before any eviction**. Tests: 7 `GigCrateTests` (promotion copies items in order + stamps FR-LIB-8; the gate is honest for no-asset / deleted-file; refresh re-stamps; detail roll-ups; markPerformed drives LRU; seam conformance; projection) + 11 `StorageBudgetTests` (defaults, the §43.6 300×13MB arithmetic, fits-evicts-nothing, LRU ordering, chronological-not-input, never-performed first, protected never evicted, can't-fit-after-eviction, `mixesEvictable`, bytes text) + 10 `StemServiceTests` (lane separates pending→ready end-to-end over real WAVs with the fake model; re-run is a no-op; performing fence; governor gate; **mid-run governor flip abandons the remaining tracks**; model absence stays pending; **lane evicts the LRU crate to make room**; refuses when even eviction can't fit; on-demand honors the fence and caches; progress stream) + 5 `GigCrateModelTests` (fakes). Suite 1340 → **1373 green** (8 skipped); Swift 6 guard OK; app builds; smoke tests pass in the pre-commit hook. DJ-only — no `xcodegen generate` (decision 25). **FR-PLIST-9, FR-ANL-9, FR-LIB-8, §41.17, §43.6, AT-STEM-\***. |
| 5.10 | complete (`1f07de9`) | record tap + encoder + segmented M4A (§37.2, FR-ENG-7, decision 14). **`Recording/RecordTap.swift`** — the RT-safe post-limiter master-bus copy: a pre-allocated lock-free SPSC ring the render closures write into after the limiter; idle unless recording (`setRecording` gates the copy, so an enabled-but-idle tap is still bit-exact); a full ring **drops and counts** the incoming block — "the ring absorbs a dropped drain", a slow encoder costs the recording's tail, never the live performance. **`Recording/RecordingEncoder.swift`** — the off-RT encoder actor: drains the ring, de-interleaves into the file's float32 processing format, writes AAC 256 kbps into a **segmented M4A** (`segment-NNN.m4a`, each a complete playable file — periodic flush so a crash/interruption costs at most the in-flight segment, NFR-REL-2); `finalize()` closes the final segment and returns `RecordingOutput` (segment URLs, total frames, sample rate, `format = "m4a-aac-256"`). `AudioGraph.Configuration.recordTapEnabled` **defaults false** — the frame-exact reader harness never constructs a tap and stays bit-exact. `PerformanceEngine.startRecording`/`stopRecording` create the per-session directory under `DJDatabase.mixesDirectory` (user content, Application Support, not backup-excluded, `mixesEvictable = false`), run the tap + encoder + an off-RT drain loop; a graph with no tap is the honest `tapNotRecording` state. `WorkspaceModel` mirrors `isRecording` + `recordingElapsed` (recorded frames = master-clock frames, §37.2) as shared session VM state; the mixer-column record chip (`dj.transport.record`, the regression-suite hook 5.10). Tests: 7 `RecordTapTests` + 3 `WorkspaceModelTests`. Suite 1373 → **1383 green** (8 skipped); Swift 6 guard OK; app builds. DJ-only — no `xcodegen generate` (decision 25). **FR-ENG-7, §37.2.** |
| 5.11 | pending | journal + recovery + finalize |
| 5.12 | pending | Finish + Mixes + review listen |
| 5.13 | pending | transition coach |
| 5.14 | pending | **DJ regression suite** (§53.7–53.12) — see [`dj-regression-suite.md`](dj-regression-suite.md) |
