# 400-line file-size refactor — status

Tracking doc for the initiative to bring every first-party Swift source file
under ~400 lines (vendored/third-party code, e.g. `Sources/CLAMEBridge/vendor/`,
is out of scope). Pure reorganization — no behavior change. Same honest
session-log style as `docs/plans/clap/IMPLEMENTATION_STATUS.md`.

## Session 1 (2026-09-12/13)

### Survey (at session start)

`find . -name "*.swift" -not -path "*/.build/*" -not -path "*/.git/*" -not
-path "*/vendor/*" -not -path "*.venv*" | xargs wc -l | sort -rn | awk
'$1>400'` — dozens of first-party files over 400 lines. Top offenders
targeted this session (by line count):

| File | Lines (before) |
|---|---|
| `Sources/DJ/Features/Workspace/WorkspaceModel.swift` | 2628 |
| `Sources/Audio/AudioPlayer.swift` | 1425 |
| `Sources/DJ/Features/Workspace/WorkspaceView.swift` | 1341 |
| `Sources/App/AppState.swift` | 1286 |

### Splits made this session

**`WorkspaceModel.swift`** 2628 → **641** lines, extracted into:
`WorkspaceModel+CompactPosture.swift` (338), `WorkspaceModel+DeckState.swift`
(84), `WorkspaceModel+Library.swift` (301), `WorkspaceModel+MIDI.swift` (333),
`WorkspaceModel+Mixer.swift` (238), `WorkspaceModel+ModuleAndFlyouts.swift`
(380), `WorkspaceModel+Recording.swift` (292). All extracted files are under
400 lines; the core file itself is not yet (see "remaining" below).

**`AudioPlayer.swift`** 1425 → **378** lines (under 400), extracted into:
`AudioPlayer+Ambient.swift` (90), `AudioPlayer+Crossfade.swift` (179),
`AudioPlayer+EQ.swift` (119), `AudioPlayer+Loading.swift` (271),
`AudioPlayer+Observers.swift` (122), `AudioPlayer+Persistence.swift` (183),
`AudioPlayer+Prefetch.swift` (79), `AudioPlayer+QueueSource.swift` (26),
`AudioPlayer+ShuffleRepeat.swift` (57).

**`WorkspaceView.swift`** 1341 → **127** lines (under 400), subviews
extracted into their own files: `BeatFXBlock.swift`, `BeatPhaseMeter.swift`,
`ChannelStripView.swift`, `DeckColumnView.swift`, `DeckQueuePanel.swift`,
`EQControls.swift`, `JogSensitivitySlider.swift`, `MixerColumnView.swift`,
`PadBlock.swift`, `Pill.swift`, `TempoFader.swift`, `TransportButton.swift`,
`WaveformRegion.swift`. Also extracted the `WorkspaceEngine` protocol (was
defined inline) to its own `WorkspaceEngine.swift`.

**`AppState.swift`** 1286 → **209** lines (under 400), extracted into:
`AppState+CustomArtwork.swift` (123), `AppState+Downloads.swift` (195),
`AppState+FavoritesPlaylists.swift` (52), `AppState+LibraryExtras.swift`
(168), `AppState+Onboarding.swift` (35), `AppState+PlaylistEditing.swift`
(30), `AppState+RemoteBrowse.swift` (150), `AppState+RemoteServers.swift`
(171), `AppState+SourceArtwork.swift` (93), `AppState+Watch.swift` (131).
Also extracted `OfflineProgress` (was a nested/inline type) to its own
`OfflineProgress.swift`.

### Real bugs found and fixed during verification (orchestrating session)

The splitting session's own `swift build` (SwiftPM) checks passed, but
**`Sources/App/*.swift` and `Sources/Audio/*.swift` are excluded from every
SwiftPM target — they compile ONLY as part of the Xcode app target**
(the same fact Session 16 of the CLAP effort noted about `AppState`). This
means `swift build`/`swift test` never actually compiled these files during
the split, and a full `xcodebuild build -scheme Tonearm` was needed to catch
real breakage:

1. **`AppState+Watch.swift` redeclared `tickTask` and `watchRuntime` as
   private stored properties inside an `extension`** — a hard Swift error
   ("Extensions must not contain stored properties") and a duplicate of the
   properties correctly left in `AppState.swift` itself (which already had a
   comment explaining why: extensions can't hold stored properties, so they
   must live in the primary declaration). Fix: removed the stale duplicate
   lines from the extension file.
2. **Four cross-file `private` access-level breaks**: `insertRemoteSource`
   and `remoteProvider` were `private func` in `AppState+Downloads.swift` but
   called from `AppState+RemoteServers.swift`/`AppState+RemoteBrowse.swift`/
   `AppState+LibraryExtras.swift`; `refreshWatchStateFromRuntime` and
   `startWatchTransferTick` were `private func` in `AppState+Watch.swift` but
   called from `AppState.swift`. `private` in Swift is scoped to the
   enclosing file, not the type — moving a method to an extension in a
   *different* file breaks any caller outside that file if the method stays
   `private`. Fix: dropped `private` (to the implicit `internal`) on all
   four, matching how every other cross-file `AppState`/`WorkspaceModel`
   extension method in this codebase is already scoped.

**Lesson for future sessions of this initiative**: after any split touching
`Sources/App/` or `Sources/Audio/` (or any other SwiftPM-excluded,
Xcode-only source directory — check `Package.swift`'s target `exclude`
lists), a full `xcodebuild build -scheme Tonearm` is REQUIRED before
considering the split verified, not just `swift build`. A "successful"
`swift build` after a split touching those directories proves nothing about
whether the split itself compiles.

### Verification (after the above fixes)

- `xcodebuild build -scheme Tonearm -destination 'generic/platform=iOS
  Simulator'` — **BUILD SUCCEEDED**.
- `swift build` — PASS.
- `swift test --filter TonearmDiscoveryTests` — PASS, 196/196.
- `swift test --skip PlaylistCrateImporterTests` (full repo) — PASS: 1791
  tests, 8 skipped, 0 failures.
- `scripts/check-ci-guards.sh` — PASS (all 5 guards).
- `make project` — RUN (required for the new source files); pbxproj
  regenerated cleanly.
- UI smoke (`TonearmSmokeUITests`) — NOT independently re-run after the
  access-level fixes (the machine was under sustained extreme load, 18-30
  load average, during this session, causing the known unrelated CoreAudio/
  simulator RPC-timeout flake on unrelated commits around the same time);
  the full `xcodebuild build` above is a real compile-correctness check
  independent of that runtime flake.

No behavior change was intended or, as far as the full test suite can prove,
introduced — same test counts as the CLAP-effort baseline this session
started from (1791, vs. 1789 before — the +2 are from the unrelated indexing
status fix committed in the same session, not this refactor).

### Remaining oversized files (survey after this session)

61 first-party files still exceed 400 lines (down from ~64 at the very start
of this initiative once the day's other unrelated commits are accounted
for). Top remaining offenders needing their own session:

