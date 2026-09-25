# Camelot/BPM matching and DJ Crate — implementation plan

Status: implemented and audited on 2026-09-25

## 1. Outcome

Add one tested musical-match policy and use it consistently when the user asks
for DJ-compatible results:

- a candidate must have an analyzed BPM within ±8% of the reference BPM;
- its Camelot key must be one of the four compatible keys: the same code, the
  same letter at the adjacent wheel number above or below (wrapping 12↔1), or
  the same number with the A/B relative-key switch;
- missing BPM or key never qualifies as a match;
- ordinary search, mood search, and Keep Playing retain their existing
  non-matching behavior when the option is off.

Add a built-in playlist grouping named **Crate**. Crate is a virtual DJ
grouping for playlists, with the detail text “Crate is where you put playlists
for DJing”. A playlist can be added to or removed from Crate without changing
its tracks or its normal playlist identity.

Add **Sort by BPM order** to playlist edit mode. It sorts the current playlist
ascending by analyzed BPM, puts tracks without a BPM at the end, and uses the
existing order as the stable tie-breaker. The new order is persisted as normal
playlist-item positions.

## 2. Existing code to reuse

- `ParsoAudioAnalysis.Camelot.compatible` already implements the four requested
  Camelot relationships and wheel wraparound.
- `SearchRepository.hardFilterClause` already performs hard Camelot filtering
  for the existing compatible-key search field.
- `SearchService` and `DiscoverySearchCoordinator` are the shared retrieval
  path for semantic search, similar-track search, mood search, saved queries,
  and candidate retrieval.
- `DiscoveryTrackAnalysis` stores the persisted BPM and Camelot key.
- `AudioPlayer+KeepPlaying` already has explicit fallback states; matching
  failure must use those states rather than silently producing an empty queue.
- `PlaylistEditor` already provides deterministic position normalization and
  `LibraryStore` already persists playlist-item reorders atomically.
- `Playlist` already participates in the domain model, database records, and
  CloudKit mapping. Crate membership will be a playlist property so it follows
  the same identity/sync path instead of introducing a second unsynced graph.

## 3. Data and policy design

### 3.1 Musical match policy

Add a portable `MusicalMatchPolicy` in the discovery target. It owns:

- `bpmToleranceRatio = 0.08`;
- `compatibleKeys(reference:)`, delegating to `Camelot.compatible`;
- a guarded relative-BPM range, rejecting non-finite or non-positive values;
- `matches(candidateBPM:candidateKey:referenceBPM:referenceKey:)`;
- SQL-friendly bounds and compatible-key codes for repository filtering.

The policy is pure and independently tested at exact boundaries, wheel
wraparound, A/B relative keys, missing values, invalid values, and values just
outside the 8% boundary.

### 3.2 Search reference plumbing

Keep `DiscoverySearchQuery` Codable and reusable for ordinary saved searches.
Do not encode a device-local reference track ID into the saved query. Add a
runtime-only search option/reference argument through `DiscoverySearchService`
and `DiscoverySearchCoordinator` instead.

`SearchService.search` will accept an optional matching reference ID and a
`matchingTracksOnly` flag. Similar-track mode will use its existing reference
as the matching anchor when the flag is enabled; semantic mood/search mode can
use a separate anchor while preserving the text/refinement query.

The repository will apply the policy before semantic top-K truncation, so a
valid matching track cannot be hidden by an unrelated semantic shortlist.
When the reference lacks BPM or key, the response will expose a distinct
“matching reference unavailable” state. The UI will explain that analysis is
needed rather than treating unknown metadata as a match.

### 3.3 Track analysis access

Reuse `SearchRepository.TrackAttributes` for discovery matching. Add the
smallest core-side BPM lookup needed by playlist sorting, or expose a shared
`TrackAnalysisSummary` on hydrated rows if that is required by the existing
row UI. Do not fabricate BPM/key values for unanalysed tracks.

## 4. Feature behavior

### 4.1 Mood

The Listen mood model keeps its prompt and selected mood refinements. When a
currently playing analyzed track exists, it submits the same semantic mood
query with that track as a musical-match anchor. This preserves the mood
meaning while narrowing candidates to mixable tracks. Mood queues refresh
against the most recently played anchor as they extend.

If there is no usable anchor, mood search remains available without the hard
match constraint. If the constrained query returns no matches, it reports the
state explicitly and uses the existing honest queue fallback rather than
creating dead air.

### 4.2 Keep Playing

Add an AppStorage-backed, default-on **Select matching tracks** setting next to
Keep Playing. Thread it through `AppState`, `AudioPlayer`, the provider seam,
and `DiscoveryRuntimeController`.

When enabled, the provider asks `SearchService` for sound-similar candidates
with the exact Camelot+BPM match gate. When disabled, it preserves the current
CLAP similar-track behavior. If matching candidates are unavailable, the
existing visible fallback chain remains: broader sound similarity, then the
same-scope shuffle fallback, with the reason surfaced in the queue UI.

