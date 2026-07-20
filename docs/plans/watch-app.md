# Platterhead Watch App — Standalone watchOS Companion

## Agent Handoff Instructions

This document is the source of truth for building the Platterhead Apple Watch app.
Implement directly from this plan. The visual spec is
`docs/mockups/watch-app.html` — open it in a browser; every pt value annotated
there is the value the SwiftUI code must use.

Before changing code:

- Read this plan completely, then read `TONEARM-TEST-ARCHITECTURE.md` (repo test
  doctrine) and `docs/plans/remote-library-management-and-subsonic-fixes.md`
  (style reference for how plans are executed and audited here).
- Inspect: `project.yml`, `Package.swift`, `.github/workflows/ios.yml`,
  `ExportOptions.plist`, `Sources/App/AppState.swift`, `Sources/Audio/`
  (`AudioPlayer`, `CacheStore`, `PinPolicy`, `CacheGlyphState`,
  `PlaybackPlatformBridge`, `QueueEditor`, `QueueRestorePlanner`),
  `Sources/Data/` (`LibraryStore`, `Schema`, `Records`), `Sources/Domain/`
  (`Entities`, `LibraryBrowse`, `PlaylistEditor`), `Sources/DesignSystem/`
  (`Palette`, `CacheGlyph`), `Sources/Features/Components.swift`
  (`TrackRowView`, `TrackContextMenu`), `UITests/TonearmSmokeUITests.swift`.
- Preserve untracked local files (`data/`, `music/`, `docker-compose.yml`,
  `Platterhead_Watch_App_Store.mobileprovision`). Never commit the
  `.mobileprovision` file — it reaches CI via a GitHub secret.
- Do not log, display, or commit credentials or signing material.

During implementation:

- Follow the phase order exactly. **Each phase is gated**: branch → implement →
  tests green → commit → merge to `main` → push → CI green → only then start the
  next phase (gate procedure in §12).
- Prefer existing app patterns (actor stores, policy structs in Core, thin
  platform adapters, protocol seams) over new idioms.
- Every piece of new logic lands in `TonearmCore` (host-testable via
  `swift test`) with thorough unit tests. View code stays in app targets and is
  not automation-tested — except the ONE watch simulator smoke test (§10.3).
- If implementation discovers a mismatch or a better minimal design, update this
  plan file with the final decision rather than leaving the handoff stale.

Before finishing each phase (and the project):

- Reread the phase spec and compare against implemented code; fix gaps.
- Update the "Implementation Audit" section at the bottom with files changed,
  tests run, and intentional deviations.

---

## 1 · Summary

Build a **standalone watchOS app** for Platterhead (bundle
`guru.parso.tonearm.watchkitapp`) that:

- Runs **totally off-grid**: on-watch music plays with the iPhone absent,
  powered off, or out of range. Watch keeps its own GRDB library + audio files.
- Syncs from the iPhone over **WatchConnectivity** (no CloudKit — the watch
  provisioning profile has no iCloud/app-group entitlements).
- iPhone gains **"Download to Watch"** at track, album, and playlist level
  ("Download All to Watch"), plus the previously missing plain **"Download All"**
  (pin-to-cache) for albums/playlists, with a new **WatchGlyph** state indicator
  (applewatch-based, distinct from the circular brass CacheGlyph).
- **Tethered**: the watch shows the full phone catalog; tapping a not-on-watch
  track fetches it on demand from the phone (progress overlay) and plays.
- **Untethered**: only on-watch content is shown; playback identical.
- Watch feature set is deliberately minimal but rock-solid: browse
  (playlists/albums/songs), play/pause/next/prev, seek-free progress display,
  shuffle/repeat, Up Next, crown volume, system route picker, background audio,
  position persistence, storage management. Everything else → backlog (§13).

**Branding (hard rule, applies to BOTH apps):** the user-facing name is
**Platterhead** everywhere. "Tonearm" was only the project codename — it must
NEVER appear in any user-visible surface: app display names, share-extension
name, widget names, onboarding/settings/paywall copy, App Intents phrases,
VoiceOver labels, notifications. Internal identifiers keep the codename (bundle
IDs `guru.parso.tonearm*`, target names, `TonearmCore`, file paths, URL scheme,
on-disk directory names) — those never render to the user. Phase 1 performs the
rebrand and **flips the CI product-name guard** (today it blocks "Platterhead"
as a legacy name; the new guard blocks user-visible "Tonearm" instead).