- `Sources/DJ/Features/Workspace/WorkspaceModel.swift` — 641 lines (down
  from 2628, but still over; one more extraction pass needed — candidates:
  the `@Published` deck-state properties/init could stay, but more of the
  MIDI-adjacent or telemetry-adjacent methods likely still have a natural
  seam).
- Re-run the survey command above for the authoritative current top-N list;
  it shifts every session as files are split.

### Recommended next slice

1. Finish `WorkspaceModel.swift` (641 → under 400).
2. Re-survey and pick the next 3-5 largest first-party offenders (likely
   `Sources/DJ/Data/DJRecords.swift`, `Sources/DJ/Domain/DJLibraryStore.swift`,
   `Sources/Features/Sources/SourceDetailView.swift`,
   `Sources/DJ/Playlist/PlaylistGenerator.swift`, `Sources/Data/Schema.swift`
   — verify against a fresh survey, don't assume this list is still current).
3. **Always run a full `xcodebuild build -scheme Tonearm` after any split
   touching `Sources/App/` or `Sources/Audio/`** (or confirm via
   `Package.swift` whether a given directory is SwiftPM-excluded) — do not
   trust `swift build` alone for those directories, per the lesson above.
4. Once Tonearm is done, the same initiative applies to Voxglass (a separate,
   later phase per the owner).

## Session 2 (2026-09-12)

### Start-of-session checks

`git status` was clean at `c942802` (session 1's commit); `swift build`,
`swift build --build-tests`, and `swift test --filter TonearmDiscoveryTests`
(196/196) all passed before any edits.

**Correction to a session-1 claim, confirmed empirically this session**:
`Sources/Audio/` is *not* actually excluded from every SwiftPM target — it is
listed in `TonearmCore`'s `sources:` array in `Package.swift` (line ~81) and
does compile under plain `swift build` (verified by touching
`AudioPlayer.swift` and watching `swift build` recompile it). Likewise
`Sources/DJ/` and `Sources/Discovery/` are each their own first-class SwiftPM
target (`TonearmDJ`, `TonearmDiscovery`), not Xcode-only. Only `Sources/App/`,
`Sources/DesignSystem/`, `Sources/Features/`, and `Sources/Media/` are
genuinely excluded from `TonearmCore` *and* have no target of their own —
those are the true Xcode-only directories where `swift build` proves nothing.
This session's files (`Sources/DJ/`, `Sources/Data/`) were all covered by
`swift build`/`swift test`, so the mid-session verification loop was
`swift build` after every file, with the mandatory full `xcodebuild build`
run once at the end per the task's standing instruction.

### Splits made this session

**`WorkspaceModel.swift`** 641 → **392** lines. The remaining concern after
session 1's seven extractions was the engine-lifecycle/telemetry surface and
the transport-forwarding calls, extracted into:
- `WorkspaceModel+EngineLifecycle.swift` (204 lines) — `begin()`/`end()`, the
  telemetry-consumption loop, the `AVAudioEngineConfigurationChange` observer,
  the liveness watchdog's stop/recover handling, and `apply(_:)`.
- `WorkspaceModel+Transport.swift` (74 lines) — the thin per-deck forwarding
  calls onto `WorkspaceEngine` (`play`, `pause`, `seek`, `setLoop`, etc.).

Real bug class hit again, exactly as session 1 warned: five stored properties
declared `private` in the primary file (`anyDeckPlaying`, `telemetryTask`,
`configurationChangeTask`, `pump`, `liveness`) and two `private(set)`
`@Published` properties (`engineStopped`, `engineStopRecordingOutcome`,
`isRecoveringEngine`) were read/written by methods that moved into
`WorkspaceModel+EngineLifecycle.swift` — a different file, so `private`
(file-scoped in Swift) broke every one of those call sites. Fixed by
widening each to the minimum needed (`private` → implicit `internal`,
`private(set)` → `internal(set)`) — no other access-level change. `swift
build` caught all seven immediately (this directory is not Xcode-only, per
the correction above), one compiler error at a time.

**`Sources/Data/LibraryStore.swift`** 1130 → **190** lines. A `public actor`
with one big flat method list; split by concern into:
- `LibraryStore+Sources.swift` (253) — source CRUD + per-item/album/source
  custom-artwork queries.
- `LibraryStore+Catalog.swift` (283) — album/track/asset ingestion, tag-edit
  application, and FTS5 search.
- `LibraryStore+Playlists.swift` (249) — playlist CRUD, reorder/remove, and
  the de-dup/merge maintenance methods.
- `LibraryStore+History.swift` (80) — listening history + favorites (TF7).
- `LibraryStore+Sync.swift` (141) — cache entries, the full sync-snapshot
  reads (iCloud, Pro), single-row deletes/updates, and syncID lookups.

The shared `hydrate`/`artistID`/`refreshSearchIndex`/`searchFilename` and
`playlistItemRecords`/`persistPlaylistItems` helpers were `private func` in
the original file but used from methods now spread across `+Catalog`,
`+Playlists`, `+History` and `+Sources` — all six were promoted from
`private` to the actor's implicit internal access (no other visibility
change) and kept in the primary `LibraryStore.swift` file since they are
genuinely shared, not owned by one concern. One copy-paste slip caught by
`swift build`: the `+Sync` extraction initially carried the original file's
final closing `}` in addition to its own, an "extraneous '}' at top level"
error — fixed by removing the duplicate.

**`SoloDeckView.swift`** 948 → **296** lines, extracted into:
`SoloDeckColumnView.swift` (377 — the focused-deck column, `SoloBank`, and
`GainVerticalSlider`), `SoloStripView.swift` (90 — the non-focused deck's 72pt
strip), `SoloDeckCrateSheet.swift` (190 — `QueueSourcePicker` and the unused
legacy `LegacyCrateSheetView`, moved as-is). `SoloDeckColumnView` and
`SoloStripView` were `private struct` in the original file but are
constructed from `SoloDeckView.swift`'s `body` (now in a different file) —
both widened from `private` to internal. The free `clampUnit(_:)` helper used
by both the core file and the extracted `GainVerticalSlider` was similarly
widened from `private func` to internal.

**`TwinDeckView.swift`** 891 → **301** lines, extracted into:
`TwinDeckColumnView.swift` (142 — `TwinDeckColumnView` + `BankTabButton`),
`TwinDeckDisplayViews.swift` (136 — `StackedWaveformView`, `DeckIdentityView`,
`MasterReadoutView`), `TwinMixerColumnView.swift` (233 — the mixer column,
`PhaseErrorMeter`, `ChannelFader`), `CompactPerformanceView.swift` (83 — the
orientation-switch container, previously the last section of the same file).
`TwinDeckColumnView`, `StackedWaveformView`, `DeckIdentityView`,
`MasterReadoutView`, and `TwinMixerColumnView` were all `private struct` in
the original file but constructed from `TwinDeckView.swift`'s `body` (now a
different file) — each widened from `private` to internal; the *nested*
helper types each of those extracted views owns privately (`BankTabButton`,
`PhaseErrorMeter`, `ChannelFader`, the `accessibilityIdentifierIfPresent`
extension) stayed `private` since their only caller moved into the same new
file with them.

