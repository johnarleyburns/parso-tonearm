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