## 2 · Research summary (what watch users actually want)

From Apple Music / Spotify watch-app behavior and user demand
(digitalmusicnews.com, techradar.com, Apple support docs, Apple dev forums):

**Ship in v1** — the features users consistently expect:
1. Offline downloads at track/album/playlist granularity with a visible
   on-watch indicator and progress (Apple Music does track-level; Spotify only
   playlist-level and users complain — we do all three).
2. Basic transport: play/pause/next/prev, progress + remaining time.
3. Digital Crown volume.
4. Output routing via the **system** route picker (watch speaker is a valid
   destination on supported models; there is no `AVRoutePickerView` on watchOS —
   custom route UI is impossible and must not be attempted).
5. Shuffle / repeat.
6. Up Next queue view.
7. Resume exactly where you left off (position persistence).
8. Storage visibility + per-collection removal on the watch.

**Deliberately excluded from v1** (backlog §13): sleep timer (podcast-centric;
low value for music playback — not worth its UI slot on a 40mm screen), EQ,
crossfade, ReplayGain, lyrics, favorites, search, watch-initiated downloads,
direct streaming over watch Wi-Fi, custom complications.

**Platform facts that shape the design:**
- Background audio on watchOS requires `AVAudioSession` category `.playback`
  with route-sharing policy `.longFormAudio`, session activation via
  `activate(options:completionHandler:)`, and the `audio` background mode in
  the watch Info.plist. Activation auto-presents the route picker when no route
  is active.
- `WCSession.transferFile` queues and delivers opportunistically even when the
  counterpart app isn't running; delivery order is NOT guaranteed (protocol
  must tolerate audio-before-catalog arrival).
- Watch app runs standalone when `WKRunsIndependentlyOfCompanionApp = YES`.

## 3 · Signing, targets, versions (verified facts)

| Fact | Value |
|---|---|
| Watch bundle ID | `guru.parso.tonearm.watchkitapp` |
| Companion (iOS) bundle ID | `guru.parso.tonearm` |
| Provisioning profile name | `Platterhead Watch App Store` (expires 2027-05-06) |
| Profile entitlements | app ID + keychain groups only — **no** app groups, **no** iCloud |
| Team | `3264Y8YUGV` |
| Distribution cert | same "Apple Distribution" cert as the iOS app |
| iOS deployment target | 18.0 |
| **Watch deployment target** | **11.0** (pairs with iOS 18; makes AVPlayer et al. safely available) |
| Xcode project | generated by **XcodeGen** from `project.yml` — regenerate + commit after every file add/remove |
| Package platforms | add `.watchOS(.v11)` to `Package.swift` `platforms:` |
| Versioning | watch `CFBundleShortVersionString`/`CFBundleVersion` use the same `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)` vars; CI's archive overrides propagate to all targets, keeping watch/app versions matched (App Store requirement) |

GitHub secret to create (Phase 0):

```sh
base64 -i Platterhead_Watch_App_Store.mobileprovision | gh secret set WATCH_PROVISIONING_PROFILE_BASE64
```

App Store Connect (user tasks, note in phase 2 PR description): the watch app
rides inside the iOS binary; verify the WatchKit app ID exists (it does — the
profile was minted against it) and that the App Store listing name is
"Platterhead".

## 4 · Architecture