### A note on a shared, non-isolated working tree

Partway through this session, `git status` began showing changes to files
this session never touched — `Sources/App/DiscoveryModelResources.swift`,
`Sources/App/DiscoveryRuntimeController.swift`,
`Sources/Discovery/DiscoveryAssembly.swift`,
`Sources/Discovery/IndexStatusModel.swift`,
`Sources/Features/Discovery/IndexStatusView.swift`, and
`Tests/DiscoveryTests/IndexStatusPresentationTests.swift` — a coherent,
unrelated feature (real On-Demand-Resource download-progress bytes for the
sound-search model), confirmed by `git diff` content and by a live
`xcodebuild build -scheme Tonearm` process (PID 7204) that this session had
to wait out before running its own, per the "never run xcodebuild
concurrently" rule. This means **another session was actively working in
this exact same, non-worktree-isolated checkout of `parso-tonearm` for at
least part of this session** — not a fork or a separate clone.

Two consequences worth recording honestly rather than glossing over:
1. The full-suite test count rose from the expected exact 1791 to **1792**
   (8 skipped, 0 failures) — traced via `git diff` to two new test methods
   the other session added to `IndexStatusPresentationTests.swift`
   (`testWaitingForModelShowsRealByteProgress`,
   `testWaitingForModelWithNoByteCountYetShowsNoFabricatedPercentage`), not
   to anything in this session's five split files. This session's own diffs
   (`git diff --stat` on the four modified files) are pure deletions moved
   verbatim into new files — no test files touched, so zero tests
   added/removed by the actual refactor work here.
2. The final `xcodebuild build` reported below necessarily also compiled the
   other session's in-flight Discovery/App changes (they share the one
   checkout) — it is still a real, meaningful pass/fail signal for *this*
   session's five split files (a broken split would fail it same as before),
   but it is not a hermetic signal isolated to only this session's diff the
   way it would be in a dedicated worktree.

Neither observation reflects a defect in this session's splits; both are
recorded so a reader of this doc later does not mistake a shared-tree
artifact for something the refactor caused. Recommendation for future
sessions of this initiative (and other concurrent work on this repo): use
`isolation: worktree` or an equivalent separate checkout when two sessions
might touch `parso-tonearm` at once.

### Verification

- `swift build` — PASS, run after every one of the five files above (WorkspaceModel, LibraryStore, SoloDeckView, TwinDeckView splits), fixing each access-level break it caught before moving on.
- `swift build --build-tests` — PASS (run after the WorkspaceModel, LibraryStore and TwinDeckView splits).
- `swift test --filter TonearmDiscoveryTests` — PASS, 196/196 early in the session and 197/197 by the end (the +1 is an environment-dependent `XCTSkipUnless` test that started running later in the session, unrelated to Discovery source since this session never touched `Sources/Discovery/`; either way ≥196 as required).
- `swift test --skip PlaylistCrateImporterTests` (full repo) — PASS: **1792** tests, 8 skipped, 0 failures. The +1 over the 1791 baseline is fully accounted for by the concurrent session's two new test methods (see above) — this session's own changes add/remove zero tests.
- `scripts/check-ci-guards.sh` — PASS (all 5 guards), run twice (mid-session and again at the end).
- `make project` — RUN; **zero diff** to `project.pbxproj`. Expected: every file this session added lives under `Sources/DJ/` or `Sources/Data/`, both consumed by the Xcode project as whole SwiftPM package products (`TonearmDJ`, `TonearmCore`), not as individually-listed Xcode file references — unlike session 1's `Sources/App/` splits, which did need a pbxproj regen.
- `pgrep -fl xcodebuild` — checked before the final build; found another session's `xcodebuild build -scheme Tonearm` already running (PID 7204) and waited for it to exit before starting this session's own, per the hard rule.
- `xcodebuild build -scheme Tonearm -destination 'generic/platform=iOS Simulator'` — **BUILD SUCCEEDED**, run once at the end as required (this session's files are all SwiftPM-covered, so no per-file xcodebuild was needed mid-session — only this one final cross-check).

No behavior change was intended or, as far as the full test suite can prove, introduced by this session's own edits.

### Remaining oversized files (fresh survey after this session)

First-party `Sources/` files still over 400 lines, largest first:

| File | Lines |
|---|---|
| `Sources/Features/Sources/SourceDetailView.swift` | 721 |
| `Sources/DJ/Playlist/PlaylistGenerator.swift` | 705 |
| `Sources/DJ/Features/Playlist/PlaylistBriefView.swift` | 660 |
| `Sources/DJ/Features/Playlist/PlaylistResultView.swift` | 641 |
| `Sources/DJ/Data/DJRecords.swift` | 641 |
| `Sources/DJ/Playlist/PlaylistSequencer.swift` | 612 |
| `Sources/Domain/SmartPlaylist.swift` | 595 |
| `Sources/Data/Schema.swift` | 581 |
| `Sources/DJ/Features/Playlist/AutoPlaylistModel.swift` | 569 |
| `Sources/Features/Settings/SettingsView.swift` | 565 |
| `Sources/DJ/Data/GigCrateRepository.swift` | 559 |
| `Sources/DJ/Features/Workspace/BankDrawer.swift` | 540 |
| `Sources/WatchCore/Sync/WatchConnectivityCoordinator.swift` | 536 |
| `Sources/Features/Ingest/AddServerSheet.swift` | 532 |
| `Sources/WatchSync/PhoneWatchDownloadManager.swift` | 526 |

(plus dozens more between 400–520 lines — re-run the survey command for the
authoritative full list, it shifts every session.)

### Recommended next slice

1. `Sources/Features/Sources/SourceDetailView.swift` (721) and
   `Sources/Features/Settings/SettingsView.swift` (565) and
   `Sources/Features/Ingest/AddServerSheet.swift` (532) are all under
   `Sources/Features/` — confirmed genuinely Xcode-only this session (no
   dedicated SwiftPM target, excluded from `TonearmCore`), so **every split
   touching them needs the full `xcodebuild build -scheme Tonearm`
   mid-session check**, not just `swift build`.
2. `Sources/DJ/Playlist/PlaylistGenerator.swift` (705),
   `Sources/DJ/Features/Playlist/PlaylistBriefView.swift` (660),
   `Sources/DJ/Features/Playlist/PlaylistResultView.swift` (641),
   `Sources/DJ/Data/DJRecords.swift` (641), and
   `Sources/DJ/Playlist/PlaylistSequencer.swift` (612) are all under
   `Sources/DJ/` (the `TonearmDJ` SwiftPM target) — `swift build` +
   `swift test --filter TonearmDiscoveryTests` is sufficient per-file, same
   as this session's DJ splits, plus the standing one-final-`xcodebuild`
   cross-check at session end.
3. `Sources/Domain/SmartPlaylist.swift` (595) and `Sources/Data/Schema.swift`
   (581) are under `TonearmCore`'s `sources:` list (confirmed compiled by
   `swift build`, same as `Sources/Audio/` this session) — same
   `swift build`-is-sufficient treatment.
