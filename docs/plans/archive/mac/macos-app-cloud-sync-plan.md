# macOS app + cloud-synced discovery index — implementation plan

Status: **ready for implementation**. Supersedes the "researched, not
planned" status of [`docs/plans/macos-indexing-sync-research.md`](macos-indexing-sync-research.md)
— read that file first for the background investigation; this file is the
actionable plan built on top of it, with the owner's decisions folded in and
several claims from that research pass corrected after reading the actual
code more closely (mainly: `CloudSyncEngine` is real but **not** fully wired
today — see §2).

Owner decisions locked in for this plan (2026-09-19):
- **Model/pipeline version mismatch → reject, requeue.** An incoming
  `discovery_embedding` (or `discovery_track_analysis`) record whose
  `modelVersion`/`preprocessingVersion`/`samplingVersion` doesn't match this
  device's currently-active pipeline version is never written locally. The
  local `discovery_index_job` for that track is reset to `queued` so this
  device re-indexes it itself and produces a compatible row.
- **Conflict resolution → local-device-wins, no overwrite.** If this device
  has *already* completed indexing a track (a local `discovery_embedding`
  row exists), an incoming remote embedding for that same track is always
  rejected outright — never overwrite completed local work with someone
  else's. Combined with the rule above: a remote embedding is accepted
  **only when** this device has not indexed that track yet **and** the
  remote embedding's pipeline version matches this device's own active
  version. That is the one case where a device benefits from another
  device's indexing work.
- **Mac is a real listening platform**, not just a faster indexing
  appliance (motivating case: headphones at work). This raises the bar from
  "runs the iOS binary" to "feels like a Mac app" — see §3.

Mockups: [`docs/plans/mockups/macos-app-mockups.html`](mockups/macos-app-mockups.html).

---

## 0. Two independent workstreams

This plan is two mostly-independent pieces of work that happen to share one
motivating request. Keep them as separate PRs/sessions:

- **§3 — the Mac app itself** (Catalyst target, windowing, CarPlay gating).
- **§2 + §4 — cloud sync of the discovery index** (finishing the core
  `CloudSyncEngine` wiring, then extending it with two new record types).

Sync work has value even before the Mac app exists (an iPhone can already
benefit from another iPhone's indexing today, in principle) and the Mac app
has value even without sync (a Mac-native listening surface for the
owner's existing library, streamed/local exactly like the iPhone build).
Ship whichever is ready first; don't block one on the other.

---

## 1. Phase 0 — spend an hour before spending a week

`project.yml`'s `Tonearm` target already sets
`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: "YES"` (line ~178). On Apple
Silicon, that means **the existing iOS binary, completely unmodified, is
already installable and runnable on macOS today** — no Catalyst target, no
code changes, nothing to build. This is not the same as Mac Catalyst: it's
the literal iOS app running via Apple's iOS-app-on-Mac compatibility layer,
in a resizable window, with a Dock icon.

Before investing in §3 (a real Mac Catalyst target), **do this first**:

1. Build and run the existing `Tonearm` scheme's Release archive (or a
   TestFlight build) on an Apple Silicon Mac — no project changes needed.
2. Actually listen through headphones at work for a few days on this
   as-is build. Note every rough edge: window can't be resized how you'd
   want, no menu bar Now Playing, keyboard media keys don't work, sidebar
   navigation feels wrong for a mouse/trackpad, whatever else.
3. Decide, informed by that list, whether §3's Catalyst investment (real
   menu bar, native window chrome, keyboard shortcuts, richer multi-column
   layout — see mockups) is worth it, or whether the Designed-for-iPad
   build is simply good enough for "headphones at work."

If CarPlay is going to be a problem, it will show up immediately: the
`CPTemplateApplicationScene` config in `Info.plist` simply won't match
anything on a Mac (no CarPlay connects to a Mac), so this should just be
inert, not broken — but verify rather than assume.

