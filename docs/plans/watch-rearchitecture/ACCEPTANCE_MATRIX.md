# Platterhead Watch Rearchitecture — Acceptance Matrix

This matrix is normative. `Host` means `swift test`; `Sim` means the deterministic
injected-transport watch/iPhone UI harness; `Device` means a paired physical iPhone and
Apple Watch. Device rows cannot be closed with simulator evidence.

Result vocabulary: `not run`, `pass`, `fail`, `blocked`, or `owner-waived`. A waiver
must include date, owner, reason, and observed risk.

## A. Architecture and privacy

| ID | Scenario | Evidence | Release blocking |
|---|---|---|---|
| A-01 | Watch SwiftData configuration explicitly uses `cloudKitDatabase: .none` | Host + guard | Yes |
| A-02 | Watch target has no iCloud, CloudKit, push, or app-group entitlement in Debug/Release archive | Guard + archive inspection | Yes |
| A-03 | Watch-linked product closure contains no GRDB or CloudKit framework/import | Guard + link map | Yes |
| A-04 | Watch code contains no remote-provider credentials, token lookup, or authenticated remote URL | Guard + review | Yes |
| A-05 | Phone remains the sole catalog/download-root authority | Host integration | Yes |
| A-06 | Protocol diagnostics never contain title, query, URL, token, credential, or absolute path | Host + review | Yes |
| A-07 | Unknown protocol version preserves local downloads and shows Upgrade Required | Host + Sim | Yes |
| A-08 | Paired-library identity change cannot silently overwrite unrelated downloads | Host + Sim | Yes |

## B. Store bootstrap and local truth

| ID | Scenario | Evidence | Release blocking |
|---|---|---|---|
| B-01 | Clean install opens persistent local SwiftData store | Host + Sim | Yes |
| B-02 | Relaunch preserves tracks, playlists, jobs, manifest, and playback state | Host + Sim | Yes |
| B-03 | In-memory container supports deterministic tests/previews | Host | Yes |
| B-04 | Store-open failure reaches recovery UI instead of terminating | Host + Sim | Yes |
| B-05 | Failed store is quarantined and repeated recovery is idempotent | Host | Yes |
| B-06 | Existing validated audio is adopted or retained across GRDB-to-SwiftData upgrade | Host fixture + Device upgrade | Yes |
| B-07 | Missing file removes track from offline results during reconciliation | Host | Yes |
| B-08 | Corrupt file is nonplayable, reported, and recoverable by retry | Host + Sim | Yes |
| B-09 | SwiftData model objects never cross actors; Sendable snapshots do | Compiler + review | Yes |
| B-10 | 5,000 downloaded tracks remain searchable within target latency | Host benchmark + Device | Yes |

## C. Connectivity and protocol

| ID | Scenario | Evidence | Release blocking |
|---|---|---|---|
| C-01 | Session activates on both apps and applies received application context | Host adapter seam + Device | Yes |
| C-02 | Background/private-queue delegate callback safely reaches owning actor | Host concurrency test | Yes |
| C-03 | Immediate request times out into actionable UI within eight seconds | Host + Sim | Yes |
| C-04 | Late response from superseded search is ignored | Host | Yes |
| C-05 | Duplicate message/file delivery is idempotent | Host fault test | Yes |
| C-06 | Out-of-order metadata/audio/delete converges correctly | Host fault test | Yes |
| C-07 | Stale revisions acknowledge without rolling state backward | Host | Yes |
| C-08 | Raw reachability blip shorter than two seconds does not switch the whole UI | Host | Yes |
| C-09 | Confirmed disconnect produces one haptic/banner and Downloads-only mode | Sim + Device | Yes |
| C-10 | Reconnect restores connected features without replacing local queue/navigation | Sim + Device | Yes |
| C-11 | Phone locked/backgrounded still services supported watch messages | Device | Yes |
| C-12 | Phone force-quit behavior is honest and recovers after relaunch | Device | Yes |
| C-13 | Watch force-quit/relaunch reconciles pending state | Device | Yes |
| C-14 | Bluetooth-only, shared Wi-Fi, and no-network paired states are exercised | Device | Yes |

## D. Connected search, browse, and phone playback