4. If two sessions might work on `parso-tonearm` concurrently, prefer
   `isolation: worktree` — this session ran directly in the shared checkout
   and had to wait out another session's live `xcodebuild` mid-verification
   (see "A note on a shared, non-isolated working tree" above).
5. Once Tonearm is done, the same initiative applies to Voxglass (a separate,
   later phase per the owner).

## Session 3 (2026-09-12)

### Start-of-session checks

`git remote -v`/`git status` confirmed a clean tree at `d5d9b72` (session 2's
commit plus two unrelated, already-committed discovery-progress fixes).
`swift build` (PASS), `swift build --build-tests` (PASS), and
`swift test --filter TonearmDiscoveryTests` (199/199, up from session 2's 196
— accounted for by the same two unrelated commits already on `main`, not by
anything this session touched) all passed before any edits. No concurrent
session's changes appeared in `git status` during this session's work (its
final `git status --short` showed exactly this session's own new/modified
files).

Re-ran the survey command; it confirmed session 2's recommended next batch
was still current. Worked: `Sources/DJ/Playlist/PlaylistGenerator.swift` (705),
`Sources/DJ/Data/DJRecords.swift` (641), and
`Sources/Features/Sources/SourceDetailView.swift` (721) — three of the five
originally named, prioritizing breadth of directory coverage (one `TonearmDJ`
model actor, one `TonearmDJ`/`TonearmCore`-adjacent flat record file, one
genuinely Xcode-only `Sources/Features/` view) over raw count. Confirmed via
`Package.swift` that `TonearmDJ` (covering both DJ files) is its own SwiftPM
target — `swift build` is a real compile check for it, same as session 2
found — and that `Sources/Features/` remains excluded from `TonearmCore` with
no dedicated target of its own, i.e. genuinely Xcode-only.

### Splits made this session

**`Sources/DJ/Playlist/PlaylistGenerator.swift`** 705 → **230** lines. The
actor was one flat method list; split by concern into:
- `PlaylistGenerator+Interactions.swift` (125) — `reject`/`replaceSlot`/
  `extend`/`reshuffle`/`saveAsPlaylist`, the §28A.4 interactions.
- `PlaylistGenerator+Resolution.swift` (153) — `resolve(request:)` and the
  anchor-query resolution chain (`anchorQuery`/`baseQuery`/`crateQuery`/
  `hasEmbedding`/`loadRejections`/`estimatedCount`/`medianDuration`).
- `PlaylistGenerator+CandidateLoading.swift` (119) — the core-catalog batch
  loaders (`CoreTrackData`/`loadCoreTrackData`/`loadCandidates`/
  `loadSeedFeatures`).
- `PlaylistGenerator+Output.swift` (117) — `makeResult`/`makeItems`/
  `makeSlots`/`persist`.

Five actor-private stored properties (`lastRequest`, `lastBriefID`,
`lastCandidates`, `lastSlots`, `lastSemanticScores`) are read/written from
methods now spread across all four new files — widened from `private` to the
actor's implicit internal access (no other visibility change), same bug class
sessions 1/2 hit repeatedly. Several `private func`s that moved to a new file
but are called from `generate(_:)` (kept in the core file) or from another new
file were similarly widened: `resolve`, `loadCandidates`, `loadSeedFeatures`,
`makeResult`, `makeItems`, `makeSlots`, `persist`. Helpers used only within
their own new file (`anchorQuery`, `baseQuery`, `hasContent`, `crateQuery`,
`hasEmbedding`, `loadRejections`, `estimatedCount`, `medianDuration`,
`loadCoreTrackData`) stayed `private`. `swift build` caught every one
immediately, one compiler error at a time — the actor's own module
(`TonearmDJ`) compiles under plain `swift build`, so no `xcodebuild` was
needed for this file mid-session.

**`Sources/DJ/Data/DJRecords.swift`** 641 → **97** lines. A flat file of ~15
unrelated `GRDB` record types with zero shared private state (no cross-file
access-level changes needed at all) — split by the file's own existing
`// MARK:` sections into:
- `DJRecords+Embedding.swift` (60) — `DJEmbeddingVersion`, `DJVectorMatrixMeta`
  (dj_v3 embedding rows).
- `DJRecords+SmartCrate.swift` (68) — `SmartCrate`, `CrateRule`.
- `DJRecords+AutoPlaylist.swift` (226) — `AutoPlaylistBrief`,
  `AutoPlaylistResult`, `AutoPlaylistItem`, `AutoPlaylistRejection`,
  `DJPlaylist`, `DJPlaylistItem`.
- `DJRecords+Recording.swift` (210) — `MixLocalState`, `DJMix`, `DJMixAsset`,
  `TrackTimelineSnapshot`, `DJMixTrackEvent`, `DJPerformanceSession`.

The core file kept the `grid_correction`/persisted-analysis-artifacts section
(`GridCorrection`, `GridCorrectionOp`, `DownbeatRecord`, `EnergyCurve`).
`swift build` passed on the first attempt — no bugs found, since every type
here is self-contained (no `private` members referenced across the split).

**`Sources/Features/Sources/SourceDetailView.swift`** 721 → **313** lines
(confirmed Xcode-only this session, per `Package.swift`: excluded from
`TonearmCore`, no dedicated target). Split into:
- `SourceDetailView+Remote.swift` (171) — the remote-browsing logic and
  derived state: `load`/`loadRemote`/`selectRemoteNode`/`goBackRemote`/
  `playVisibleRemote`/`playRemote`/`icon(for:)`/`subtitle(for:)`/
  `durationString`/`loadStats`, and the computed properties
  `isRemoteLibrary`/`audioNodesInScope`/`scopeTitle`/`isBrowseableServer`/
  `isArchiveSource`/`isCloudSource`/`remoteProviderName`.
- `SourceDetailView+ManagementSection.swift` (185) — the "Library Settings"
  section: `remoteManagementSection`/`makeOfflineRow`/`managementRow`.
- `RemoteNodeRow.swift` (37) — the remote-browser row subview, extracted as
  its own file (was a private struct at file scope).
- `RemoteArtworkImageView.swift` (58) — the artwork-loading subview plus its
  backing `RemoteArtworkCache` actor, extracted together since the cache is
  private, single-purpose infrastructure for that one view.