This phase costs almost nothing and might make §3 optional. **Do not skip
it because §3 looks more interesting to build.**

---

## 2. Phase 1 — finish `CloudSyncEngine`'s core wiring first

The research doc's claim that sync is "already solved" for `track`/`album`/
etc. is **half true**. What's genuinely solid:

- `Sources/Sync/RecordMapping.swift` — pure, tested `CKRecord ↔ GRDB row`
  mappers for `Source`/`Album`/`Track`/`Asset`/`Playlist`/`PlaylistItem`/
  `Favorite`/`PlayEvent`/`CustomArtwork`/`AppSettings`/`PlaybackState`, each
  keyed by a stable `syncID` UUID column (added in migration v7).
- `Sources/Sync/SyncGating.swift` — account/toggle gating logic.
- `Sources/Sync/SyncMerge.swift` — small pure merge helpers (last-write-wins
  by modified date, play-history merge, deletion application).

What's **not** done, read directly from `Sources/Sync/CloudSyncEngine.swift`
as of this plan:

- `enqueue(recordIDs:)` (the method that's supposed to tell `CKSyncEngine`
  about a local write) **is never called from anywhere in the app.** Grep
  confirms zero call sites outside the file itself. Nothing currently
  triggers an upload when a track/playlist/etc. changes locally.
- `nextRecordZoneChangeBatch` — the delegate method that's supposed to
  build the real `CKRecord` for each pending change via `RecordMapping` —
  instead returns a bare `CKRecord(recordType: "Placeholder", recordID:)`
  for every pending change. It does not call `RecordMapping.record(from:)`
  at all yet.
- `applyFetched(_:)` — the pull-path delegate method — only logs a count of
  fetched modifications/deletions. It does not decode via `RecordMapping`,
  does not call into `SyncMerge`, and does not write anything to the local
  database.

In short: the *mapping and gating* infrastructure this plan needs is real
and reusable, but the actual read/write plumbing that moves data through
`CKSyncEngine` needs to be built before extending it with two more record
types would do anything. **Build this first, as its own PR, with its own
test coverage, for the existing record types** — it's valuable
independent of the Mac/discovery-sync motivation (today, iCloud Sync's
toggle in Settings turns on an engine that doesn't actually sync anything).

### 2.1 What "finish the wiring" means concretely

- Call `CloudSyncEngine.shared.enqueue(recordIDs:)` after each local mutating
  write to a synced table. The natural place is `LibraryStore`'s insert/
  update/delete methods for the synced tables (`Source`, `Album`, `Track`,
  `Asset`, `Playlist`, `PlaylistItem`, `Favorite`, `PlayEvent`,
  `CustomArtwork`) — likely via a small internal hook so call sites don't
  all need to remember to do this by hand. Look at how `AppState.reload()`
  and `LibraryStore+Catalog.swift`'s insert methods are structured today.
- Implement `nextRecordZoneChangeBatch` to actually look up each pending
  record's underlying row (by the `Int64` id encoded in — or resolved from
  — the `CKRecord.ID`, since `RecordMapping.recordID(type:syncID:zoneID:)`
  embeds the type + `syncID` in the record name) and build the real record
  via the matching `RecordMapping.record(from:...)` function.
- Implement `applyFetched(_:)` to decode each modification via the matching
  `RecordMapping.<type>(from:)` function, resolve parent references (a
  `sourceSyncID`/`albumSyncID`/etc. on the decoded value) to local `Int64`
  ids via a `syncID → localId` lookup, apply `SyncMerge`'s last-write-wins
  logic where applicable, and upsert into `LibraryStore`. Handle deletions
  by resolving `syncID` and deleting the local row.
- Add integration test coverage (the file's own comments note this path is
  "networked; covered by integration tests, excluded from the unit job" —
  find or create that integration test target/config and actually populate
  it; today there appears to be no such coverage for this file at all).

Do not attempt to redesign `RecordMapping`/`SyncMerge`/`SyncGating` — they're
solid. This phase is purely "wire the engine to the mappers that already
exist."

