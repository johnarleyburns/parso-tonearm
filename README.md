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

In the same spirit, remote libraries used to be the one paid feature — a tax on the music
that lives on *other people's servers you already pay for*. They are free now too, along
with semantic search and auto-generated playlists.

The line is simple:

> **Free — everything about *listening*.** A complete player for music you own, wherever it
> lives, including finding it by feel and having the app build playlists for you.
>
> **Pro — everything about *performing*.** Platterhead DJ is coming: decks, mixing, stems,
> recording and hardware. One price, once, forever.

### Free, forever

All formats (FLAC, Opus, ALAC, MP3, AAC, WAV/AIFF) · gapless · 10-band EQ · ReplayGain ·
crossfade · unlimited cache, any size · any prefetch depth · folder watch · full Music
browse by artist, album and genre · queue and playlist editing · local import · widgets,
Shortcuts, share extension · listening stats · scrobbling · lyrics · iCloud Sync (Music,
playlists, favorites, artwork, presets) · parametric EQ · crossfeed · convolution ·
bit-perfect output · smart playlists · tag editor · bulk edits · duplicate detection ·
**all 11 remote-library providers (archive.org, Dropbox, Google Drive, OneDrive, pCloud,
Subsonic/Navidrome, WebDAV, Jellyfin, Plex, SMB and Jamendo genre libraries)** · semantic vibe search ·
auto-generated playlists · analysis stages 1–2 (BPM, key, energy) · zero telemetry, no
account.

### Pro — Platterhead DJ (coming)

Two decks, mixing, beat sync, hot cues, stems, recording and MIDI hardware — one time, no
subscription, no account. Anyone who bought the retired remote-libraries product before the
transition receives Platterhead DJ at no charge.

## Roadmap

- **Platterhead DJ (Pro)** — two decks, stems, recording, hardware.
- **CarPlay** — *planned, pending Apple's entitlement approval.* It will ship **free** once
  approved. It is deliberately absent from the paid feature list until it is real.
- **iPad and Mac** apps.

The remote connector OAuth handoff plan lives in
[`docs/plans/remote-oauth-connectors-handoff.md`](docs/plans/remote-oauth-connectors-handoff.md).

## Remote library connectors

Remote libraries are free, but they still follow Tonearm's privacy rule: Tonearm
talks only to services you explicitly connect, stores credentials in Keychain, and never
routes your music through a Tonearm server.

| Connector | Tier | Sign-in | Setup |
| --- | --- | --- | --- |
| archive.org (public lists, items, collections) | Guided | URL only | Paste an item, list, favorites, or collection URL to stream. |
| archive.org (private lists) | Guided | URL + username/password | Enter the private list URL and archive.org credentials. |
| Dropbox | Guided | OAuth + PKCE | Sign in, approve read-only file access, browse folders. |
| Google Drive | Guided | OAuth + PKCE | Sign in with Drive readonly access, browse folders. |
| OneDrive | Guided | OAuth + PKCE | Sign in with Microsoft `Files.Read`, browse folders. |
| pCloud | Guided | OAuth | Sign in, then Tonearm uses the correct pCloud API host. |
| Subsonic/Navidrome | Guided | URL + username/password | Enter your server URL and account credentials. |
| WebDAV | Guided | URL + username/password | Use a WebDAV endpoint for Nextcloud, ownCloud, rclone, or a NAS. |
| Jellyfin | Guided | URL + username/password | Enter the Jellyfin URL and an account with music-library access. |
| Jamendo genre libraries | Guided | none | Pick a genre (free, Creative-Commons music); each becomes its own library. Requires a Jamendo application `client_id` in `TONEARM_JAMENDO_CLIENT_ID`. |
| Plex | Advanced | URL + Plex token | Enter the direct Plex server URL and account token. |
| SMB | Advanced | iOS Files folder grant | Connect SMB in Files first, then choose the shared folder in Tonearm. |

Cloud OAuth requires provider client IDs in app builds. Configure these Xcode build settings
before using the production sign-in buttons:

- `TONEARM_DROPBOX_CLIENT_ID`
- `TONEARM_GOOGLE_DRIVE_CLIENT_ID`
- `TONEARM_ONEDRIVE_CLIENT_ID`
- `TONEARM_PCLOUD_CLIENT_ID`
- `TONEARM_PCLOUD_CLIENT_SECRET` when your pCloud app requires it
- `TONEARM_JAMENDO_CLIENT_ID` — the Jamendo application credential (register at devportal.jamendo.com); it is an application key, not a user login.

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
make models           # fetch the Core ML packages pinned in Config/models.lock
make project          # project.yml -> Tonearm.xcodeproj (wraps xcodegen)
xcodebuild test -scheme Tonearm -destination 'platform=iOS Simulator,name=iPhone 16'
```

**No converted model is in the repository** — GitHub rejects any file over 100 MB.
`make models` downloads the three Core ML packages pinned in `Config/models.lock`
(CLAP audio + text and the Demucs stems model, ~460 MB) and checksum-verifies
them into `Resources/Models/`; a package already on your machine is kept, and
`scripts/fetch-models.sh --force` replaces it. Without a package, the feature it
backs reports itself unavailable rather than failing — semantic search says so,
and the decks play the full mix with the stem faders disabled.

`make project` rather than bare `xcodegen generate`: it first writes
`Config/models-odr.yml` from which of those packages are actually on this
machine, so the ODR tag for a missing one is not in the project. Without that
overlay the spec has no include to read and xcodegen stops; run `make project`
once after cloning.

Requires iOS 18. Single dependency: [GRDB](https://github.com/groue/GRDB.swift).

## Architecture

Product rules live in **pure, unit-tested types** with no SwiftUI, no UIKit, no singletons
and no I/O — `URLGrammar`, `FileSelectionPolicy`, `SyncGating`, `SyncMerge`,
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
  WatchPlayback/ WatchPlayerEngine, position store, audio output protocol
  WatchSync/     WatchCatalog, transfer queue, sync messages, library filter
WatchApp/
  Views/         SwiftUI views for watch (Now Playing, Up Next, browse, storage)
```

## Apple Watch

Platterhead includes a standalone watchOS 11 app (`guru.parso.tonearm.watchkitapp`) that
plays downloaded music completely off-grid — no iPhone required.

- **Sync**: Transfer music from iPhone over WatchConnectivity at track, album, or playlist
  level. Manage transfers in Settings → Apple Watch.
- **Playback**: Full transport (play/pause/next/prev), Up Next queue with tap-to-jump,
  shuffle/repeat, Digital Crown volume, background audio, position persistence.
- **Browse**: Playlists, albums, and alphabetical song list with on-watch content filtering
  when untethered.
- **Storage**: View and manage on-watch content with byte counts and per-item delete.

## Terms

Tonearm is proprietary software. All rights are reserved; use and distribution require
permission under the terms in [`LICENSE`](LICENSE). Tonearm is a clean-room app inspired by
foobar2000's *values* — format breadth, gapless, zero telemetry, power-user transparency. It
shares no code with it.
