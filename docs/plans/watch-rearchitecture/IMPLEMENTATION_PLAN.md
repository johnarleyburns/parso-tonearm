# Platterhead Watch App — SwiftData / iPhone-Only Sync Rearchitecture

Status: **adopted; Phase 1 complete; Phase 2 next**

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
| Root | `watch.root`, `watch.connection.banner`, `watch.nowPlaying`, `watch.search`, `watch.playlists`, `watch.downloads` |
| Search | `watch.search.field`, `.scope`, `.loading`, `.retry`, `.downloads`, `watch.search.result.<stableID>` |
| Collection | `watch.collection.playPhone`, `.playLocal`, `.download`, `.status`, `watch.track.<stableID>` |
| Now Playing | `watch.now.target`, `.title`, `.elapsed`, `.previous`, `.playPause`, `.next`, `.upNext`, `.more`, `.continueLocal`, `.chooseRoute` |
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
- Phase 2: **next**.
