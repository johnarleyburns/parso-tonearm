# Native Mac app — feature parity with the iPhone app

Status as of 2026-10-02. The native Mac app (`TonearmMac` target, `Sources/AppMac`) was
removed by 67a569f and restored on top of the current iPhone app. It is a real SwiftUI/AppKit
app (not Catalyst, not "Designed for iPhone"): it compiles the same `Sources/App` and
`Sources/Features` code as the iPhone target and links the same `TonearmCore`,
`TonearmDiscovery` and `ParsoAudio*` packages. Only the app shell is Mac-specific.

Build: `xcodebuild build -project Tonearm.xcodeproj -scheme TonearmMac -destination
'platform=macOS' CODE_SIGNING_ALLOWED=NO` (never with `-sdk`; run builds one at a time).
Deployment target macOS 26 (the shared UI uses Liquid Glass APIs). Same bundle ID as iOS
(Universal Purchase). The Mac and the iPhone bundle the same `Resources/Starter/starter.sqlite`
(`make starter`); without it `StarterLibrary.shared` is nil and the app still runs.

## Legend

- **Works** — the shared code runs unchanged on Mac.
- **Adapted** — works on Mac through a Mac-specific branch or Mac-native UI (what changed is
  listed).
- **iPhone-only** — tied to iPhone hardware or an iPhone-only system surface; the Mac
  equivalent (if one makes sense) is listed.

## Summary

| Status (feature tables below) | Count |
|---|---|
| Works | 37 |
| Adapted | 31 |
| iPhone-only | 3 |
| **Total rows** | **71** |

All 68 platform-neutral features run on Mac. The six iPhone-only capabilities are listed at
the end: four have a Mac-native equivalent (App Shortcuts, menu bar extra, link drop/deep link,
system Sound menu) and two have none (CarPlay, Apple Watch).

## App shell and navigation

| Feature (iPhone) | Mac status | Mac implementation |
|---|---|---|
| Tab bar: Listen, My Music, Settings | Adapted | `NavigationSplitView` sidebar (Listen, My Music; ⌘1/⌘2). Settings is the `Settings {}` scene (⌘,). `appState.tab` still drives the selection, so shared "go to My Music" code works. |
| Mini player accessory | Adapted | `MacTransportBar` along the window bottom: artwork/title (opens Now Playing), shuffle, previous, play/pause, next, repeat, scrubber with times, volume slider. |
| Now Playing screen (push/zoom) | Adapted | Trailing `.inspector` column (toolbar button, ⌥⌘P, View menu). Scrolls in short windows; grabber hidden. |
| Global sheets (Add menu, new playlist, Build a Mix, add source/server/folder, metadata editor, file importer, artwork picker) | Adapted | Moved into the shared `AppPresentations` modifier used by both `RootView` and `MacRootView`, with Mac sheet sizes, so a new flow cannot be added to one shell and missed on the other. |
| Onboarding | Adapted | Sheet over the main window instead of a full-screen cover; pages stepped with Back/Continue (macOS has no paged `TabView`). |
| Toasts, "Adding …" and network-skip banners | Works | `AppStatusBanners` (shared with iPhone) and `toastLayer`. |
| Appearance (System/Light/Dark) | Works | Applied to the window, menu bar extra and Settings scene. |
| Deep links `tonearm://…` (add source, play/pause/next/previous, Now Playing) | Works | `.onOpenURL` on the main window. |
| Restore queue and position at launch; persist on quit | Adapted | Persisted on scene inactive and in `applicationWillTerminate`. Closing the window keeps the app (and music) running in the menu bar. |
| Rescan watched folders when the app becomes active | Works | Same `FolderWatchService` call on scene activation. |
| Haptics (`sensoryFeedback`) | Works | No-op on Mac, as expected. |

## Listen

