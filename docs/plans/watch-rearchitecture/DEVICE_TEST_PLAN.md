# Paired-device watch test plan

Use matching new builds on BOTH devices. The compressed catalog uses protocol 3;
build 539 is not the counterpart for this build. Record each device's build number.
Simulator/host tests do not prove physical WatchConnectivity audio delivery.

## 1. Clean watch reset

On watch About → Reset to Default, first Cancel: nothing should change.
Then confirm Reset Watch. Close Platterhead from the watch app switcher and reopen.
The reset runs before opening its database, deletes watch audio/artwork/staging,
catalog/playlists, sync history, playback position and preferences, and leaves
iPhone music untouched. Apple-owned pending transfers are not cancelled by reset.
Metadata may repopulate from the phone; that is NOT downloaded audio.

Immediately check Installed on this watch = 0, with empty Search and Albums until
audio arrives. If old audio remains playable, record the build and reset message.
If About still says reset scheduled after a fresh process launch, report that.

## 2. Connection and metadata, without starting audio

Keep both apps open. Watch home and Sync Status should show iPhone connected or
not connected. When disconnected, Sync Now is disabled and says
“Sync Now available when connected to iPhone.” No watch request is queued.
When connected, tap Sync Now ONCE. It sends one live sync request and shows
“Syncing with iPhone…” until the phone's push arrives. Within eight seconds it
should show “Sync updated” or a clear failure. Record exact text and duration.
There is no metadata-confirmation workflow or repeated watch polling. A sync
update does not count as installed audio.

The phone should toast “Apple Watch connected” when live reachability transitions
to connected, not on every periodic status update. Phone Sync Now may queue when
the watch app is not reachable; that asymmetry is intentional.

## 3. One fresh, small audio transfer

Choose ONE short track already fully downloaded and playable on iPhone, not an
old pending transfer. Prefer a local MP3/M4A or the built-in CC0 ocean recording
if available. Record title, source and file size. Start the watch download ONCE
and confirm. It should appear in My Music → On My Watch and Apple Watch Settings.
Pending tracks have no completed checkmark; real byte progress is separate from
installation. A 100% sender progress value is not proof of installed watch audio.

On watch Sync Status → Diagnostics & Refresh, Refresh and record these verbatim:
Audio receipt, Artwork receipt, Watch report, Last native delivery and Sync/Metadata
check, including timestamps. Also record Installed on this watch and the phone's
exact track status. Do not reset/reinstall/retry while capturing the evidence.

| Observation | Failure stage / next evidence |
| --- | --- |
| No phone job or On My Watch entry | Confirmation, track persistence or root queueing; record toast and whether the track came from ad-hoc Jamendo browsing. |
| “Couldn't save” / “Couldn't queue” toast | Phone persistence/queue setup failed before native audio submission. |
| “iPhone can't reach that source” | Source resolution/fetch failed, before audio transfer. Report whether cached playback works. |
| “Could not convert the local audio” | Local bytes were selected, but AAC preparation failed; no audio file submitted. Record original codec/source. |
| Submitted, no audio receipt | No audio callback recorded in this app session. This does not prove Apple never delivered in a previous session. |
| Audio delivered / saved awaiting worker | Native callback and inbox retention succeeded; installation worker has not completed. |
| Waiting for catalog metadata | Audio reached the installer; selected-track metadata/binding is missing. Record last catalog update. |
| Integrity/storage/processing error | Installer rejected received audio; record exact summary and relevant raw code. |
| Installed on watch, phone still pending | Installation succeeded; returning watch report or phone reconciliation is stale. |

These observations locate the stage. They cannot reveal Apple's internal radio/
queue scheduling reason; do not infer a specific root cause without more evidence.
“Report queued” and artwork receipt are not audio installation confirmation.

## 4. Playback and persistence

After Installed increases and Audio receipt says installed, play the track on
watch. Disconnect the phone/disable its Bluetooth and verify watch playback still
advances. Close/reopen the watch app and verify the track remains searchable and
playable. Record any playback error and whether elapsed time advances.

## 5. Playlist and removal

Explicitly download a small two-track playlist from iPhone. Its name and ordered
membership should appear on watch once playable tracks are present. Watch offers
no remote search, playlist creation or download/retry controls. Remove a track
through phone My Music → On My Watch with confirmation. After a fresh watch report
it should disappear; the iPhone copy stays. A later sync must not silently re-add
it from the old playlist selection. Explicit download again is allowed.

## 6. UI regressions

Now Playing uses an outlined download icon when not downloaded and filled when
downloaded. Both downloading and removal ask for confirmation; Cancel changes
nothing. Apple Watch and Advanced Settings each open in one tap; expandable
sections align left/right margins. Jamendo scroll retains its position through
page loading and returning from Now Playing. Find starts with no library rows
until a query/filter and does not clip controls.

Send results by step number, with exact text/timestamps. Stop at the first failed
audio stage instead of accumulating retries: that preserves a clean diagnostic
trail for one attempt.