---

## 3. Phase 2 — Mac Catalyst target

Only start this once Phase 0 has actually informed whether it's needed.

### 3.1 New target in `project.yml`

Add a `TonearmMac` target (or extend `Tonearm` with a second platform if
xcodegen's multi-platform target support fits better — check the xcodegen
version pinned in this repo first) with:
- `platform: macOS`, a `macOS` deployment target (pick something recent
  enough for `CKSyncEngine`, which needs iOS 17-equivalent macOS — macOS 14
  Sonoma).
- Same `sources`/`excludes` list as `Tonearm` today, **plus** excluding
  `CarPlay/**` under `#if !targetEnvironment(macCatalyst)` — unlike
  Designed-for-iPad, Mac Catalyst does not link CarPlay at all, so
  `Sources/App/CarPlay/*.swift` needs compile-time gating, not just runtime
  inertness. Wrap the CarPlay scene delegate class, its `Info.plist`
  scene-configuration entry, and `CarPlayRootBuilder`/
  `CarPlaySearchDelegate` in `#if !targetEnvironment(macCatalyst)`.
- `SUPPORTS_MACCATALYST: "YES"` (or use xcodegen's Catalyst target
  generation, whichever this project's xcodegen version supports more
  cleanly), `DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER: "NO"` if you want
  the same bundle ID as iOS (recommended — one App Store listing, one
  TestFlight, matches how `SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD` already
  ships as one universal binary today).
- Re-run `scripts/generate-project.sh` (`make project`) after editing
  `project.yml`, same as any other target change this session already did
  for `Sources/Tools/BuiltInEmbedder`.

### 3.2 UI work — native-feeling, not just "runs"

Per the owner's "real listening on headphones at work" requirement, treat
this as worth real polish, not a minimal compile pass. From the mockups
(`docs/plans/mockups/macos-app-mockups.html`):

- **Menu bar Now Playing** — a `NSMenu`/`MenuBarExtra`-equivalent (SwiftUI's
  `MenuBarExtra` works under Catalyst) showing the current track, transport
  controls, and a "Open Platterhead" action. This is the single highest-
  value addition for "listening in the background at work" — no need to
  keep the window frontmost.
- **Native window sizing** — the existing `RootView` tab-bar-at-bottom
  layout (Listen/My Music/Settings) is an iPhone pattern. On Mac, prefer a
  persistent sidebar (`NavigationSplitView`, which the codebase may not use
  yet — check `RootView.swift`) with the same three destinations, sized for
  a resizable window rather than a fixed phone aspect ratio.
