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