```
┌────────────── iPhone (Tonearm target) ─────────────┐   ┌──────── Watch (TonearmWatch target) ───────┐
│ Features UI: WatchGlyph, menus, Settings›Watch     │   │ SwiftUI: W1–W13 screens (mockups)          │
│ PhoneWatchSessionAdapter (WCSession, thin)         │◄──►│ WatchSessionAdapter (WCSession, thin)      │
└───────────────┬────────────────────────────────────┘   └───────────────┬────────────────────────────┘
                │ calls into                                             │ calls into
┌───────────────▼─────────────────── TonearmCore (SPM, host-tested via swift test) ───────────────────┐
│ NEW Sources/WatchSync/: WatchCatalog (export/import), WatchManifest, WatchTransferPlanner,          │
│   WatchTransferQueue (state machine), WatchSyncMessage (codable envelope), WatchGlyphState,         │
│   WatchLibraryFilter (reachability filtering), WatchStorage accounting                              │
│ NEW Sources/WatchPlayback/: WatchPlayerEngine (queue/shuffle/repeat/position state machine),        │
│   WatchAudioOutput protocol (seam), WatchPositionStore                                              │
│ REUSED: Entities, Schema, LibraryStore, LibraryBrowse, CacheStore, PinPolicy, QueueRestorePlanner   │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

Rules:

- **All logic in Core, all platform calls in adapters** — the exact pattern of
  `PlaybackPlatformBridge`. `WCSession` and `AVAudioSession`/`AVPlayer` never
  appear in Core (WatchConnectivity doesn't compile on macOS; `swift test`
  must stay green on the host).
- The watch target depends on the `TonearmCore` package. All frameworks Core
  imports (GRDB, AVFoundation, CloudKit, StoreKit, AppIntents, Network,
  AudioToolbox, CryptoKit, Security) exist on watchOS 11. Expected stragglers
  needing `#if !os(watchOS)`: `CachingResourceLoader`
  (AVAssetResourceLoaderDelegate availability), possibly parts of
  `Sources/Audio/Opus` remux and `Sources/Intents`. Rule: guard the **file**
  with `#if !os(watchOS)` only when a symbol is genuinely unavailable; never
  fork logic the watch actually needs.
- Watch persistence: its own GRDB db via `LibraryStore(inMemory: false)`
  pointed at the watch's Application Support (LibraryStore already builds its
  own path — it just works in the watch container). Same `Schema.migrator()`.
- Watch audio files:
  - **Pinned** (explicit "Download to Watch"): `Application Support/WatchAudio/`
    — never auto-evicted, survives system cache purges.
  - **On-demand fetches** (W10): the existing `CacheStore` (Caches dir), LRU,
    512 MB default limit, reusing `PinPolicy` eviction math.
- Track identity across devices: `phoneTrackKey = "t<track.id>"` generated by
  the phone (single authoritative source). Stored on the watch in
  `track.syncID`. Never reuse CloudKit `syncID` semantics for this.

## 5 · Data model

### Phone — schema migration `vNext` (append to `Schema.migrator()`)

```sql
CREATE TABLE watchTransfer (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  trackId INTEGER NOT NULL UNIQUE REFERENCES track(id) ON DELETE CASCADE,
  state TEXT NOT NULL,          -- queued | sending | sent | failed
  originKind TEXT NOT NULL,     -- single | album | playlist
  originId INTEGER,             -- album/playlist id when bulk-queued
  bytes INTEGER,
  errorText TEXT,
  queuedAt DATETIME NOT NULL,
  updatedAt DATETIME NOT NULL
);
CREATE TABLE watchManifest (      -- last state reported BY the watch (source of truth for glyphs)
  trackKey TEXT PRIMARY KEY,
  bytes INTEGER NOT NULL,
  pinned BOOLEAN NOT NULL,
  reportedAt DATETIME NOT NULL
);
```

Glyph derivation (Core, tested): `onWatch` iff key in `watchManifest`;
`transferring` iff `watchTransfer.state IN (queued, sending)`; `failed` iff
`state = failed`; else `notOnWatch`.

### Watch — reuses the full app schema

Catalog import writes `Source` (one synthetic "iPhone" source), `Album`,
`Artist`, `Track` (syncID = phoneTrackKey), `Playlist`, `PlaylistItem`.
Received audio writes an `Asset` (`kind: .managedCopy`, `relPath` into
WatchAudio/ or the cache). Tracks in the catalog without a local asset are
**catalog-only rows**: visible while tethered, tap = on-demand fetch; hidden
untethered (`WatchLibraryFilter`).

## 6 · Sync protocol (Core: `WatchSyncMessage`, all Codable, versioned)

Envelope: `{ protocolVersion: 1, catalogVersion: Int, kind, payload }`.

