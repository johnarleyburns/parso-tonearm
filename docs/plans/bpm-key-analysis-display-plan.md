# BPM and key analysis display plan

Status: **researched; ready for implementation review**.

Scope: expose analyzed BPM and musical key in Now Playing, My Music, and Playlists. This plan
does not build a new audio-analysis engine. It connects the analysis that already exists in the
discovery index to the library row model and the shared SwiftUI presentation surfaces.

## 1. Executive decision

Reuse the existing native `ParsoAudioAnalysis` pipeline as the canonical inferred-metadata source.
Add one optional, presentation-neutral analysis summary to `TrackRow`, hydrate it from
`discovery_track_analysis`, and render it through the existing shared track-row component.
Now Playing gets a compact copy of the same summary.

The first user-facing format should be:

```text
128.0 BPM · 8A
```

`8A` is the Camelot code for the DJ workflow. The accessible/detail label should expand it to
the human-readable key, for example `A minor, Camelot 8A`.

Unknown values must remain unknown. Do not display a fabricated BPM fallback, stale analysis
from a different asset revision, or a key with no valid normalization.

## 2. Research findings

### 2.1 The analyzer already exists in this repository

The current indexer already has a real musical-analysis stage:

- [`DiscoveryTrackAnalysis`](../Sources/Data/DiscoveryRecords.swift) stores `bpm`, `key`,
  `energy`, phrase information, the analyzed asset revision, and the analysis scope.
- [`DiscoveryMigrations`](../Sources/Data/DiscoveryMigrations.swift) creates the
  `discovery_track_analysis` table.
- [`BoundedIndexWorker`](../Sources/Discovery/BoundedIndexWorker.swift) reads audio, constructs
  `AnalysisAudio`, runs `FullAnalysis.run`, converts the detected key to a Camelot code, and
  persists the result.
- `Package.swift` already links the `ParsoAudioAnalysis` product from the local
  `parso-audio-engine` package checkout.

The current persistence path is therefore not the blocker. The main missing path is:

```text
discovery_track_analysis
        ↓
LibraryStore.hydrate / search materialization
        ↓
TrackRow
        ↓
TrackRowView / NowPlayingView
```

### 2.2 The package choice is already the right one

`parso-audio-engine` is a native Swift package with offline BPM, key, structure, waveform, and
loudness analysis. It uses an Accelerate-backed pipeline and is already part of this project.
There is no reason to add a second DSP dependency for this feature.

Apple's `AVFoundation` metadata APIs can read embedded ID3 BPM and initial-key tags, but those
are file-provided metadata rather than inferred analysis. They are useful as an optional fallback
or provenance source, not as a replacement for the existing analyzer.

Apple's `SoundAnalysis` framework is for sound classification, not general musical BPM/key
estimation. Essentia is technically viable but introduces AGPL licensing, so it should not be
added when the existing native package is available.

### 2.3 Accuracy and scope constraint

The current worker analyzes at most 60 seconds centered on the track midpoint. This is a
deliberate indexing budget, especially for remote assets. It means the first implementation
should describe the result as analyzed/inferred metadata, not as a hand-verified full-track
annotation.

The existing row already records `analysisScopeSeconds`, and the result is tied to
`assetRevision`. Those fields should remain part of the validity decision.

## 3. Data model and persistence

### 3.1 Add a UI-facing summary type

Add a small value type near `TrackRow`, or in the shared domain layer if the app's target layout
requires it:

```swift
public struct TrackAnalysisSummary: Equatable, Sendable {
    public var bpm: Double?
    public var camelotKey: String?
    public var musicalKey: String?
    public var bpmConfidence: Double?
    public var keyConfidence: Double?
    public var source: Source
    public var analysisVersion: Int
    public var assetRevision: Int64
    public var scopeSeconds: Double?
    public var completedAt: Date?

    public enum Source: String, Sendable {
        case inferred
        case embeddedMetadata
    }
}
```

The exact placement can follow the current target boundaries, but UI code should not depend
directly on the GRDB record type. The summary is the stable presentation contract.

### 3.2 Attach it to `TrackRow`

Update [`TrackRow`](../Sources/Data/LibraryStore.swift) with:

```swift
public var analysis: TrackAnalysisSummary?
```

