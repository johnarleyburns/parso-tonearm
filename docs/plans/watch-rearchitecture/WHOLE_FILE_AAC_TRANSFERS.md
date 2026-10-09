# Watch audio: whole-file AAC128 (2026-10-07)

This replaces the resumable/chunk design at the owner's request.

## Delivery contract

- The iPhone prepares every source as AAC-LC in M4A, 128,000 bits/sec,
  stereo, 44.1 kHz. The encoder uses explicit settings, not the unspecified
  Apple M4A export preset. Original phone audio is unchanged.
- Prepared, app-owned snapshots are keyed by source SHA-256 and format version.
  Security-scoped document access covers the complete read/encode operation.
- Production audio calls `transferFile` exactly once with the entire prepared
  file and its checksum/size metadata. There is no chunk sender, chunk capability,
  confirmation window, live-reachability gate, or application-level byte resume.
- Apple's native outstanding transfers and progress are the transport authority.
  Delivery completion is not proof of installed audio. Only a validated watch-local
  asset can play offline or count as downloaded.
- The watch moves Apple's inbox file synchronously before the delegate returns.
  It then verifies, installs, and reports local truth independently of phone liveness.
  Its fanout observer is installed in the coordinator initializer, before native
  activation; background-startup deliveries cannot fall into an unwired observer gap.

## Reconciliation and consent

The foreground watch publishes a coalesced status every 15 seconds, plus durable
reports on catalog/install changes. Reports include catalog size, installed track
IDs/bytes, received files awaiting metadata, and attempt-specific errors. The phone
publishes its current catalog/download view periodically and restores the latest
watch report on relaunch. Both retain their own authority: phone transfer state
cannot manufacture a ready watch asset; a watch report cannot manufacture phone
byte progress. Background execution and radio scheduling remain Apple's decision.

Failures have no next-attempt timer. A submitted file unconfirmed after 24 hours
shows a retry question without re-enqueueing or cancelling Apple's file. Only a
user retry cancels that old attempt and submits a new file. Interrupted process
work also asks for approval. Late completion/error reports are matched to the
persisted whole-file attempt ID, so they cannot fail a replacement.

Migration stops unfinished old-format/chunk jobs and asks for approval before an
AAC transfer. Previously installed audio remains playable. Old chunk protocol
types remain only for compatibility and historical regression tests; neither
production assembly instantiates the chunk sender/assembler.

## UI and verification

### Metadata-only check (2026-10-08)

A regression reproduced a destructive deferred-install bug with the real CC0 AAC:
audio received before its catalog row was retained, then an unrelated catalog page
triggered retryDeferred. Retention tried to move the retained file onto itself by
first deleting it. Later matching metadata therefore had no audio left to install.
Audio/artwork retention now skips self-moves, and retention failures report an
installation error instead of claiming the bytes are safely deferred. Regression
coverage includes unrelated pages and repeated deferred processing after a new
installer is created, then successful installation without another transfer.
This is a confirmed file-loss path; the owner's exact remaining device stall is
not established from the diagnostics snapshot alone.

Both Settings surfaces have a Sync now check inspired by Cladiron's Phone Sync.
It uses a small, correlated request/reply carrying each device's status, with a
durable background copy when live messaging is unavailable. Confirmed means the
peer actually answered with its metadata, not merely that Apple accepted a queue
write. Queued and failed checks remain distinct. This status check does not tick
the download manager, restart audio transfers, or transcode anything. Full catalog
republication remains the separate Reconcile action on iPhone.

Native immediate-message cancellation releases the continuation even if Apple's
reply/error callback never arrives. Otherwise a structured deadline task group
waits forever for its cancelled, non-cooperative child. Tests exercise the missing
callback and cancellation-before-install races. This is a confirmed code defect,
not a proven explanation of the paired-device audio failure.

The phone connects its inbound receiver before activating the native session.
Periodic watch reports also surface a failed application-context enqueue instead
of recording it as a successfully queued report. The watch's readable diagnostics
distinguish that queue failure from a local-library read failure.

Live app reachability is not Bluetooth pairing, metadata delivery, or audio-file
delivery. Actual audio delivery on the owner's devices remains unresolved; neither
the fake transport nor simulator playback closes that physical-device criterion.

On This Watch separates Downloaded audio from Catalog on this watch. Diagnostics
shows readable receipt/report state, with raw codes behind an explicit button.
No queued transfer is represented as an installed track or successful sync.

Build 537 device feedback showed both metadata checks and diagnostics stuck,
despite responsive watch navigation. The restricted-worker host suite did not
reproduce the stall; its cause remains unproven. Diagnostics now takes a synchronous,
bounded-memory snapshot without awaiting the watch's background actors. Native
callbacks record receipt and inbox ownership before scheduling installation, and
metadata checks record their local preparation checkpoints. These changes expose
where work stops; they do not claim to fix physical-device delivery. iPhone Settings
also omits total-device storage utilization, retaining actual downloaded audio
counts/bytes and actionable insufficient-space warnings.