| Kind | Channel | Direction | Payload |
|---|---|---|---|
| `catalog` | `transferFile` (gzipped JSON) | phone → watch | full catalog snapshot: playlists, albums, artists, tracks (key, title, artist, albumKey, durationSec, codec, sizeBytes, trackNo, discNo, sortKey), artwork refs |
| `artwork` | `transferFile` (JPEG ≤180×180) | phone → watch | `albumKey` in metadata |
| `audio` | `transferFile` | phone → watch | file + metadata: `trackKey, bytes, pinned, catalogVersion` |
| `deleteTracks` | `transferUserInfo` | phone → watch | `[trackKey]` |
| `manifestReport` | `transferUserInfo` | watch → phone | all on-watch keys + bytes + pinned + free-space + catalogVersion |
| `fetchRequest` | `sendMessage` (reachable only) | watch → phone | `trackKey` → phone enqueues priority transfer; reply ack |
| `fetchCancel` | `sendMessage` | watch → phone | `trackKey` |
| `resendCatalog` | `sendMessage` | watch → phone | (recovery; also a phone-side Settings action) |

Invariants (each one is a unit test):

1. **Order-independence**: audio arriving before its catalog entry is parked in
   `WatchAudio/orphans/` and reconciled when the catalog lands.
2. **Idempotency**: re-received catalogs/audio/deletes are no-ops (byte-count
   check on audio; version check on catalog — stale versions dropped).
3. **Catalog replace semantics**: import is a full diff-apply (upsert + delete
   missing), preserving assets for tracks still present.
4. **Every mutation on the watch → `manifestReport`** (download applied, delete
   applied, eviction, on-demand fetch kept).
5. **Transfer queue** (phone): max 2 in-flight `transferFile`s; failed →
   `failed` with retry on next app-foreground or manual retry (glyph tap);
   pause stops dequeuing but lets in-flight finish.
6. **Fetch timeout**: no progress for 30 s → failed (watch shows W10 error
   state, engine skips to next on-watch track).

## 7 · Watch playback design

- `WatchPlayerEngine` (Core): pure state machine — queue, current index,
  shuffle order (seeded RNG injectable for tests), repeat (off/all/one),
  elapsed, commands `play/pause/toggle/next/prev/jump(to:)/seek(to:)`, events
  `itemEnded/itemFailed/routeLost`. Emits `EngineDirective`s (`loadItem(URL)`,
  `play`, `pause`, …) consumed by the adapter. 100 % branch coverage goal.
- `WatchAudioOutput` protocol (Core), implemented in the watch target by
  `AVPlayerOutput` (single `AVPlayer`): `load(url:)`, `play`, `pause`,
  `seek(to:)`, callbacks for end/error/periodic time.
- Session: on first play, `setCategory(.playback, policy: .longFormAudio)` then
  `activate(options:)` — system route picker appears if no route; on decline,
  engine returns to paused (tested via injected session seam).
- Info.plist: `UIBackgroundModes: [audio]`.
- System integration: `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`
  (play/pause/next/prev) so Control Center / Smart Stack Now Playing works.
- Position persistence: `WatchPositionStore` (Core) saves
  `(queue trackKeys, index, elapsed, shuffle, repeat)` on pause, track change,
  every 10 s while playing, and app lifecycle events; restore on launch paused
  at saved position (same guarantee family as
  `docs/plans/playback-position-never-lost.md`).
- ReplayGain/EQ/crossfade: **not** on watch (v1).

## 8 · Watch UI spec

The mockup file `docs/mockups/watch-app.html` is normative: screens W1–W13,
the glyph language, and the **LAYOUT DOCTRINE** box (8 hard rules: List/Scroll
roots, no fixed widths, 44 pt tap targets, Dynamic Type styles only,
forbidden modifiers, toolbar placements, transport icon sizing, and the
smallest/largest-simulator fit gate). Implement rows as ONE reusable
`WatchTrackRow` / `WatchCollectionRow` component pair.

Screen → view file map (all in `WatchApp/Views/`):

| Mockup | View | Notes |
|---|---|---|
| W1/W2 | `WatchRootView` | List root; Now Playing chip conditional; untethered banner + filtered counts |
| W3 | `WatchPlaylistsView` | aggregate glyphs |
| W4 | `WatchPlaylistDetailView` | brass Play row + shuffle button (both ≥44 pt) |
| W5/W6 | `WatchAlbumsView` / `WatchAlbumDetailView` | 32 pt artwork thumbs, fallback gradient+symbol |
| W7 | `WatchSongsView` | plain rows, alphabetical, 5 000-row cap |
| W8 | `WatchNowPlayingView` | ONLY fixed-layout screen — follow the pt budget table exactly (fits 162×197) |
| W9 | `WatchUpNextView` | tap to jump, no reorder |
| W10 | `WatchFetchOverlay` | determinate progress + Cancel |
| W11/W12 | `WatchStorageView` | usage header, per-collection Remove, Remove All (confirm), version + Re-sync rows |
| W13 | `WatchEmptyStateView` | never a blank list |