Keep it optional. A track can be present, playable, and searchable before analysis is complete.
Existing initializers and test fixtures should default it to `nil` so this remains source-safe for
callers that do not need analysis.

### 3.3 Validate the row before exposing analysis

`LibraryStore.hydrate` should only attach a row when the analysis matches the current playable
asset:

1. Fetch the selected/current `Asset` as it does today.
2. Fetch `DiscoveryTrackAnalysis` by `trackId`.
3. Require matching `assetId` and `assetRevision`.
4. Require the current musical-analysis pipeline version.
5. Convert the stored Camelot key to the display model.
6. Return `nil` for incomplete, stale, or invalid analysis.

Do not make display code repeat these validity checks.

### 3.4 Confidence and provenance migration

The current table stores BPM and key but not confidence or provenance. Before presenting the
values as authoritative, add a new schema migration after the repository's current latest
migration. The migration should add nullable columns such as:

- `bpmConfidence`
- `keyConfidence`
- `analysisSource`
- `analysisWindowStartSeconds`

`analysisScopeSeconds` already exists and should be reused.

The source should remain `inferred` for `FullAnalysis.run` results. If embedded metadata fallback
is implemented later, it should write `embeddedMetadata`, never silently overwrite an inferred
result of the same asset revision.

If the pinned `ParsoAudioAnalysis` version exposes key confidence but not BPM confidence through
`FullAnalysisResult`, make that a small upstream API addition first: expose the selected tempo
candidate's confidence in the full-result value. Do not invent a BPM confidence score in the app
from an unrelated heuristic.

### 3.5 Optional embedded-metadata fallback

Treat this as a follow-on, not a prerequisite for the first UI pass:

1. Extend the normalized metadata path to recognize BPM and initial-key tags.
2. Normalize an embedded key to the same Camelot representation used by inferred analysis.
3. Persist the fallback with `analysisSource = embeddedMetadata` and the current asset revision.
4. Replace it when a successful inferred analysis completes.

This can improve first-display latency for tagged files, but it must not create two competing
truths in the UI.

## 4. Analysis pipeline changes

### 4.1 Preserve current bounded indexing behavior initially

Keep the current 60-second midpoint window for the first implementation. It is already bounded,
remote-aware, resumable, and covered by worker tests.

Update the commit path in `BoundedIndexWorker` to persist the new confidence/provenance/window
fields once the analysis package exposes the required values.

The worker must continue to write nullable values when analysis cannot determine BPM or key.
Unknown BPM is not `120`; unknown key is not a guessed Camelot code.

### 4.2 Add an explicit full-track analysis path later

If user testing shows midpoint analysis is insufficient for DJ preparation, add a separate
full-track or multi-window consensus job rather than silently changing the indexing budget.

That later job should:

- run at lower priority than normal playback;
- be available on demand from track details or a preparation surface;
- use multiple windows or a full decode depending on asset type;
- record its scope and algorithm version;
- replace the bounded result only when it has a higher-quality provenance policy.

This is not required for the first display milestone.

## 5. Library and search plumbing

### 5.1 Central hydration

Update `LibraryStore.hydrate` so the following existing consumers receive the summary without
separate UI-specific queries:

- My Music songs and group-detail views
- playlist detail rows
- recently played/favorite rows that use `TrackRow`
- catalog lookup by track ID

The playlist path already hydrates playlist items through the library store, so this should be a
single data-layer change rather than a playlist-specific implementation.

### 5.2 Search result materialization

`SearchRepository` already joins `discovery_track_analysis` for BPM/key filtering and ranking.
Update its `TrackRow` materialization to attach the same validated summary used by
`LibraryStore.hydrate`. There must be one formatting and validity policy for ordinary library
rows and search results.

### 5.3 Sync and cross-device behavior

The analysis outcome already has CloudKit sync support through the discovery analysis record.
Keep the asset revision and analysis version in the acceptance rules so a stale Mac result cannot
replace a newer local result.

When an incoming analysis row is accepted, invalidate the affected track row. Do not require a
full library reload for one completed analysis.

## 6. UI implementation

### 6.1 Shared formatter

Add a pure formatter/presentation helper, for example `TrackAnalysisDisplay`, with these rules:

