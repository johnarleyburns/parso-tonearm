# Platterhead

[![iOS Build & TestFlight](https://github.com/johnarleyburns/parso-tonearm/actions/workflows/ios.yml/badge.svg)](https://github.com/johnarleyburns/parso-tonearm/actions/workflows/ios.yml)

Platterhead is a privacy-first music player for people who own their music.

Local files, referenced in place — never copied, never uploaded. Plus stream-only playback
of archive.org audio from links you paste. No account. No ads. No telemetry. Platterhead never
phones home; it talks only to services you explicitly connect.

**FLAC · Opus · ALAC · MP3 · AAC · WAV/AIFF · gapless · 10-band EQ · ReplayGain**

Streamed audio is cached transparently as you listen, so music you've played is simply
there when you're offline. There is no download button, because you don't need one.

---

## Platterhead is free

Everything about listening, organizing, analyzing, searching, playlist building, and
Mixes are included. There is no account, no subscription, no feature paywall, and
no telemetry.

If Platterhead is useful to you, Settings includes an optional one-time contribution to
development. It unlocks nothing; it simply adds a Supporter badge as a thank-you.

### Everything, free

All formats (FLAC, Opus, ALAC, MP3, AAC, WAV/AIFF) · gapless · 10-band EQ · ReplayGain ·
crossfade · unlimited cache, any size · any prefetch depth · folder watch · full Music
browse by artist, album and genre · queue and playlist editing · local import · widgets,
Shortcuts, share extension · listening stats · scrobbling · lyrics · iCloud Sync (Music,
playlists, favorites, artwork, presets) · parametric EQ · crossfeed · convolution ·
bit-perfect output · smart playlists · tag editor · bulk edits · duplicate detection ·
**all 14 remote-library providers (archive.org, Dropbox, Google Drive, OneDrive, pCloud, Box,
Yandex.Disk, Subsonic/Navidrome, WebDAV, Jellyfin, Emby, Plex, SMB and Jamendo genre libraries)** ·
semantic vibe search ·
auto-generated playlists · analysis stages 1–2 (BPM, key, energy) ·
**Mixes** — build an explainable order from your own music with phrase-aware transitions · zero telemetry, no account.

## Mixes

Mixes plan order, tempo shape, key relationships, and transition preparation from your library. They do not use bass-swap EQ or stems; the regular crossfade remains the honest fallback.

## TestFlight and human QA

The release system reconciles accepted uploads with App Store Connect on a
schedule. `testflight-uploaded` means Apple accepted the archive;
`testflight-processing` means it is not ready; `ready-for-qa` means the exact
version/build is processed (`VALID`). `testflight-distribution-confirmed` is
extra tester-group evidence. `testflight-access-unverified` does not mean the
build cannot be installed—it only records an unavailable or empty group query.
Testers should install the exact build named in the issue's **TestFlight
availability** comment, run its checklist, then record device, OS, build, and
pass/fail on the issue. Only the human owner closes issues.

## Roadmap

- **CarPlay** — *planned, pending Apple's entitlement approval.* It is deliberately absent
  from this list until it is real.

## Remote library connectors

Remote libraries are free, but they still follow Platterhead's privacy rule: Platterhead
talks only to services you explicitly connect, stores credentials in Keychain, and never
routes your music through a Platterhead server.

| Connector | Tier | Sign-in | Setup |
| --- | --- | --- | --- |
| archive.org (public lists, items, collections) | Guided | URL only | Paste an item, list, favorites, or collection URL to stream. |
| archive.org (private lists) | Guided | URL + username/password | Enter the private list URL and archive.org credentials. |
| Dropbox | Guided | OAuth + PKCE | Sign in, approve read-only file access, browse folders. |
| Google Drive | Guided | OAuth + PKCE | Sign in with Drive readonly access, browse folders. |
| OneDrive | Guided | OAuth + PKCE | Sign in with Microsoft `Files.Read`, browse folders. |
| pCloud | Guided | OAuth | Sign in, then Platterhead uses the correct pCloud API host. |
| Box | Guided | OAuth | Sign in, approve read-only file access, browse folders. |
| Yandex.Disk | Guided | OAuth + PKCE | Sign in with read-only Disk access, browse folders. |
| Subsonic/Navidrome | Guided | URL + username/password | Enter your server URL and account credentials. Also reaches Ampache (use its API key as the password) and Funkwhale (use its separate Subsonic password) through the same Subsonic-compatible API. |
| WebDAV | Guided | URL + username/password | Use a WebDAV endpoint for Nextcloud, ownCloud, rclone, or a NAS. |
| Jellyfin | Guided | URL + username/password | Enter the Jellyfin URL and an account with music-library access. |
| Emby | Guided | URL + username/password | Enter the Emby URL and an account with music-library access. |
| Jamendo genre libraries | Guided | none | Pick a genre (free, Creative-Commons music); each becomes its own library. Requires a Jamendo application `client_id` in `TONEARM_JAMENDO_CLIENT_ID`. |
| Plex | Advanced | URL + Plex token | Enter the direct Plex server URL and account token. |
| SMB | Advanced | iOS Files folder grant | Connect SMB in Files first, then choose the shared folder in Platterhead. |

Cloud OAuth requires provider client IDs in app builds. Configure these Xcode build settings
before using the production sign-in buttons:

- `TONEARM_DROPBOX_CLIENT_ID`
- `TONEARM_GOOGLE_DRIVE_CLIENT_ID`
- `TONEARM_ONEDRIVE_CLIENT_ID`
- `TONEARM_PCLOUD_CLIENT_ID`
- `TONEARM_PCLOUD_CLIENT_SECRET` when your pCloud app requires it
- `TONEARM_BOX_CLIENT_ID` and `TONEARM_BOX_CLIENT_SECRET` — Box's OAuth token endpoint has no PKCE support, so a client secret is required (confidential client), same as pCloud.
- `TONEARM_YANDEX_CLIENT_ID` and, if your Yandex ID app registers as a confidential client rather than a public/PKCE one, `TONEARM_YANDEX_CLIENT_SECRET`.
- `TONEARM_JAMENDO_CLIENT_ID` — the Jamendo application credential (register at devportal.jamendo.com); it is an application key, not a user login.

Register the `tonearm://oauth/<provider>` redirect for Dropbox, OneDrive, pCloud, Box, and
Yandex.Disk (where `<provider>` is `dropbox`, `oneDrive`, `pCloud`, `box`, or `yandexDisk`).
**Google Drive is a special case**: Google's
"iOS" OAuth client type has no free-text redirect-URI field — it ties the redirect to a
reversed-client-ID custom scheme instead. Create the credential as type **iOS** with Bundle ID
`guru.parso.tonearm`, then derive the scheme from the resulting Client ID by stripping
`.apps.googleusercontent.com` and prepending `com.googleusercontent.apps.` (e.g. client ID
`12345-abc.apps.googleusercontent.com` → `com.googleusercontent.apps.12345-abc`). **This derived
value is not an xcconfig build setting** — hardcode it directly in both project.yml's
`CFBundleURLTypes` entry for `guru.parso.tonearm.google-oauth` and
`OAuthClientConfiguration.swift`'s `googleDriveReversedClientID` constant, and keep the two in
sync. Xcode's Info.plist `$(VAR)` build-setting substitution silently collapses to a
1-character garbage value for a string nested this deep (array > dict > array > string) —
confirmed against real archived TestFlight builds (#808/#809) — so it can't be sourced from an
xcconfig variable the way the other three providers' client IDs are.

Each provider's app-review form asks for a **Privacy Policy URL**:
<https://johnarleyburns.github.io/parso-tonearm/> (published from this repo's `gh-pages` branch).

**Before release:** each cloud-drive OAuth app (Dropbox, Google Drive, OneDrive, pCloud, Box,
Yandex.Disk) starts
in that provider's own "development"/"testing" tier, where only accounts the owner explicitly
allowlists in that provider's developer console can sign in — everyone else is blocked. Each
provider must be submitted for and pass that provider's production/verification app review
before real users can connect that provider, independent of shipping the app itself.

Integration tests use a local fake server instead of real provider credentials:

```sh
make test-integration
```

That target starts `docker-compose.remote-test.yml`, sets
`TONEARM_REMOTE_INTEGRATION_BASE_URL`, runs `RemoteIntegrationTests`, and tears the server
down.

## Languages

Platterhead ships in seven languages: English, Deutsch, Español, Français, 日本語, Português (Brasil) and 简体中文. It follows the iPhone's language; to pick a language just for Platterhead, open Settings → Apps → Platterhead → Language. Settings → About → Language lists every language in the build and links there.

Every screen is translated: the iPhone app, Apple Watch app, widgets, Share extension, CarPlay, Siri and App Shortcuts phrases, the sound-index status, and the system permission prompts. Counts use each language's own plural rules. Genre and mood names are translated; provider names, Platterhead, BPM and Camelot keys stay as they are.

The translations are first drafts. Every entry is marked `needs_review` until a native speaker checks it in context. Strings are extracted by the Swift compiler: after changing UI text, run `scripts/sync-localization-catalogs.sh`, add the new keys in all seven languages, and `scripts/check-localization-catalogs.sh` (part of `make ci-guards`) fails if any language is missing.

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

Every commit runs `swift test` via a local pre-commit hook; CI does the same on push.
The UI smoke test suite (`make test-ui-regression`) is run by hand before a release,
not on every commit — it needs a simulator and takes longer than the commit loop
should.

## Architecture

Product rules live in **pure, unit-tested types** with no SwiftUI, no UIKit, no singletons
and no I/O — `URLGrammar`, `FileSelectionPolicy`, `SyncGating`, `SyncMerge`,
`ImportRouter`, `ByteRangeMap`, `PlaybackResilience`. Views bind, format and dispatch; they
never decide. If a view contains an `if` that encodes a product rule, that rule belongs in a
tested type instead.

```
Sources/
  App/          AppState, PlatterheadApp
  Domain/       entities + policy (no UIKit/SwiftUI)
  Data/         LibraryStore (GRDB + FTS5), ArtworkStore, BookmarkVault
  Audio/        AudioPlayer, CacheStore, CachingResourceLoader, EQ/, Opus/
  IA/           archive.org: URLGrammar, ItemResolver, List/CollectionResolver
  Support/      The optional Supporter contribution (import StoreKit is CI-fenced to this dir)
  Sync/         CloudSyncEngine (CKSyncEngine) + pure mapping/merge/gating
  Features/     SwiftUI views — thin
  WatchPlayback/ WatchPlayerEngine, position store, audio output protocol
  WatchSync/     WatchCatalog, transfer queue, sync messages, library filter
WatchApp/
  Views/         SwiftUI views for watch (Now Playing, Up Next, browse, storage)
```

Offline/dev-only tooling lives in `tools/` (none of it runs at app runtime or in the normal
`swift test` gate):

```
tools/
  starter-shards/   Jamendo starter-pack shard build + validate + assemble (build_shard.py,
                     assemble_starter.py, shardlib.py) — produces the bundled Mood Starter catalog.
                     merge_micro_shard.py merges a standalone micro-batch (one that doesn't belong
                     in the frozen manifest-v1.json cohort — see .github/workflows/
                     build-starter-micro-shard.yml and Config/starter-batches/micro/) into a copy
                     of an already-assembled starter.sqlite without touching its existing rows.
  starter-blends/   Starter Blends: structure-input.json (the fixed 9-blend/45-edge track
                     sequence + already-measured track facts) feeds Sources/Tools/StarterBlendEdgePlanner
                     (real DropDetector/DropAwareEdgePlanner edge planning, run via
                     .github/workflows/regen-starter-blend-edges.yml); generate-runtime-data.py is the
                     older v1-era translator, kept for reference.
  blend-lab/        The original hand-run Python reference for drop/bass-exit/phrase detection
                     (structure.py, djmix.py) that Sources/Domain/Mix/DropAwareEdgePlanner.swift and
                     ParsoAudioAnalysis.DropDetector port into the app. Superseded for anything
                     automatic — kept because it's still the clearest place to read the algorithm.
  starter-catalog/  Generates tools/starter-catalog/jamendo_taxonomy_v1.json from
                     Sources/Remote/Providers/JamendoGenreProvider.swift (the sole genre/subgenre
                     authority — see CLAUDE.md). search_tag.py is an ad-hoc single-tag Jamendo
                     search (metadata only) for curating a new blend/cohort addition.
  clap-coreml/      CLAP audio/text encoder export + Core ML conversion for on-device embeddings.
  demucs-coreml/    Demucs stem-separation model export + Core ML conversion.
  starter-expand/   Expands the starter-pack candidate pool ahead of shard generation.
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

Tonearm is the historical codename used by the source project.

Platterhead is free software, licensed under the GNU General Public License v3.0 or later, with an
additional permission under GPLv3 §7 allowing distribution through Apple's App Store — see
[`LICENSE`](LICENSE). Platterhead is a clean-room app inspired by foobar2000's *values* — format
breadth, gapless, zero telemetry, power-user transparency. It shares no code with it.