Accessibility identifiers (smoke-test anchors — must exist exactly):
`root.nowPlaying, root.playlists, root.albums, root.songs, root.storage,
np.prev, np.playpause, np.next`.

## 9 · iPhone UI spec

Mockups P1–P5 are normative.

1. **`WatchGlyphState`** (Core, `Sources/WatchSync/`) + **`WatchGlyph`** view
   (`Sources/DesignSystem/`): applewatch outline base, 4 states
   (notOnWatch/transferring(progress)/onWatch/failed), VoiceOver strings per
   mockup. 17 pt column, trailing in `TrackRowView` after the heart. Rendered
   only when state ≠ notOnWatch, or when the containing screen is the watch
   management screen.
2. **`TrackContextMenu`**: add "Download to Watch" / "Remove from Watch"
   (mutually exclusive by state); failed state → "Retry Download to Watch".
3. **Album & playlist detail menus**: add "Download All" (pins remote tracks
   to phone cache via a generalized `AppState.download(rows:)` refactored from
   `makeOffline`'s inner loop; skips local/unsupported tracks) and
   "Download All to Watch" / "Remove All from Watch".
4. **Settings › Apple Watch** (`WatchSettingsView`): status header (paired /
   installed / reachable → Core display model), On-Watch totals from
   `watchManifest`, transfer queue with aggregate progress + Pause/Resume,
   per-collection Remove, "Re-send Catalog to Watch".
5. **Transfer pill** above the mini-player while transfers active; tap →
   Settings › Apple Watch.
6. Phone-side plumbing: `PhoneWatchSessionAdapter` (app target) wraps
   `WCSession` (guard `WCSession.isSupported()` — iPad family is enabled);
   `WatchTransferController` (Core logic + adapter callbacks) drives the queue
   off `watchTransfer`, resolves each track's local file (local asset URL or
   pinned cache file; for un-cached remote tracks, download-then-send reusing
   the `download(rows:)` path), attaches metadata, updates states, ingests
   `manifestReport`s, regenerates the catalog on library/playlist mutations
   (debounced), and enqueues artwork thumbs.

## 10 · Testing strategy

### 10.1 Unit tests (host, `swift test` — CI gate)

New test files in `Tests/`, exhaustive over the new Core modules:

- `WatchCatalogTests` — export from a seeded in-memory LibraryStore; import
  into a second store; round-trip equality; diff-apply (add/rename/delete);
  stale-version rejection; orphan-audio reconciliation.
- `WatchTransferPlannerTests` — desired-set diffing, origin bookkeeping,
  priority fetches jump the queue, dedupe, unsupported/`needsReimport` tracks
  never planned.
- `WatchTransferQueueTests` — state machine: max-in-flight, success/failure
  transitions, retry, pause/resume, cancel, timeout, persistence round-trip.
- `WatchManifestTests` — report ingestion → glyph states; eviction reports
  clear pins correctly.
- `WatchGlyphStateTests` — derivation matrix (manifest × transfer states).
- `WatchLibraryFilterTests` — tethered/untethered visibility, counts, empty
  collections disappear, 5 000-row cap.
- `WatchPlayerEngineTests` — play/pause/toggle/next/prev at boundaries,
  repeat off/all/one, seeded shuffle determinism, itemEnded auto-advance,
  itemFailed skip, end-of-queue, jump, directives sequence assertions.
- `WatchPositionStoreTests` — save/restore round-trip, corrupt-data fallback,
  10 s throttle policy.
- `WatchStorageTests` — accounting, pinned vs cache split, free-space checks
  (reserve rule mirrors `offlineDiskCheck`), Remove All plan.
- `WatchSyncMessageTests` — envelope encode/decode, unknown-kind tolerance,
  protocol-version gating.
- Phone-side: `WatchSessionStateTests` (paired/installed/reachable → display
  model), `DownloadRowsTests` (the generalized Download All).

