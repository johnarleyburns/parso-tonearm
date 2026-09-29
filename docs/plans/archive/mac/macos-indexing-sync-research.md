# macOS build + cloud-synced sound index — research notes

Status: **researched, not planned**. Owner request: "study what a macos
version would look like that's both usable in general and lets us index BUT
keep the music index db synable to cloud (not the tracks just the music db)
so I can index on mac and see results on the phone if i want." This captures
findings so a future session can turn it into a real plan without
re-deriving the groundwork — it is not itself an implementation plan.

## 1. Mac Catalyst is realistic; CarPlay is the one real blocker

The app is a pure iOS target today (`project.yml`: `platform: iOS`
everywhere, `TARGETED_DEVICE_FAMILY: "1,2"`, no Mac Catalyst target). Adding
one is realistic — the one hard blocker found is CarPlay
(`Sources/App/CarPlay/CarPlaySceneDelegate.swift`, `CPTemplateApplicationScene`):
CarPlay APIs don't exist on Mac Catalyst, so that code needs
`#if !targetEnvironment(macCatalyst)` gating. Background audio/AVAudioSession
code should port with only minor adjustment. No other hard blockers
surfaced in this pass — re-verify at implementation time, this was not an
exhaustive line-by-line audit of every UIKit call site.

## 2. The hard sync problem is already solved

The instinct that "matching an embedding to the same song on another device"
is the hard part is correct in general, but **this codebase already solved
it** for other tables. `Sources/Sync/` has a working CloudKit engine
(`CloudSyncEngine.swift`, `RecordMapping.swift`) that already syncs `source`,
`album`, `track`, `asset`, `playlist`, `favorite`, `playEvent`,
`customArtwork` — each keyed by a UUID `syncID` column, added in migration
v7 specifically because "Int64 PKs aren't safe across devices." **`track`
rows already carry this stable cross-device `syncID`.** A new
embedding-sync feature just needs to key off the track's existing `syncID` —
no new identity scheme to design.

## 3. Why it doesn't sync today: a deliberate exclusion, not a gap

`Sources/Data/DiscoveryMigrations.swift`'s own header comment: *"All ten
tables here are device-local derived state: they are intentionally NOT
added to any CloudKit/sync export list... None of them gained a `syncID`
column."* `discovery_embedding` and `discovery_track_analysis` — the two
tables that actually matter for this feature — currently have **no**
`syncID` at all. Reversing this is a deliberate decision to make and
document, not filling in an oversight.

## 4. Size estimate

Embeddings are 512-dim, int8-quantized (confirmed via this session's own
recall-gate test logs: "dims 512", int8) → roughly 512 bytes/track for the
vector plus ~8 bytes for `scale` ≈ **520 bytes/track**.
`discovery_track_analysis` (bpm/key/energy/phrase — small scalars) is well
under 200 bytes/track. Combined, **~700 bytes/track** — a 20,000-track
library syncs to roughly **14 MB total**. Trivially inside CloudKit's
per-record (~1MB) and per-user quota limits, especially structured as one
small record per track rather than one giant blob.

## 5. Recommendation: extend the existing CloudKit engine

Don't stand up a second, parallel sync mechanism (e.g. a shared iCloud Drive
file). The `RecordMapping`/`CloudSyncEngine`/`syncID` pattern already
exists, is tested, and is keyed correctly by track identity — adding two new
`CKRecord` types (`discoveryEmbedding`, `discoveryTrackAnalysis`) keyed by
the track's own `syncID` is a natural, small extension of infrastructure
that's already there, not new architecture.

## 6. Rough sync-flow sketch (not a spec)

1. Add a `syncID` column to `discovery_embedding` and
   `discovery_track_analysis` — a real schema migration.
2. Extend `RecordMapping` with the two new record types, keyed by the
   track's existing `syncID` (a lookup, not a new generator).
3. On write (indexing completes a track locally), enqueue a CloudKit upload
   for that record, same pattern the existing synced tables already use.
4. On the receiving device, when an incoming embedding record's `syncID`
   resolves to an already-known local `track` row, upsert into
   `discovery_embedding` keyed by the LOCAL `trackId` (translated via
   `syncID → trackId`, mirroring however the existing sync engine does this
   translation for `track` itself), then trigger a vector-index rebuild.

## 7. Open questions a real plan must resolve

- **Model/pipeline-version mismatches across devices.** A Mac indexing with
  a newer CLAP model than an iPhone has downloaded — should the phone reject
  an incompatible embedding, or trigger its own model download? Needs a
  real decision, not an assumption.
- **Conflict resolution.** If two devices independently re-index the same
  track (e.g. after a pipeline version bump on each), should the newer
  write always win (last-write-wins, matching typical CloudKit sync
  semantics), or does something more careful need to happen given
  embeddings are derived data, not user data?
- **Whether "usable in general" on macOS is actually wanted independent of
  the indexing motivation** — the CarPlay-gating work is needed either way;
  worth confirming the Mac build is valued as a real listening platform too,
  not purely as a faster indexing appliance, since that changes how much UI
  polish (vs. a minimal Catalyst pass) is worth investing.

## 8. Related, separately-researched context

`docs/plans/mood-based-listening-plan.md`'s own §8.1/earlier research found
indexing is deliberately pinned to CPU-only, never GPU/ANE, for thermal
reasons (see `DiscoveryRuntimeController.swift`'s `executionContext`
comment). A Mac would help even under that same CPU-only policy — faster
raw CPU cores, and far more thermal headroom before `ProcessInfo
.thermalState` escalates — without needing to touch that policy at all. If
Mac indexing speed alone (not sync) is the goal, revisiting the CPU-only
restriction is a separate, likely higher-leverage lever than a Mac build.