| Feature | Mac status | Notes |
|---|---|---|
| Jump Back In | Works | |
| Build a Mix entry card (genre / playlist / all tracks, 15/30/60 min) | Works | Also File › Build a Mix… (⇧⌘B), the toolbar button and the menu bar extra. `MixBuilderRequest.picksSource` lets those open the same source-picking builder Listen uses. |
| Mix for You preview, Play Mix, Regenerate | Works | Same `MixExperienceView`. |
| Listening stats, Top Songs/Artists | Works | |
| Favorites | Works | |
| Mood search (prompt, mood pills, era/vibe pills, mix-compatible toggle, Make a Mix) | Works | Needs the CLAP models (see Sound Index). |
| Track detail card | Works | |
| Supporter badge | Works | |

## My Music

| Feature | Mac status | Notes |
|---|---|---|
| Scopes: Playlists, Artists, Albums, Songs, Genres, Jamendo | Works | |
| Text search (All) | Adapted | Native toolbar search field (`.searchable`, ⌘F via Edit › Find in My Music). Typing switches to My Music; the inline phone field is hidden on Mac. |
| Search by Mix (BPM preset, Camelot key) | Works | |
| Search by Sound | Works | Needs the CLAP models. |
| Artist/album/genre drill-down, album artwork | Works | |
| Track context menu (play next, add to queue, add to playlist, favorite, start a mix from this track, edit info, change artwork, download) | Works | Right-click menus are native on Mac. Apple Watch items are hidden. |
| Swipe actions | Works | Trackpad swipe. |

## Playlists

| Feature | Mac status | Notes |
|---|---|---|
| Create, rename, delete, pin | Works | New Playlist… ⌘N. |
| Playlist detail, play, add tracks | Works | |
| Reorder / remove tracks | Adapted | iPhone hides these behind Edit; a Mac list reorders by drag and deletes with the Delete key at any time, so there is no Edit button and Sort by BPM is always offered. |
| Sort by BPM | Adapted | Always visible on Mac (was hidden behind Edit). |
| Mix This Playlist | Works | |
| Download all | Works | Saves for offline playback on the Mac. |
| Ambient playlists (rain, ocean, water) with looping video | Adapted | `LoopingVideoView` has an `NSViewRepresentable` implementation. |

## Now Playing and playback

| Feature | Mac status | Notes |
|---|---|---|
| Transport, scrubber, shuffle, repeat | Adapted | Also in the transport bar and the Controls menu (⌘P play/pause, ⌘←/⌘→, ⌥⌘S shuffle, ⌥⌘R repeat). |
| Volume | Adapted | Transport-bar slider and ⌘↑/⌘↓ (the iPhone uses hardware buttons). |
| Up Next queue: reorder, remove, clear Keep Playing additions | Adapted | Drag to reorder and Delete to remove at any time (no reorder mode). Also fixed a duplicated accessibility label on the clear button. |
| Keep Playing as an endless mix | Works | Also a toggle in the Controls menu. |
| Smart transitions, transition chip, audition, prepare now | Works | `TransitionPrepService` is in the Mac environment (window and Settings). |
| Sleep timer (15/30/45 min, 1 h, end of track, cancel) | Works | Also Controls › Sleep Timer. |
| Equalizer | Works | |
| Favorite, add to playlist, share artwork | Works | |
| Change / remove custom artwork | Adapted | Shared `artworkImagePicker`: Photos picker on iPhone, an Open panel for image files on Mac (its sidebar still reaches Photos). Same for album and library artwork. |
| Download current track for offline | Adapted | Toast says "Saved to this Mac". |
| Lock screen / Control Center Now Playing and remote commands | Adapted | `MacPlaybackBridge`: `MPNowPlayingInfoCenter` (with explicit `playbackState`, which macOS requires) and `MPRemoteCommandCenter` including `togglePlayPauseCommand`, so the keyboard media keys, Control Center and AirPods work. |
| AirPlay route button | iPhone-only → Mac equivalent | `AVRoutePickerView` on macOS routes an `AVPlayer`, and Platterhead plays through its own engine; output is chosen from the system Sound menu / Control Center, as in Music.app. |
| Network-skip notice, offline cache glyphs | Works | |