- **Keyboard shortcuts + media keys** — Space to play/pause, arrow keys for
  seek/track skip, and confirm the existing `SystemPlaybackBridge`/
  `MPRemoteCommandCenter` wiring picks up macOS hardware media keys for
  free (it likely does, since that's the same API surface Catalyst maps
  keyboard media keys onto — verify, don't assume).
- **Now Playing in the Dock icon / Touch Bar** is optional polish, not
  required for v1.
- Leave `Sources/Features/*` mostly as-is where the phone layouts already
  read fine at a wider width (the design system's `glassSurface`/card
  patterns aren't iPhone-specific) — the sidebar/window-chrome is the real
  Mac-specific work, not a rewrite of every screen.

### 3.3 What to explicitly skip for v1

- Multiple windows / new-window-per-source — not requested, adds real
  complexity (window-scoped `@StateObject` vs the current
  single-`AppState`-instance assumption throughout the codebase).
- Full drag-and-drop file import redesign — the existing "Add Folder" flow
  can stay as-is; a native Finder drag-and-drop *would* be nice but is a
  separate, smaller follow-up, not blocking.
- Menu bar customization / preferences window as a separate `NSWindow` —
  reuse the existing `SettingsView` inside the main window for v1.

---

## 4. Phase 3 — sync the discovery index

Only after §2's core wiring is real. This is the piece the owner actually
asked for: "index on Mac, see results on the phone."

### 4.1 Schema migration

New migration (next available slot — `Sources/Data/Schema.swift` currently
lists through `v23`, so this is **`v24`**; add `"v24"` to that array and a
matching `DiscoveryMigrations.v24(_:)`, following the exact pattern of
`v18`/`v19`/`v20` in `Sources/Data/DiscoveryMigrations.swift`):

```swift
// Sources/Data/DiscoveryMigrations.swift
static func v24(_ db: Database) throws {
    try db.alter(table: "discovery_embedding") { t in
        t.add(column: "syncID", .text)
    }
    try db.create(indexOn: "discovery_embedding", columns: ["syncID"], options: .unique)

    try db.alter(table: "discovery_track_analysis") { t in
        t.add(column: "syncID", .text)
    }
    try db.create(indexOn: "discovery_track_analysis", columns: ["syncID"], options: .unique)
}
```

Existing local rows get a `syncID` backfilled (a `UUID().uuidString`, same
pattern `RecordMapping.record(from:)` already uses for the `?? UUID()...`
fallback on other types) either in this migration or lazily on first sync
attempt — check how the v7 `syncedTables` migration backfilled `syncID` for
pre-existing rows and match that approach exactly rather than inventing a
new backfill strategy.

This deliberately reverses the `DiscoveryMigrations.swift` header comment's
current claim that discovery tables are "intentionally NOT added to any
CloudKit/sync export list" — **update that comment** when this migration
lands, since it will no longer be accurate for these two tables
specifically (the other eight discovery tables — jobs, checkpoints, asset
state, etc. — stay device-local; only the two *result* tables sync).

### 4.2 `RecordMapping` additions

Two new `RecordType` cases and mapper pairs, following the exact shape of
the existing `track(from:)`/`record(from: Track, ...)` pair:

```swift
case discoveryEmbedding = "DiscoveryEmbedding"
case discoveryTrackAnalysis = "DiscoveryTrackAnalysis"
```

`record(from: DiscoveryEmbedding, trackSyncID: String?, zoneID:)` carries:
`syncID`, `trackSyncID`, `modelVersion`, `preprocessingVersion`,
`samplingVersion`, `dimensions`, `quantizedVector` (as `CKRecordValue` —
`Data`/blob is a native CKRecord field type, no extra encoding needed），
`scale`, `completedAt`. Mirror for `DiscoveryTrackAnalysis` with its own
scalar columns (`bpm`, `key`, `energy`, `phraseSummary`,
`analysisScopeSeconds`, `completedAt`, `analysisVersion`).

Do **not** sync `assetId`/`assetRevision` — those are local-file-identity
concepts (which physical file on *this* device produced the embedding) and
have no meaning on a receiving device; the receiving device resolves its
own `assetId` for the same `track` independently. This mirrors how
`RecordMapping.record(from: Asset, ...)`'s own doc comment already
explains omitting the local `bookmark` blob for the same reason (device-
specific data doesn't cross devices; C4 in that file's terms).

### 4.3 The accept/reject logic (owner's decisions, §"Owner decisions" above)

This is new logic, not a mechanical extension of `SyncMerge`'s existing
last-write-wins helper — the owner's rule is deliberately *not*
last-write-wins. Add a new pure function (test it directly, no CloudKit
needed, same pattern as the rest of `SyncMerge.swift`):

```swift
// Sources/Sync/SyncMerge.swift (or a new DiscoveryEmbeddingSync.swift
// alongside it, if keeping SyncMerge focused on the existing scalar-merge
// helpers reads better)
enum DiscoveryEmbeddingSyncDecision {
    case accept          // write the incoming record locally
    case rejectRequeue   // incompatible version: discard, requeue local job
    case rejectKeepLocal // already indexed locally: discard, no requeue
}

static func decide(
    incomingModelVersion: Int, incomingPreprocessingVersion: Int, incomingSamplingVersion: Int,
    activeModelVersion: Int, activePreprocessingVersion: Int, activeSamplingVersion: Int,
    localEmbeddingExists: Bool
) -> DiscoveryEmbeddingSyncDecision {
    let versionMatches = incomingModelVersion == activeModelVersion
        && incomingPreprocessingVersion == activePreprocessingVersion
        && incomingSamplingVersion == activeSamplingVersion
    guard versionMatches else { return .rejectRequeue }
    guard !localEmbeddingExists else { return .rejectKeepLocal }
    return .accept
}
```

Wire this into the pull path built in §2.1's `applyFetched(_:)`:
1. Decode the incoming `DiscoveryEmbedding`/`DiscoveryTrackAnalysis` record.
2. Resolve `trackSyncID → local trackId`. If unresolvable (track doesn't
   exist locally yet — e.g. this device hasn't imported that source), skip
   for now; there's nothing to attach the embedding to. (Whether to
   pre-fetch and hold pending embeddings for tracks that arrive later is an
   optimization, not required for v1 — re-fetching on the next sync pass
   after the track exists is simpler and correct, if slightly redundant.)
3. Look up this device's currently-active pipeline version — the existing
   `EmbeddingModelSpec`/pipeline-version constants `BoundedIndexWorker`
   already uses for its own `modelVersion`/`preprocessingVersion`/
   `samplingVersion` fields on write (grep
   `Sources/Discovery/BoundedIndexWorker.swift` for exactly where those
   version numbers come from — reuse the same source of truth, don't
   hardcode a second copy).
4. Check whether `discovery_embedding` already has a row for that local
   `trackId` (query, not merely "was there ever a job") — that's
   `localEmbeddingExists`.
5. Call `decide(...)`. On `.accept`, upsert into `discovery_embedding`
   keyed by the local `trackId`, and — critically — also upsert a matching
   `discovery_index_job` row with `state = "complete"` (mirroring exactly
   what `AppState+BuiltInMoodIndex.swift`'s built-in-index seeding already
   does for its own bundled vectors: "seeds a matching `.complete`
   `discovery_index_job` row per track" so the reconciler doesn't queue
   live re-indexing over a result that just arrived from sync). On
   `.rejectRequeue`, if a local `discovery_index_job` row exists for that
   track, reset its `state` to `"queued"` (via the same repository method
   `IndexJobRepository` already uses elsewhere to requeue — check for an
   existing "reset to queued" helper before writing a new one; if the job
   row doesn't exist yet, this is a no-op, since something will naturally
   discover the track needs indexing through the normal reconciliation
   sweep). On `.rejectKeepLocal`, do nothing.
6. After the vector actually changes for a track, trigger the same "vector
   index rebuild" hook `BoundedIndexWorker` (or its caller) already
   triggers when local indexing completes a track — search for where that
   happens on the local-completion path today rather than inventing a
   second rebuild trigger.

### 4.4 Push path

Symmetric to §2.1's `nextRecordZoneChangeBatch`: when a local
`discovery_index_job` transitions to `complete` (the real, local indexing
path — `BoundedIndexWorker.finalizeEmbeddingOutcome`, per this session's
earlier research into that exact function for the built-in mood index
work), call `CloudSyncEngine.shared.enqueue(recordIDs:)` with the new
embedding/analysis record IDs, same as any other synced-table write.

### 4.5 What NOT to sync (explicit, matching §4.1's updated header comment)

Everything else in `Sources/Data/DiscoveryMigrations.swift` stays
device-local: `discovery_asset_state`, `discovery_index_job` itself (a
device's own job queue/lease state has no meaning on another device — only
its *outcome*, the embedding, is shared), `discovery_window_checkpoint`
(mid-indexing scratch state), and anything else added since. Re-affirm this
explicitly in code review — it would be an easy mistake to sync the job
table by accident and have two devices fight over lease tokens.

---

## 5. Phase 4 — optional: faster Mac indexing (separate lever, not required)

Per the research doc's §8: indexing is deliberately pinned to
`executionContext: { .background }` → CPU-only, never GPU/ANE, specifically
for iPhone thermal reasons (`Sources/App/DiscoveryRuntimeController.swift`
lines ~63-80). A Mac has far more thermal headroom and more CPU cores even
under that same CPU-only policy — so Mac indexing should already be
meaningfully faster than iPhone indexing with **zero code changes**, purely
from more/faster CPU cores.

If indexing speed on Mac specifically is later found to be a bottleneck
worth addressing further (separate from this sync plan, and separate from
whether the Mac is plugged in or on battery), revisiting whether Mac
builds can safely use `.cpuAndGPU`/ANE — since a Mac's thermal envelope and
`ProcessInfo.thermalState` behavior differ substantially from an iPhone's —
is the next lever. That is genuinely separate research (thermal behavior
differs by chip, not just by "Mac vs iPhone"), not a natural extension of
this sync plan, and should not be bundled into the same PR.

---

## 6. Testing / acceptance criteria

- `swift test` stays green throughout (per `CLAUDE.md`'s hard rule — no
  Swift 6 concurrency shortcuts, no warning suppression).
- New unit tests for `DiscoveryEmbeddingSyncDecision.decide(...)` covering
  all three outcomes, matching `RecordMapping`/`SyncMerge`'s existing
  pure-function-first testing style (no live CloudKit needed for this
  logic).
- New unit tests for the `RecordMapping` additions (`record(from:)` /
  `discoveryEmbedding(from:)` round-trip), matching `RecordMappingTests`'
  existing pattern for other types.
- Integration test (the networked, excluded-from-unit-job category §2.1
  calls out) proving: index track A on device/simulator 1 → sync → device/
  simulator 2 receives a `discovery_embedding` row for the same track (by
  `syncID`) → device 2's mood search can find it without re-indexing.
  Also prove the reject-and-requeue path: seed device 2 with a
  `discovery_index_job` already `complete` for that track, push an
  incompatible-version embedding from device 1, confirm device 2's row is
  untouched and no requeue happens (`.rejectKeepLocal`); then prove the
  requeue path with device 2 *not* yet indexed and an incompatible version
  incoming (`.rejectRequeue` → job state becomes `queued`).
- Manual acceptance for §3 (Mac app): archive a Release build for the new
  Catalyst target, confirm CarPlay code is excluded from the build (not
  just inert) by checking the build log for `CarPlay/` under the Catalyst
  target's compiled-sources list — it should not appear at all.
- Manual acceptance for the whole feature, matching the owner's original
  ask verbatim: index a track on the Mac while working (headphones
  connected), then open the app on the iPhone and confirm that track shows
  up as indexed (findable by mood search) without the phone having
  downloaded or processed the audio itself.

---

## 7. Open questions genuinely still open

Everything the owner was asked has an answer folded into this plan. What's
left is implementation-detail judgment calls to make *during* the work,
not blocking decisions:

- Exact xcodegen syntax for a Catalyst target in this repo's pinned
  xcodegen version (multi-platform single target vs. a second target) —
  resolve by checking the installed xcodegen version and its docs at
  implementation time, not by guessing here.
- Whether to backfill `syncID` for existing `discovery_embedding`/
  `discovery_track_analysis` rows inside the v24 migration itself or lazily
  on first sync attempt — either is fine; match whatever v7's `syncID`
  backfill for the original synced tables did, for consistency.
- Whether pending-embeddings-for-not-yet-imported-tracks (§4.3 step 2)
  needs a proper pending queue or can just rely on the next periodic sync
  pass — start with "rely on the next pass" and only build a pending queue
  if that proves to lose data in practice (e.g. the remote record ages out
  of CloudKit's change window before the track finally gets imported
  locally — unlikely, but worth a code comment noting the assumption).