- BPM: one decimal place for DJ consistency, e.g. `128.0 BPM`.
- Primary key: Camelot code, e.g. `8A`.
- Detail/accessibility key: human-readable musical key plus Camelot code.
- Both values present: `128.0 BPM · 8A`.
- BPM only: `128.0 BPM`.
- Key only: `8A`.
- Neither present: no analysis chip/subtitle.
- Low-confidence or invalid values: follow the chosen threshold policy; otherwise show an honest
  unavailable state rather than a guessed value.

The formatter should be unit-testable without SwiftUI.

### 6.2 Now Playing

Update [`NowPlayingView`](../Sources/Features/NowPlaying/NowPlayingView.swift) near the existing
title/artist metadata or quality row:

- show the compact analysis line below artist metadata;
- keep it visually secondary to title and artist;
- include a VoiceOver label such as “128 BPM, A minor, Camelot 8A”;
- show no value for an unanalyzed track;
- optionally show `Analyzing…` only when the current track is actively queued/running, not as a
  permanent placeholder.

Now Playing may need a track-row lookup or a small analysis lookup keyed by the current track ID.
Prefer subscribing to the same app-state invalidation used by the library instead of polling.

### 6.3 My Music and shared track rows

Update [`TrackRowView`](../Sources/Features/Components.swift) to append the formatter output to
the existing subtitle. Preserve duration/codec/unsupported-reason text and use a separator that
remains readable at compact widths.

Example:

```text
4:12 · FLAC · 128.0 BPM · 8A
```

On narrow layouts, allow the analysis portion to truncate after the existing title/subtitle
truncation policy. Do not create a second song-row design only for analyzed tracks.

### 6.4 Playlists

Playlist detail already renders the shared track-row component. Once playlist hydration carries
the summary, the same analysis line should appear automatically in playlist rows.

Do not add BPM/key columns, sorting, or filtering to playlists in this first display milestone.
Those are useful DJ features but would expand the scope beyond displaying the analysis result.

## 7. Refresh and state propagation

The worker currently commits analysis directly to the database. A completed commit therefore
needs an explicit UI refresh signal.

Add a lightweight analysis invalidation channel with either:

- a monotonically increasing analysis revision plus affected track IDs; or
- a publisher/async stream of `AnalysisChange(trackID:)` events.

The event should be emitted for:

- local analysis completion;
- accepted CloudKit analysis result;
- asset replacement that invalidates a previous result.

Consumers should refresh only affected rows. The fallback behavior can be a normal AppState
reload if the existing architecture makes a targeted update impractical, but a full-library
reload should be treated as the temporary implementation rather than the final design.

## 8. Implementation phases

### Phase 0 — Confirm package API and fixtures

- Verify the exact `FullAnalysisResult` fields available from the pinned package.
- Confirm the selected tempo confidence can be exposed without an app-local guess.
- Identify a small set of real audio fixtures covering constant tempo, half/double-tempo
  ambiguity, minor/major keys, silence, and unsupported/corrupt files.
- Record the current pipeline version and define the display confidence thresholds.

Exit criteria: the result contract and fixture expectations are written down before schema work.

### Phase 1 — Persistence contract

- Add the analysis confidence/provenance/window migration.
- Extend `DiscoveryTrackAnalysis` and record mapping.
- Update `BoundedIndexWorker` commit code.
- Add migration and record round-trip tests.
- Add worker assertions for revision matching and nullable unknown values.

Exit criteria: analysis results are durable, versioned, and distinguish inferred from fallback
metadata.

### Phase 2 — Track-row hydration

- Add `TrackAnalysisSummary`.
- Add optional `analysis` to `TrackRow`.
- Centralize the validity check.
- Update `LibraryStore.hydrate`.
- Update search-result materialization.
- Add tests for fresh, stale, wrong-asset, wrong-version, partial, and valid analysis rows.

Exit criteria: every normal library/search/playlist row gets the same optional summary.

### Phase 3 — Formatting and shared rows

- Add the pure formatter.
- Update `TrackRowView`.
- Add snapshot or view-model tests for every nil/partial/complete/low-confidence state.
- Verify compact-width truncation and accessibility labels.

Exit criteria: My Music and Playlists display identical analysis treatment.