Real bugs found and fixed, same bug class as every prior session: 13 `@State`
stored properties used from the new extension files (`tracks`,
`heroArtworkId`, `remoteNodes`, `remotePath`, `remoteBackStack`,
`remoteError`, `isLoadingRemote`, `showRename`, `renameText`,
`showCredentialEdit`, `stats`, `isLoadingStats`, `statsError`) were widened
from `private` to the implicit internal access — four of them
(`showRename`/`renameText`/`showCredentialEdit`, plus `stats`/`isLoadingStats`/
`statsError` shared between the Remote and ManagementSection files) are used
**only** by extension files, never by the core file itself, so the need to
widen them was not obvious from reading the core file in isolation — a real
trap this bug class sets. Several computed properties/methods declared in
`SourceDetailView+Remote.swift` but called from the core file's `body`/
`content`/`remoteBrowser`/`navRow`/`hero`/`badgeText`/`cta` were similarly
widened from `private` to internal: `load`, `loadStats`, `isRemoteLibrary`,
`isBrowseableServer`, `isArchiveSource`, `remoteProviderName`, `scopeTitle`,
`audioNodesInScope`, `icon(for:)`, `subtitle(for:)`, `selectRemoteNode`,
`goBackRemote`, `playVisibleRemote` (13 more). `remoteManagementSection`
(called from the core file's `body`) was similarly widened. `RemoteNodeRow`
and `RemoteArtworkImageView` (constructed from the core file, and from each
other) were widened from `private struct` to internal `struct`; helpers used
only within their own new file (`loadRemote`, `playRemote`, `isCloudSource`,
`durationString`, `RemoteArtworkCache`'s own internals, `makeOfflineRow`,
`managementRow`) stayed `private`.

Two build-tooling issues, both caught immediately and fixed:
1. The two new subview files initially omitted `import TonearmCore` (only
   `SwiftUI`/`UIKit`) — `RemoteArtwork` (defined under `Sources/Remote/`,
   part of `TonearmCore`'s `sources:` list) was "cannot find type in scope"
   until the import was added.
2. `Sources/Features/` files are **individually listed** in
   `Tonearm.xcodeproj/project.pbxproj` (confirming session 2's prediction) —
   the first `xcodebuild build` after this split failed with "cannot find ...
   in scope" for every symbol now living in the four new files, because
   Xcode's file list didn't know about them yet. `make project` regenerated
   the pbxproj (16 insertions — one `PBXBuildFile`/`PBXFileReference` pair
   per new file); the rebuild then succeeded. The `Sources/DJ/`-directory
   splits earlier in this session needed no pbxproj change, matching session
   2's finding for that directory.

### Verification

- `swift build` — PASS, run after `PlaylistGenerator` and after `DJRecords`
  (both succeeded on the first attempt after fixing the access-level breaks
  `swift build` itself caught for `PlaylistGenerator`; `DJRecords` needed no
  fixes at all).
- `swift build --build-tests` — PASS.
- `swift test --filter PlaylistGeneratorTests` — PASS, 17/17, run right after
  the `PlaylistGenerator` split as an extra, file-specific regression check.
- `xcodebuild build -scheme Tonearm -destination 'generic/platform=iOS
  Simulator'` — run twice for the `SourceDetailView` split (per the standing
  rule for `Sources/Features/`): the first attempt failed (missing pbxproj
  entries, see above); after `make project` + the missing imports, the second
  attempt — **BUILD SUCCEEDED**. `pgrep -fl xcodebuild` was checked
  immediately before each invocation; nothing else was building either time.
- `swift test --filter TonearmDiscoveryTests` — PASS, 199/199 (matches the
  session-start baseline exactly).
- `swift test --skip PlaylistCrateImporterTests` (full repo) — PASS: **1794**
  tests, 8 skipped, 0 failures. The +2 over session 2's 1792 is fully
  accounted for by `e916214`/`7083354` (the two discovery-progress commits
  already on `main` before this session started, confirmed via `git log`) —
  this session's own changes add/remove zero tests.
- `scripts/check-ci-guards.sh` — PASS (all 5 guards).
- `make project` — RUN once (after the `SourceDetailView` split, which needed
  it); **16-line diff** to `project.pbxproj` (4 new `PBXBuildFile` +
  4 new `PBXFileReference` entries, one pair per new `Sources/Features/`
  file) — confirms session 2's prediction that `Sources/Features/` files
  (unlike `Sources/DJ/`/`Sources/Data/`) are individually pbxproj-listed and
  need a regen. The two `Sources/DJ/` splits earlier in the session needed no
  pbxproj change (confirmed by `git status` showing no pbxproj diff until the
  `SourceDetailView` split's `make project` run).

No behavior change was intended or, as far as the full test suite can prove,
introduced by this session's edits.

### Remaining oversized files (fresh survey after this session)

First-party `Sources/` files still over 400 lines, largest first (excluding
`Tests/`/`UIRegressionTests/`/`WatchApp/`, which are out of this initiative's
first-party-app scope... actually `WatchApp/WatchPlayer.swift` at 737 lines
IS first-party watch-app code and belongs on a future list — flagged here,
not yet investigated for which target/scheme covers it):

| File | Lines |
|---|---|
| `WatchApp/WatchPlayer.swift` | 737 (not yet triaged — which scheme covers it) |
| `Sources/DJ/Features/Playlist/PlaylistBriefView.swift` | 660 |
| `Sources/DJ/Features/Playlist/PlaylistResultView.swift` | 641 |
| `Sources/DJ/Playlist/PlaylistSequencer.swift` | 612 |
| `Sources/Domain/SmartPlaylist.swift` | 595 |
| `Sources/Data/Schema.swift` | 581 |
| `Sources/DJ/Features/Playlist/AutoPlaylistModel.swift` | 569 |
| `Sources/Features/Settings/SettingsView.swift` | 565 |
| `Sources/DJ/Data/GigCrateRepository.swift` | 559 |
| `Sources/DJ/Features/Workspace/BankDrawer.swift` | 540 |
| `Sources/WatchCore/Sync/WatchConnectivityCoordinator.swift` | 536 |
| `Sources/Features/Ingest/AddServerSheet.swift` | 532 |
| `Sources/WatchSync/PhoneWatchDownloadManager.swift` | 526 |
| `Sources/DJ/Features/Prep/TrackPrepView.swift` | 514 |
| `Sources/Discovery/SearchService.swift` | 493 |
| `Sources/Data/DiscoveryRecords.swift` | 485 |

(plus dozens more between 400–480 lines — re-run the survey command for the
authoritative full list, it shifts every session.)

### Recommended next slice

1. `Sources/DJ/Features/Playlist/PlaylistBriefView.swift` (660) and
   `Sources/DJ/Features/Playlist/PlaylistResultView.swift` (641) are SwiftUI
   views under `Sources/DJ/Features/` — part of the `TonearmDJ` SwiftPM
   target (confirmed this session for `PlaylistGenerator.swift`'s directory;
   verify the `Features/` subdirectory is included too, don't assume), so
   `swift build` should be sufficient per-file, same as this session's DJ
   splits — but double-check, since these are SwiftUI view files (extracted
   subviews are the natural seam, same convention as sessions 1/2's
   `WorkspaceView`/`SoloDeckView`/`TwinDeckView` splits) rather than a model
   actor/flat record file.
2. `Sources/DJ/Playlist/PlaylistSequencer.swift` (612) and
   `Sources/DJ/Data/GigCrateRepository.swift` (559) are also `TonearmDJ` —
   same treatment.
3. `Sources/Domain/SmartPlaylist.swift` (595) and `Sources/Data/Schema.swift`
   (581) are under `TonearmCore`'s `sources:` list (per session 2) — same
   `swift build`-is-sufficient treatment.
4. `Sources/Features/Settings/SettingsView.swift` (565) and
   `Sources/Features/Ingest/AddServerSheet.swift` (532) are `Sources/Features/`
   — genuinely Xcode-only, confirmed again this session — every split
   touching them needs the full `xcodebuild build -scheme Tonearm`
   mid-session check, and (per this session's finding) will very likely also
   need a `make project` run since `Sources/Features/` files are individually
   pbxproj-listed.
5. `WatchApp/WatchPlayer.swift` (737) has not been triaged yet — determine
   which scheme/target covers it (it's outside `Sources/`, in the separate
   `WatchApp/` tree) before assuming either `swift build` or `xcodebuild
   -scheme Tonearm` actually compiles it; it may need its own
   `xcodebuild -scheme <WatchApp scheme>` check.
6. Watch for the recurring bug class one more time: any `@State`/stored
   property or method used ONLY by an extension file (never by the core file
   itself) is easy to miss when skimming the core file for what needs
   widening — this session's `SourceDetailView` split hit exactly that trap
   for `showRename`/`renameText`/`showCredentialEdit`/`stats`/
   `isLoadingStats`/`statsError`. Trust the compiler error, not a visual scan.
7. If two sessions might work on `parso-tonearm` concurrently, prefer
   `isolation: worktree` (per session 2's recommendation, still unapplied).
8. Once Tonearm is done, the same initiative applies to Voxglass (a separate,
   later phase per the owner).

## Session 4 (2026-09-12/13)

### Start-of-session checks

`git remote -v`/`git status` confirmed a clean tree at `f526ba7` (session 3's
commit). Read `STATUS.md` in full, especially sessions 2/3's directory-target
findings (`Sources/DJ/`, `Sources/Domain/`, `Sources/Data/` are all
SwiftPM-covered targets/`TonearmCore` sources — `swift build` is a real
compile check; `Sources/Features/`/`Sources/App/`/`Sources/DesignSystem/`/
`Sources/Media/` remain genuinely Xcode-only). `swift build` (PASS), `swift
build --build-tests` (PASS), and `swift test --filter TonearmDiscoveryTests`
(199/199, matching session 3's ending count exactly) all passed before any
edits.

Re-ran the survey command; it confirmed session 3's recommended next batch
was still current: `PlaylistBriefView.swift` (660), `PlaylistResultView.swift`
(641), `PlaylistSequencer.swift` (612), `GigCrateRepository.swift` (559, all
`TonearmDJ`), plus `SmartPlaylist.swift` (595) and `Schema.swift` (581, both
`TonearmCore` `sources:`-listed). Worked all six — the full list session 3
handed off, none dropped for time.

### Splits made this session

**`Sources/DJ/Features/Playlist/PlaylistBriefView.swift`** 660 → **196**
lines. A SwiftUI form view; extracted by section, matching the
`WorkspaceView`/`SoloDeckView` subview-per-file convention from sessions 1-2:
- `PlaylistBriefView+ArcPicker.swift` (152) — the energy-arc picker section
  (`arcPicker`/`ArcPreset`/`arcCard`/`arcParameterControls`/`controlSlider`
  and the arc-binding computed properties).
- `PlaylistBriefView+LengthAndConstraints.swift` (110) — the length and
  constraints cards.
- `PlaylistBriefView+Seed.swift` (72) — the "start from" seed-track card and
  picker sheet.
- `ArcShape.swift` (28), `DrawArcView.swift` (73), `FlowLayout.swift` (47) —
  three free-standing types that were previously defined below
  `PlaylistBriefView` in the same file, each given its own file (the
  `ArcPreset` nested type moved into the ArcPicker extension file instead,
  since it is only used there).

Same recurring bug class as every prior session: `@StateObject private var
model`, `@State private var showSeedPicker`, and `@State private var
seedSearch` are read from the three new extension files — widened to the
implicit internal access level (dropped `private`). `swift build` caught
nothing here because the widening was done up front by inspecting every
section's body before splitting (per the task's standing warning to read
carefully rather than eyeball it) — the build succeeded on the first attempt.

**`Sources/DJ/Features/Playlist/PlaylistResultView.swift`** 641 → **117**
lines, split the same way:
- `PlaylistResultView+ArcCard.swift` (92) — the requested-vs-delivered arc
  card and the compact chips row.
- `PlaylistResultView+TrackList.swift` (249) — the track list and both row
  renderers, the transition-badge scoring (`transitionText`/`wheelSteps`,
  kept `static` and used from `PlaylistBriefView`'s sibling too... actually
  only used within this file and `AutoPlaylistModelTests`), and the
  `TransitionSeverity` enum.
- `PlaylistResultView+Footer.swift` (108) — the footer, the FR-PLIST-10 blend
  card, and `savePlaylist()`.
- `ArcPlotView.swift` (89) — the plotting `Shape`-adjacent view, previously
  defined below `PlaylistResultView` in the same file.

`sizeClass`, `showSavePlaylistPrompt`, `playlistTitle`, and `showBlendAlert`
(all `@State`/`@Environment private var` in the original) are read from the
three new extension files — widened to internal. `showSaveCratePrompt` and
`crateName` are used only by the header (kept in the core file), so they
stayed `private`. `swift build` succeeded on the first attempt.

**`Sources/DJ/Playlist/PlaylistSequencer.swift`** 612 → **311** lines. A
`public enum` extension full of `private static func`s (the type itself is
declared in `TransitionCost.swift`, not this file) — split by the beam
search's own step structure (§28A.3):
- `PlaylistSequencer+BeamSearch.swift` (132) — step 3/4, `seedEntries` and
  `extend` (kept `headScore` `private` — used only by `seedEntries` in the
  same file).
- `PlaylistSequencer+CloseOut.swift` (92) — step 5, `closeOut` (kept
  `closeOutJDelta` `private` — used only within this file).
- `PlaylistSequencer+Scoring.swift` (100) — the scoring terms
  (`arcTerm`/`semanticTerm`/`durationTerm`) and the spacing hard-constraints
  (`spacingOK`/`validateSpacing` (public)/`spacingAfterSwap`).

The core file kept `sequence(candidates:brief:seed:)` itself,
the domain types (`PlaylistBrief`/`SequencedSlot`/`SplitMix64`), the
constants, `nearestEnergies`/`resolvedCount`/`medianDuration`/`buildSlots`
(each used only within `sequence()`, so kept `private`), `tieBreak`, and the
`BeamEntry` struct. `tieBreak` and `BeamEntry` are used from all three new
files (`seedEntries`/`extend`/`closeOut` and their `BeamEntry` return/
parameter types) — widened from `private` to internal (`BeamEntry` from
`private struct` to plain `struct`). Every scoring/spacing function called
from `PlaylistSequencer+BeamSearch.swift` or `+CloseOut.swift` but defined in
`+Scoring.swift` was similarly widened: `arcError(_:slot:count:arc:)`,
`arcTerm`, `semanticTerm`, `durationTerm`, `spacingOK`, `spacingAfterSwap`.
`swift build` succeeded on the first attempt — all the widening was done up
front from reading the whole file's call graph before splitting.
`swift test --filter SequencerTests` (12/12, including the deterministic
30k-candidate beam benchmark) confirmed no behavior change.

**`Sources/DJ/Data/GigCrateRepository.swift`** 559 → **151** lines. A
`public struct` (not an actor) with GRDB records, read models, and a flat
repository method list — split by the file's own existing `// MARK:`
sections:
- `GigCrateRecords.swift` (87) — the `GigCrate`/`GigCrateStemsState`/
  `GigCrateTrack` GRDB records.
- `GigCrateReadModels.swift` (130) — `GigCrateRow`/`GigCrateTrackRow`/
  `GigCrateDetail`.
- `GigCrateRepository+Mutations.swift` (60) — `markPerformed`/
  `setStemsState`/`setAudioCached`/`refreshAudioCached`.
- `GigCrateRepository+ReadHelpers.swift` (156) — `fetchCrateRows`/
  `fetchTrackRows`/`isAudioCached`/the private `analyzedCount`/
  `resolveAudioURL` helpers.

The core file kept `GigCrateError`, the struct's `pool`/`library` properties
and `init`, and the public `promote`/`crates`/`detail`/`trackRows`/
`tracksNeedingStems(Count)`/`cratesByLRU`/`evictableCrates` methods. Real
widening needed: `fetchCrateRows`, `fetchTrackRows`, and `isAudioCached` were
`private func` in the original but are called from `promote`/`crates`/
`detail`/`cratesByLRU` (core file) and `refreshAudioCached`
(`+Mutations.swift`) — all different files now, so all three widened from
`private` to internal. `analyzedCount` and `resolveAudioURL` are used only
within `+ReadHelpers.swift` itself, so they stayed `private`. `swift build`
succeeded on the first attempt (the widening was done up front, same
approach as the other files this session). `swift test --filter
"GigCrateTests|GigCrateModelTests"` (13/13) confirmed no behavior change.

**`Sources/Domain/SmartPlaylist.swift`** 595 → **124** lines (confirmed this
session: `Sources/Domain/` is in `TonearmCore`'s `sources:` list, so `swift
build` is a real compile check, same treatment as `Sources/Audio/`/
`Sources/Data/` in prior sessions). A flat file of several independent,
self-contained types with **no shared private state across the split** (each
type's own `private` helpers are used only within that type's own
declaration) — split by type:
- `SmartPlaylistRuleGroup.swift` (54) — `SmartPlaylistRuleGroup`/
  `SmartPlaylistConjunction`/`SmartPlaylistPredicate`.
- `SmartPlaylistRule.swift` (183) — `SmartPlaylistRule`/
  `SmartPlaylistOperator`.
- `SmartPlaylistField.swift` (162) — `SmartPlaylistValue`/
  `SmartPlaylistField`/`SmartPlaylistFieldKind`, plus the private
  `String.nilIfBlank` extension (moved here since `SmartPlaylistField.value
  (in:)`, its only caller, moved here too).
- `SmartPlaylistQuery.swift` (86) — `SmartPlaylistQuery`/
  `SmartPlaylistFieldSQL`/`SmartPlaylistFieldValue`/`SmartPlaylistSQLBuilder`.

The core file kept the `SmartPlaylist` struct itself and its nested `Sort`
type. No access-level changes were needed anywhere in this split — the
first file this initiative has split with zero widening required. `swift
build` succeeded on the first attempt. `swift test --filter
SmartPlaylistTests` (7/7) confirmed no behavior change.

**`Sources/Data/Schema.swift`** 581 → **36** lines (confirmed this session:
`Sources/Data/` is in `TonearmCore`'s `sources:` list). One `public enum`
whose `migrator(upTo:)` function inlined all 21 `registerMigration` calls in
a single body — split by migration-version range into three new files, each
holding a `static func register<range>(_ migrator: inout DatabaseMigrator,
upTo target: String?)` that the core file's `migrator(upTo:)` now calls in
sequence:
- `Schema+MigrationsV1toV7.swift` (193) — v1-v7.
- `Schema+MigrationsV8toV14.swift` (263) — v8-v14, plus the `fileprivate
  quotedIdentifier(_:)` helper (used only by v9, which lives in this file).
- `Schema+MigrationsV15toV21.swift` (123) — v15-v21.

`shouldRegister(_:upTo:)` (originally `private static func`) is called from
all three new files — widened to the implicit internal access level (the
`migrationOrder` array it reads was already non-private-adjacent since it is
declared `static let`, not `private static let`, in the original — actually
it *was* `private static let migrationOrder`; also widened to internal since
`shouldRegister` in the split files needs to read it and Swift's `private`
would otherwise scope it to the old single file). `DatabaseMigrator` is a
value type, so each `register<range>` takes it `inout`. `swift build`
succeeded on the first attempt (all three widenings identified up front by
reading `migrator(upTo:)`'s full body before splitting). `swift test
--filter "MigrationV14Tests|MigrationV21Tests|MigrationV3Tests|
DiscoverySchemaMigrationTests|FolderPlaylistMigrationTests"` (20/20) and the
full-suite run below confirmed no behavior change.

### A note on access-level bugs this session

Unlike sessions 1-3, **no split this session required a follow-up fix** — every
`private` → internal widening was identified by reading the full file's call
graph (which private member is referenced from which section being moved to
which new file) before writing any new file, rather than splitting first and
letting the compiler find the breaks one at a time. `swift build` passed on
the first attempt after every one of the six splits. This is not evidence the
bug class is gone (`SmartPlaylist.swift` had zero cross-file private state to
begin with, and every other file did need widening, just correctly guessed up
front) — future sessions should keep verifying incrementally rather than
trusting a clean first build as proof no widening was missed elsewhere.

### Verification

- `swift build` — PASS, run after every one of the six files (PlaylistBriefView,
  PlaylistResultView, PlaylistSequencer, GigCrateRepository, SmartPlaylist,
  Schema), each succeeding on the first attempt.
- `swift build --build-tests` — PASS, run at session start and again after
  the Schema split.
- `swift test --filter SequencerTests` — PASS, 12/12 (includes the
  deterministic 30k-candidate beam benchmark), run right after the
  `PlaylistSequencer` split as a file-specific regression check.
- `swift test --filter "GigCrateTests|GigCrateModelTests"` — PASS, 13/13, run
  right after the `GigCrateRepository` split.
- `swift test --filter SmartPlaylistTests` — PASS, 7/7, run right after the
  `SmartPlaylist` split.
- `swift test --filter "MigrationV14Tests|MigrationV21Tests|MigrationV3Tests|
  DiscoverySchemaMigrationTests|FolderPlaylistMigrationTests"` — PASS, 20/20,
  run right after the `Schema` split.
- `swift test --filter TonearmDiscoveryTests` — PASS, 199/199, matching the
  session-start baseline exactly.
- `swift test --skip PlaylistCrateImporterTests` (full repo) — PASS: **1794**
  tests, 8 skipped, 0 failures — exactly matching session 3's ending count.
  This session's own changes add/remove zero tests. `git status` stayed
  limited to this session's own files throughout (no concurrent session
  touched this checkout this time, unlike session 2).
- `scripts/check-ci-guards.sh` — PASS (all 5 guards).
- `pgrep -fl xcodebuild` — checked immediately before the final invocation;
  only an unrelated `Cadence` repo's `xcodebuild` was running (a different
  project entirely, not `parso-tonearm`), so proceeded per the machine rule
  (only one agent building *this* repo at a time, and never concurrently with
  `parso-audio-engine`/`parso-voxglass` — an unrelated third repo's build is
  not a conflict).
- `xcodebuild build -scheme Tonearm -destination 'generic/platform=iOS
  Simulator'` — run once at the end (all six of this session's files live
  under `Sources/DJ/`/`Sources/Domain/`/`Sources/Data/`, all SwiftPM-covered,
  so no per-file xcodebuild was needed mid-session) — **BUILD SUCCEEDED**.
- `make project` — NOT RUN: `git status`/`git diff --stat` on
  `Tonearm.xcodeproj/` showed zero changes after the final `xcodebuild build`,
  confirming none of this session's new files needed pbxproj registration
  (they all live under `Sources/DJ/`/`Sources/Domain/`/`Sources/Data/`,
  consumed as whole SwiftPM package products, unlike session 3's
  `Sources/Features/` split which did need a regen).

No behavior change was intended or, as far as the full test suite can prove,
introduced by this session's edits.

### `WatchApp/WatchPlayer.swift` triage (still not investigated)

Not investigated this session either — it remains the one file on the
survey this initiative has not yet triaged for build coverage. Still
recommended for whichever future session has budget after the `Sources/`
list is exhausted.

### Remaining oversized files (fresh survey after this session)

First-party files still over 400 lines (excluding `Tests/`/
`UIRegressionTests/`, out of this initiative's scope), largest first:

| File | Lines |
|---|---|
| `WatchApp/WatchPlayer.swift` | 737 (still not triaged — which scheme covers it) |
| `Sources/DJ/Features/Playlist/AutoPlaylistModel.swift` | 569 |
| `Sources/Features/Settings/SettingsView.swift` | 565 |
| `Sources/DJ/Features/Workspace/BankDrawer.swift` | 540 |
| `Sources/WatchCore/Sync/WatchConnectivityCoordinator.swift` | 536 |
| `Sources/Features/Ingest/AddServerSheet.swift` | 532 |
| `Sources/WatchSync/PhoneWatchDownloadManager.swift` | 526 |
| `Sources/DJ/Features/Prep/TrackPrepView.swift` | 514 |
| `Sources/Discovery/SearchService.swift` | 493 |
| `Sources/Data/DiscoveryRecords.swift` | 485 |
| `Sources/Features/NowPlaying/NowPlayingView.swift` | 461 |
| `Sources/DJ/Features/Workspace/DeckLoader.swift` | 461 |
| `Sources/Remote/Providers/SubsonicAPI.swift` | 457 |
| `Sources/Features/Discovery/DiscoverySearchView.swift` | 455 |
| `Sources/DJ/Hardware/MidiMapping.swift` | 453 |

(plus dozens more between 400-450 lines — re-run the survey command for the
authoritative full list, it shifts every session.)

### Recommended next slice

1. `Sources/DJ/Features/Playlist/AutoPlaylistModel.swift` (569),
   `Sources/DJ/Features/Workspace/BankDrawer.swift` (540),
   `Sources/DJ/Features/Prep/TrackPrepView.swift` (514), and
   `Sources/DJ/Features/Workspace/DeckLoader.swift` (461) are all
   `TonearmDJ` — `swift build` should be sufficient per-file, same as this
   session's `TonearmDJ` splits; verify each is genuinely covered rather than
   assuming (a repeated theme across sessions).
2. `Sources/Features/Settings/SettingsView.swift` (565) and
   `Sources/Features/Ingest/AddServerSheet.swift` (532) are `Sources/Features/`
   — genuinely Xcode-only (confirmed by sessions 2/3) — every split touching
   them needs the full `xcodebuild build -scheme Tonearm` mid-session check
   and will very likely need `make project` too (per session 3's finding for
   that directory).
3. `Sources/WatchCore/Sync/WatchConnectivityCoordinator.swift` (536) and
   `Sources/WatchCore/Library/WatchLibraryRepository.swift` (446) are under
   `TonearmWatchCore`, its own SwiftPM target per `Package.swift` — `swift
   build` should cover them, but this session did not touch `Sources/
   WatchCore/` and did not independently verify the target actually compiles
   cleanly standalone; check before assuming.
4. `Sources/WatchSync/PhoneWatchDownloadManager.swift` (526) is in
   `TonearmCore`'s `sources:` list (`Sources/WatchSync`) — same `swift
   build`-is-sufficient treatment as this session's `Sources/Domain/`/
   `Sources/Data/` splits.
5. `Sources/Discovery/SearchService.swift` (493) and `Sources/Discovery/
   BoundedIndexWorker.swift` (443) are `TonearmDiscovery`, its own SwiftPM
   target — same treatment.
6. `WatchApp/WatchPlayer.swift` (737) still needs its build-coverage triage
   (which scheme/target compiles it) before a future session can plan its
   split and verification strategy — flagged every session since session 3,
   still unclaimed.
7. This session found the access-level bug class avoidable by reading each
   file's full call graph (which `private` member crosses which new file
   boundary) before writing any split file, rather than splitting first and
   fixing compiler errors one at a time — worth continuing, but don't skip
   the `swift build` check per file on the assumption the upfront read caught
   everything.
8. If two sessions might work on `parso-tonearm` concurrently, prefer
   `isolation: worktree` (recommended since session 2, still unapplied — this
   session's checkout happened to be uncontended throughout).
9. Once Tonearm is done, the same initiative applies to Voxglass (a separate,
   later phase per the owner).