| ID | Scenario | Evidence | Release blocking |
|---|---|---|---|
| D-01 | Free-text track title search returns ranked phone results | Host + Sim + Device | Yes |
| D-02 | Artist, album, and playlist text produce typed results | Host + Sim | Yes |
| D-03 | Search cancellation/generation handling prevents result flashback | Host + Sim | Yes |
| D-04 | Empty query, no results, timeout, and disconnect are distinct | Sim | Yes |
| D-05 | Browse pages playlists/albums/songs/recent without full-catalog transfer | Host payload test + Device | Yes |
| D-06 | Playlist plays on iPhone in stored order from index zero | Host integration + Device | Yes |
| D-07 | Track row plays on iPhone from selected position | Host integration + Device | Yes |
| D-08 | Play/pause/next/previous/jump/shuffle/repeat affect phone only | Host spy + Device | Yes |
| D-09 | Phone Now Playing title, elapsed, queue index/count, and rate reconcile | Host + Device | Yes |
| D-10 | Deleted result or unavailable source returns typed error, no silent no-op | Host + Sim | Yes |
| D-11 | Empty playlist is visibly nonplayable | Host + Sim | Yes |
| D-12 | Active target label always reads iPhone or Apple Watch | Sim | Yes |

## E. Download planning and transfer

| ID | Scenario | Evidence | Release blocking |
|---|---|---|---|
| E-01 | Individual track download survives phone/watch relaunch | Host + Device | Yes |
| E-02 | Album batch downloads all supported tracks and reports unsupported siblings | Host + Device | Yes |
| E-03 | Playlist pin mirrors added/removed phone membership | Host + Device | Yes |
| E-04 | Shared track transfers once across multiple roots | Host | Yes |
| E-05 | Removing one root preserves tracks required by another root | Host + Sim | Yes |
| E-06 | Removing a playlist preserves separately pinned tracks | Host + Sim | Yes |
| E-07 | Phone cache hit is adopted without downloading source twice | Host integration | Yes |
| E-08 | Cellular-disabled job visibly waits for Wi-Fi | Host + Sim + Device | Yes |
| E-09 | Outstanding file transfers rehydrate after phone relaunch | Host + Device | Yes |
| E-10 | Cancellation is correct whether cancel or delivery wins the race | Host fault test | Yes |
| E-11 | Transient failures back off and bounded retry stops | Host | Yes |
| E-12 | Authentication/source failures require action and do not spin | Host + Sim | Yes |
| E-13 | Watch shows count/state progress, not fabricated incoming byte progress | Sim + review | Yes |
| E-14 | Phone shows sender-side byte progress where available | Host adapter seam + Device | No |
| E-15 | Audio is validated by ID, byte count, checksum, codec, and reserve | Host | Yes |
| E-16 | Existing ready asset remains until replacement commits | Host crash/fault test | Yes |
| E-17 | Partial playlist reads `n of m` and plays only ready members | Host + Sim | Yes |
| E-18 | Manifest converges desired/actual state after interrupted install/delete | Host + Device | Yes |
| E-19 | 500-track desired set remains bounded and responsive | Host soak + Device spot-check | Yes |

## F. Offline library and search

| ID | Scenario | Evidence | Release blocking |
|---|---|---|---|
| F-01 | Disconnected root contains no phone-only track | Host query + Sim + Device | Yes |
| F-02 | Every offline-visible track resolves to an existing validated local file | Host invariant | Yes |
| F-03 | Downloaded track/artist/album search works with phone absent | Host + Sim + Device | Yes |
| F-04 | Downloaded playlist title search works with phone absent | Host + Sim | Yes |
| F-05 | Empty offline library explains how to download from iPhone | Sim | Yes |
| F-06 | Local collection counts and partial state remain accurate after deletion | Host + Sim | Yes |
| F-07 | Reconnection does not hide or reorder current downloaded results unexpectedly | Sim + Device | Yes |

## G. Watch-local playback

| ID | Scenario | Evidence | Release blocking |
|---|---|---|---|
| G-01 | Local downloaded track plays with iPhone powered off/out of range | Device | Yes |
| G-02 | Downloaded playlist plays in order entirely offline | Sim + Device | Yes |
| G-03 | Local play/pause/next/previous/jump/shuffle/repeat are correct | Host + Sim + Device | Yes |
| G-04 | Previous restarts after three seconds and goes back before three seconds | Host | Yes |
| G-05 | Corrupt item is skipped with visible explanation | Host + Sim | Yes |
| G-06 | Crown controls local watch volume | Sim + Device | Yes |
| G-07 | No route/declined route returns to paused actionable state | Host seam + Device | Yes |
| G-08 | Bluetooth route loss pauses or follows documented route policy | Host seam + Device | Yes |
| G-09 | Interruption begin/end obeys resumability flags | Host seam + Device | Yes |
| G-10 | Background/wrist-down playback continues for 60 minutes | Device | Yes |
| G-11 | System Now Playing and headphone controls stay synchronized | Device | Yes |
| G-12 | Relaunch restores valid queue paused at saved position | Host + Sim + Device | Yes |
| G-13 | Missing queue entries are pruned deterministically on restore | Host | Yes |
| G-14 | Close Now Playing leaves playback and queue intact | Sim + Device | Yes |
| G-15 | Continue on Apple Watch appears only when current asset is local | Host + Sim | Yes |
| G-16 | Continue on Apple Watch begins near last confirmed elapsed time | Host + Device | Yes |
| G-17 | Reconnect never automatically moves local playback to iPhone | Host + Device | Yes |