### Phase 4 — Now Playing

- Resolve the current track's validated analysis summary.
- Add the compact analysis line to Now Playing.
- Subscribe to analysis invalidation.
- Test that the display updates after an analysis commit without changing playback state.

Exit criteria: the currently playing track gains BPM/key when analysis becomes available and
removes stale values after asset replacement.

### Phase 5 — Sync and refresh hardening

- Emit local completion events.
- Wire accepted incoming analysis records to targeted invalidation.
- Test local-vs-incoming revision conflict behavior.
- Verify Mac-produced results can be displayed on iPhone after sync without re-decoding the audio.

Exit criteria: analysis behaves as a synced derived outcome, not a device-local UI cache.

### Phase 6 — Optional metadata fallback and full-track refinement

- Add embedded BPM/key fallback only if first-display latency warrants it.
- Add on-demand full-track/multi-window analysis only after real fixture and user testing show
  bounded midpoint analysis is insufficient.

Exit criteria: optional enhancements do not change the canonical display contract or introduce
stale/guessed values.

## 9. Tests and acceptance criteria

### Unit tests

- `TrackAnalysisSummary` conversion and asset/version validity.
- Camelot-to-human-key display mapping.
- BPM formatting and partial-result formatting.
- Confidence threshold policy.
- Migration and `DiscoveryTrackAnalysis` Codable/GRDB round trip.
- Worker persistence for valid, unknown, unsupported, and stale results.
- `TrackRow` hydration for all validity cases.
- Search-result materialization matches library hydration.
- Invalidation targets only affected track IDs.

### Integration tests

1. Import a fixture.
2. Run the discovery worker.
3. Verify `discovery_track_analysis` contains BPM/key.
4. Hydrate the track through the library store.
5. Verify My Music and playlist row presentation.
6. Set the track as current playback.
7. Verify Now Playing presentation.
8. Replace the asset and verify the old analysis disappears until the new revision completes.

### Acceptance criteria

- A valid analyzed track displays BPM and key in Now Playing, My Music, and Playlists.
- All three surfaces use the same canonical values and formatting.
- An unanalyzed or unsupported track never displays a guessed BPM/key.
- A result from the wrong asset revision is never displayed.
- Existing BPM/key search filters continue to work.
- Analysis completion refreshes visible UI without restarting the app.
- Synced analysis can be displayed on another device after revision/version validation.
- Playback and library performance are not degraded by per-row audio work or repeated full-library
  queries.

## 10. Files expected to change

Likely app changes:

- `Sources/Data/LibraryStore.swift`
- `Sources/Data/DiscoveryRecords.swift`
- `Sources/Data/DiscoveryMigrations.swift`
- `Sources/Data/RecordMapping.swift` or the current discovery record mapping file
- `Sources/Discovery/BoundedIndexWorker.swift`
- `Sources/Discovery/SearchRepository.swift`
- `Sources/App/AppState.swift`
- `Sources/App/DiscoveryRuntimeController.swift`
- `Sources/Features/Components.swift`
- `Sources/Features/NowPlaying/NowPlayingView.swift`
- Playlist/library presentation tests

Possible upstream package change:

- `parso-audio-engine`'s public full-analysis result, only if BPM confidence is not currently
  exposed.

No separate analyzer, service, or third-party copyleft dependency should be introduced.

## 11. Research sources

- [Parso Audio Engine](https://github.com/johnarleyburns/parso-audio-engine) — existing MIT Swift
  package and offline analysis pipeline.
- [AVMetadataKey.id3MetadataKeyBeatsPerMinute](https://developer.apple.com/documentation/avfoundation/avmetadatakey/id3metadatakeybeatsperminute)
  — embedded ID3 BPM metadata.
- [Retrieving media metadata](https://developer.apple.com/documentation/avfoundation/retrieving-media-metadata)
  — AVFoundation metadata access model.
- [Apple SoundAnalysis](https://developer.apple.com/documentation/soundanalysis) — classification
  framework, not the recommended BPM/key inference path.
- [Essentia rhythm extractor](https://github.com/MTG/essentia/blob/master/src/algorithms/rhythm/rhythmextractor2013.cpp)
  — technically relevant alternative, rejected here because of AGPL licensing.