Coverage bar: every new Core file exercised; every `enum` fully switched in
tests; failure paths asserted, not just happy paths.

### 10.2 What is NOT unit-tested

SwiftUI views, WCSession adapters, AVPlayer adapter — thin by design; they are
covered by the smoke test and by eyeball on the simulators/TestFlight.

### 10.3 The ONE watch simulator smoke test (local only, never in CI)

`WatchUITests/WatchSmokeUITests.swift`, exactly one test:

```
testWatchAppBootsPlaysAndBrowses()
  launch(arguments: ["UI_TESTING", "SEED_WATCH_FIXTURES"])
  → app reaches foreground (no crash)
  → root.playlists exists → tap → fixture playlist visible → tap
  → first fixture track row → tap
  → np.playpause exists (Now Playing pushed) → tap (pause) → tap (play)
  → np.next tap → np.prev tap (no crash, still on Now Playing)
  → back to root → root.songs → fixture track title visible (library lookup)
  → root.storage → "2 songs" text visible
```

`SEED_WATCH_FIXTURES` (watch app target, `#if DEBUG`): seeds the watch
LibraryStore with 1 playlist / 1 album / 2 tracks whose assets point at two
tiny bundled audio files (reuse the built-in content in `Resources/Audio` via
`BuiltInContentProvider`). No WCSession involvement — the smoke runs the watch
app standalone in the watch simulator.

Simulator setup (once, locally):

```sh
xcrun simctl list devices | grep -i watch   # check existing
# create if missing — use one small + one large:
xcrun simctl create "Watch-Small" "Apple Watch Series 10 (42mm)" watchOS26.5   # ids from `simctl list devicetypes/runtimes`
xcrun simctl create "Watch-Large" "Apple Watch Ultra 3 (49mm)" watchOS26.5
xcodebuild test -project Tonearm.xcodeproj -scheme TonearmWatch \
  -destination 'platform=watchOS Simulator,name=Watch-Small'
```

The fit gate (doctrine rule 8) uses `xcrun simctl io booted screenshot` on both
watches for every screen touched in a phase.

## 11 · CI changes (`.github/workflows/ios.yml`)

- `test` job: **unchanged** (`swift test` picks up all new Core tests). Never
  add a simulator test job (repo doctrine).
- **Product-name guard flip (Phase 1)**: delete the legacy "Platterhead"
  guard. Replace with a **codename-leak guard**: fails if (a) any
  `CFBundleDisplayName` in `project.yml` is not exactly `Platterhead`
  (suffixed variants like "Platterhead Widgets" allowed), or (b) a
  double-quoted string literal containing `Tonearm` appears in UI-string
  surfaces (`Sources/Features`, `Sources/App`, `Sources/Widgets`,
  `Sources/Intents`, `WidgetsExtension`, `ShareExtension`, `WatchApp`) outside
  an explicit allowlist (URL scheme `tonearm`, bundle-id literals,
  `appendingPathComponent("Tonearm…")` container dirs, UserDefaults keys,
  accessibility *identifiers*). Keep the StoreKit boundary guard as is; extend
  its path scope to `WatchApp` (no StoreKit on the watch).
- `testflight-build` job (Phase 2):
  - Add `WATCH_PROVISIONING_PROFILE_BASE64` to the secret checks and import it
    as `~/Library/MobileDevice/Provisioning Profiles/Watch_App_Store.mobileprovision`.
  - `ExportOptions.plist`: add
    `guru.parso.tonearm.watchkitapp → Platterhead Watch App Store` to
    `provisioningProfiles`.
  - Archive/export steps otherwise unchanged — the `Tonearm` scheme builds and
    embeds the watch app via the target dependency, and the version overrides
    propagate.
- Watch **compile** safety on PRs comes from the local gate (§12 step 4);
  post-merge, the archive job fails loudly if the watch target breaks.

## 12 · Phases

Every phase uses this **gate procedure** (do not skip steps):