The real Nox_Sound CC0 ocean recording is encoded by the production iPhone
preparation implementation in the host test. Tests verify AAC format, bitrate,
one whole `transferFile`, installation and decoding. That generated M4A is bundled
for the watch simulator smoke test, which exercises the actual watch player,
elapsed advancement, pause, next/previous, and offline browsing.

Tests also cover 24-hour consent, native-owned transfers, no timer retry after
failure, restart recovery, and bidirectional offline status reports. Simulator
playback proves decoding and playback state, not audible hardware output or
actual paired-device WatchConnectivity delivery.

### Local-only simplification (2026-10-08)

The watch is an installed-audio
player. Search, playlists, and albums include playable local tracks only. It exposes no
download, retry, pause, or removal commands; iPhone protocol routing rejects watch-originated
download/control/search requests. The phone sends only metadata for explicitly selected
watch downloads and reported installed audio. Selected-only pages are marked, so old full
catalog deliveries still queued by Apple are ignored. Legacy uninstalled catalog metadata
is pruned without removing validated audio. Playlist selections are frozen until another
explicit iPhone download, preventing removed tracks from being added back automatically.

My Music defaults to Playlists, with On My Watch second and persisted scope selection.
On My Watch mirrors last-reported installed IDs plus selected pending IDs, includes real
active-transfer progress, and reserves completion checkmarks for reported installed IDs.
Its removal action cancels pending transfers, withdraws a track from every selected root,
and queues watch removal without removing the iPhone copy. The report timestamp remains
visible: this is last-reported device truth, not a claim of live reachability. Listen and
My Music show loading until the initial library read completes; Listen cannot race bootstrap
with an early empty read. Jump Back In and Favorites reserve the same height while
loading, empty, and populated. Mix building lives on Mood; its Play action starts
a queue of mix-compatible results directly. Settings sections are collapsible,
with Apple Watch immediately accessible and Playback initially collapsed.

Audio and artwork receipts are separate diagnostics: an artwork callback cannot
overwrite the latest audio receipt. Build 538 device testing confirmed metadata
and artwork activity but zero installed audio; the physical audio stall remains
unresolved. Queued reports and submitted files are not installation confirmation.

### Follow-up controls and transport audit (2026-10-09)

Production watch coordination is phone-push-only: no automatic hello, catalog
refresh, remote search, browse, playback, download, or reconciliation requests.
Startup displays native app reachability without requesting metadata. Sync Now
is disabled while disconnected and sends a live-only status/sync request while
connected; it never queues a watch-originated request. Watch status reports and
responses remain separate from requests. The phone may query watch truth live
or through durable messaging and pushes selected metadata after a sync request.
The live watch request carries no manifest and does not read the watch database.
Its acknowledgement means request acceptance only; the UI finishes on the
phone's pushed update, with a separate eight-second UI timeout. Routine watch
status polling is removed. The phone coalesces unchanged status and uses context
rather than mirroring every update through another request/reply.

Settings adapts Voxglass's grouped raised cards, icon-led headings, consistent
gutters and explanatory subtitles. Apple Watch Settings groups connection,
downloaded audio, last update and a prominent sync action without a user-facing
“metadata confirmation” flow. Diagnostic history remains available.

This matches Cladiron's `WatchWorkoutManagerSync.requestSettingsSync`: require
an activated/reachable session, then `sendMessage` with no queued fallback.
Cladiron's phone publishes coalesced application context, which its watch also
reads at activation. Its phone's “synced” toast follows successful context
submission rather than proving audio delivery (it has no music-file workflow).

Catalog pages contain selected/installed track IDs, display/search fields,
duration, artwork references, and explicitly downloaded playlist names/order.
Empty fields, false readiness flags, and legacy redundant artwork identifiers
are omitted. Catalog payloads are binary property lists compressed with LZFSE,
then transported through WatchConnectivity user-info, never transferFile.
Protocol version 3 makes this compression contract explicit: both apps need
the new build. Older queued envelopes cannot silently be treated as new-format
metadata. The physical-device audio criterion is still unresolved.

All standalone metadata (selected catalog pages, playlist membership, roots,
device reports, sync checks, errors, and removal commands) uses WatchConnectivity
messages, application context, or durable user-info envelopes. It does not use
file transfer. The native `transferFile` adapter now rejects descriptors other
than whole AAC/M4A audio or artwork; descriptor fields accompanying those files
are still necessary to identify and validate the delivered asset.

Diagnostics and its Refresh control are reached from Sync Status, not About.
Now Playing uses outlined/filled download icons and requires explicit confirmation
for both download and local-download removal. Find no longer browses the library
before a query/filter, and its controls no longer have a clipping height cap.

Watch preparation checks complete primary, alternate and Opus caches, and does not
let a stale managed path hide those cache entries. AAC conversion supplies format
hints for extensionless cache blobs. Conversion failures have a distinct preparation
result and visible message instead of falsely claiming the remote source is
unreachable. The exact physical-device failure remains unproven. Native iPhone/watch
compilation and 117 focused host tests passed; updated UI assertions were not run.

Apple references:

- [File delivery and synchronous inbox ownership](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session(_:didreceive:))
- [File transfer scheduling and paired-device testing](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))
- [Explicit encoder bitrate](https://developer.apple.com/documentation/avfaudio/avencoderbitratekey)