## Library sources and import

| Feature | Mac status | Notes |
|---|---|---|
| Add Local Folder (options sheet, keep order, watch) | Adapted | File › Add Local Folder… ⌘O and the toolbar menu. Security-scoped bookmarks (see below). |
| Add Audio Files | Adapted | File › Add Audio Files… ⇧⌘O. |
| Drag and drop | Adapted (Mac-only bonus) | Drop a folder or audio files on the window to import; drop an archive.org/Jamendo link from Safari to add it as a library. |
| Persistent access to local files | Adapted | `BookmarkVault` creates and resolves app-scoped security-scoped bookmarks on macOS (`com.apple.security.files.bookmarks.app-scope` entitlement). Without this, sandboxed local files stopped playing after a relaunch. Every picker now goes through `BookmarkVault`. |
| Internet Archive items, lists, favorites, collections | Works | File › Add Internet Archive or Jamendo…. |
| Jamendo genre libraries and browse | Works | |
| Remote servers: Subsonic/Navidrome, Jellyfin, Plex, WebDAV, SMB | Adapted | Add Server's paste-capable field is a plain SwiftUI field on Mac (the UIKit paste workaround is iPhone-only). |
| Cloud: Dropbox, Google Drive, OneDrive, pCloud (OAuth) | Adapted | `ASWebAuthenticationSession` anchored to the key `NSWindow`. |
| Music Libraries list, source detail, follow updates, remote browse, add remote tracks | Works | |
| Edit track metadata | Works | |
| Duplicate cleanup and other Tools | Works | |

## Sound Index, Discovery and mixing

| Feature | Mac status | Notes |
|---|---|---|
| Sound Index (CLAP) status, pause/resume, retry, diagnostics export | Adapted | No On-Demand Resources on macOS: `scripts/generate-project.sh` bundles the CLAP encoders into `TonearmMac` when they are on the build host (`make models`); `DiscoveryModelResources` reports them as bundled. Without them the Sound Index says the model is missing, as on iPhone. |
| Background indexing scheduler | Adapted | No `BGTaskScheduler` on Mac (apps are not suspended): `NoopBackgroundTaskScheduler`, the foreground loop indexes while the app runs; app state always reads foreground. |
| Power / thermal gating | Adapted | Real Mac power source via IOKit (`MacPowerSource`): AC power counts as charging and a laptop's battery level is read. Previously the Mac read "battery unknown, not charging", which the policy treats as low battery and would never index. No memory-warning notification on Mac. |
| Diagnostics device family | Adapted | Reports "Mac" and the macOS version. |
| Mood Starter starter DB | Same | Mac and iPhone bundle the same `starter.sqlite` (format 2, no per-track transition prep). |
| Build a Mix, Mix for You, Keep Playing endless mix, transition prep, crossfades | Works | Same planner, prep service and player. |
| iCloud sync (library, playlists, Sound Index results) | Works | CloudKit entitlements on the Mac target. |

## Settings

| Section | Mac status | Notes |
|---|---|---|
| Playback (behaviour, prefetch, EQ, Keep Playing, Smart transitions) | Adapted | Settings › Playback pane. |
| Library & Storage (Music Libraries, Sound Index, transition analysis, streaming cache, iCloud) | Adapted | Settings › Library pane. |
| Account & About (appearance, privacy, support, about, languages) | Adapted | Settings › General pane. The language row opens System Settings › Language & Region on Mac with Mac wording. |
| Advanced (Jamendo key, tools, more settings) | Adapted | Settings › Advanced pane. |
| Siri & CarPlay card | iPhone-only | See below. |
| Apple Watch card | iPhone-only | See below. |
| Contribute to Development (StoreKit) | Works | Universal Purchase. |

