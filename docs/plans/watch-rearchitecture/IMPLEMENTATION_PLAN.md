# Platterhead Watch App — SwiftData / iPhone-Only Sync Rearchitecture

Status: **adopted; Phases 1–5 complete; Phase 6 next**

Priority: **highest active product priority**

Replaces: `docs/plans/watch-app.md` and the current GRDB watch implementation

Mockups: [`mockups/index.html`](mockups/index.html)

Acceptance suite: [`ACCEPTANCE_MATRIX.md`](ACCEPTANCE_MATRIX.md)

## 0. Instructions to the implementing agent

Read this entire document, then `CLAUDE.md`, `TONEARM-TEST-ARCHITECTURE.md`,
`current_status.md`, and `ACCEPTANCE_MATRIX.md` before changing code. Open every
mockup from `mockups/index.html`. Do not perform new product or architecture research;
the decisions below are closed unless an Apple API proves unavailable in the selected
SDK. If that happens, record the exact compiler/runtime evidence in this plan and choose
the smallest compatible implementation that preserves the product behavior.

Work on `main`; do not create a branch. One phase equals one commit unless a phase
explicitly defines subcommits. Never push without asking the owner. Preserve unrelated
working-tree changes. Regenerate the committed Xcode project with `make project` after
adding/removing sources or changing `project.yml`. Swift 6 complete concurrency and zero
new warnings are hard gates.

At the end of every phase:

1. Reread that phase and its acceptance rows.
2. Run every listed automated gate.
3. Perform the listed simulator checks.
4. Update this document's Implementation Audit and `current_status.md` with facts,
   counts, failures, and deferred physical-device work.
5. Commit the phase on `main`, respecting repository hooks.
6. Stop. Do not begin the next phase in the same turn unless the owner explicitly asks.

No phase may claim success from simulator-only WatchConnectivity behavior when its gate
requires a paired physical iPhone and Apple Watch.

## 1. Corrected decisions from the research proposal

These corrections are normative.

### 1.1 SwiftData scope

The **watch** is rearchitected around SwiftData. The iPhone's mature GRDB library remains
the authoritative catalog. Migrating the entire iPhone library from GRDB to SwiftData is
unrelated to watch reliability, would endanger the app's FTS, remote-library, CloudKit,
playlist, analysis, and DJ paths, and is not part of this plan.

The iPhone may continue its existing CloudKit behavior. The watch may not. Phone-to-watch
sync is an explicit projection from GRDB records into versioned DTOs.

### 1.2 Connected playback is remote playback

WatchConnectivity is not a real-time audio transport. In connected mode, search and
library commands execute on the iPhone and playback defaults to the iPhone's existing
`AudioPlayer`; the watch is a remote control and reflects the phone's now-playing state.
Audio follows the iPhone's selected route.

To hear audio from headphones paired to the watch, the track must exist as a validated
local watch file. A connected watch may ask the phone to download/transfer it, but playback
begins only after installation completes. Do not stream audio bytes through `sendMessage`,
run a hidden HTTP server on the phone, or expose credentials/remote URLs to the watch.

### 1.3 Offline visibility is watch-local, not phone-local

When disconnected, the watch shows only tracks whose audio files are installed and
validated on the watch, plus collections derived from those tracks. A phone cache pin is
not an offline watch download. Product copy always says **Downloaded to Apple Watch**.

### 1.4 No CloudKit means structural exclusion

The current watch target has no CloudKit entitlement; the iPhone entitlement entries in
the generated project do not belong to `TonearmWatch`. Preserve that. Configuration alone
is insufficient, however: the replacement watch target must not depend on the broad
`TonearmCore` product that includes `Sources/Sync` and GRDB.

Enforce all three final boundaries:

- watch target has no iCloud, CloudKit, push, or app-group entitlement;
- watch SwiftData configuration explicitly uses `.none` for CloudKit;
- final watch-linked package products contain no `import CloudKit`, GRDB dependency,
  CloudKit symbols, container identifiers, or phone credential providers. During Phases
  1–5 only, existing GRDB watch behavior is isolated in the temporary
  `TonearmWatchLegacyCore` product described in §3.1; that product may depend on GRDB but
  may never contain or depend on CloudKit code.

### 1.5 Reachability is a capability, not the database mode

`WCSession.isReachable` controls immediate messaging only. It must not delete metadata,
invalidate downloads, or become the sole source of UI truth. A debounced connection model
combines session activation, reachability callbacks, command success/failure, last phone
snapshot, and local-download availability.

### 1.6 Download truth has two authorities

The iPhone owns **desired download roots** (pinned tracks and pinned playlists). The watch
owns **installed asset truth** (validated files and bytes). UI state is derived by
reconciling both; a queued transfer is never rendered as downloaded.

### 1.7 Authoritative platform references

These references informed the closed decisions; implementation should use the selected SDK's
signatures but should not reopen the product model:

- Apple [`WCSession`](https://developer.apple.com/documentation/watchconnectivity/wcsession):
  immediate messages require reachability; application context is newest-state; user info and
  file transfers are queued background mechanisms.
- Apple [Transferring data with Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity):
  channel semantics, progress, and outstanding transfer behavior.
- Apple [Playing Background Audio](https://developer.apple.com/documentation/watchkit/playing-background-audio):
  watch background mode, `.playback`, `.longFormAudio`, route activation.
- Apple [SwiftData CloudKit opt-out](https://developer.apple.com/documentation/swiftdata/modelconfiguration/cloudkitdatabase-swift.struct/none):
  `.none` disables managed CloudKit synchronization.
- Apple [Designing for watchOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-watchos):
  glanceable interactions, shallow hierarchy, Crown-first navigation, independent utility.
- Apple [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields):
  watch text entry occupies the screen and returns on Search/Cancel.
- Apple Watch [Music behavior](https://support.apple.com/guide/watch/play-music-apd70768b20b/watchos):
  local music, iPhone control, Downloads, search, queue, and Crown volume mental models.
- Spotify [Apple Watch behavior](https://support.spotify.com/us/article/spotify-on-apple-watch/):
  explicit watch downloads, offline library, and direct-watch versus phone-control distinction.

## 2. Product contract

### 2.1 Connected mode

With a reachable paired iPhone, the watch can:

- search the complete iPhone catalog using free text;
- browse phone playlists, recently played items, albums, and songs using paged requests;
- play a track, album, or playlist through the iPhone player;
- control play/pause, previous, next, queue selection, shuffle, repeat, and elapsed position;
- display the phone's authoritative now-playing queue and state;
- open Downloads and play watch-local music without changing to the phone player;
- request Download to Apple Watch for a result, track, album, or playlist;
- show truthful queued/transferring/installing/partial/complete/failed states.

Connected playback target defaults to the last explicit target, initially **iPhone**.
Every Now Playing screen labels the active target as `iPhone` or `Apple Watch`; transport
commands never ambiguously control both.

### 2.2 Disconnected mode

After a debounced connected-to-disconnected transition, the watch:

- gives one haptic and presents a nonblocking `iPhone unavailable` banner;
- changes the root scope to **Downloads on This Watch**;
- searches only locally playable downloaded tracks and derived collections;
- retains local playback, queue, shuffle/repeat, and position without the phone;
- never displays a row that will fail merely because its audio is on the phone;
- explains when there are no downloads and tells the user to use the iPhone app;
- does not repeatedly alert during the same outage.

If phone playback was active, show `Playback continues on iPhone` when that fact is known.
If the current phone track is downloaded locally, offer `Continue on Apple Watch` at the
last confirmed elapsed position. Never switch playback targets automatically.

### 2.3 Reconnection

Reconnection restores connected browsing/search and flushes pending acknowledgements. It
does not dismiss the current screen, replace a local queue, or move playback back to the
iPhone. A compact `iPhone connected` confirmation may appear once.

### 2.4 Download semantics

- **Track pin:** keeps one track downloaded until explicitly removed.
- **Playlist pin:** continuously mirrors that playlist's phone membership. New tracks are
  queued; removed tracks are removed only if no other pin requires them.
- **Album download:** represented as explicit track pins grouped by album; it does not
  create a hidden permanent album-sync rule.
- Shared tracks transfer once and use reference-counted desired roots.
- Removing a playlist download never removes a separately pinned track or a track required
  by another downloaded playlist.
- Partial collections remain visible in Downloads with `n of m` and play only completed
  tracks. They are never labelled complete.
- Unsupported or source-unavailable tracks remain listed in phone management with a clear
  per-track reason and do not block playable siblings.

### 2.5 Storage policy

Pinned watch audio lives in Application Support and is never app-evicted. Reserve at least
the greater of 500 MB or 10% of reported free capacity before accepting a batch. Recheck
before every file installation. Storage estimates are estimates; installed byte counts
come from the watch.

The watch and iPhone both provide removal by track, playlist, album group, and all downloads.
Deletion is idempotent and reference-aware. An interrupted deletion reconciles on the next
manifest exchange.

### 2.6 Quality bar

The app must feel native and deliberate:

- focused interactions achievable in one or two taps;
- shallow navigation and Crown-friendly vertical lists;
- meaningful empty, loading, stale, partial, and failure states;
- no fake progress, silent command failure, blank screen, or indefinite spinner;
- 44-point minimum interactive targets where geometry permits;
- Dynamic Type, VoiceOver, Reduce Motion, high contrast, and non-color state labels;
- background audio and system Now Playing integration for watch-local playback;
- battery-conscious snapshots and no polling loop while idle.

## 3. Target architecture

```text
                         PAIRED DEVICES ONLY

 iPhone                                                     Apple Watch
 ─────────────────────────────────────────────────────────────────────────
 Existing GRDB LibraryStore                                Local SwiftData
 Existing AudioPlayer                                      WatchLibraryStore
         │                                                        │
 PhoneWatchCoordinator                                      WatchCoordinator
         │                                                        │
 PhoneWatchSessionAdapter  ◄──── versioned protocol ────►  WatchSessionAdapter
         │                  messages / contexts / files            │
 PhoneDownloadPlanner                                      WatchFileInstaller
         │                                                        │
 source resolver + cache                                  validated local files

 Connected target: iPhone AudioPlayer  ◄── remote commands ── watch UI
 Local target:     watch UI ──► WatchPlaybackCoordinator ──► AVPlayer
```

### 3.1 Package products and dependency rules

Create these products in `Package.swift`:

1. `TonearmWatchProtocol`
   - Foundation only.
   - Stable IDs, protocol envelope, commands, responses, snapshots, file metadata,
     revisions, error codes, and pure state reducers.
   - No SwiftData, GRDB, CloudKit, WatchConnectivity, AVFoundation, credentials, URLs
     containing authentication, or app UI.

2. `TonearmWatchCore`
   - Depends only on `TonearmWatchProtocol`.
   - SwiftData models/repositories, local search normalization, download projection,
     connectivity reducer, playback state machine, queue persistence policy, storage
     planning, and test seams.
   - No GRDB, CloudKit, WatchConnectivity, or phone remote-provider code.

3. `TonearmWatchLegacyCore` — temporary, deleted in Phase 6
   - Contains only the existing GRDB-backed types required to keep the shipped watch UI
     operable while the SwiftData path is built.
   - May depend on GRDB. It may not include `Sources/Sync`, CloudKit, phone credentials,
     remote-provider authentication, or other broad `TonearmCore` features.
   - No new product behavior is implemented here; fixes are limited to keeping the legacy
     path compiling and safe during migration.

4. Existing `TonearmCore`
   - Continues to own the iPhone GRDB library and existing features.
   - Depends on `TonearmWatchProtocol` for phone-side DTO construction and reducers.
   - Old `Sources/WatchSync` and `Sources/WatchPlayback` files are migrated or deleted;
     do not compile duplicate implementations.

During Phases 1–5, `TonearmWatch` depends on `TonearmWatchCore`,
`TonearmWatchProtocol`, and temporary `TonearmWatchLegacyCore`, never broad
`TonearmCore`. Phase 6 removes `TonearmWatchLegacyCore`; the final watch depends only on
the two new products. The iPhone app depends on `TonearmCore` and
`TonearmWatchProtocol`.

From Phase 1, a structural guard fails if any watch-linked product contains CloudKit or
if any watch source imports it. The guard allows GRDB only inside the named temporary
legacy product. Phase 6 removes that allowlist and fails on any watch-linked GRDB.

### 3.2 Platform adapters

Platform frameworks remain in app targets:

- `PhoneWatchSessionAdapter`: `WCSessionDelegate`, transport only.
- `WatchSessionAdapter`: `WCSessionDelegate`, transport only.
- `WatchAVPlayerOutput`: AVPlayer and AVAudioSession only.
- `WatchNowPlayingPublisher`: system Now Playing and remote-command integration.
- `WatchRouteMonitor`: route/interruption events.
- `WatchFileSystem`: atomic staging/install/delete and checksum access.

Adapters decode/encode typed envelopes and forward Sendable values to actors. They do not
query databases, decide UI state, or mutate transfer jobs directly.

### 3.3 Coordinators and actors

- `PhoneWatchCoordinator` (`@MainActor` observable facade): connected state, phone playback
  snapshots, user actions, UI presentation.
- `PhoneWatchSyncActor`: request routing, catalog projections, download-root reconciliation,
  transfer scheduling, manifest ingestion.
- `WatchCoordinator` (`@MainActor` observable facade): screen state, active target, banners,
  navigation-safe actions.
- `WatchSyncActor`: protocol sequencing, SwiftData repository writes, manifest generation,
  orphan/stale transfer reconciliation.
- `WatchPlaybackCoordinator` (`@MainActor`): local queue and output lifecycle.

No singleton may be initialized from a SwiftUI `body`. Dependencies are assembled once in
the app entry point and injected through the environment. Legacy singleton APIs remain only
behind a temporary compatibility adapter and are deleted before Phase 10.

## 4. Watch SwiftData schema

Use a dedicated schema version and migration plan. All persistent IDs are stable strings
from the phone; no phone GRDB integer primary key crosses the protocol boundary.

### `WatchTrackModel`

- `trackID: String` — stable phone `syncID`; required and indexed in repository logic.
- `title`, `normalizedTitle`.
- `artist`, `normalizedArtist`.
- `albumTitle`, `normalizedAlbum`.
- `durationSeconds`, `trackNumber`, `discNumber`.
- `artworkID` and local thumbnail filename, optional.
- `codec`, expected byte count, expected SHA-256.
- `phoneRevision`, `metadataUpdatedAt`.
- relationship to `WatchAssetModel`, optional.

### `WatchPlaylistModel`

- `playlistID`, `title`, `normalizedTitle`, `phoneRevision`.
- ordered `WatchPlaylistEntryModel` children with `trackID` and ordinal.
- `desiredOnWatch` and last reconciliation date.

### `WatchAssetModel`

- `trackID`, relative filename, installed bytes, SHA-256, installed date.
- validation state: installing / ready / corrupt / pendingDeletion.
- only `.ready` assets are playable or counted as downloaded.

### `WatchDownloadJobModel`

- request ID, track ID, root IDs, state, expected bytes/checksum.
- queued/transferring/received/installing/ready/failed/cancelled.
- attempt count, error code, safe user message, created/updated timestamps.
- state transitions are monotonic within one attempt; retry creates a new attempt token.

### `WatchDownloadRootModel`

- root ID and kind: track / playlist / albumBatch.
- source ID, desired track IDs, phone revision, created date.
- playlist roots remain live; album batches and track roots remain explicit snapshots.

### `WatchPlaybackStateModel`

- target-independent local queue IDs, index, elapsed, shuffle/repeat, updated date.
- restore only tracks with ready assets; remove missing/corrupt entries deterministically.

### `WatchSyncStateModel`

- protocol version, paired-library identity, last applied phone revision, last manifest ID,
  last connection date, last successful sync date.

Do not persist transient connected search results or phone queue pages. SwiftData models are
never sent across actors; repositories return Sendable value snapshots.

### 4.1 Container bootstrap and recovery

Construct the container before rendering normal content, using:

```swift
ModelConfiguration(
    "PlatterheadWatch",
    schema: watchSchema,
    isStoredInMemoryOnly: false,
    cloudKitDatabase: .none
)
```

The launch state is `opening`, `ready`, `recovered`, or `degraded`. On an unreadable store:

1. preserve the failed store in a dated quarantine location;
2. open a fresh local store;
3. scan the audio directory and retain files as recoverable orphans;
4. request/reconcile phone state when available;
5. show an honest recovery notice.

Never `fatalError` because the persistent store failed to open.

## 5. Protocol specification

### 5.1 Envelope

All logical payloads use a typed Codable envelope encoded as binary property-list `Data`:

```text
protocolVersion
messageID UUID
correlationID UUID?
pairedLibraryID String
phoneRevision Int64
sentAt Date
kind enum
payload Data
```

Use `sendMessageData` for immediate request/reply. Put encoded `Data` under one stable key
for application context and user-info transfers. File metadata remains property-list-safe
and includes only IDs, versions, sizes, checksum, codec, and pin intent.

Unknown optional fields are ignored. Unsupported protocol versions return a typed
`upgradeRequired` error and leave local downloads usable.

### 5.2 Channels

| Capability | WCSession API | Rule |
|---|---|---|
| Immediate search/browse/playback command | `sendMessageData` | Requires reachable; 8-second UI deadline |
| Latest phone/connection/now-playing snapshot | `updateApplicationContext` | Coalesced; newest state only |
| Durable desired-root/delete/reconcile event | `transferUserInfo` | Idempotent by message ID |
| Audio/artwork/catalog projection file | `transferFile` | Background/opportunistic; checksum required |
| Watch manifest acknowledgement | `transferUserInfo` | Contains actual ready files and bytes |

Never assume delivery order across channels.

### 5.3 Request kinds

- `hello` / `helloReply`: protocol negotiation, paired-library identity, capabilities.
- `searchRequest` / `searchResponse`: query, scope, page token, generation token.
- `browseRequest` / `browseResponse`: playlists/albums/recent/songs pages.
- `collectionRequest` / `collectionResponse`: ordered tracks for one collection.
- `playCommand` / `commandReply`: phone player play/pause/next/previous/jump/shuffle/repeat.
- `phonePlaybackSnapshot`: source, queue window, current item, elapsed anchor date/rate.
- `setDownloadRoots`: complete desired-root revision.
- `downloadStatusSnapshot`: queued/active/failed summary.
- `watchManifest`: complete actual ready-asset manifest, capacity, free bytes.
- `requestReconciliation`: either side asks for current authoritative snapshot.
- `removeAssets`: reference-resolved track IDs and revision.
- `error`: stable machine code plus safe display message.

### 5.4 Revisions and idempotency

- `pairedLibraryID` changes after phone library reset/reinstall; the watch prompts before
  replacing unrelated downloaded content.
- Phone catalog/download-root revisions are monotonic `Int64` values persisted on phone.
- Every event has a message ID stored in a bounded applied-message ledger.
- Stale revisions are acknowledged but not applied.
- Duplicate files validate and acknowledge without rewriting.
- Audio arriving before metadata is staged by request/track ID and reconciled later.
- Metadata arriving without audio remains a nonplayable download job, never a track in the
  offline search result.

### 5.5 Stable error codes

Transport and domain errors use these machine codes; localized copy maps in the UI layer:

| Code | Meaning | Retry policy |
|---|---|---|
| `phoneUnavailable` | Immediate phone command cannot run | User retry after reconnect |
| `requestTimedOut` | No reply by command deadline | One user retry; never background-spin |
| `protocolUpgradeRequired` | Protocol versions incompatible | App upgrade required |
| `pairedLibraryChanged` | Phone library identity differs | User confirms replacement/reconcile |
| `contentNotFound` | Track/collection disappeared | Refresh result; no automatic retry |
| `sourceUnavailable` | Phone cannot resolve source | User/source action required |
| `authenticationRequired` | Remote source needs phone sign-in | Open source settings on iPhone |
| `waitingForWiFi` | Network policy blocks source download | Automatic when policy permits |
| `unsupportedAudio` | Codec/source cannot be prepared | Permanent until content changes |
| `insufficientWatchStorage` | Reserve would be violated | Remove downloads, then retry |
| `transferFailed` | WCSession transfer failed transiently | Bounded scheduler retry |
| `checksumMismatch` | Received file failed validation | Delete staging; explicit/bounded retry |
| `installationFailed` | Atomic file/store install failed | Reconcile and bounded retry |
| `audioRouteUnavailable` | Watch has no usable output | User chooses/connects output |
| `playbackItemFailed` | Local player rejected ready item | Mark suspect, skip, offer redownload |
| `storeRecovered` | Watch store was rebuilt | Informational; reconciliation follows |

## 6. Search, browse, and connection state

### 6.1 Connected search

- Debounce text input 250 ms after at least two non-whitespace characters; submit immediately
  on Search.
- Normalize query on the phone with the existing library search policy.
- Cancel superseded UI tasks; generation IDs cause late replies to be dropped.
- Return at most 30 mixed results per page with typed track/playlist/album rows and a page
  token. Never serialize the complete phone catalog.
- Recent searches stay on watch only and contain text, not result metadata; cap at 10 and
  provide Clear.
- Empty, no-results, timed-out, and disconnected-during-search are distinct states.

### 6.2 Offline search

Search local normalized title/artist/album fields and downloaded playlist titles. Results
must join through a `.ready` asset. Ranking: exact normalized title, prefix title, title
contains, artist prefix, album prefix, then locale-aware title order. Cap initial results at
100 and paginate locally if needed.

### 6.3 Connection reducer

Core states:

```text
activating
connected(lastReplyAt)
suspectedDisconnected(since)
disconnected(lastConnectedAt)
incompatibleProtocol
unpaired
```

Do not flip the UI on every raw callback. Enter `suspectedDisconnected` on a negative
reachability callback or immediate-command failure, wait a two-second grace period, and
cancel if a successful reply arrives. Active command failures may surface immediately on
the command while the global mode waits for the grace period. Haptic/banner occurs only on
the confirmed connected → disconnected edge.

## 7. Playback design

### 7.1 Explicit targets

`PlaybackTarget` is `iPhone` or `thisWatch`. It is always visible on Now Playing and in the
play action sheet when both are available.

- iPhone target delegates all queue and transport state to `AudioPlayer` through the phone
  coordinator. The watch predicts elapsed time from `(elapsed, snapshotDate, rate)` but
  periodically corrects to authoritative snapshots.
- This Watch target owns a local queue containing only ready assets and drives one AVPlayer.
- Transport is sent to exactly one target.
- Changing target is an explicit user action. If the item is unavailable on the destination,
  explain why and offer Download to Apple Watch where applicable.

### 7.2 Local audio session

- Enable watch background audio.
- Configure `.playback`, `.default`, `.longFormAudio` and activate before loading playback.
- Handle no route, route loss, interruptions, media-services reset, item failure, app
  background, and wrist-down behavior.
- A declined/missing route returns to paused with `Choose headphones or a speaker`.
- Local playback continues through navigation and wrist-down.

### 7.3 Local queue rules

- Playlist/album play uses currently ready members in stored order and states when items are
  missing (`Playing 8 downloaded tracks`).
- Shuffle is deterministic for the session and persists across relaunch.
- Repeat off/all/one, previous behavior at elapsed <3 seconds, next/end behavior, tap-to-jump,
  and corrupt-file skipping are pure reducer rules with exhaustive tests.
- Persist on queue mutation, track change, pause, interruption, app inactive/background, and
  every 10 seconds while playing. Restore paused at the saved position.

### 7.4 System integration

Publish title, artist, album, duration, elapsed, rate, queue index/count, artwork, and stable
content identifiers. Register only supported remote commands. Keep Smart Stack/system Now
Playing in sync. Do not mix mutually exclusive Now Playing API families.

### 7.5 Continue on Watch

When phone playback becomes unreachable and its current track has a ready local asset:

- offer `Continue on Apple Watch`;
- use the last authoritative elapsed anchor, clamped to duration;
- build the local queue from downloaded members of the phone queue snapshot;
- never claim gapless handoff; label the action, pause briefly, and begin locally;
- do not send a speculative stop to an unreachable phone.

## 8. Download pipeline

### 8.1 Phone planning

`PhoneWatchDownloadPlanner` expands roots into desired track IDs, resolves reference counts,
estimates bytes, identifies unsupported/unavailable files, and emits a deterministic plan.
The phone persists roots and jobs in GRDB using a new migration; do not overload the old
`watchTransfer` table if its semantics cannot represent roots, retries, revisions, and
multiple attempts cleanly.

Priority order:

1. user-selected current-track download;
2. retries explicitly requested by the user;
3. individual track/album batch;
4. playlist background synchronization;
5. artwork.

Resolve remote audio into the existing phone cache before transfer. Downloads respect the
phone's network policy. If cellular downloading is disabled, show `Waiting for Wi-Fi`.

### 8.2 Transfer scheduling

- Maximum two outstanding audio file transfers and one metadata/artwork transfer.
- Observe sender-side `Progress` for phone UI only.
- On watch, show count/state progress because WCSession does not provide honest incoming byte
  progress before delivery.
- Persist every state transition before scheduling the external transfer.
- Rehydrate from `outstandingFileTransfers` at launch/activation.
- Cancellation calls transfer cancellation where possible and remains idempotent if delivery
  wins the race.
- Retry transient failures with bounded exponential backoff; authentication/source/file
  failures require user action and do not spin.

### 8.3 Watch installation

1. Receive into framework-provided temporary URL.
2. Copy into a unique staging file before returning from the callback.
3. Validate request ID, expected bytes, SHA-256, supported codec, and free-space reserve.
4. Atomically move into Application Support using a content-addressed filename.
5. In one SwiftData transaction, mark asset ready and update the job/manifest.
6. Send a manifest acknowledgement.
7. Delete staging artifacts.

Never delete an existing ready asset until a replacement is installed and committed.

## 9. Normative UI inventory

The mockups define hierarchy and state language, not hard-coded pixel dimensions. Use native
watchOS components, Dynamic Type, safe areas, and current SDK conventions.

### Watch screens

| ID | Screen | Required states |
|---|---|---|
| W1 | Connected Home | iPhone target, Now Playing, Search, phone playlists, Downloads |
| W2 | Search | recent, typing, loading, results, no results, timeout, disconnect |
| W3 | Phone collection detail | Play on iPhone, download, partial/failed status |
| W4 | Downloads | playlists, albums, tracks, aggregate storage |
| W5 | Offline Home | unavailable banner, Downloads-only scope, local search |
| W6 | Local collection detail | ready/partial counts, play downloaded members |
| W7 | Now Playing — iPhone | explicit target, authoritative remote controls |
| W8 | Now Playing — Apple Watch | local transport, Crown volume, route state |
| W9 | Up Next | active target, tap-to-jump, unavailable rows explained |
| W10 | Download activity | queued/transferring/installing/failed, retry/cancel |
| W11 | Storage | used/free, collections, remove actions, corrupt recovery |
| W12 | Empty/recovery | no downloads, incompatible protocol, recovered store |

### iPhone screens

| ID | Screen | Required states |
|---|---|---|
| P1 | Track/album/playlist menu | Download/Remove/Retry to Apple Watch |
| P2 | Settings > Apple Watch | paired, connection, actual storage, desired roots |
| P3 | Download queue | per-root and per-track status, pause/retry/cancel |
| P4 | Storage management | reference-aware removal and Remove All confirmation |
| P5 | Transfer banner | compact progress with failure affordance |

### Interaction rules

- Connection banners never cover transport controls and remain accessible to VoiceOver.
- Status uses text/icon in addition to color.
- Search is one top-level action; watchOS full-screen text entry is expected.
- Destructive removals state that music remains on the iPhone.
- `Close` dismisses Now Playing; it does not clear the queue or stop playback. Stopping and
  clearing are separate intentional actions.
- Crown controls volume only on local watch playback; for iPhone playback it adjusts the
  phone player only if the platform API and current app behavior support it reliably.
- Every asynchronous button immediately shows accepted/queued or a typed error.

### Stable accessibility identifiers

Identifiers are test/API contracts and must not be localized:

| Surface | Identifiers |
|---|---|
| Root | `watch.root`, `watch.connection.banner`, `watch.nowPlaying`, `watch.search`, `watch.playlists`, `watch.albums`, `watch.songs`, `watch.downloads` |
| Search | `watch.search.field`, `.scope`, `.loading`, `.retry`, `.downloads`, `watch.search.result.<stableID>` |
| Collection | `watch.collection.playPhone`, `.playLocal`, `.download`, `.status`, `watch.album.<stableID>`, `watch.track.<stableID>` |
| Now Playing | `watch.now.target`, `.artwork`, `.title`, `.elapsed`, `.remaining`, `.previous`, `.playPause`, `.next`, `.upNext`, `.more`, `.continue`, `.routeHint`, `.chooseRoute` |
| Downloads | `watch.downloads.activity`, `.storage`, `.removeAll`, `watch.download.<requestID>`, `watch.download.retry.<requestID>` |
| Recovery | `watch.store.opening`, `.recovery`, `.continue`, `.details` |
| iPhone management | `settings.watch`, `settings.watch.queue`, `.storage`, `.reconcile`, `.removeAll`, `watchRoot.<rootID>`, `watchJob.<requestID>` |

Dynamic IDs use the protocol's stable IDs encoded to a UI-test-safe lowercase hex/base64url
form, never a title or database row ID.

## 10. Legacy replacement map

| Existing component | Disposition |
|---|---|
| `Sources/WatchSync/WatchCatalog.swift` | Replace whole-catalog GRDB import with paged protocol + downloaded projection |
| `WatchManifestRecord` | Replace watch side with SwiftData asset truth; phone side gets revised GRDB manifest tables |
| `WatchTransferQueue` / `WatchTransferController` | Replace with root-aware persistent planner/scheduler |
| `WatchLibraryFilter` | Replace with repository queries requiring ready local assets offline |
| `WatchSessionAdapter` | Rewrite as transport-only typed adapter |
| `WatchSyncHandler` | Delete; responsibilities move to `WatchSyncActor` and file installer |
| `LibraryStore.shared` in WatchApp | Remove completely |
| `WatchFixtureSeeder` GRDB fixtures | Replace with in-memory/on-disk SwiftData fixtures and bundled audio |
| `WatchPlayer.shared` | Replace with injected coordinator; no global singleton |
| `AVPlayerOutput` | Retain concept, rewrite lifecycle/error handling as `WatchAVPlayerOutput` |
| current watch browse views | Rebuild against snapshot models and mockups |
| old watch tests | Port useful reducer cases; delete assertions for superseded GRDB/catalog behavior |

No compatibility shim remains after Phase 10.

## 11. Testing doctrine

### 11.1 Host tests

Every reducer, planner, protocol codec, migration decision, search ranker, manifest reconcile,
queue rule, and retry policy is tested with `swift test`. New package targets must remain
host-compilable. No platform adapter is allowed to accumulate logic merely because it is hard
to host-test.

### 11.2 SwiftData tests

Use in-memory containers for repository behavior and temporary on-disk containers for schema
migration/recovery. Test actor crossing through Sendable snapshots, not by passing model
objects. Include corrupt/missing file reconciliation and store-open failure injection.

### 11.3 Simulator UI tests

Keep exactly one watch smoke method, but expand its deterministic fixture journey to cover:

- connected fixture mode search and phone-target Now Playing;
- switch to Downloads, local playback, pause/next/previous;
- simulated disconnect and Downloads-only filtering;
- download failure/retry and storage screen;
- relaunch and restored local queue.

The fixture transport is injected; the test does not depend on simulator WatchConnectivity or
the network. Do not add the watch simulator test to CI.

### 11.4 Physical-device gates

Real WatchConnectivity transfer, background delivery, route activation, wrist-down audio,
Bluetooth headphones, phone force-quit, watch force-quit, airplane mode, reconnect, storage
pressure, battery use, and TestFlight installation require paired hardware. These gates are
enumerated in `ACCEPTANCE_MATRIX.md` and may not be marked complete from simulator evidence.

### 11.5 Structural guards

CI fails when:

- watch target/product dependency graph includes CloudKit at any phase;
- watch source imports CloudKit or contains an iCloud container identifier;
- after Phase 6, watch target/product dependency graph includes GRDB or a watch source
  imports GRDB; before cutover, GRDB is allowed only in `TonearmWatchLegacyCore`;
- watch target gains iCloud, CloudKit, push, or app-group entitlements;
- watch SwiftData container is created without explicit `.none`;
- a protocol switch lacks unknown-version behavior;
- more than one watch UI smoke test method exists;
- new Swift 6 warnings appear.

## 12. Implementation phases

### Phase 1 — Architecture boundary and executable skeleton

Outcome: the project has compiler-enforced watch-only products and a local-only SwiftData
bootstrap seam, while shipped behavior remains on the legacy path behind a feature flag.

Implement:

1. Add `TonearmWatchProtocol` and `TonearmWatchCore` products/targets with minimal typed stable
   ID, protocol-version, playback-target, connectivity-state, and store-bootstrap types.
2. Add temporary `TonearmWatchLegacyCore`, containing the minimum existing GRDB-backed types
   required by the current Watch UI but excluding `Sources/Sync`, CloudKit, credentials, and
   unrelated phone features. Change `TonearmWatch` from broad `TonearmCore` to the three
   scoped products. Do not duplicate source files across modules.
3. Add an app-entry dependency assembly and `WatchFeatureFlags.swift` with
   `swiftDataWatchArchitecture` defaulting off outside tests until Phase 6 cutover.
4. Add `WatchStoreBootstrap` creating a versioned local SwiftData container with explicit
   `cloudKitDatabase: .none`, plus in-memory test construction and recoverable failure states.
5. Add CI guards for dependency graph/imports/entitlements/container configuration.
6. Verify generated Debug and Release watch build settings contain no entitlement file and
   archive inspection contains no CloudKit entitlement.
7. Add an Architecture Decision Record section to the audit with the exact package graph.

Expected files:

- `Package.swift`
- `project.yml`, generated `Tonearm.xcodeproj`
- `Sources/WatchProtocol/*`
- `Sources/WatchCore/Bootstrap/*`
- `WatchApp/App/WatchAppAssembly.swift`
- `WatchApp/App/WatchFeatureFlags.swift`
- `scripts/check-ci-guards.sh`
- `Tests/WatchArchitectureBoundaryTests.swift`
- `Tests/WatchStoreBootstrapTests.swift`

Tests/gates:

```sh
make ci-guards
swift test
make project
xcodebuild build -project Tonearm.xcodeproj -scheme Tonearm \
  -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild build -project Tonearm.xcodeproj -scheme TonearmWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Definition of done:

- watch target no longer links broad `TonearmCore` or any CloudKit-bearing product;
- GRDB is reachable only through the explicitly temporary `TonearmWatchLegacyCore` product;
- local SwiftData bootstrap passes persistent/in-memory/failure tests;
- current legacy watch UI still launches through the compatibility assembly;
- no user behavior has been silently removed;
- guards prove the no-CloudKit rule structurally.

### Phase 2 — SwiftData schema, repositories, migration, and recovery

Outcome: all new watch local truth is implemented and independently testable.

Implement schema/models from §4, repositories returning Sendable snapshots, normalized local
search, manifest calculation, storage accounting, file-to-database reconciliation, quarantine
recovery, and deterministic fixture seeding. Build a one-time migration reader from the old
watch GRDB database if it can safely recover already-downloaded audio; otherwise scan existing
audio and request phone reconciliation. Never discard validated user audio merely because the
old metadata store is unreadable.

Tests: model CRUD/relationships, ready-only queries, search ranking, shared playlist membership,
partial collections, manifest bytes, missing/corrupt files, orphan adoption, schema migration,
store quarantine, repeated recovery, and old-container upgrade fixture.

Definition of done: a local library can be seeded, searched, relaunched, recovered, and rendered
from snapshots without GRDB or the phone.

### Phase 3 — Typed protocol and reliable connectivity state

Outcome: both apps speak one versioned, idempotent protocol and expose honest connection state.

Implement §5 codecs, capability negotiation, application-context snapshots, immediate request
router, durable event ledger, revision rules, correlation/deadline handling, transport-only
adapters, connection reducer/grace period, and injected fake transport. Port the workout app's
useful callback-to-main-actor and application-context recovery patterns without copying its
workout-specific payload design.

Tests: encode/decode every kind, unknown fields/version, duplicate/stale/out-of-order events,
late replies, reconnect, pairing identity change, callbacks from non-main queues, activation
with received context, two-second grace, one alert per outage.

Definition of done: deterministic integration tests drive phone and watch coordinators through
a fake duplex transport; no dynamic dictionary parsing exists outside adapters.

### Phase 4 — Phone projections, remote search/browse, and playback bridge

Outcome: connected watch behavior works end to end without transferring the full catalog.

Implement paged GRDB projections, search/browse request handlers, compact DTO factories,
collection detail, phone `AudioPlayer` command adapter, authoritative now-playing snapshots,
elapsed anchors, queue windows, shuffle/repeat/jump acknowledgements, and typed errors.

Tests: FTS/free-text ranking parity, page tokens, deleted result between request/play, empty
playlist, remote source unavailable, queue ordering, all transport commands, stale snapshot,
target isolation, and payload-size budgets.

Definition of done: fake-transport watch tests search the complete phone fixture library, play a
playlist through a spy phone player, and observe authoritative Now Playing state.

### Phase 5 — Desired downloads and phone transfer manager

Outcome: track/album/playlist watch downloads are durable, reference-aware, observable, and
resumable on the phone.

Add the GRDB migration for download roots/jobs/manifest/revisions; implement planner,
source resolver, cache adoption, network-policy waits, storage estimate, scheduler,
outstanding-transfer rehydration, cancellation, bounded retry, desired-root snapshots, and
manifest reconciliation. Preserve existing phone downloads independently from watch roots.

Tests: every root combination, shared references, playlist edits, dedupe, unsupported tracks,
cache hit/miss, Wi-Fi wait, restart with outstanding jobs, transfer callback races, cancellation,
retry classes, watch reset, and actual/desired divergence.

Definition of done: a phone-side integration test plans a mixed playlist, transfers each audio
file once through a fake writer, survives relaunch, and converges after manifest receipt.

### Phase 6 — Watch file installation and offline cutover

Outcome: SwiftData becomes the shipped watch persistence path and offline content is truthful.

Implement atomic installer, SHA-256/size/codec validation, reserve checks, staging cleanup,
asset replacement, manifest acknowledgements, deletion reconciliation, partial collection
projection, and local file URL resolution. Enable `swiftDataWatchArchitecture` by default.
Migrate/adopt existing files, then remove runtime use of `LibraryStore.shared`, old watch GRDB,
`WatchCatalog.import`, and `WatchSyncHandler`. Delete `TonearmWatchLegacyCore`, remove its
dependency, and tighten the structural guard so any watch-linked GRDB fails.

Tests: audio before metadata, metadata before audio, duplicate delivery, corrupt/truncated file,
wrong request, low storage, replacement race, delete/install race, shared root removal, crash at
each installation boundary, and convergence after restart.

Definition of done: with fake connectivity disabled, only ready local tracks and derived
collections appear; every visible row resolves to a valid local file.

### Phase 7 — Connected and offline watch navigation/search UI

Outcome: W1–W6 and W12 match the mockups and mode contract.

Rebuild root, search, result, collection, Downloads, offline, empty, incompatibility, and store
recovery screens using injected coordinators and value snapshots. Implement recent searches,
debounce/generation handling, Crown scrolling, partial/failed statuses, connection banner/haptic,
reconnection confirmation, and stable accessibility identifiers.

Tests: reducer/presenter snapshots for every state; extend the single injected-transport watch
smoke journey. Perform smallest/largest supported watch simulator screenshots in light/dark,
large Dynamic Type, VoiceOver labels/order, Reduce Motion, and high contrast.

Definition of done: no spinner exceeds its deadline without becoming an actionable state; a
disconnect immediately yields a useful downloaded library rather than broken phone rows.

### Phase 8 — iPhone download and storage experience

Outcome: P1–P5 provide complete control and truthful transfer visibility.

Replace current glyph/menu/settings behavior with root-aware statuses, download/remove/retry at
track/album/playlist level, queue details, pause/resume/cancel, actual watch capacity, unsupported
reasons, playlist auto-sync explanation, reference-aware confirmations, transfer banner, and
Watch reset/reconcile actions. Keep all row/menu behavior accessible and consistent with the
existing Platterhead design system.

Tests: pure presenters and planner actions; extend existing iPhone smoke/regression paths rather
than adding redundant test functions. Verify offline phone, unpaired watch, unreachable watch,
partial playlist, failed item, and remove-shared-track copy.

Definition of done: every watch download can be initiated, understood, retried, or removed from
the iPhone without opening the watch app.

### Phase 9 — Watch-local playback and system media integration

Outcome: W7–W9 provide reliable local and remote playback with explicit targets.

Implement/rework local playback reducer, AVPlayer adapter, audio session and route lifecycle,
background mode, interruptions, media-services reset, queue persistence/restore, Crown volume,
system Now Playing, remote commands, explicit target switching, remote snapshot prediction, and
Continue on Apple Watch. `Close` must not stop playback.

Tests: exhaustive reducer matrix, queue restoration with missing files, elapsed anchor drift,
target isolation, interruption/route decisions, item failure skip, remote command registration,
continue-on-watch queue projection, and spy output directive order. Extend the one watch smoke.

Definition of done: local fixture audio plays through navigation/background in simulator, remote
controls target only the phone spy, and relaunch restores a valid paused local queue.

### Phase 10 — Reliability, observability, and legacy deletion

Outcome: the new architecture is the only architecture and failures are diagnosable without
leaking private data.

Delete superseded GRDB watch code, catalog import, old manifests/queues, compatibility flag,
singletons, and dead tests. Add privacy-safe structured diagnostics for activation, request
latency, transfer state, install result, manifest convergence, playback target, route events,
store recovery, and disconnect duration. Add an in-app diagnostics export containing IDs hashed
per export, state codes, timestamps, versions, and byte counts—never titles, URLs, credentials,
tokens, paths, or search text.

Run fault-injection/soak harnesses: 1,000 duplicate/out-of-order events, 500-track desired set,
rapid connect/disconnect, 100 cancellations, relaunch at every job state, and six-hour local
playback state simulation.

Definition of done: no legacy implementation remains in the watch target, all structural guards
pass, fault tests converge, and memory/disk usage is bounded.

### Phase 11 — Award-quality polish, physical-device matrix, and release

Outcome: the experience is release-ready on paired hardware and meets every acceptance row.

Polish animation/haptics, artwork, loading transitions, complications/Smart Stack only if they
materially improve Now Playing access and do not jeopardize reliability, App Intent/Siri entry
for downloaded playback if platform-supported, localization readiness, accessibility audit,
battery/thermal profiling, launch/search latency profiling, storage pressure, Bluetooth route
testing, and TestFlight upgrade from the old watch app.

Required measured targets on supported hardware:

- warm root usable within 1 second; cold root within 2 seconds at p95;
- local search results within 150 ms p95 for 5,000 downloaded tracks;
- connected search acknowledgement/results within 1.5 seconds p95 on nearby paired devices;
- transport command acknowledgement within 500 ms p95;
- no foreground hang over 2 seconds during transfer/install/reconcile;
- 60 minutes wrist-down local playback without termination or unexpected pause;
- idle watch app performs no repeating network/database polling;
- all `ACCEPTANCE_MATRIX.md` release-blocking rows pass or are explicitly owner-waived with a
  recorded reason.

Definition of done: physical-device report is attached to the audit, TestFlight upgrade retains
or recovers existing downloads, no CloudKit entitlement/import/link path exists on watch, and
the owner signs off on the final listening and UX pass.

## 13. Cross-phase file layout target

```text
Sources/
  WatchProtocol/
    IDs.swift
    Envelope.swift
    Messages.swift
    Snapshots.swift
    Errors.swift
  WatchCore/
    Bootstrap/
    Data/
    Domain/
    Search/
    Sync/
    Playback/
  App/Watch/
    PhoneWatchCoordinator.swift
    PhoneWatchSessionAdapter.swift
    PhoneWatchSyncActor.swift
    PhoneWatchDownloadPlanner.swift
WatchApp/
  App/
  Connectivity/
  Data/
  Downloads/
  Playback/
  Views/
Tests/
  WatchProtocolTests/
  WatchCoreTests/
  WatchPhoneTests/
```

The exact subdivision may adapt to SwiftPM target-path constraints, but ownership and forbidden
dependencies may not.

## 14. Global definition of done

- All connected/offline/download/playback behavior in §2 ships.
- Watch local persistence is SwiftData with `.none` CloudKit configuration.
- Watch target/product closure contains no GRDB or CloudKit.
- No watch code contacts remote music providers or holds their credentials.
- The iPhone is the only sync authority; the watch remains useful without it.
- Every offline-visible track has a validated ready local file.
- Track and playlist downloads are durable, reference-aware, and recoverable.
- Phone and watch playback targets are explicit and isolated.
- Background local playback, Now Playing, route/interruption, and restore behavior work.
- Mockup inventory, accessibility identifiers, and acceptance matrix are current.
- Host tests, guards, iPhone build, watch build, one watch smoke, relevant iPhone smoke, and
  physical-device gates are recorded green.
- Legacy GRDB watch code and compatibility paths are deleted.
- `current_status.md` names this plan as the main priority and accurately identifies the next
  phase.

## 15. Implementation Audit

Record one entry per phase with commit SHA, files changed, tests added, exact command results,
simulator/device models, measured timings, known limitations, and any plan correction supported
by compiler or device evidence.

- Planning pass (2026-08-26): architecture/research reviewed; implementation not started.
- Phase 1 (2026-08-26, this commit): **complete** — established the compiler-enforced
  boundary, local-only SwiftData bootstrap, feature-flagged assembly, temporary isolated
  GRDB compatibility store, and structural CI guards.

  Architecture Decision Record — exact Phase 1 package graph:

  ```text
  TonearmWatch
  ├── TonearmWatchProtocol                 (Foundation only)
  ├── TonearmWatchCore
  │   └── TonearmWatchProtocol             (SwiftData; CloudKit explicitly .none)
  └── TonearmWatchLegacyCore               (temporary through Phase 6)
      ├── TonearmWatchProtocol
      ├── TonearmWatchCore
      └── GRDB
  ```

  `TonearmWatch` has no dependency on broad `TonearmCore`; no watch-linked source imports
  CloudKit, credentials, OAuth, or iCloud APIs. GRDB is reachable only through the named
  compatibility product. The iPhone target retains `TonearmCore` and adds the protocol
  product for its sender adapter. Existing watch rows are adopted once into the isolated
  compatibility database without deleting the original database.

  Files changed: package/project manifests and generated project; new `WatchProtocol`,
  `WatchCore`, and `WatchLegacy` sources; watch app assembly/flag and compatibility wiring;
  structural guard; architecture/bootstrap tests. Tests added: 6. Gates: `make ci-guards`,
  `make project`, and `git diff --check` passed; `swift test` passed 1,579 tests with 8
  intentional skips and 0 failures in 95.819s; clean iPhone 16 simulator and generic watchOS
  simulator builds passed (about 65s and 67s); unsigned generic watchOS Release archive
  passed (about 56s). Debug and Release build settings contain no
  `CODE_SIGN_ENTITLEMENTS`; archive/product inspection found no CloudKit/iCloud entitlement.
  Known limitation: physical-watch and signed-distribution verification remain assigned to
  their later acceptance phases; the new SwiftData architecture stays off by default until
  Phase 6.
- Phase 2: complete — versioned SwiftData schema, repositories returning Sendable snapshots,
  normalized offline search, manifest/storage accounting, file reconciliation, quarantine
  recovery, and the one-time legacy adoption.

  All nine models of §4 ship behind `WatchSchemaV1` and open through `WatchSchemaMigrationPlan`;
  every stable ID is `@Attribute(.unique)`. `WatchLibraryRepository` is an actor that never lets a
  `PersistentModel` cross its boundary — `WatchLibraryValues.swift` holds the value types it
  returns and accepts.

  Four decisions worth recording, because each one rejected an easier alternative:

  1. **Stale revisions are dropped, not merged.** §5.4 says a stale revision is acknowledged but
     not applied, so `upsertTrack`/`upsertPlaylist` return `.staleIgnored` and leave the row alone
     rather than taking `max(revision)` while writing the older payload — which is what the first
     draft did, and it would have let an out-of-order phone event resurrect deleted playlist rows.
  2. **The launch-time audio scan does not hash.** Recovery reports
     `WatchRecoverableFileSnapshot` (name and size only) instead of a `WatchOrphanSnapshot`
     carrying a placeholder digest. Hashing every downloaded track would block launch, and a fake
     checksum would have been a lie that `adoptOrphan` then silently rejected. Only
     `reconcileFiles()` hashes, and it does so in 256 KB chunks so a large track is never resident.
  3. **Adoption is validated twice.** `adoptOrphan` re-measures the file and additionally requires
     agreement with `expectedBytes`/`expectedSHA256` when the track carries them, so a rebuilt
     store cannot mark an unrelated file "ready" for a track that happens to be waiting.
  4. **The legacy reader is injected, not imported.** `WatchLegacyUpgrade` takes a snapshot
     closure; `WatchAppAssembly` supplies `LegacyWatchLibraryStore.migrationSnapshot()`. That is
     what keeps GRDB out of `TonearmWatchCore` while still allowing the one-time adoption, and the
     structural guard enforces it. When the reader throws, the upgrade still succeeds as
     `.legacyUnreadable(retainedFiles:)` — audio is kept and phone reconciliation is requested,
     never deleted.

  Storage accounting implements the §2.5 reserve (the greater of 500 MB or 10% of free capacity).
  Note `volumeAvailableCapacityForImportantUsage` does not exist on watchOS, so the plain
  available-capacity key is used; this was only caught by the watchOS build, not by `swift test`.

  Files changed: new `Sources/WatchCore/Library/WatchLibraryValues.swift`,
  `WatchLibraryRepository.swift`, `WatchLibraryModels.swift`, and `WatchLegacyUpgrade.swift`;
  `WatchStoreBootstrap.swift` (versioned schema, quarantine, honest recovery reporting);
  `LegacyLibraryStore.migrationSnapshot()`; watch app assembly/launch wiring; extended structural
  guards. Tests added: 23 across `WatchLibraryRepositoryTests` and `WatchLegacyUpgradeTests`.
  Gates: `make ci-guards` passed (and the new guards were each verified to fail when violated);
  `swift test` passed 1,602 tests with 8 intentional skips and 0 failures in 95.9s; the
  `TonearmWatch` watchOS build and the `Tonearm` iOS build both succeeded.
  Known limitation: the new architecture flag remains off, so none of this is on the shipped
  launch path yet — `runLegacyUpgradeIfNeeded()` returns immediately until Phase 6 flips it.
- Phase 3 (2026-08-26, this commit): **complete** — one versioned, idempotent protocol, honest
  connection state, transport-only adapters, and a deterministic fake duplex link that both
  coordinators are driven through in `swift test`.

  §5 ships as `Sources/WatchProtocol/`: `IDs.swift` (six `RawRepresentable` stable IDs that encode
  as bare strings), `Errors.swift` (all sixteen §5.5 codes with a retry policy and a fixed copy
  string each), `Snapshots.swift`, `Messages.swift` (all seventeen kinds, each with the §5.2
  channel it belongs on), and `Envelope.swift` (binary plist, version-probed before decode).
  `Connectivity/` adds the reducer, the ledger and revision gate, the transport seam, the router,
  and the fake link.

  Layout note against §13: the shared machinery sits in `TonearmWatchProtocol` because it is the
  only common ancestor of the phone and watch targets, and `PhoneWatchProtocolCoordinator` sits in
  `TonearmCore/Sources/WatchSync/` rather than `Sources/App/Watch/` because `Sources/App` is
  excluded from the SwiftPM target and would therefore be invisible to `swift test` — the phase's
  definition of done requires the *phone* coordinator to be driven by host tests. Ownership and the
  forbidden dependencies are unchanged; only the subdivision adapted, which §13 permits.

  Five decisions worth recording:

  1. **`WatchProtocolFault` has no string field at all.** A-06 is not enforced by review but by the
     type: there is nowhere to put a title, a query, a path, or a token. Display copy is a fixed
     table keyed by the code, and a guard fails the build if a stored `String` property appears.
  2. **The reducer is a pure value type taking `now: Date`.** The two-second grace period is
     therefore tested at the millisecond without waiting two seconds, and the only real timer lives
     in the coordinators' `graceTask`. `suspectedDisconnected` keeps `isConnectedForUI` true — C-08
     is about the *mode* not switching, and a blip may move a transient chip but never Downloads-only
     mode.
  3. **A cached application context does not prove the peer is awake.** The first draft let
     `activate(receivedContext:)` run through the same path as a live delivery, which drove the
     reducer to `connected` from state the phone published hours ago; a watch out of range showed a
     fully connected UI built entirely from cache. `accept(_:notesLiveness:)` now separates drawing
     the state from believing the link (C-01 with an honest C-05..C-10).
  4. **Reconnect renegotiates only after a *confirmed* outage.** Returning from a sub-grace blip
     reuses the session; returning from `disconnected` sends a fresh hello, because the phone may
     have been updated or switched libraries while it was away. One round trip per real absence,
     none per flap.
  5. **Search carries a double generation guard.** The generation echoed in the payload catches a
     phone answering an older request; the coordinator's own counter catches a merely slow reply.
     Either alone loses the race, so a superseded search returns `.superseded` — a first-class
     outcome, distinct from "no results", so a late answer cannot repaint the list (C-04).

  One concurrency exception exists in the whole phase, in both adapters: `nonisolated(unsafe) let
  handler = replyHandler`. WatchConnectivity's `sendMessageData` reply handler predates `Sendable`,
  is documented as callable from any queue exactly once, and cannot be transferred as `sending`
  because it arrives as a task-isolated parameter of an Objective-C delegate method.
  `@preconcurrency import` does not lift it. The exception is scoped to that one local binding and
  is paired with `WatchReplyHandlerBox`, a `Mutex`-backed carrier that clears the closure under the
  lock — so the "exactly once" half is enforced rather than merely documented. No `@unchecked
  Sendable` was added; `WatchInMemoryLedgerPersistence` uses `Mutex` for the same reason.

  Files changed: new `Sources/WatchProtocol/{IDs,Errors,Snapshots,Messages,Envelope}.swift` and
  `Sources/WatchProtocol/Connectivity/{WatchConnectionReducer,WatchMessageLedger,WatchTransport,
  WatchProtocolRouter,WatchFakeDuplexLink,WatchSessionTransport}.swift`; new
  `Sources/WatchCore/Sync/{WatchConnectivityObserver,WatchConnectivityCoordinator}.swift`; new
  `Sources/WatchSync/PhoneWatchProtocolCoordinator.swift`; new transport-only adapters
  `WatchApp/Connectivity/WatchProtocolSessionAdapter.swift` and
  `Sources/App/Watch/PhoneWatchProtocolAdapter.swift`; `ArchitectureTypes.swift` repointed at the
  new envelope with `.legacy` retained for `WatchSyncEnvelope`; four new guards in
  `scripts/check-ci-guards.sh`. Tests added: 65 — 17 `WatchProtocolEnvelopeTests`, 11
  `WatchConnectionStateTests`, 12 `WatchMessageLedgerTests`, 25 `WatchProtocolIntegrationTests`.

  Gates: `make ci-guards` passed, and the two new guards that can fail were each verified to fail
  when violated (a stored `String` on the fault; a real `[String: Any]` in `WatchCore`) — the
  dictionary guard strips comment lines first, because `WatchTransport.swift`'s doc comment states
  the rule it enforces. `make project` regenerated; `git diff --check` clean. `swift test` passed
  **1,667 tests with 8 intentional skips and 0 failures in 96.6s** (Phase 2 baseline: 1,602). The
  `TonearmWatch` generic watchOS Simulator build and the `Tonearm` iPhone 16 simulator build both
  succeeded with no new warnings.

  Known limitations: the new protocol is not on the shipped path — neither adapter is wired into
  an app assembly, and the legacy dictionary transport (`WatchSessionAdapter`,
  `PhoneWatchSessionAdapter`, `WatchTransferController`) still runs the watch until Phase 6 flips
  the flag; `WatchPhoneRequestHandling` ships with defaults that answer `sourceUnavailable`, since
  Phase 4 supplies the GRDB-backed projections. C-11..C-14 are Device rows and remain deferred, as
  do the I-05..I-11 measurements. Two pre-existing warnings in the untouched legacy files
  `Sources/WatchSync/WatchTransferQueue.swift:80` and `WatchTransferController.swift:149` are
  unchanged by this phase.
- Phase 4 (2026-08-26, this commit): **complete** — GRDB-backed phone projections, the §5
  request handlers the Phase 3 `sourceUnavailable` defaults stood in for, the `AudioPlayer`
  command bridge, and authoritative anchored now-playing snapshots. A fake-transport watch now
  searches the complete phone fixture library and plays a playlist through a spy phone player
  under `swift test`, with no simulator.

  Layout, per the Phase 3 note and §13: the host-testable pieces live in
  `TonearmCore/Sources/WatchSync/` — `PhoneWatchProjection.swift` (stable-ID prefixes `trow:`
  /`prow:`/`arow:`/`irow:` per §4, opaque `{offset}` base64 page tokens per §6.1 that decode to
  zero on corruption, and the DTO factories), `PhoneWatchPlaybackBridge.swift` (the `AudioPlayer`
  seam plus `WatchPlaybackSnapshotBuilder`, the one place the §5.3 "never the whole queue" window
  math exists), and `PhoneWatchRequestHandler.swift` (an actor conforming to
  `WatchPhoneRequestHandling`). Only the concrete `AudioPlayer`-backed adapter is Xcode-only:
  `Sources/App/Watch/PhoneWatchPlaybackAdapter.swift`, which holds no protocol logic and no
  `[String: Any]`. Both new adapters stay unwired until Phase 6 constructs them from `AppState`.

  Three decisions worth recording:

  1. **Search ranking parity comes from reusing `LibraryStore.search`, not reimplementing it.**
     Track hits go through the existing FTS query so the watch sees the same order as the phone;
     only albums/playlists/artists — which have no FTS index — use a normalized
     diacritic/case-insensitive contains, sorted by title. The rows are concatenated then paged,
     so a page token is an offset into the merged result, not per-kind cursors.
  2. **The snapshot carries an elapsed anchor, never a ticking clock.** `WatchPlaybackSnapshotBuilder`
     emits `elapsedSeconds + elapsedAnchorDate + rate`; the watch projects the current position
     itself. The queue window is clamped to `queueWindowLimit` (20) centred on the current index,
     so the count is stable near the ends and a long queue is never serialized.
  3. **Every play path re-reads authoritative state.** `handlePlayCommand` forwards the command to
     the bridge fire-and-forget, then returns `.accepted(await player.snapshot(...))` — the watch
     never trusts the command's optimistic view. A track deleted between request and play, or an
     empty collection, returns `.rejected(.contentNotFound)`; a `WatchProtocolFault` thrown during
     resolution is caught and mapped to its code, anything else to `.playbackItemFailed`.

  `LibraryStore` gained two additive read methods: `playlist(id:)` and
  `albumTrackRows(albumId:)` (disc/track order, hydrated).

  Files changed: new `Sources/WatchSync/{PhoneWatchProjection,PhoneWatchPlaybackBridge,
  PhoneWatchRequestHandler}.swift`; new `Sources/App/Watch/PhoneWatchPlaybackAdapter.swift`;
  `Sources/Data/LibraryStore.swift` (+2 methods); regenerated `Tonearm.xcodeproj`. Tests added:
  18 in `Tests/PhoneWatchProjectionTests.swift`, including the end-to-end
  `testWatchSearchesAndPlaysAcrossTheFakeDuplexLink` that drives a real
  `PhoneWatchProtocolCoordinator` and `WatchConnectivityCoordinator` over `WatchFakeDuplexLink`.

  Gates: `make ci-guards` passed; `make project` regenerated; `swift test` passed **1,685 tests
  with 8 intentional skips and 0 failures in 96.6s** (Phase 3 baseline: 1,667). Clean `iPhone 16`
  simulator and `Watch-Large` watchOS simulator builds both succeeded with no new warnings.

  Toolchain note: adding the two `LibraryStore` methods on top of an existing `.build` directory
  produced a stale incrementally-compiled `TonearmCorePackageTests.xctest` that failed
  `PlaylistCrateImporterTests` (spurious `noTracksOnDevice`, then SIGSEGV). `rm -rf .build` and a
  full rebuild resolve it deterministically; CI checks out fresh so it is unaffected. No source
  fix was needed — the code is correct, the incremental cache was not.

  Known limitations: the handler and both adapters are not on the shipped path — Phase 6 wires
  them from `AppState` and flips `swiftDataWatchArchitecture`. Device rows (C-11..C-14) and the
  I-05..I-11 measurements remain deferred to their acceptance phases. Screenshot and owner-signoff
  gates are deferred per the code-complete scope.
- Phase 5 (2026-08-27, this commit): **complete** — durable, reference-aware, resumable phone-side
  watch downloads. The schema `v15` migration adds `watchDownloadRoot` / `watchDownloadJob` /
  `watchDownloadManifestEntry` / `watchDownloadRevision` (seeded revision row `(1, 0)`), separate
  from the legacy `watchTransfer` table so existing phone downloads are untouched (§8.1). A
  fake-writer integration test plans an album + playlist + single-track mix (with a shared track
  and an unsupported track), transfers each real file exactly once, survives a simulated relaunch
  via `resumeOutstanding()`, and converges to `isIdle` / `readyCount == 5` /
  `estimatedRemainingBytes() == 0` after manifest receipt — the Phase 5 definition of done.

  Layout, per §13 and the Phase 3/4 pattern: all host-testable protocol logic is in
  `TonearmCore/Sources/WatchSync/` —
  - `PhoneWatchDownloadModels.swift` — `PhoneWatchDownloadRoot` (a complete revision, never a
    delta), `PhoneWatchDownloadJob` (one per track; `requestID` UUID key; states
    queued→resolving→transferring→sent, plus waitingForWiFi / failed / cancelled),
    `PhoneWatchManifestEntry`, and the internal GRDB records.
  - `PhoneWatchDownloadPlanner.swift` — pure, clockless reconciliation of desired roots + installed
    manifest truth + existing jobs into a deterministic `Plan` (`toCreate` / `toCancel` /
    `toReset`), with §8.1 priority buckets and E-04/E-05 reference counts.
  - `PhoneWatchTransferScheduler.swift` — `maxAudioInFlight = 2`, `maxMetadataInFlight = 1`,
    bounded exponential backoff (`base 5s`, `cap 300s`), and `WatchProtocolRetryPolicy`-derived
    failure classification.
  - `PhoneWatchDownloadStore.swift` — `actor` over the library `DatabaseQueue`; every state
    transition is persisted here *before* the manager touches the transfer seam. Prunes settled
    jobs (sent / cancelled / failed) once the track is installed or no longer desired.
  - `PhoneWatchDownloadManager.swift` (new) — the orchestrator `actor`: reconcile → plan → persist
    → pump. Injected seams (`PhoneWatchAudioResolving`, `PhoneWatchFileTransferring`,
    `PhoneWatchNetworkGate`, root emitter, playlist expander, clock) keep it fully host-tested.

  The one Xcode-only file is `Sources/App/Watch/PhoneWatchDownloadAdapter.swift` — it binds the
  seams to `LibraryStore` / `BookmarkVault` / `CacheStore` / `WatchSessionWriter` and holds no
  protocol logic. Unwired until Phase 6 constructs it from `AppState`.

  Three decisions worth recording:

  1. **The planner has no clock; the manager owns the retry timer.** A transient failure gets a
     `nextAttemptAt` from the scheduler's backoff. `reconcile()` computes which timers have
     elapsed and folds those track IDs into the same `explicitRetryTrackIDs` set the user's manual
     retries use — so the planner stays pure and backoff is never defeated by a re-reconcile
     clearing `nextAttemptAt`.
  2. **A `.sent` job is kept until the watch manifest confirms it.** Dedup is by track: a sent-but-
     unconfirmed job blocks re-queueing, and `pruneSettledJobs` drops it only once the manifest
     lists the track (§1.6 — the watch owns installed truth, a queued transfer is never rendered
     as downloaded).
  3. **Relaunch trusts the transfer framework, not the store.** `resumeOutstanding()` resets a
     job stranded in `.transferring` / `.resolving` whose track the framework no longer lists as
     outstanding back to `.queued`; genuinely in-flight transfers are left alone. The adapter's
     `outstandingTransfers()` returns `[]` for now (rehydrating `WCSession.outstandingFileTransfers`
     into job identity is Phase 6 wiring), so a relaunch conservatively re-queues and the manifest
     dedupes.

  On-demand fetch of a remote-only track is explicitly Phase 8: `PhoneWatchLibraryAudioResolver`
  resolves only already-local audio (imported asset or complete stream-cache entry) and returns
  `.unavailable` otherwise.

  Files changed: new `Sources/WatchSync/{PhoneWatchDownloadModels,PhoneWatchDownloadPlanner,
  PhoneWatchTransferScheduler,PhoneWatchDownloadStore,PhoneWatchDownloadManager}.swift`; new
  `Sources/App/Watch/PhoneWatchDownloadAdapter.swift`; `Sources/Data/Schema.swift` (v15 migration
  + `migrationOrder`); `Sources/WatchSync/PhoneWatchProjection.swift` (+1 public `trackRowID(_:)`
  resolution seam for the out-of-module adapter); regenerated `Tonearm.xcodeproj`. Tests added:
  28 in `Tests/PhoneWatchDownloadTests.swift`.

  Gates: `make ci-guards` passed; `make project` regenerated; `swift test` passed **1,713 tests
  with 8 intentional skips and 0 failures in 97.7s** (Phase 4 baseline: 1,685). Clean `iPhone 16`
  simulator and `Watch-Large` watchOS simulator builds both succeeded with no new warnings.

  Known limitations: the manager and adapter are not on the shipped path — Phase 6 wires them from
  `AppState`. Device rows (C-11..C-14), the I-05..I-11 measurements, and screenshot / owner-signoff
  gates remain deferred per the code-complete scope.
- Phase 6 (2026-08-27, this commit): **complete** — SwiftData is the only watch persistence path,
  `TonearmWatchLegacyCore` is deleted, and offline content is truthful: with the connectivity
  coordinator disconnected, the watch shows only ready local tracks and the playlists/albums
  derived from them, and every visible row resolves to a valid local file.

  Package graph after the cutover:

  ```text
  TonearmWatch
  ├── TonearmWatchProtocol                 (Foundation only)
  └── TonearmWatchCore
      └── TonearmWatchProtocol             (SwiftData; CloudKit explicitly .none)
  ```

  `TonearmWatchLegacyCore` and its GRDB edge are gone; `Sources/WatchLegacy/` is deleted; the
  structural guard now fails on any `product: TonearmWatchLegacyCore`, any `import GRDB` anywhere
  in the watch closure, the reappearance of `Sources/WatchLegacy/`, or the reappearance of
  `WatchApp/App/WatchFeatureFlags.swift`.

  Watch runtime graph (`WatchAppAssembly`): `WatchStoreBootstrap.open()` → `WatchLibraryRepository`
  → `WatchFileInstaller` (staging under `Application Support/PlatterheadWatch/Staging`) →
  `WatchSyncActor` (observer; turns link events into SwiftData truth, publishes the manifest back)
  → `WatchConnectivityCoordinator(transport: WatchProtocolSessionAdapter.transport,
  stateStore: WatchDefaultsSyncStateStore, observer: WatchFanoutObserver([syncActor, reachability]))`
  → `WatchProtocolSessionAdapter(endpoint: coordinator)`. The `@MainActor` `WatchLibraryModel` is
  the views' single source of truth and is refreshed from `WatchSyncActor.onLibraryChanged`.

  Phone runtime graph (`PhoneWatchRuntime`, owned by `AppState`): `PhoneWatchPlaybackAdapter`
  (bridges `AudioPlayer`) → `PhoneWatchRequestHandler` → `PhoneWatchProtocolCoordinator(transport:
  PhoneWatchProtocolAdapter.transport, revisionStore: <GRDB-backed adapter over
  PhoneWatchDownloadStore>)` → `PhoneWatchProtocolAdapter.activate()`, plus
  `PhoneWatchDownloadManager` whose `emitRoots` seam calls `coordinator.sendDownloadRoots`. The
  old `PhoneWatchSessionAdapter`, `WatchTransferController`, and full-catalog `WatchCatalog.export`
  are off the runtime path; `AppState` no longer imports GRDB. `WatchCatalog` itself and the
  legacy `watchTransfer`/`watchManifest` tables remain for Phase 10 to delete.

  Four decisions worth recording:

  1. **`removeTracks` leaves playlist membership alone.** Membership is the phone's; a track deleted
     from under a still-desired playlist is dropped from the library and its file, but its
     `WatchPlaylistEntryModel` stays — `WatchPlaylistSnapshot.isPartial` already tells the UI the
     row is incomplete, and `WatchLibraryModel` hides a playlist only once it has *no* ready track.
  2. **The watch has no streaming fallback after the cutover.** `WatchPlayer` resolves a track to
     its local file or nothing; the fetch-from-phone overlay and `WatchFetchOverlay.swift` are
     deleted. Offline truth is the only truth (§1.3, §2.2).
  3. **A composite observer, not a second `setObserver`.** The coordinator holds exactly one
     observer, and the watch needs two (`WatchSyncActor` for truth, `WatchReachabilityObserver`
     for chrome), so `WatchFanoutObserver` forwards all twelve callbacks verbatim.
  4. **One shared revision counter on the phone.** `PhoneWatchDownloadRevisionAdapter` bridges the
     GRDB `watchDownloadRevision` row into the coordinator's `WatchPhoneRevisionStore` seam so the
     download manager and the protocol coordinator stamp the same monotonic value.

  Migration: `WatchAppAssembly` runs a one-time move of any audio left in the pre-cutover
  `Application Support/WatchAudio` (and the caches mirror) into the new store's audio directory,
  keyed by a `legacyAudioMigration.v1` metadata flag; `WatchSyncActor` adopts the survivors by
  checksum on the next reconciliation once the phone re-declares the tracks. The GRDB legacy
  *reader* (`LegacyWatchLibraryStore.migrationSnapshot()`) is gone, so `WatchLegacyUpgrade` is no
  longer invoked; it and `migrateLegacy` stay in `TonearmWatchCore` (they still compile and are
  still unit-tested) for a possible future importer.

  Smoke fixture: DEBUG watch builds do not embed the `TonearmCore` SPM resource bundle, so
  `Resources/Audio/ambient-ocean.wav` is now copied into the `TonearmWatch` bundle directly
  (project.yml). `WatchFixtureSeeder` marks it ready with its real SHA-256 and builds the two
  playlists the one smoke method browses; playback advances the elapsed clock from the local file.

  Files changed: new `Sources/App/Watch/PhoneWatchRuntime.swift`,
  `WatchApp/App/{WatchLibraryModel,WatchDefaultsSyncStateStore,WatchConnectivityObservers}.swift`;
  rewritten `WatchApp/App/WatchAppAssembly.swift`, `WatchApp/PlatterheadWatchApp.swift`,
  `WatchApp/WatchPlayer.swift`, `WatchApp/WatchFixtureSeeder.swift`, all seven `WatchApp/Views/*`,
  `Sources/App/AppState.swift` (watch section), `Sources/Features/Settings/WatchSettingsView.swift`,
  `Sources/App/Watch/PhoneWatchDownloadAdapter.swift`; deleted
  `Sources/App/PhoneWatchSessionAdapter.swift`, `WatchApp/App/WatchFeatureFlags.swift`,
  `WatchApp/Views/WatchFetchOverlay.swift`, `Sources/WatchLegacy/LegacyLibraryStore.swift`;
  `Package.swift` (LegacyCore product/target/dep removed), `project.yml` (LegacyCore dep removed,
  watch fixture WAV added), `scripts/check-ci-guards.sh` (tightened), `Sources/WatchSync/
  PhoneWatchProjection.swift` (+`playlistRowID`/`albumRowID` seams), regenerated `Tonearm.xcodeproj`.
  Tests added: 17 — `Tests/WatchFileInstallerTests.swift` (12), `Tests/WatchSyncActorTests.swift`
  (5); `Tests/WatchArchitectureBoundaryTests.swift` repointed at `TonearmWatchProtocol`.

  Gates: `make ci-guards` passed (new guard clauses each verified to fail when violated);
  `make project` regenerated; `rm -rf .build && swift test` passed **1,729 tests with 8 intentional
  skips and 0 failures in 97.5s** (Phase 5 baseline: 1,713). Clean `iPhone 16` and `Watch-Large`
  simulator builds; the iPhone UI smoke (`TonearmSmokeUITests`, 17.6s) and the single watch UI
  smoke (`WatchSmokeUITests`, 32.5s — boots, plays the seeded local WAV with the elapsed clock
  advancing, toggles transport both ways, browses to the second playlist, shows the iPhone status)
  both passed.

  Known limitations, deferred per the code-complete scope: physical-device matrix (C-11..C-14),
  the I-05..I-11 timing measurements, screenshot and owner-signoff gates. The watch Storage screen
  is read-only this phase — local removal from the watch is Phase 8's iPhone-authoritative flow.
  Live-server "watch pulls audio over HTTP" has no automated coverage by design (§53 by-hand
  regression suite). `WatchCatalog` and the legacy `watchTransfer`/`watchManifest` phone tables
  are still present for Phase 10 to delete.
- Phase 7 (2026-08-27, this commit): **complete** — the watch's navigation and search surfaces
  rebuilt for both modes against §9 W1–W6/W12 and the stable accessibility-identifier contract. A
  slow request never leaves an endless spinner: it becomes `.unreachable` with Try Again / Search
  Downloads; a cold launch with no phone is an offline player from the first frame, not broken
  phone rows.

  New presentation layer in `Sources/WatchCore/Presentation/` — all host-tested, all injectable:
  - `WatchSearchPresenter` — the one search state machine. Debounced 250 ms after the second
    non-whitespace character; a presenter-side generation guard drops a late reply from a
    superseded query; `.recent → .tooShort → .loading → .results/.noResults/.unreachable` in
    connected mode, `.offlineResults/.offlineNoResults` in offline mode. The debounce sleep and
    both search backends are closures, so the whole machine runs under `swift test`.
  - `WatchRecentSearchStore` — `UserDefaults`-backed, capacity 6, plus an in-memory double.
  - `WatchConnectionChrome` — the banner model. Starts `.unavailable` (offline until negotiated);
    a sub-grace blip shows `.temporarilyUnavailable` but is not a confirmed offline banner;
    `disconnectPulse` increments once per confirmed outage for a single haptic; `.incompatible`
    is sticky until relaunch; holds the A-08 library-replacement prompt.

  Watch app: `WatchChromeObserver` (a third fanout observer) drives the chrome and flips the
  search presenter's mode from `connectionStateDidChange` / `didConfirmDisconnection` /
  `didReconnect` / `negotiationDidFail(.protocolUpgradeRequired)` / `pairedLibraryChange…`. New
  screens: `WatchConnectionBanner` (text + icon, never colour alone, never over transport),
  `WatchSearchView` (W2), `WatchPhonePlaylistsView` + `WatchPhoneCollectionView` (W1 browse / W3 —
  "Play on iPhone" is always the primary action, Download shows the manage-on-iPhone note because
  the protocol has no watch→phone download request), `WatchDownloadsView`, `WatchRecoveryView`
  (W12, diagnostics are state codes and counts only). `WatchRootView` switches connected vs
  offline home. All identifiers migrated to the §9 `watch.*` contract; the smoke test moved with
  them.

  Two decisions worth recording:

  1. **The chrome starts offline, not connected.** `WatchConnectionChrome(initial: .unavailable)`
     means a launch with no reachable phone shows a usable downloaded library immediately; the
     coordinator's first `connectionStateDidChange` upgrades it only once negotiation proves the
     phone is there. The alternative — start connected, correct on failure — flashes broken phone
     rows on every offline launch.
  2. **The connected journey is host-covered, not in the smoke test.** The watchOS simulator
     cannot pair a phone and its full-screen text entry is not scriptable in XCUITest, so the one
     smoke method exercises the offline journey (boot → local search surface → play a seeded
     playlist with the elapsed clock advancing → transport both ways → second playlist → back to a
     usable root). Connected search/browse/play-on-iPhone is covered by `WatchSearchPresenterTests`,
     `WatchConnectionChromeTests`, and the existing `WatchProtocolIntegrationTests` duplex-link
     tests.

  Files changed: new `Sources/WatchCore/Presentation/{WatchSearchPresenter,WatchRecentSearchStore,
  WatchConnectionChrome}.swift`; new `WatchApp/Views/{WatchConnectionBanner,WatchSearchView,
  WatchConnectedViews}.swift`; rewritten `WatchApp/Views/WatchRootView.swift`,
  `WatchApp/PlatterheadWatchApp.swift`, `WatchApp/App/{WatchAppAssembly,WatchConnectivityObservers}.swift`;
  identifier + minor updates to `WatchApp/Views/{WatchPlaylistsView,WatchAlbumsView,WatchStorageView,
  WatchNowPlayingView}.swift`; rewritten `WatchUITests/WatchSmokeUITests.swift`; regenerated
  `Tonearm.xcodeproj`. Tests added: 14 — `Tests/WatchSearchPresenterTests.swift` (9),
  `Tests/WatchConnectionChromeTests.swift` (5).

  Gates: `make ci-guards` passed; `make project` regenerated; `rm -rf .build && swift test` passed
  **1,743 tests with 8 intentional skips and 0 failures in 99.5s** (Phase 6 baseline: 1,729). Clean
  `iPhone 16` and `Watch-Large` simulator builds; the iPhone UI smoke and the single watch UI smoke
  (`WatchSmokeUITests`, ~45s) both passed.

  Known limitations, deferred per the code-complete scope: the smallest/largest-watch screenshot
  matrix in light/dark, large Dynamic Type, VoiceOver label/order audit, Reduce Motion, and high
  contrast; the physical-device matrix; and I-05..I-11 timing. The connected-mode UI compiles and
  is wired but has no simulator coverage (see decision 2). W7–W11 (Now Playing target switching,
  Up Next unavailable-row copy, download activity, full storage management) are Phases 8–9.
- Phase 8 (2026-08-27, this commit): **complete** — the iPhone download and storage experience
  (§9 P1–P5). Every watch download can now be started, understood, paused, retried, or removed from
  the iPhone without opening the watch app.

  New pure core in `Sources/WatchSync/PhoneWatchManagementPresenter.swift` (host-tested, clockless):
  projects `roots` + `jobs` + `manifestEntries` + the watch-reported `WatchManifestPayload` +
  pairing onto a `Snapshot` — pairing/connection, storage (installed/capacity/free bytes, used
  fraction, a `SpaceShortfall` when the remaining transfer + reserve exceeds free space, H-03),
  `ActivityRow`s with a typed `ActivityStage` (`.queued/.resolving/.transferring/.waitingForWiFi/
  .failed/.paused`), `CollectionRow`s with ready/waiting/unavailable/failed buckets, and a
  `TransferBanner`. `collectionDetail(rootID:)` adds the reference-aware removal preview
  (`tracksReleasedByRemoving` — E-04/E-05) and the first unavailable track's safe typed reason.

  Schema `v16`: a durable `paused` column on `watchDownloadRoot` (existing rows default false — a
  relaunch must not resume a transfer the owner stopped). `PhoneWatchDownloadManager` gained
  `pauseRoot` / `resumeRoot` (paused roots stay declared to the watch so installed tracks are kept,
  but reconcile excludes them from planning and cancels any job no unpaused root still wants),
  `cancelJob(requestID:)`, and `requestRetry(requestID:)`. The planner change worth noting: a
  user-cancelled job now stays cancelled until an explicit retry (previously a bare re-reconcile
  recreated it). `pruneSettledJobs` still spans *all* roots so a paused root's `.sent`-but-
  unconfirmed dedup guard is not lost.

  Phone wiring: `PhoneWatchProtocolAdapter.currentCapability()` reads `WCSession.isPaired` /
  `isWatchAppInstalled` / `isReachable`; `PhoneWatchRuntime` retains the last `WatchManifestPayload`,
  builds the snapshot in `refresh()`, tracks `connectedSince`, and exposes the five management
  actions + `collectionDetail`. `AppState` republishes `watchManagement` and its legacy
  `watchSessionState` is now honestly derived (not just reachable-vs-not).

  Views: rewritten `Sources/Features/Settings/WatchSettingsView.swift` (P2/P3 overview — header
  with real storage + used %, shortfall card, Downloading list, Downloaded Collections, Reconcile +
  Remove All with the "music remains in Platterhead" confirmation); new
  `Sources/Features/Settings/WatchDownloadDetailViews.swift` — `WatchDownloadQueueView` (P3, per-job
  Cancel / Try Again / Remove from Queue) and `WatchDownloadedCollectionDetailView` (P4, keep-on-watch
  toggle = pause/resume, status breakdown with the unavailable reason, reference-aware Remove copy);
  `GlassDock`'s transfer pill reworked into the P5 banner (`watch.transferBanner`, failure
  affordance). P1 menu wording unified to "…to Apple Watch" in `Components.swift`,
  `SourceDetailView`, `PlaylistsView`, `NowPlayingView`; `showWatchSettings` is finally presented
  from `RootView`. Identifiers per §9: `settings.watch`, `.queue`, `.storage`, `.reconcile`,
  `.removeAll`, `watchRoot.<rootID>`, `watchJob.<requestID>`.

  Files changed: new `Sources/WatchSync/PhoneWatchManagementPresenter.swift`, new
  `Sources/Features/Settings/WatchDownloadDetailViews.swift`; `Sources/Data/Schema.swift` (v16),
  `Sources/WatchSync/{PhoneWatchDownloadModels,PhoneWatchDownloadManager,PhoneWatchDownloadPlanner}.swift`,
  `Sources/App/Watch/{PhoneWatchProtocolAdapter,PhoneWatchRuntime}.swift`, `Sources/App/AppState.swift`,
  `Sources/Features/{Settings/WatchSettingsView,Chrome/GlassDock,RootView,Components,
  Sources/SourceDetailView,Playlists/PlaylistsView,NowPlaying/NowPlayingView}.swift`, regenerated
  `Tonearm.xcodeproj`. Tests added: 18 — `Tests/PhoneWatchManagementPresenterTests.swift` (14),
  `Tests/PhoneWatchDownloadTests.swift` (+4: v16 round-trip, pause cancels in-flight, resume
  re-queues, cancel stays cancelled across reconcile).

  Gates: `make ci-guards` passed; `make project` regenerated; `rm -rf .build && swift test` passed
  **1,761 tests with 8 intentional skips and 0 failures** (Phase 7 baseline: 1,743). Clean
  `iPhone 16` and `Watch-Large` simulator builds; iPhone UI smoke and the single watch UI smoke
  both passed.

  Known limitations, deferred per the code-complete scope: the Dynamic Type / VoiceOver / Reduce
  Motion / high-contrast visual matrix; the device legs of H-01 / H-03 / H-04 / H-07 (byte
  reconciliation, storage-full, reference-aware removal, reconcile repair on real hardware). No new
  simulator UI test — per §11.3 the iPhone smoke path is extended rather than adding functions, and
  the presenter/planner logic is fully host-covered.
- Phase 9 (complete): split into commits because the phase spans far more than 6–8 — 9a
  (local-playback core), 9b (audio-session lifecycle + Now Playing), 9c (explicit targets +
  remote prediction + W7–W9), 9d (`Continue on Apple Watch`). Phase 10 is next.
  - **9a (2026-08-27, this commit): pure local-playback core, no I/O, no view changes.**
    `WatchQueueSnapshot` gains `isShuffled` / `shuffleSeed` / `repeatMode` with a hand-written
    `Decodable` so a position persisted by a pre-Phase-9 build (those keys absent) restores with
    sane defaults instead of decoding-throwing and being wiped by `loadOrClear`. Shuffle is now a
    deterministic SplitMix64 permutation of `(seed, queue)` — `WatchSeededRNG`,
    `setShuffle(_:seed:)`, seed persisted in the snapshot — so a relaunch that re-derives the order
    from the same input reproduces the session sequence (§7.3). New
    `WatchPlayerEngine.restored(from:availableKeys:)`: a pure constructor that rebuilds a **paused**
    engine, drops every track whose file key is absent, remaps the current index to the surviving
    track nearest the saved position (current → first-after → last-before → 0), and keeps `elapsed`
    only when the current track itself survived. Files: `Sources/WatchCore/Playback/WatchPlayerEngine.swift`;
    new `Tests/WatchPlaybackRestoreTests.swift` (13 cases). Gates: `swift test --filter` over the
    playback engine/position/restore suites — 36 pass / 0 fail. Full `swift test`, `make ci-guards`,
    and both simulator builds run by the pre-commit hook. Deferred to 9b: audio session +
    route/interruption/media-services-reset lifecycle, background audio, Crown volume applied to the
    player, system Now Playing + supported-only remote commands, `Close` must not stop playback,
    edge/10s persistence, spy directive-order tests, one watch smoke. Deferred to 9c: explicit
    `iPhone`/`thisWatch` target model + switch UI, remote snapshot prediction wiring,
    `Continue on Apple Watch`, W7–W9 screens.
  - **9b (2026-08-27, this commit): audio-session lifecycle + system integration.** New pure
    `WatchAudioSessionPolicy` (`Sources/WatchCore/Playback/WatchAudioSessionPolicy.swift`):
    `WatchAudioEvent` (route lost/available, interruption began/ended-with-`shouldResume`,
    media-services reset, app background/foreground, wrist-down) → ordered `[WatchAudioAction]`
    (pause / persist / rebuildSession / resumeIfWasPlaying / show|clearRouteHint). Invariants:
    route loss + interruption both park paused+persisted with a route hint; the only auto-resume
    is `interruptionEnded(shouldResume: true)` while already playing; media-services reset stays
    paused. `WatchAudioOutput` gains `setVolume(_:)` and `rebuildSession()`; a new pure
    `applyWatchDirectives(_:to:)` applies engine directives **in order** (the old `WatchPlayer`
    spawned one `Task` per directive, racing `.loadItem` vs `.play`). `WatchPlayer` observes
    `AVAudioSession` interruption/route/media-reset notifications + `scenePhase`, runs them
    through the policy, publishes `routeHint`, applies Crown `volume` to the player, and persists
    on inactive/background. Remote command center: only play/pause/togglePlayPause/next/previous
    enabled, everything else explicitly disabled. `Close` in `WatchNowPlayingView` now only
    `dismiss()`es — playback continues, the root chip reopens it. `restorePositionIfAvailable`
    delegates to 9a's `WatchPlayerEngine.restored(...)` so shuffle seed / repeat mode survive.
    Files: `Sources/WatchCore/Playback/{WatchAudioSessionPolicy,WatchAudioOutput}.swift`,
    `WatchApp/{WatchPlayer,AVPlayerOutput}.swift`, `WatchApp/PlatterheadWatchApp.swift`,
    `WatchApp/Views/{WatchNowPlayingView,WatchRootView}.swift`; new `Tests/WatchAudioSessionPolicyTests.swift`
    (9) + `Tests/WatchDirectiveApplierTests.swift` (3, spy ordering); `WatchUITests/WatchSmokeUITests.swift`
    gained a Close-doesn't-stop-playback leg — it pops to the root and reads the Now Playing
    chip's new `playing`/`paused` accessibility value (the chip renders only on the root, and
    Now Playing is a sheet over whatever screen launched it). Gates: `swift test` (full), `make ci-guards` clean,
    watch + iPhone simulator builds green. Deferred to 9c: explicit `iPhone`/`thisWatch` target
    model + switch UI, remote snapshot prediction, W7–W9 screens. Deferred to 9d: `Continue on
    Apple Watch`. Deferred to the physical-device pass: real
    route/interruption/background/wrist-down behaviour (§11.4) — the simulator does not deliver
    those notifications authentically.
  - **9c (2026-08-27, this commit): explicit playback targets + remote prediction + W7–W9.**
    New pure `WatchPlaybackTarget` (`iPhone`/`thisWatch`) + `WatchPlaybackTargetStore`
    (`Sources/WatchCore/Playback/`, UserDefaults, default `.iPhone`); `WatchPlaybackCoordinator`
    (`@MainActor`, `WatchApp/`) is the sole mutator — local play → `.thisWatch`, an accepted
    phone `playCollection`/`playTrack` → `.iPhone`, the Now Playing target row switches by hand
    (§7.1, never automatic). New pure `WatchRemotePlaybackState` (`Sources/WatchCore/Playback/`)
    wraps the last `WatchPhonePlaybackSnapshot` + arrival `Date`, predicts elapsed from the
    `(elapsed, anchorDate, rate)` anchor clamped to duration, exposes staleness, and `applying(_:)`
    drops an out-of-order snapshot (I-06). `WatchRemotePlayer` (`@MainActor`, `WatchApp/`) holds
    it, forwards transport to the phone, and — only while W7 is on screen — runs a 1s prediction
    clock + a 5s `requestSnapshot` correction poll. New additive
    `WatchTransportAction.requestSnapshot`: read-only, `PhoneWatchRequestHandler` falls through to
    the trailing `.accepted(snapshot)`. `PhoneWatchRuntime` also pushes a snapshot via
    `publishContext` when the player's structure fingerprint changes, folded into the existing 5s
    tick (no new poll; `currentTime` drift is not a trigger). `WatchNowPlayingView` → W7/W8 switch
    (`watch.now.target` row); `WatchUpNextView` → W9 (active target's queue, `iPhone only` on
    rows not downloaded locally). The root Now Playing chip is left local-only: observing the
    remote/target state from the root's `.carousel` `List` destabilised its lazy row realisation
    and dropped below-fold rows from the a11y tree (the watch smoke caught it — `watch.playlists`
    not found after a nav pop). Files:
    `Sources/WatchCore/Playback/{WatchPlaybackTarget,WatchRemotePlaybackState}.swift`,
    `Sources/WatchCore/Sync/WatchConnectivityCoordinator.swift`, `Sources/WatchProtocol/Messages.swift`,
    `Sources/WatchSync/PhoneWatchRequestHandler.swift`, `Sources/App/Watch/PhoneWatchRuntime.swift`,
    `WatchApp/{WatchRemotePlayer,WatchPlaybackCoordinator}.swift`,
    `WatchApp/App/{WatchRemotePlaybackObserver,WatchAppAssembly}.swift`,
    `WatchApp/{WatchPlayer}.swift`, `WatchApp/Views/{WatchNowPlayingView,WatchUpNextView}.swift`;
    new `Tests/WatchPlaybackTargetTests.swift` (5) + `Tests/WatchRemotePlaybackStateTests.swift`
    (6), one `requestSnapshot` case in `PhoneWatchProjectionTests`; the watch smoke asserts
    `watch.now.target` reads `Apple Watch` after a local play. Gates: `swift test` (full),
    `make ci-guards` clean, watch + iPhone simulator builds green, watch smoke green. Deferred to
    9d: `Continue on Apple Watch` (§7.5) + pure `WatchContinueOnWatchPlan`. Deferred polish: a
    secondary cross-target play affordance on the browse screens. Deferred to the physical-device
    pass: a paired-phone remote-control journey (the watchOS sim cannot pair a phone).
  - **9d (2026-08-27, this commit): Continue on Apple Watch (§7.5).** New pure
    `WatchContinueOnWatchPlan.make(from:locallyAvailable:now:)` (`Sources/WatchCore/Playback/`):
    projects the phone's last snapshot onto a local queue — downloaded members of the queue
    window in order, start index at the phone's current track among survivors, `elapsedAnchor`
    = last authoritative anchor projected to now and clamped to duration; `nil` (no offer) when
    the current track isn't downloaded here or nothing is playing; an empty window still
    continues the one known track. `WatchRemotePlaybackObserver.didConfirmDisconnection` →
    `WatchPlaybackCoordinator.armContinueFromDisconnect()` (only if iPhone was the target),
    which builds the plan against `WatchAppAssembly.locallyAvailableTrackIDs()` and publishes
    `continuePrompt`; `didReconnect` clears it. The W7 branch of `WatchNowPlayingView` shows the
    `iPhone Unavailable` card (`watch.now.continue` / `Keep Waiting`) instead of transport;
    `acceptContinue()` → `WatchAppAssembly.startContinueOnWatch` resolves to local snapshots,
    `WatchPlayer.play` (selects the this-watch target) + new `WatchPlayer.seek(to:)`. Labelled,
    brief pause, begins locally — never gapless, never a speculative stop to the unreachable
    phone. Files: `Sources/WatchCore/Playback/WatchContinueOnWatchPlan.swift`,
    `WatchApp/{WatchPlaybackCoordinator,WatchPlayer}.swift`,
    `WatchApp/App/{WatchRemotePlaybackObserver,WatchAppAssembly}.swift`,
    `WatchApp/Views/WatchNowPlayingView.swift`; new `Tests/WatchContinueOnWatchPlanTests.swift`
    (6). Gates: `swift test` (full), `make ci-guards` clean, both simulator builds + watch smoke
    green. Deferred: the coordinator glue has no host test (watch app target, not a SwiftPM
    lib); the paired-hardware disconnect→continue journey is the physical-device pass. **Phase 9
    is now complete.**
  - **9 follow-up (2026-08-27, this commit): §7.1 cross-target play affordance.**
    `WatchPlaylistDetailView` shows `Play on iPhone` (`watch.collection.playPhone`) below the
    local Play All / Shuffle when `model.phoneReachable` — the local playlist id is the phone
    collection ref id (the sync actor stores `playlistID: root.sourceID`), so
    `playOnPhone(.playCollection(...))` just works. `WatchPhoneCollectionView` shows
    `Play on Apple Watch` (`watch.collection.playLocal`) below Play on iPhone when any member is
    downloaded here. Both routes go through a new shared
    `WatchAppAssembly.playLocalTrackIDs(_:startAt:seekTo:)` (also now the body of
    `startContinueOnWatch`). Deferred to **Phase 11**: (1) a root Now Playing chip reflecting the
    iPhone target — observing remote/target state from the root's `.carousel` `List` broke its
    lazy row realisation (watch smoke), so the chip stays local-only until it can be laid out
    outside the List; (2) all paired-hardware behaviour (route/interruption/background/wrist-down,
    the disconnect→continue journey) — the watchOS simulator cannot pair a phone.
- Phase 10 (COMPLETE, 2026-08-27): spanned more than 6–8 tasks (legacy deletion, diagnostics,
  fault/soak harnesses), so it was split into commits 10a–10f like Phase 9. DoD met: no legacy
  implementation remains in the watch target, all structural guards pass, the six fault/soak
  scenarios converge, memory/disk are bounded. Phase 11 is next.
- Phase 11 (agent-closable slice COMPLETE, 2026-08-28; commits 11a–11d): the parts that do not
  need paired hardware. What landed:
  - **11a (`f34162a`): the one watch smoke covers the basic-functions journey.** Open the
    app → search surface → find a track in the Tracks list, start/stop → find an album, play,
    start/stop → playlist transport journey → exit while playing. Still exactly one test
    method (`verify-ui-smoke-tests.sh` enforces it). New stable a11y ids `watch.albums` /
    `watch.songs` (root nav rows) and `watch.album.<stableID>` (album rows), added to the §9
    contract table. A `reveal` helper swipes the root `.carousel` to bring below-fold rows
    into the a11y tree before asserting. Owner pushed this commit 2026-08-27.
  - **11b (`e444fc5`): root Now Playing chip reflects the active target + accessibility pass.**
    The chip (Phase 9 deferral) is now its own `WatchNowPlayingChip` view with its own
    `@ObservedObject`s, so a churny remote/target update invalidates only the chip and not
    `WatchRootView.body` — the isolation the Phase 9 note called for, without moving the chip
    out of the list. It shows the predicted iPhone state when the target is iPhone ("On
    iPhone"), the local player otherwise. Accessibility (I-01/I-02): VoiceOver labels on every
    icon-only control (local + remote transport, Up Next, volume, target row + hint); the
    "downloaded on watch" state carries a VoiceOver label in the search and phone-collection
    lists (not colour-alone); queue rows announce "Now playing"/"Paused here".
  - **11c (`e780131`): Siri / Shortcuts entry for downloaded playback.** Two watchOS App
    Intents driving the local engine only — `PlayDownloadedPlaylistIntent` (name resolved by
    the pure host-tested `WatchPlaylistNameMatch`) and `ResumeWatchPlaybackIntent` —
    registered by `WatchShortcutsProvider`. New: `WatchPlaylistNameMatch.swift`,
    `WatchApp/AppIntents/WatchPlaybackIntents.swift`, `WatchPlaylistNameMatchTests.swift` (6).
  - **11d (`09f9149`): docs** — the `ACCEPTANCE_MATRIX.md` run record, this audit entry, and
    the `current_status.md` Phase 11 block.
  - **11e (`75dbbef`): the smoke asserts the elapsed clock freezes on stop.** The
    downloaded-track and album legs read `watch.now.elapsed`, wait 3s, and assert it has not
    moved — a stop that only relabels the Play button can't pass. Both legs run with the
    iPhone absent (simulator default); the fixture seeder's ready-asset copy is the simulated
    download.
  - **11f (this commit): Now Playing reworked + the watch audio path hardened.** The screen is
    a vertical `ScrollView` (Apple Music / Spotify class): 104pt rounded artwork, rounded
    title/artist, a real scrubber with monospaced times, a roomy transport row, a footer —
    fixes the toolbar/title overlap and the crowded bottom the owner reported. Artwork comes
    from the downloaded file's embedded cover metadata (`AVAsset.load(.commonMetadata)`) — no
    protocol change — and is also handed to `MPNowPlayingInfoCenter`; gradient+glyph
    placeholder otherwise. `AVPlayerOutput` stops swallowing `AVAudioSession.activate()`
    failures: it reports a reason, records a `.routeEvent` diagnostic, and the W8 body shows a
    "Choose an Audio Output" card (`watch.now.chooseRoute`) that re-requests the route. A KVO
    observer on `AVPlayer.rate` publishes `outputRate` → `watch.now.debugRate` under
    UI_TESTING for the on-device audio pass. New a11y id `watch.now.artwork`; §9 contract
    updated. **Not closable here:** true audio *output* — the watchOS simulator has no audio
    hardware — stays an owner/device check.
  - Gates across 11a–11f: `rm`-clean `swift test` green via the pre-commit hook (1,756 + 6);
    watch simulator build green; the one watch smoke green (3× locally for 11b and 11f);
    `make ci-guards` clean; `make project` regenerated for 11c with a clean `.xcodeproj` diff.
  - I-04 (Reduce Motion) is satisfied by construction: `grep` finds no
    `withAnimation`/`.animation(`/`.transition(` anywhere in `WatchApp/`, and the only motion
    is `ProgressView` (a progress indicator, kept).
  - **Deferred to the owner (paired hardware + sign-off):** I-05..I-13 measured targets
    (launch/search/transport p95, Instruments main-thread stalls, battery/thermal for the
    60-minute run, the TestFlight upgrade, the full mockup-screenshot audit); every `Device`
    row in sections C/G/H; and the final listening + UX pass. These are Phase 11's DoD and
    are not agent-closable.
  - **10a (2026-08-27, this commit): pre-cutover watch transfer pipeline deleted (§10, §12).**
    The Phase 6 cutover left the old full-catalog / transfer-queue code compiling but
    unreferenced; it is now gone. Deleted sources: `Sources/WatchSync/{WatchCatalog,
    WatchLibraryFilter,WatchTransferController,WatchTransferQueue}.swift`,
    `Sources/WatchProtocol/WatchSyncMessage.swift` (the legacy `WatchSyncEnvelope` /
    `WatchCatalogSnapshot` / `Watch*DTO` cluster). `WatchTransferState` (the four-case
    queued/sending/sent/failed enum) was the one symbol still live — `AppState`'s track-row
    glyph maps download-job state onto it — so it moved to `WatchGlyphState.swift` beside the
    `WatchGlyph` API that is its only consumer. `WatchManifest.report(from:)` (returned the
    deleted `WatchManifestReport`) dropped; its stats helpers and `WatchLocalManifestEntry`
    stay. `WatchProtocolVersion.legacy` removed. Domain/GRDB: `WatchTransferRecord` /
    `WatchManifestRecord` structs + their `FetchableRecord` extensions deleted; new schema
    **v17** drops the v12 `watchTransfer` / `watchManifest` tables (no reader/writer since the
    cutover; no data migration needed). `WatchManifestPayload` and the `.watchManifest`
    protocol message are the *new* stack and untouched. Deleted tests:
    `Tests/{WatchCatalogTests,WatchLibraryFilterTests,WatchTransferQueueTests,
    WatchTransferPlannerTests,WatchSyncMessageTests,MigrationV12Tests}.swift`;
    `PhoneWatchDownloadTests.testV15DoesNotDisturbLegacyWatchTransferTable` →
    `testV17DropsLegacyWatchTransferTables`; one obsolete `WatchManifestTests` case removed.
    New guards in `check-ci-guards.sh`: the five deleted source files must not return, and no
    `WatchCatalog` / `WatchSyncEnvelope` / `WatchTransferRecord` / `WatchManifestRecord`
    reference may reappear in `Sources`/`Tests`/`WatchApp`. Gates: `rm -rf .build && swift
    build` clean, `make ci-guards` clean, `make project` regenerated (no `.xcodeproj` diff —
    folder-globbed), watch/schema/download test subset green. Full `swift test` + simulator
    smokes run by the pre-commit hook.
  - **10b (2026-08-27, this commit): the privacy-safe diagnostics core (§12).** New pure
    `Sources/WatchCore/Diagnostics/`: `WatchDiagnosticEvent` (category ∈ {activation, request,
    transferState, installResult, manifestConvergence, playbackTarget, routeEvent,
    storeRecovery, disconnectDuration}, a fixed-vocabulary `stateCode`, timestamp, optional
    opaque `correlationID`, optional numeric `durationMillis`/`byteCount`/`count` — no free-text
    field exists); `WatchDiagnosticsLog` fixed-capacity ring (drops oldest — bounded memory);
    `WatchDiagnosticsRecorder` `actor` sink with injectable clock; `WatchDiagnosticsExporter`
    builds the in-app export as JSON carrying only per-export salted-SHA-256-hashed correlation
    ids (fresh random salt per export, 16 hex chars), state codes, ISO-8601 timestamps,
    `WatchProtocolVersion.current`, and the numeric measurements. `Tests/WatchDiagnosticsTests.swift`
    (6): ring eviction, clock stamping, hash stability/salt sensitivity, and a raw correlation
    id never appears in the encoded JSON. No call sites wired yet — that is 10c. Gate: `rm -rf
    .build && swift build --target TonearmWatchCore` clean; the new suite green.
  - **10c (2026-08-27, this commit): first diagnostics call sites + the in-app export UI (§12).**
    `WatchAppAssembly` owns the shared `WatchDiagnosticsRecorder` (`diagnostics`) and
    `diagnosticsExport()` (stamps `CFBundleShortVersionString`, fresh salt). Wired:
    `start()` → `.activation "started"` + `.storeRecovery <launchState.rawValue>`;
    `WatchPlaybackCoordinator.setTarget` → `.playbackTarget <rawValue>` on every explicit switch;
    `WatchRemotePlaybackObserver` (converted `final class` → `actor` to hold a `disconnectedAt`
    stamp) → `.routeEvent "disconnected"` and `.disconnectDuration "reconnected"` with the
    measured `durationMillis`. New `WatchDiagnosticsView` (Storage › Diagnostics,
    `watch.storage.diagnostics`) renders the encoded JSON in a monospaced `ScrollView` +
    Refresh (`watch.diagnostics.json` / `watch.diagnostics.refresh`). Gate: `make project` +
    `xcodebuild build -scheme TonearmWatch` (watchOS sim) green; `make ci-guards` clean; full
    `swift test` + smokes by the hook.
  - **10d (2026-08-27, this commit): legacy deletion finished (§10, §12).** The superseded
    GRDB→SwiftData *catalog import* is deleted — `Sources/WatchCore/Library/WatchLegacyUpgrade.swift`
    (whole file), `WatchLibraryRepository.migrateLegacy(_:)`, and the `WatchLegacyLibrarySnapshot`
    / `WatchLegacyTrackSnapshot` / `WatchLegacyPlaylistSnapshot` value types — unreachable since
    Phase 6 removed the legacy product that supplied the GRDB reader. Metadata is rebuilt from
    the phone by reconciliation, so no user data is lost. Dead tests removed
    (`WatchLegacyUpgradeTests`, `testLegacyUpgradeIsIdempotentAndAdoptsValidatedAudio`, `Counter`).
    `check-ci-guards.sh`: the deleted file must not return and no `WatchLegacyUpgrade` /
    `WatchLegacyLibrarySnapshot` / `migrateLegacy(` reference may reappear. **Kept on purpose:**
    `WatchAppAssembly.migrateLegacyAudioIfNeeded` — the one-time, idempotent *audio* bridge that
    preserves downloaded tracks across the TestFlight upgrade; it does not duplicate the new
    architecture. No compatibility flag remains (`WatchFeatureFlags.swift` went in Phase 6).
    Gate: `rm -rf .build && swift build --target TonearmWatchCore` clean; `make ci-guards` clean;
    `WatchLibraryRepositoryTests` green.
  - **10e (2026-08-27, this commit): the remaining diagnostics call sites (§12).** All nine
    signals now record. `WatchConnectivityCoordinator` takes an optional `WatchDiagnosticsRecorder`
    and logs one `.request` per round trip (`stateCode` = message kind on success / fault code on
    failure, `durationMillis` = wall time — covers request latency and negotiation, a `hello`
    request). `WatchSyncActor` takes it too: `.installResult` per install outcome (`installed`
    carries `byteCount`, a rejection its fault code) and `.manifestConvergence "reported"` on every
    `publishManifest` with ready `count` + installed `byteCount`. New `WatchDiagnosticsObserver`
    (record-only `WatchConnectivityObserver`) joins the fanout for `.transferState`, `.activation`,
    and `.routeEvent`. `WatchAppAssembly` threads the shared `diagnostics` into all three. Tests:
    `Tests/WatchDiagnosticsWiringTests.swift` (3) + two `WatchProtocolIntegrationTests` cases; each
    asserts no event carries a correlation id or free text. Gate: `swift test` watch subset +
    `xcodebuild build -scheme TonearmWatch` (watchOS sim) + `make ci-guards` green; full suite by
    the hook.
  - **10f (2026-08-27, this commit): the fault-injection / soak harnesses — Phase 10 done (§12).**
    Six `swift test` scenarios, each asserting **convergence** + **bounded memory/disk**.
    `Tests/WatchSoakTests.swift`: (1) 1,000 shuffled duplicate/out-of-order durable events through
    `WatchAppliedMessageLedger` + `WatchRevisionGate` → newest revision wins, no regression applied,
    ledger ≤ 512-id capacity; (3) 500 reachability flaps through `WatchConnectionReducer` → settles
    connected, exactly one disconnect alert per confirmed outage (250), never per-flap; (6) six
    simulated hours of local playback (`WatchPlayerEngine` repeat-all 12-track queue, 2,160 position
    saves, predicted remote clock) → engine stays a valid in-range queue, predicted clock clamped
    to duration, persisted blob never grows past ~1 KB. `Tests/PhoneWatchDownloadTests.swift`:
    (2) 500-track desired set → converges idle, each file transferred once, job table prunes to
    empty; (4) 100 cancellations → all stay cancelled across reconciles, none revived, no dup jobs;
    (5) relaunch at every `PhoneWatchJobState` → `resumeOutstanding` converges each to a consistent
    terminal, ≤ one job per track. Gate: all six green; full suite + both smokes by the hook.
    **Phase 10 DoD met** — no legacy in the watch target, guards pass, fault tests converge,
    memory/disk bounded.
