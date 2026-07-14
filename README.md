# Tonearm

A privacy-first music player for people who own their music.

Local files, referenced in place — never copied, never uploaded. Plus stream-only playback
of archive.org audio from links you paste. No account. No ads. No telemetry. Tonearm never
phones home; it talks only to services you explicitly connect.

**FLAC · Opus · ALAC · MP3 · AAC · WAV/AIFF · gapless · 10-band EQ · ReplayGain**

Streamed audio is cached transparently as you listen, so music you've played is simply
there when you're offline. There is no download button, because you don't need one.

---

## Redesign: the free/Pro line

Tonearm's Pro tier originally gated *conveniences* — cache size, prefetch depth, folder
watch. Those are taxes on your own disk and your own phone, and we've removed them. They
are free, permanently, and a CI test (`Tests/FreeTierRegistryTests.swift`) fails the build
if anyone ever tries to re-gate them.

The new line is simple:

> **Free — a complete player.** Everything about *your files, on this device.*
>
> **Pro — reach and mastery.** Your music *wherever it lives*, on *every device you own*,
> with the tools to master it.

### Free, forever

All formats (FLAC, Opus, ALAC, MP3, AAC, WAV/AIFF) · gapless · 10-band EQ · ReplayGain ·
crossfade · unlimited cache, any size · any prefetch depth · folder watch · full library
browse by artist, album and genre · queue and playlist editing · archive.org sources ·
local import · widgets, Shortcuts, share extension · listening stats · scrobbling · lyrics ·
zero telemetry, no account.

### Tonearm Pro — $9.99, one time

1. **Remote Libraries** — your music wherever it lives: Subsonic/Navidrome, Jellyfin, Plex,
   WebDAV, SMB, Dropbox, Google Drive, OneDrive, pCloud. Streamed through the same
   transparent cache as everything else, so it goes offline by itself.
2. **iCloud Sync** — library, playlists, favorites, play history, artwork and EQ presets
   across your devices. Your iCloud, your data, off by default.
3. **iPad + Mac** — same purchase, every device.
4. **Pro Audio & Library Tools** — parametric EQ, crossfeed, convolution, bit-perfect
   output; smart playlists; tag editor; bulk edits; duplicate detection.

**One price. Forever.** No subscription, no account, no telemetry — while VOX charges
$49.99/year and Flacbox puts ads in its free tier. Family Sharing is on. And because Tonearm
is GPLv3, you can always build Pro from source instead.

## Roadmap

- **CarPlay** — *planned, pending Apple's entitlement approval.* It will ship **free** once
  approved. It is deliberately absent from the paid feature list until it is real.
- **Remote Libraries**, provider by provider — Subsonic/Navidrome first, then WebDAV/SMB,
  Jellyfin, Plex, and the cloud drives.
- **iPad and Mac** apps.

The full analysis and the phased build plan live in
[`docs/redesign/01-agentic-build-plan.md`](docs/redesign/01-agentic-build-plan.md).

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