The queue extension must continue excluding history, queued tracks, and the
reference track. Tests cover both setting states, matching candidates,
unknown analysis, no matches, and in-flight extension/resume behavior.

### 4.3 Search

Add a **Matching tracks** toggle to the Find Music screen when a reference
track is active. It is opt-in for generic search and can be enabled from the
existing “More like this” context. The toggle reruns the same query through the
shared service and displays a clear empty/unavailable state.

The result path remains useful for DJ playlist building: text/refinement
search still ranks semantically, while the toggle hard-gates BPM and Camelot
compatibility before ranking.

### 4.4 Playlist BPM sorting

Add a PlaylistEditor sort operation that preserves the current order for ties,
places nil BPM after known BPM, renumbers positions, and leaves the playlist
items otherwise unchanged. Add a store/AppState operation that persists the
entire order in one database write.

Expose **Sort by BPM order** from playlist edit mode. The visible list updates
optimistically, then reloads from the store. The action is disabled or clearly
explained when no tracks have analyzed BPM values.

## 5. Crate grouping

### 5.1 Persistence

Add `Playlist.isInCrate` with a default of `false` to the domain model and the
playlist table in a new migration. Register it in the schema migration order,
add the GRDB record field, and include it in CloudKit playlist mapping so Crate
membership follows the existing playlist record across devices.

The migration must preserve every existing playlist and be covered by schema
migration tests.

### 5.2 UI

- Add a Crate row at the top of Playlists with a crate icon and the explanatory
  detail text.
- Add `CrateDetailView` showing only playlists where `isInCrate` is true.
- Add “Add to Crate” / “Remove from Crate” actions to playlist context menus and
  the playlist detail overflow menu.
- Keep playlist navigation, rename, pin, delete, download, and track editing
  behavior unchanged.
- Show an honest empty state explaining that Crate is for DJing playlists.

## 6. Tests

Add or extend tests for:

- pure Camelot/BPM policy, including 8% boundary precision and wheel wrap;
- SearchRepository eligibility and SearchService semantic/similar matching;
- coordinator/view-model propagation of matching mode;
- MoodQuerySource refresh with and without an anchor;
- Keep Playing setting propagation, filtering, fallback, and exclusions;
- playlist BPM sorting, nil placement, tie stability, and persistence;
- v26 schema migration and playlist record round-trip with `isInCrate`;
- Crate membership add/remove and filtering;
- UI-facing accessibility identifiers and copy for Crate and matching controls.

## 7. Audit loop and acceptance criteria

After implementation, audit every requirement in this document against the
diff, not just the tests. Fix any missing wiring, stale comments, platform
conditionals, or behavior that silently broadens a requested match. Repeat
until the audit has no open gaps.

Acceptance requires:

1. `swift test` and the repository CI/guardrail command pass.
2. Matching is deterministic, shared, and hard-gated when selected.
3. Unknown analysis never qualifies as a match and never displays a fake BPM.
4. Mood, Keep Playing, and Search all exercise the same policy.
5. Crate membership survives persistence and CloudKit mapping.
6. BPM sorting is ascending, stable, persistent, and visibly available in edit
   mode.
7. The final audit records no unresolved plan-to-code gaps.

## 8. Final implementation audit

The plan was checked against the implementation after the first test/build
pass. The audit found and closed three gaps before this status was marked
complete:

1. The initial Keep Playing implementation went directly from a failed
   Camelot/BPM gate to shuffle. It now retries ordinary CLAP similarity and
   records `readyFromBroaderSimilarity` / `matchingUnavailable`, with the
   reason shown in Up Next before the same-scope shuffle fallback.
2. Crate playlist rows initially used a visible `NavigationLink` around a row
   that already draws its own chevron. They now use the established invisible
   navigation-link/ZStack pattern, avoiding duplicate chevrons and duplicate
   accessibility elements.
3. BPM sorting was initially always enabled in the playlist overflow menu.
   It now checks for real analyzed BPM data and disables the action, with an
   accessibility explanation, when none is available.

The final wiring is present in `MusicalMatchPolicy`, `SearchRepository`, and
`SearchService`; the runtime-only anchor travels through
`DiscoverySearchCoordinator` and `DiscoverySearchViewModel`. Mood uses the
currently playing track and advances that anchor as Keep Playing advances.
Keep Playing defaults to matching enabled but exposes the setting in
`AppStorage`; Search exposes an opt-in toggle from More Like This. Unknown
BPM/key values are excluded and produce an explicit unavailable state.

Crate membership is persisted by the v26 migration, GRDB playlist record,
CloudKit mapping, AppState/store actions, and the Playlists/Crate UI. The
playlist BPM sort is stable, ascending, places unknown BPM last, and persists
positions in one transaction.

Verification completed:

- `make ci-guards`
- full `swift test`: 1,278 tests passed, 12 existing environment-dependent
  tests skipped, 0 failures
- `xcodebuild -project Tonearm.xcodeproj -scheme TonearmMac ... build`
- `xcodebuild -project Tonearm.xcodeproj -scheme Tonearm ... build`
- `git diff --check`

No unresolved plan-to-code gaps remain.
