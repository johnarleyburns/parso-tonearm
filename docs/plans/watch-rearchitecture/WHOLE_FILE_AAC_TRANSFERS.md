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

The real Nox_Sound CC0 ocean recording is encoded by the production iPhone
preparation implementation in the host test. Tests verify AAC format, bitrate,
one whole `transferFile`, installation and decoding. That generated M4A is bundled
for the watch simulator smoke test, which exercises the actual watch player,
elapsed advancement, pause, next/previous, and offline browsing.

Tests also cover 24-hour consent, native-owned transfers, no timer retry after
failure, restart recovery, and bidirectional offline status reports. Simulator
playback proves decoding and playback state, not audible hardware output or
actual paired-device WatchConnectivity delivery.

Apple references:

- [File delivery and synchronous inbox ownership](https://developer.apple.com/documentation/watchconnectivity/wcsessiondelegate/session(_:didreceive:))
- [File transfer scheduling and paired-device testing](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:))
- [Explicit encoder bitrate](https://developer.apple.com/documentation/avfaudio/avencoderbitratekey)
