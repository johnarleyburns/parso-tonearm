# Tonearm

[![iOS Build & TestFlight](https://github.com/johnarleyburns/parso-tonearm/actions/workflows/ios.yml/badge.svg)](https://github.com/johnarleyburns/parso-tonearm/actions/workflows/ios.yml)

A privacy-first music player for people who own their music.

Local files, referenced in place — never copied, never uploaded. Plus stream-only playback
of archive.org audio from links you paste. No account. No ads. No telemetry. Tonearm never
phones home; it talks only to services you explicitly connect.

**FLAC · Opus · ALAC · MP3 · AAC · WAV/AIFF · gapless · 10-band EQ · ReplayGain**

Streamed audio is cached transparently as you listen, so music you've played is simply
there when you're offline. There is no download button, because you don't need one.

---

## The free/Pro line

Tonearm's Pro tier originally gated *conveniences* — cache size, prefetch depth, folder
watch, iCloud sync, audio tools, smart playlists, and tag editing. Those are taxes on your
own disk and your own phone, and we've removed them. They are free, permanently, and a CI
test (`Tests/FreeTierRegistryTests.swift`) fails the build if anyone ever tries to re-gate
them.

The new line is simple:

> **Free — a complete player.** Everything you can do *with your music, on your own devices.*
>
> **Pro — reach.** Your music *wherever else it lives*. Remote libraries only.

### Free, forever

All formats (FLAC, Opus, ALAC, MP3, AAC, WAV/AIFF) · gapless · 10-band EQ · ReplayGain ·
crossfade · unlimited cache, any size · any prefetch depth · folder watch · full library
browse by artist, album and genre · queue and playlist editing · archive.org sources ·
local import · widgets, Shortcuts, share extension · listening stats · scrobbling · lyrics ·
iCloud Sync (library, playlists, favorites, artwork, presets) · parametric EQ · crossfeed ·
convolution · bit-perfect output · smart playlists · tag editor · bulk edits ·
duplicate detection · zero telemetry, no account.

### Remote Libraries — $7.99, one time

Connect to your music wherever it lives. All 9 providers: Dropbox, Google Drive, OneDrive,
pCloud, Subsonic/Navidrome, WebDAV, Jellyfin, Plex and SMB. Streamed through the same
transparent cache as everything else, so it goes offline by itself.

**One price. Forever.** No subscription, no account, no telemetry — while VOX charges
$49.99/year and Flacbox puts ads in its free tier. Family Sharing is on. And because Tonearm
is GPLv3, you can always build Pro from source instead.

## Roadmap

- **CarPlay** — *planned, pending Apple's entitlement approval.* It will ship **free** once
  approved. It is deliberately absent from the paid feature list until it is real.
- **Remote Libraries** — OAuth polish, provider-specific troubleshooting, and broader
  integration coverage.
- **iPad and Mac** apps.

The remote connector OAuth handoff plan lives in
[`docs/plans/remote-oauth-connectors-handoff.md`](docs/plans/remote-oauth-connectors-handoff.md).

## Remote library connectors

Remote libraries are a Pro feature, but they still follow Tonearm's privacy rule: Tonearm
talks only to services you explicitly connect, stores credentials in Keychain, and never
routes your music through a Tonearm server.

| Connector | Tier | Sign-in | Setup |
| --- | --- | --- | --- |
| Dropbox | Guided | OAuth + PKCE | Sign in, approve read-only file access, browse folders. |
| Google Drive | Guided | OAuth + PKCE | Sign in with Drive readonly access, browse folders. |
| OneDrive | Guided | OAuth + PKCE | Sign in with Microsoft `Files.Read`, browse folders. |
| pCloud | Guided | OAuth | Sign in, then Tonearm uses the correct pCloud API host. |
| Subsonic/Navidrome | Guided | URL + username/password | Enter your server URL and account credentials. |
| WebDAV | Guided | URL + username/password | Use a WebDAV endpoint for Nextcloud, ownCloud, rclone, or a NAS. |
| Jellyfin | Guided | URL + username/password | Enter the Jellyfin URL and an account with music-library access. |
| Plex | Advanced | URL + Plex token | Enter the direct Plex server URL and account token. |
| SMB | Advanced | iOS Files folder grant | Connect SMB in Files first, then choose the shared folder in Tonearm. |

Cloud OAuth requires provider client IDs in app builds. Configure these Xcode build settings
before using the production sign-in buttons:

- `TONEARM_DROPBOX_CLIENT_ID`
- `TONEARM_GOOGLE_DRIVE_CLIENT_ID`
- `TONEARM_ONEDRIVE_CLIENT_ID`
- `TONEARM_PCLOUD_CLIENT_ID`
- `TONEARM_PCLOUD_CLIENT_SECRET` when your pCloud app requires it

Register the `tonearm://oauth/<provider>` redirect for each OAuth app, where `<provider>` is
`dropbox`, `googleDrive`, `oneDrive`, or `pCloud`.

Integration tests use a local fake server instead of real provider credentials:

```sh
make test-integration
```

That target starts `docker-compose.remote-test.yml`, sets
`TONEARM_REMOTE_INTEGRATION_BASE_URL`, runs `RemoteIntegrationTests`, and tears the server
down.

## Building

```sh
xcodegen generate     # project.yml -> Tonearm.xcodeproj
xcodebuild test -scheme Tonearm -destination 'platform=iOS Simulator,name=iPhone 16'
```

Requires iOS 18. Single dependency: [GRDB](https://github.com/groue/GRDB.swift).

## Architecture

Product rules live in **pure, unit-tested types** with no SwiftUI, no UIKit, no singletons
and no I/O — `URLGrammar`, `FileSelectionPolicy`, `ProGating`, `SyncGating`, `SyncMerge`,
`ImportRouter`, `ByteRangeMap`, `PlaybackResilience`. Views bind, format and dispatch; they
never decide. If a view contains an `if` that encodes a product rule, that rule belongs in a
tested type instead.

```
Sources/
  App/          AppState, TonearmApp
  Domain/       entities + policy (no UIKit/SwiftUI)
  Data/         LibraryStore (GRDB + FTS5), ArtworkStore, BookmarkVault
  Audio/        AudioPlayer, CacheStore, CachingResourceLoader, EQ/, Opus/
  IA/           archive.org: URLGrammar, ItemResolver, List/CollectionResolver
  Pro/          StoreKit 2 entitlement (import StoreKit is CI-fenced to this dir)
  Sync/         CloudSyncEngine (CKSyncEngine) + pure mapping/merge/gating
  Features/     SwiftUI views — thin
```

## License

GPLv3. Tonearm is a clean-room app inspired by foobar2000's *values* — format breadth,
gapless, zero telemetry, power-user transparency. It shares no code with it.