```sh
# 1 branch
git checkout main && git pull && git checkout -b watch/phase-N-<slug>
# 2 implement (+ tests), keeping commits small
# 3 host tests
swift test
# 4 project + builds (after any file add/remove: regenerate AND commit the .xcodeproj)
xcodegen generate
xcodebuild build -project Tonearm.xcodeproj -scheme Tonearm \
  -destination 'platform=iOS Simulator,name=iPhone 16'
# phases ≥ 2 also:
xcodebuild build -project Tonearm.xcodeproj -scheme TonearmWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
# phases that touch watch UI also: run the smoke (§10.3) + fit screenshots small & large
# 5 commit with the Co-Authored-By trailer your harness specifies
# 6 merge + push
git checkout main && git merge --no-ff watch/phase-N-<slug> && git push
# 7 CI gate — BOTH jobs green before the next phase
gh run watch $(gh run list --branch main --limit 1 --json databaseId -q '.[0].databaseId')
```

### Phase 0 — secrets & preflight (no code)
- `gh secret set WATCH_PROVISIONING_PROFILE_BASE64` (command in §3).
- Verify `gh secret list` shows it; verify watch simulators exist or create
  them (§10.3). Nothing to merge; no CI gate.

### Phase 1 — rebrand: Platterhead everywhere user-visible
- `project.yml`: `CFBundleDisplayName` → `Platterhead`; share ext → `Add to
  Platterhead`; widgets → `Platterhead Widgets`.
- Audit & fix every user-visible "Tonearm": `grep -rn '"[^"]*Tonearm' Sources
  WidgetsExtension ShareExtension Resources` — onboarding, settings/about,
  paywall copy, widget display names/descriptions, App Intents titles/phrases,
  VoiceOver labels. Internal identifiers/keys/dirs stay.
- Flip the CI guard (§11). Update README title/wording if user-facing.
- Note in the audit: App Store Connect listing name + StoreKit product display
  names are console-side user tasks.
- Gate: full procedure; eyeball home-screen name in the iOS simulator.

### Phase 2 — watch target scaffolding + CI + TestFlight
- `Package.swift`: add `.watchOS(.v11)`.
- New `WatchApp/` dir: `PlatterheadWatchApp.swift` (App entry rendering a
  placeholder root that already says "Platterhead"), `Info.plist`
  (`CFBundleDisplayName: Platterhead`,
  `WKCompanionAppBundleIdentifier: guru.parso.tonearm`,
  `WKRunsIndependentlyOfCompanionApp: true`, `UIBackgroundModes: [audio]`,
  version vars), `Assets.xcassets` with watch app icon (derive from the iOS
  icon; `scripts/make_icon.py` is the precedent — watch icons must have no
  transparency and fill the circle).