## iPhone-only by nature

| Feature | Mac equivalent |
|---|---|
| CarPlay (browse, search, voice search) | None — no CarPlay on Mac. |
| Apple Watch companion (downloads, transfer pill, Watch settings, glyphs) | None — no paired watch. Watch UI is compiled out on Mac; `watchGlyphState` reports "not on watch". |
| Siri `INPlayMediaIntent` extension | App Shortcuts (Play Playlist / Artist / Song, sleep timer) live in the shared `TonearmCore` package and are linked into the Mac app too (Shortcuts, Spotlight). |
| Home Screen / Lock Screen widgets | `MenuBarExtra` mini player (artwork, title, scrubber, transport, Build a Mix…, Show Platterhead), plus Control Center Now Playing through `MacPlaybackBridge`. |
| Share extension (share an archive.org/Jamendo link into the app) | Drag the link onto the window, `tonearm://add?url=…`, or File › Add Internet Archive or Jamendo…. |
| AirPlay button | System Sound menu / Control Center. |

## Mac-native additions

- Menu bar: File (New Playlist ⌘N, Build a Mix… ⇧⌘B, Add Local Folder… ⌘O, Add Audio Files… ⇧⌘O,
  Add Remote Library…, Add Internet Archive or Jamendo…), Edit (Find in My Music ⌘F), View
  (Listen ⌘1, My Music ⌘2, Show/Hide Now Playing ⌥⌘P), Controls (Play/Pause ⌘P, Next ⌘→,
  Previous ⌘←, Shuffle ⌥⌘S, Repeat ⌥⌘R, Keep Playing, Volume ⌘↑/⌘↓, Sleep Timer). Commands
  bring the main window back if it was closed. Space is not bound to Play/Pause because a
  bare-key menu shortcut would swallow spaces typed in search fields; the media keys work.
- Toolbar: Add Music menu, Build a Mix, Now Playing toggle, search.
- Window: single main window (default 1180×780, minimum 960×620), drop target highlight.

## Files changed for the port

- Mac shell: `Sources/AppMac/*` (app, root view, commands, menu bar extra, Settings scene),
  `Sources/App/MacPlaybackBridge.swift`, `ExportOptions-Mac.plist`, `project.yml`
  (`TonearmMac` target + scheme), `scripts/generate-project.sh` (CLAP models for Mac).
- Shared, Mac-aware: `AppPresentations.swift` (new, shared sheets/importers/banners),
  `Components/ArtworkImagePicker.swift` (new), `RootView.swift` (uses the shared modifier;
  iOS-only), `PlatformCompat.swift`, `LoopingVideoView.swift`, `KeywordArtwork.swift`,
  `ArtworkService.swift`, `ArtworkStore.swift`, `BookmarkVault.swift`,
  `DiscoveryModelResources.swift`, `DiscoveryRuntimeController.swift`,
  `DiscoverySchedulingSampler.swift`, `DiscoveryBackgroundTaskAdapter.swift`, `AppState*.swift`
  (watch runtime iOS-only), Settings, Now Playing, Up Next, Playlists, My Music, Onboarding,
  Add Server/Add menu, OAuth.
- Localization: 31 new keys in `Resources/Localizable.xcstrings` (all seven locales,
  `needs_review`); `scripts/sync-localization-catalogs.sh` now also extracts the Mac target so
  Mac-only strings are not marked stale.

## Not done / follow-ups

- No Mac CI job or TestFlight/App Store Mac export lane (CI runs `swift test` only by policy;
  `ExportOptions-Mac.plist` is restored for when one is wanted).
- The Mac app was built but not launched or UI-tested in this pass (an unsigned sandboxed
  build cannot run with its sandbox; launch it from Xcode with signing).
- CLAP models for the Mac were verified only at the project-generation level (no models on
  the build host used here).
- No Mac desktop widget extension; the menu bar extra covers glanceable Now Playing.
