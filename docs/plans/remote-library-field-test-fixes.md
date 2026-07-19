# Remote Library Field-Test Fixes

## Scope

This pass fixes the field-test issues around remote-library entry points, Pro upgrade handoff, Music/Libraries terminology, secure paste in connector auth fields, Subsonic streaming, remote artwork, remote playback metadata, and miniplayer provenance.

Internal Swift type and folder names such as `LibraryView`, `SourcesView`, `LibraryStore`, and `Source` remain unchanged to avoid broad churn. User-facing copy now uses `Music` for the music collection surface and `Libraries` for connected sources.

## Entry Points And Pro Flow

- `AppState.requestAddRemoteLibrary()` is the single entry point used from Music, Libraries, and the global add menu.
- Free users see the Pro paywall from the Add Remote Library entry point.
- Pro users go directly to Libraries and open `AddServerSheet`.
- Purchases or restores started from Add Remote Library show a completion sheet only after Pro is active.
- The completion sheet actions are:
  - `Add Library Now`: opens Libraries and presents `AddServerSheet`.
  - `Maybe Later`: dismisses without opening the connector sheet.
- Lock icons are shown only for gated Add Remote Library actions.

Relevant files:

- `Sources/App/AppState.swift`
- `Sources/Features/RootView.swift`
- `Sources/Features/Components.swift`
- `Sources/Features/Ingest/AddMenuSheet.swift`
- `Sources/Features/Settings/ProPaywallView.swift`
- `Sources/Pro/AddRemoteLibraryProFlow.swift`

## Credential Handling

Remote connector passwords and tokens continue to flow through `CredentialStore` and Apple Keychain. They are not persisted in the database and should not be logged, documented, embedded in mockups, or hardcoded in tests.

`AddServerSheet` uses a paste-capable secure UIKit text field wrapper for password and token inputs so users can paste long credentials without changing the storage path.

Local/manual Subsonic testing can use the untracked helper:

```sh
source scripts/subsonic-test-env.local.sh
swift test --filter SubsonicLocalSmokeTests
```

The helper is excluded locally through `.git/info/exclude` and must not be committed.

## Remote Playback And Metadata

- Remote providers can now attach `RemoteTrackMetadata` and `RemoteArtwork` to `RemoteNode` and `ResolvedAsset`.
- `RemoteTrackRowFactory` builds transient `TrackRow` values with synthetic album and artist context when provider metadata exists.
- Subsonic, Jellyfin, and Plex populate title, artist, album, album artist, track/disc numbers, duration, codec, bitrate/sample-rate details, and artwork references where available.
- WebDAV, SMB, Dropbox, Google Drive, OneDrive, and pCloud retain filename fallback behavior unless metadata is exposed later.
- Subsonic streams now tolerate valid `200 OK` full-body audio responses as well as `206 Partial Content` range responses.
- `ResolvedAsset.supportsByteRanges` is respected by `AudioPlayer` and `CachingResourceLoader`.
- Provider artwork support starts with Subsonic `getCoverArt.view` and includes authenticated Jellyfin/Plex image URLs.
- MiniPlayer provenance is derived from `row.source?.kind`: archive.org stays `archive.org`; remote providers show their provider name.
- MiniPlayer is hidden while full Now Playing is presented.

Relevant files:

- `Sources/Remote/RemoteLibraryProvider.swift`
- `Sources/Remote/RemoteTrackRowFactory.swift`
- `Sources/Audio/AudioPlayer.swift`
- `Sources/Audio/CachingResourceLoader.swift`
- `Sources/Audio/RemoteStreamingResponsePolicy.swift`
- `Sources/Audio/PlaybackDisplayPolicy.swift`
- `Sources/Media/ArtworkService.swift`
- `Sources/Remote/Providers/SubsonicProvider.swift`
- `Sources/Remote/Providers/JellyfinProvider.swift`
- `Sources/Remote/Providers/PlexProvider.swift`

## Tests

Added or extended coverage:

- Add Remote Library free/Pro behavior and completion-sheet actions.
- Keychain/local encrypted credential wording and Music/Libraries terminology.
- Remote playback metadata preservation across Subsonic, Jellyfin, Plex, WebDAV, SMB, Dropbox, Google Drive, OneDrive, and pCloud fakes.
- Subsonic `206` and `200` stream policy, stream URL auth, cover-art decode, and artwork URL generation.
- Fake integration server range/non-range streaming, cover art endpoints, metadata, and authenticated image/audio routes.
- Optional local Navidrome smoke test gated by `TONEARM_SUBSONIC_TEST_URL`, `TONEARM_SUBSONIC_TEST_USER`, and `TONEARM_SUBSONIC_TEST_PASSWORD`.
- Miniplayer display policy for archive.org, remote providers, cache suffixes, and Now Playing suppression.

Primary commands:

```sh
swift test
make test-integration
source scripts/subsonic-test-env.local.sh
swift test --filter SubsonicLocalSmokeTests
xcodebuild test -scheme Tonearm -project Tonearm.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 16'
```