## H. Storage and recovery UX

| ID | Scenario | Evidence | Release blocking |
|---|---|---|---|
| H-01 | Phone and watch show watch-reported installed bytes | Host + Sim + Device | Yes |
| H-02 | Batch preflight and per-file install preserve required reserve | Host + Device | Yes |
| H-03 | Storage-full failure identifies required/free space and removal route | Sim + Device | Yes |
| H-04 | Remove track/playlist/album/all is reference-aware and idempotent | Host + Sim + Device | Yes |
| H-05 | Removal copy says music remains on iPhone | Sim | Yes |
| H-06 | Staging files are cleaned after success, failure, and restart | Host fault test | Yes |
| H-07 | Reconcile action repairs stale phone/watch status | Host + Device | Yes |

## I. Accessibility, performance, and finish

| ID | Scenario | Evidence | Release blocking |
|---|---|---|---|
| I-01 | VoiceOver labels, values, hints, and traversal order cover all controls/states | Sim audit + Device | Yes |
| I-02 | State is never communicated by color alone | Review + Sim | Yes |
| I-03 | Large Dynamic Type has no clipped primary action on smallest supported watch | Sim screenshots + Device | Yes |
| I-04 | Reduce Motion removes nonessential animation without hiding progress | Sim | Yes |
| I-05 | Warm/cold root launch meet 1s/2s p95 targets | Device measurement | Yes |
| I-06 | Local 5,000-track search meets 150ms p95 | Device measurement | Yes |
| I-07 | Nearby connected search meets 1.5s p95 | Device measurement | Yes |
| I-08 | Transport acknowledgement meets 500ms p95 | Device measurement | Yes |
| I-09 | No main-thread stall exceeds two seconds during sync/install | Instruments + Device | Yes |
| I-10 | Idle app has no repeating network/database polling | Energy log + review | Yes |
| I-11 | Battery/thermal result for 60-minute playback is recorded | Device measurement | Yes |
| I-12 | TestFlight upgrade from legacy watch app retains/adopts or safely recovers downloads | Device upgrade | Yes |
| I-13 | All mockup screens/states have implementation screenshots | Audit | Yes |
| I-14 | User-facing name is Platterhead; no Tonearm codename leaks | Guard + Sim | Yes |

## Run record

Add dated runs below; do not edit expected behavior in the tables to make a result pass.

| Date | Build/commit | Devices | Rows | Result/notes |
|---|---|---|---|---|
| 2026-08-28 | Phase 11 11a–11d (`f34162a`..this commit) | Apple Watch Ultra 3 (49mm) watchOS 26.5 simulator; host `swift test` | I-01 (Sim portion), I-02, I-04, I-14; D-12, G-03/G-14 (Sim) | Pass. I-01: VoiceOver labels now on every icon-only watch control (transport, Up Next, volume, target row + hint); traversal unchanged. Full VoiceOver traversal on a real device stays a Device row. I-02: the "downloaded on watch" indicator, previously a bare green glyph, carries a VoiceOver label in search + phone-collection lists; queue rows announce "Now playing"/"Paused here"; the connection banner was already text+icon. I-04: satisfied by construction — `grep` finds no `withAnimation`/`.animation`/`.transition` in `WatchApp/`; the only motion is `ProgressView`. I-14: `make ci-guards` codename guard clean. The one watch smoke (`WatchSmokeUITests`) exercises track/album/playlist local playback, the persistent Now Playing chip across Close, and app exit — green 3× locally. Device measurement rows I-05..I-13, I-11, I-12 and all C/G/H `Device` rows remain not run — owner/hardware. |
| 2026-08-26 | Phase 3 (this commit) | iPhone 16 simulator; generic watchOS simulator; host `swift test` | A-06, A-07, A-08; C-01..C-10 | Pass: 65 new host tests, 1,667 total, 0 failures. A-06 is structural — `WatchProtocolFault` has no string field and a guard enforces it. C-08/C-09/C-10 are driven through the pure reducer and again end-to-end over the fake duplex link. C-11..C-14 remain Device rows and are untouched. Protocol is not yet on the shipped path; the legacy transport still runs the watch until Phase 6. |
| 2026-08-26 | Phase 1 (this commit) | iPhone 16 simulator; generic watchOS simulator/archive | A-01, A-02; structural prerequisites for A-03/A-04 | Pass: scoped graph only; Debug/Release have no entitlement file; unsigned Release archive contains no CloudKit/iCloud entitlement. Signed archive and physical-device evidence remain deferred to their scheduled phases. |