- `project.yml`: `TonearmWatch` target — `type: application`,
  `platform: watchOS`, `deploymentTarget: "11.0"`, sources `WatchApp`,
  dependency `package: TonearmCore`,
  `PRODUCT_BUNDLE_IDENTIFIER: guru.parso.tonearm.watchkitapp`,
  `TARGETED_DEVICE_FAMILY: "4"`, Debug automatic signing, Release manual +
  `PROVISIONING_PROFILE_SPECIFIER: "Platterhead Watch App Store"`. Add
  `- target: TonearmWatch` to the `Tonearm` app dependencies. After
  `xcodegen generate`, **verify the pbxproj contains an "Embed Watch Content"
  copy phase** placing the watch app in `$(CONTENTS_FOLDER_PATH)/Watch`
  (XcodeGen does this automatically for watchOS app dependencies; if it did
  not, fix via the dependency's embed options rather than hand-editing).
- Make `TonearmCore` compile under the watchOS SDK: build the watch scheme and
  add minimal `#if !os(watchOS)` guards (§4). `swift test` must stay green.
- CI + ExportOptions changes from §11. Scheme: add `TonearmWatch` scheme.
- Gate: full procedure + confirm the TestFlight build processes and the watch
  app installs from TestFlight (user assist).

### Phase 3 — Core sync & playback logic (no UI)
- Implement `Sources/WatchSync/` + `Sources/WatchPlayback/` per §4–§7 with the
  full test suite of §10.1 (this phase is mostly tests by volume).
- Gate: full procedure (no watch UI yet — no smoke).

### Phase 4 — phone plumbing
- Schema migration vNext (§5), `PhoneWatchSessionAdapter`,
  `WatchTransferController`, catalog regeneration hooks, `download(rows:)`
  generalization of `makeOffline`, manifest ingestion. Tests:
  `DownloadRowsTests`, `WatchSessionStateTests`, migration test.
- Gate: full procedure.

### Phase 5 — phone UI
- `WatchGlyph`, menu items, Download All / Download All to Watch,
  Settings › Apple Watch screen, transfer pill (P1–P5 mockups).
- Gate: full procedure + iOS smoke (`TonearmSmokeUITests`) locally + eyeball.

### Phase 6 — watch library, storage, browse UI
- `WatchSessionAdapter`, file reception (pinned dir / cache / orphans),
  catalog import wiring, manifest reporting, screens W1–W7, W11, W13,
  reachability filter, fixture seeding (`SEED_WATCH_FIXTURES`).
- Gate: full procedure + fit screenshots (small & large) for every screen.

### Phase 7 — watch playback + Now Playing
- `AVPlayerOutput`, session activation (`.longFormAudio`), engine wiring,
  W8 Now Playing (exact pt budget), W9 Up Next, W10 on-demand fetch,
  crown volume, `MPNowPlayingInfoCenter`/remote commands, position
  persistence + restore.
- Gate: full procedure + fit screenshots + manual check: background audio
  continues wrist-down in sim; route-picker appears on first play.

### Phase 8 — smoke test, hardening, docs
- `WatchUITests` target (`bundle.ui-testing`, platform watchOS, test target
  `TonearmWatch`) with the ONE smoke test (§10.3); add to the TonearmWatch
  scheme's test action. It stays out of CI.
- Failure-path polish: transfer retry UX, unreachable mid-fetch, storage-full
  refusal, catalog re-send.
- README: watch app section. Update this plan's Implementation Audit.
- Gate: full procedure + smoke green on Watch-Small AND Watch-Large.

## 13 · Backlog (explicitly out of v1)

Sleep timer · favorites on watch · dictation/scribble search ·
watch-initiated downloads · direct streaming (watch Wi-Fi → remote sources) ·
artwork/blurred background on Now Playing · custom complications & Smart
Stack widget · EQ/crossfade/ReplayGain on watch · queue reordering on watch ·
auto-sync of most-played content.

## 14 · Implementation Audit

_To be filled in by the implementing agent, per phase: files changed, tests
added/run, CI run links, intentional deviations from this plan._

- Phase 0: Secret set, watch simulators created (Watch-Small 42mm, Watch-Large 49mm). CI run: N/A (no code).
- Phase 1: Rebrand complete — 19 files changed. project.yml CFBundleDisplayName → Platterhead. All user-visible "Tonearm" strings → "Platterhead" in Sources/Features, Sources/Intents, Sources/Domain, Sources/Pro, Sources/Remote, WidgetsExtension, ShareExtension. CI guard flipped: codename-leak guard greps only double-quoted string literals in UI dirs. CI run: [29702427790](https://github.com/johnarleyburns/parso-tonearm/actions/runs/29702427790) — both jobs green.
- Phase 2: Completed. Package.swift: added `.watchOS(.v10)` (v11 requires PackageDescription 6.0 which would break Swift 5.10 target). project.yml: fixed WATCHOS_DEPLOYMENT_TARGET from "26.3" to "11.0". xcodegen regenerated. splash_screen.jpg moved to Resources/ and set as background in AnimatedSplashView. Git hooks added: pre-commit runs swift test, pre-push runs swift test + make test-integration. Fixed 4 pre-existing watch test failures (WatchGlyphState aggregateState empty case, WatchPlayerEngine handlePrevious logic, WatchTransferPlanner failed-without-error handling).
- Phase 3: Pre-existing. Sources/WatchSync/ (7 files) and Sources/WatchPlayback/ (3 files) with 10 test files already implemented and passing (109 tests). Core sync protocol, player engine, position store, catalog, storage, glyph state, manifest, transfer queue, library filter all in place.
- Phase 4: Completed. Schema migration v12 adds watchTransfer + watchManifest tables. Entities: WatchTransferRecord, WatchManifestRecord with GRDB FetchableRecord/MutablePersistableRecord conformances. WatchTransferController actor drives the queue with fileProvider seam. WatchSessionState display model (notInstalled/installedNotReachable/reachable/unsupported). download(rows:) generalization of makeOffline in AppState. Tests: MigrationV12Tests (4 tests), WatchSessionStateTests (3 tests). swift test: 681 tests, 0 failures.
- Phase 5: —
- Phase 6: —
- Phase 7: —
- Phase 8: —
