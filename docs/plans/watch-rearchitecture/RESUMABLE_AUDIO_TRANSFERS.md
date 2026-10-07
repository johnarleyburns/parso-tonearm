# Resumable watch audio transfers

## Policy

Audio is sent in 1 MiB (1,048,576 byte) files, with **one unconfirmed chunk
globally**, not one per track. The final chunk may be smaller. The whole cached
asset stays on the phone. There is no audio-quality reduction in this protocol;
existing watch-compatible audio preparation still runs before chunking.

Apple does not document an ideal chunk size. Its
[transferFile documentation](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))
allows background delivery and system throttling. The
[file-transfer API](https://developer.apple.com/documentation/watchconnectivity/wcsessionfiletransfer)
offers progress and cancellation, not an application-controlled resume offset.
1 MiB is a conservative starting policy, not a measured optimum. Real paired-device
profiling is required to compare throughput and reliability against other sizes.

## Checkpoint contract

1. Phone journals an immutable chunk and attempt ID before enqueueing it.
2. Watch checks chunk length and SHA-256, saves its bytes in Application Support,
   and atomically writes its receipt journal.
3. Watch reports received indexes in its manifest. Only that acknowledgement
   advances saved progress and permits the next chunk. WCSession completion does not.
4. After every piece is present, the watch streams assembly in 64 KiB buffers,
   verifies whole-file length/SHA-256, and uses the existing audio installer.
   Only an installed manifest entry makes the track playable or counts as downloaded.

Phone and watch journals survive process termination. Negotiated capabilities are
scoped to the WCSession paired-watch directory ID, allowing a background iPhone
relaunch to resume without a foreground handshake. Watch recovery validates retained
watch pieces; a damaged/missing piece loses only its own checkpoint. New phone
plans can adopt matching watch receipts. Track identity, full-asset digest, size,
and chunk layout must match before any checkpoint is reused.

Pause/restart cancels only unconfirmed system transfers and retains good watch
chunks. Old attempt callbacks and old manifests cannot fail a replacement or
erase newer progress.
Watch-side rejection reports identify the exact chunk attempt; a delayed failure
or a track-only legacy failure cannot fail its replacement. A delivered chunk with
no acknowledgement is retried after
five minutes; a system-owned transfer is left to WatchConnectivity unless the
user explicitly restarts it. A watch rejection is shown as a failure rather than
silently cycling. Restarting retries assembly/installation as well as delivery.

Completed-but-uninstalled chunks are reassembled during reconciliation after a
watch restart. Confirmed installed assets release their chunk copies. Phone copies
are removed only after WCSession relinquishes them, or after recovery proves they
are neither system-owned nor pending.

Protocol v2 separates chunk metadata from legacy whole-file metadata. Both apps
must be updated; queued v1 context/user-info packets cannot poison a v2 session.
Legacy unfinished whole-file jobs restart once when v2 chunk capability is
negotiated. Opaque bytes inside an old WCSession transfer cannot be migrated.

## Status and limits

Settings on the phone and Sync Status on the watch show saved percentage and chunk
counts separately from installed tracks/bytes, with queued, transferring,
awaiting-confirmation, installation, pause, and failure states. Total watch storage
includes watchOS and other apps and is not transfer progress. Phone sync history
shows report receipt, catalog publication/receipt, status publication, and installation.

Assembly temporarily needs room for both retained pieces and the completed file,
in addition to the existing storage reserve. Journals are durable checkpoints, not
backups: uninstalling the watch app, removing a download, or actual storage
corruption can discard them. Background execution and Bluetooth availability
remain controlled by Apple; no test can guarantee uninterrupted radio delivery.

## Verification

`WatchResumableAudioTransferTests` covers a 100 MiB transfer interrupted at 50%
with both actors recreated, one global unconfirmed chunk, completion-vs-receipt
semantics, acknowledgement loss, late callbacks, fresh phone journals, corrupted
watch checkpoints, duplicate/out-of-order chunks, final-assembly recovery, and the
production watch receive/installer/offline playback path. Existing download tests
cover durable delivery grace, queued-file concurrency, restart, pause/remove,
migration, and truthful management status. Apple requires actual paired devices
for file-transfer validation; simulator and fake-link tests do not replace that check.

## Build 534 device findings (2026-10-07)

The paired phone's persisted journal shows Home Cooking III chunk zero delivered
by WCSession but no recorded watch manifest, with zero acknowledged chunks.
The missing acknowledgement occupies the single global slot; other tracks wait.
The cause of the absent watch report remains unproven. Do not treat successful
fake-link tests as evidence that the physical-device stall is resolved.

Two iPhone TestFlight crash reports (11:00 and 11:11 local time, build 534)
both trap in the error callback resuming the checked continuation in
`WatchSessionTransport.sendImmediate`. The native completion now claims that
continuation atomically once, ignoring repeated/racing reply and error callbacks.
Envelope tests exercise error/error/reply, reply/error/reply, and 100 concurrent
callbacks. Playlist activity labels now use the phone library's per-track titles,
and About exposes the existing Diagnostics screen with a watch UI regression test.
