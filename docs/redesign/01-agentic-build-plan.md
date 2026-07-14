# Tonearm — Redesign & Agentic Build Plan

> Companion: this plan supersedes the tier design in `docs/opus-pro-unlock/` (specifically
> decisions D5 and D7, and the six-feature Pro tier in `00-overview.md` / `02-pro-unlock.md`).
> The Opus/FLAC/gapless engineering in that folder stands unchanged.

## Context

Tonearm ("Platterhead") is a privacy-first iPhone music player: local files referenced in place, plus stream-only archive.org playback from pasted URLs. The audio engine is genuinely strong — a byte-range caching `AVAssetResourceLoader`, an LRU cache actor, native FLAC, a hand-rolled Ogg→CAF Opus remuxer, near-gapless item swapping. As of `5c80bc5` the Pro tier and iCloud sync are committed.

**The problem this plan solves:** the Pro tier gates *conveniences* (cache size, prefetch depth, folder watch) rather than *capability*, which taxes the user's own disk and — per `docs/opus-pro-unlock/04-tonearm-implementation-plan.md` — takes back features that were previously free. It sits on top of a free tier that loses to foobar2000 (free) on artist browsing, queue editing, and ReplayGain. Meanwhile the highest-revenue feature in the entire category (remote libraries: cloud drives + self-hosted servers) is absent, even though `CachingResourceLoader` + `CacheStore` + `Source.kind` already constitute ~80% of that engine.

### The competitive field

| | Model | Price | Notable |
|---|---|---|---|
| **foobar2000** | Free, no IAP | $0 | Gapless, ReplayGain, UPnP client+server+renderer, Audio Unit DSP, skins. ~148 ratings — tiny reach, cult credibility. |
| **Doppler** | Paid up front | $9 one-time, 7-day trial | Polished, FLAC/ALAC, **CarPlay**, AirPlay 2, Wi-Fi transfer, Merge Albums, year-end Listening Reports. Mac app sold separately. |
| **VOX** | Freemium + subscription | $4.99/mo or **$49.99/yr** | Free = playback + hi-res. Premium = EQ, crossfade, BS2B, Audio Units, cloud locker. |
| **Flacbox** (Everappz) | Freemium + lifetime/sub | Ads in free tier | 120+ formats incl. DSD. **30+ cloud services.** Free capped hard: 10 playlists, 3 clouds, 100 favorites. 1M+ downloads. |
| **Evermusic** (same co.) | Freemium | — | **11M downloads, 4.6★, 18k ratings.** It is a cloud-storage player. |
| **Marvis Pro** | Paid | ~$10 | Smart playlists, Metadata Builder — but it's an Apple Music front-end. |
| **Self-hosted clients** | Mixed | play:Sub paid; Amperfy/Finamp free | Subsonic/Navidrome/Jellyfin/Plex. Symfonium — the best of them — **is Android-only. The iOS lane is open.** |

**Read the ratings column.** foobar2000 — the app whose *values* Tonearm was built to honor — has ~148 ratings. Evermusic, essentially "a player that reads your cloud drives," has 11 million downloads. The volume in this category is not in codec purity. It is in **reach: getting a person's music, wherever it lives, onto their phone.**

### Decisions taken

1. **Privacy invariant restated** — from *"network = archive.org only"* to *"Tonearm never phones home; it talks only to services you explicitly connect."* This unlocks cloud drives, self-hosted servers, scrobbling, and lyrics.
2. **Optimize for maximum revenue.** Broad free tier drives installs and reviews; Pro sells reach.
3. **Ungate cache size, prefetch depth, folder watch, and EQ.** Pro earns its price with capability.
4. **Price:** $9.99 one-time, Family Sharing **on**, no subscription. Staying one-time is a weapon, not a concession — it is the sharpest wedge against VOX ($49.99/yr) and Flacbox (ads).
5. **Nothing unbuilt appears on the paywall.**
6. **CarPlay is built last** — the CarPlay audio entitlement needs Apple's approval, which is out of our control. Apply on day one so the clock runs in the background; document it in the README roadmap as *planned, pending Apple*; keep it off the paywall until it is real.

### Verified current state (fresh pass, working tree clean at `5c80bc5`)

- ✅ **iCloud sync is real** — `Sources/Sync/CloudSyncEngine.swift` (CKSyncEngine, private DB) is wired into `TonearmApp.swift:25,36` and `SettingsView.swift:224`, with pure `SyncGating`/`SyncMerge`/`RecordMapping` behind it. *No longer vapor.*
- ❌ **EQ has no UI.** `EQEngine`/`EQPreset`/`EQAudioTap` are complete; the only reference anywhere in `Sources/Features/` is the paywall's marketing string.
- ❌ **CarPlay is nothing** — one enum case, one paywall row.
- 🐞 `streamOnCellular` is dead: written to `AudioPlayer.swift:56`, never read, no `NWPathMonitor` in the codebase.
- 🐞 `prefetchDepth` defaults to 2; free clamp is 1; free stepper maxes at 1.
- 🐞 "Custom" cache preset button is a no-op (passes `-1`, guarded out).
- 🐞 `familyShareable: false` in `Resources/Tonearm.storekit`.
- 🐞 Name split: bundle/docs say Tonearm, the app displays "Platterhead".
- ❌ No Artist entity (artist is a string on `Album`); `LibraryView` is a flat list; FTS5 indexes track title only.
- ❌ No queue editing; no playlist reorder/rename UI (`renamePlaylist` exists at `LibraryStore.swift:308`, unused).

---

## The new tier line

> **Free — a complete player.** Everything about *your files, on this device.*
> **Pro — reach and mastery.** Your music *wherever it lives*, on *every device you own*, with the tools to master it.

**Free, forever (CI-pinned):** all formats · gapless · 10-band EQ · ReplayGain · crossfade · unlimited cache · any prefetch depth · folder watch · library browse by artist/album/genre · queue and playlist editing · archive.org sources · local import · widgets, Shortcuts, share extension · listening stats · scrobbling · lyrics · zero telemetry · **CarPlay when Apple approves it**.

**Pro — $9.99 one-time:**
1. **Remote Libraries** — Subsonic/Navidrome, Jellyfin, Plex, WebDAV, SMB, Dropbox, Drive, OneDrive, pCloud. Streamed through the same transparent cache, so it goes offline by itself. No download manager, because you don't need one.
2. **iCloud Sync** — library, playlists, favorites, history, artwork, EQ presets.
3. **iPad + Mac** — same purchase.
4. **Pro Audio & Library Tools** — parametric EQ, crossfeed, convolution, bit-perfect output; smart playlists; tag editor; duplicate detection.

Buckets 1–3 are literally "beyond this device." Bucket 4 is the one deliberate exception to *on-device is free*, and it is defensible: advanced, optional, and genuinely expensive to build.

---

## Engineering doctrine for every task below

The repo already has the right instinct — `URLGrammar`, `FileSelectionPolicy`, `ProGating`, `SyncGating`, `SyncMerge`, `ImportRouter`, `StringSimilarity`, `ByteRangeMap`, `PlaybackResilience`, `SpectrogramDetector` are all pure, dependency-free, and unit-tested. **Every task extends that pattern and never deviates from it:**

1. **Logic first, in a pure type.** Decisions, policy, parsing, sorting, diffing, merging, and state transitions live in structs/enums with no SwiftUI, no UIKit, no singletons, no I/O. They take inputs and return values.
2. **A test file per logic type, written in the same task.** Aim high on case count — boundaries, empties, duplicates, malformed input, downgrade paths. If a behavior is worth a sentence in this plan, it is worth an assertion.
3. **Views are thin.** A view may bind, format, and dispatch. It may not decide. If a view contains an `if` that encodes a product rule, that rule belongs in a tested type.
4. **Stores and services are thin too.** `LibraryStore` gets queries; `AudioPlayer` gets mechanism. Policy lives in the pure layer next to them.
5. **One task = one PR = one agentic session.** Each carries its own acceptance criteria and leaves CI green.

---

# TASK 0 — README + CarPlay entitlement

1. Create `README.md` with the project intro and a **Redesign** section stating the free/Pro line above, and a **Roadmap** section listing **CarPlay as planned, pending Apple's entitlement approval**. This is the *only* place CarPlay is promised until it ships.
2. **(Human)** File the CarPlay audio app entitlement request with Apple. Long, unpredictable lead time. Nothing else in this plan waits on it.

---

# PHASE A — Truth & Tier Reset

*Blocks submission. Nothing here is optional. Ends with an app whose paywall tells the truth.*

### A1 · Ship the EQ UI and make EQ free
The engine exists and is unreachable; the paywall sells it. Fix both ends.

- **Logic:** `Sources/Audio/EQ/EQSettings.swift` — pure `EQSettings` value type (`bands: [Float]`, `enabled: Bool`, `activePresetID: String?`) plus `EQSettingsStore` policy: clamp gains to ±12 dB, resolve preset → bands, detect "modified from preset", serialize to/from a `UserDefaults` payload. `EQPreset.swift` already holds the built-ins (Flat / Concert hall / Spoken / 78 rpm) and user-preset storage — extend, don't replace.
- **Remove gates:** delete `guard ProFeature.isEnabled(.eq)` at `Sources/Audio/AudioPlayer.swift:295` and `:314`.
- **Tests:** `Tests/EQSettingsTests.swift` — clamping at both rails, preset resolution, preset→modified→re-select round trip, unknown preset ID falls back to Flat, serialization round trip, bypass produces exactly-flat bands. The existing bit-transparency null test in `Tests/EQTests.swift` must stay green with the gate gone.
- **View:** `Sources/Features/Settings/EQView.swift` — 10 vertical sliders, preset picker, bypass toggle, "Save preset". Binds straight to `EQSettings`; **no product logic in the view.** Entry points: a row in `SettingsView`, a button in `NowPlayingView`.
- **Accept:** a free user can open the EQ, move a band, and hear it.

### A2 · Rewrite the tier contract
- **Logic:** `Sources/Pro/ProFeature.swift` → `enum ProFeature { case remoteLibraries, icloudSync, proAudioTools, smartPlaylists, tagEditor }`. Delete `cachePresets`, `prefetchDepth`, `folderWatch`, `eq`, `carplay`.
- **Logic:** `Sources/Pro/ProGating.swift` — delete `freeMaxCacheBytes`, `freeMaxPrefetchDepth`, `isCachePresetLocked`, `allowedCacheLimit`, `clampedPrefetchDepth`, `isPrefetchDepthLocked`. What remains is the entitlement read.
- **Tests:** rewrite `Tests/FreeTierRegistryTests.swift` to pin the **expanded free list** — formats, gapless, EQ, ReplayGain, crossfade, cache size, prefetch depth, folder watch, CarPlay, library browse, queue editing, IA sources, local import, privacy — none of which may ever be a `ProFeature`. Assert `ProFeature.allCases.count == 5` and the exact case set. **Delete** `Tests/CachePresetGateTests.swift` and `Tests/PrefetchDepthTests.swift`.
- **Accept:** re-gating any free feature fails CI loudly.

### A3 · Ungate the conveniences, fix the adjacent bugs
- Remove the lock/paywall branches in `SettingsView.swift:111` (cache presets) and `:159-181` (prefetch stepper). All four presets free; add a real **Custom** entry (numeric; floor 100 MB, ceiling 80% of free disk — the ceiling rule is in `TONEARM-requirements-design-v2.md` FR-3.2 and was never shipped).
- Fix the **no-op Custom button** (`presetButton` guards out `-1`).
- Fix `AppState.swift:39` (`prefetchDepth` default `2`); free stepper range becomes `0...5`; drop `ProGating.clampedPrefetchDepth` at `AppState.swift:104`.
- Remove folder-watch gates: `Sources/Features/Ingest/AddFolderSheet.swift:81-96` and `FolderWatchService.swift:25,59`.
- **Logic:** `Sources/Audio/CacheLimitPolicy.swift` — pure: validate a custom limit against free disk; return a clamped value plus a reason string.
- **Tests:** `Tests/CacheLimitPolicyTests.swift` — below floor, above ceiling, exactly at bounds, zero free disk, absurd inputs.
- **Accept:** a free user sets a 10 GB cache and prefetch depth 5. `Tests/FolderWatchTests.swift` passes with no entitlement.

### A4 · Make "Stream on cellular" actually work *(real-money bug)*
Today the setting is stored, pushed to `AudioPlayer.streamOnCellular` (`:56`), and **never read**. A user who turns it off still burns cellular data.

- **Logic:** `Sources/Audio/NetworkPolicy.swift` — pure: `decide(assetKind:isCached:pathIsExpensive:streamOnCellular:) -> PlaybackDecision` returning `.play`, `.skipWiFiOnly`, or `.playFromCache`. Local and fully-cached assets always play.
- **Mechanism:** an `NWPathMonitor` wrapper feeding `pathIsExpensive` into `AudioPlayer`; enforce on play **and** on prefetch (`AudioPlayer.swift:359-360`).
- **Tests:** `Tests/NetworkPolicyTests.swift` — the full truth table: {local, cached remote, uncached remote} × {wifi, cellular} × {toggle on, off}. Assert cached tracks *always* play regardless (the FR-2.7 contract), and that queue advance skips `.skipWiFiOnly` rows.
- **View:** a "Wi-Fi only" row state and a skip toast.
- **Accept:** on a real device on cellular with the toggle off, an uncached remote track refuses to play and the queue skips it.

### A5 · Honest paywall, new SKU, real entry point
- `Resources/Tonearm.storekit`: `displayPrice` → **9.99**, `familyShareable` → **true**, description rewritten to the four Pro buckets.
- `Sources/Features/Settings/ProPaywallView.swift`: four rows — Remote Libraries, iCloud Sync, iPad + Mac, Pro Audio & Library Tools. **Delete the CarPlay row and the `comingSoon` flag entirely.** Keep "Restore Purchase" and the "build Pro from source" GPL link.
- `ProStore.displayPrice` hardcodes a `"$9.99"` fallback — update it.
- **Add a Pro entry point to Settings' About card.** Today the paywall is reachable *only* by tapping a locked control; once A3 removes the locks there is **no path to the paywall or to Restore Purchase at all.** This is a launch blocker *created by* A3 — ship A3 and A5 together or ship neither.
- **Tests:** rewrite `Tests/ProPaywallTests.swift` — four rows, exact titles, **no feature may carry a `comingSoon` flag**, and every advertised feature maps to a `ProFeature` case with a reachable entry point.
- **Accept:** sandbox purchase → all five Pro features unlock together; restore works; Pro survives airplane mode; revoke clears all five.

### A6 · One name
Pick Tonearm or Platterhead. Unify the bundle display name, `PrivacyView` copy ("Platterhead collects nothing…"), the About card ("Platterhead 0.1"), `IAClient`'s User-Agent, and the README. Add a CI grep asserting the loser's string appears zero times.

---

# PHASE B — Library Foundations

*The growth phase. Free tier reaches parity, then passes foobar2000. This buys installs, ratings, and the top of the funnel.*

### B1 · Artist / album-artist / genre / year in the schema
- `Sources/Data/Schema.swift` **migration v8**: `artist` table (id, name, sortName, syncID); `album.artistId`, `album.albumArtist`, `album.genre`; `track.genre`, `track.composer`, `track.artistId`. Backfill artists from the existing `album.artist` strings inside the migration.
- `Sources/Domain/Entities.swift`: `Artist` struct; new fields on `Album`/`Track`.
- **Logic:** `Sources/Domain/ArtistNamePolicy.swift` — pure: normalize and sort-key an artist name ("The Beatles" → sort "Beatles"), split multi-artist strings ("A feat. B", "A & B", "A; B"), decide album-artist vs track-artist, detect "Various Artists".
- **Tests:** `Tests/ArtistNamePolicyTests.swift` — leading articles across languages, feat./with/&/;/, separators, unicode and diacritics, empty and whitespace-only, "Various Artists" variants. `Tests/SchemaMigrationV8Tests.swift` — migrate a v7 DB with known albums; assert artists are created, deduped case-insensitively, and no track is orphaned.
- **Accept:** existing libraries migrate with zero data loss.

### B2 · Ingest populates the new fields
- `Sources/Features/Ingest/IngestService.swift` — read `AVAsset` album-artist, genre, composer, disc number, sample rate, bit depth (the columns exist; ingest leaves them nil today). `Sources/IA/ItemResolver.swift` — map IA item metadata to the same fields.
- **Logic:** `Sources/Domain/MetadataNormalizer.swift` — pure: an `AVMetadataItem` key/value bag → a normalized `TrackMetadata`, with the existing filename-parse fallback. Reuse `Sources/Art/FilenameQueryParser.swift`.
- **Tests:** `Tests/MetadataNormalizerTests.swift` — ID3 vs iTunes vs common keys, conflicting keys, `"1/12"` track-number forms, missing everything (filename fallback), garbage bytes.

### B3 · Library browse UI
- **Logic:** `Sources/Domain/LibraryBrowse.swift` — pure: given `[TrackRow]`, produce grouped and sorted sections for Artists / Albums / Songs / Genres, including the A–Z/# index-title computation.
- `LibraryStore`: `allArtists()`, `albums(forArtist:)`, `tracks(forArtist:)`, `allGenres()`.
- **Tests:** `Tests/LibraryBrowseTests.swift` — grouping, sort stability, numeric/symbol/unicode index bucketing, empty library, one artist with 1000 albums, compilation albums grouping under album-artist.
- **View:** rebuild `Sources/Features/Library/LibraryView.swift` as a segmented Artists / Albums / Songs / Genres browser with an A–Z index rail. Thin.

### B4 · Full-text search across the library
FTS5 currently indexes **track title only** (`Sources/Data/LibraryStore.swift:261`).
- Migration v9: rebuild `track_fts` over title + artist + album + genre + filename.
- **Logic:** `Sources/Data/SearchQueryBuilder.swift` — pure: a user string → a sanitized FTS5 `MATCH` expression (prefix matching, quoting, operator escaping, empty/`*`/`"` handling).
- **Tests:** `Tests/SearchQueryBuilderTests.swift` — injection attempts, unbalanced quotes, FTS operators as literals, CJK, empty, whitespace-only, very long queries.

### B5 · Queue editing
- **Logic:** `Sources/Audio/QueueEditor.swift` — pure: `move(from:to:)`, `remove(at:)`, `insertNext(_:)`, `append(_:)` over a `(queue, currentIndex)` pair, returning a new pair. **The current index must track correctly through every operation** — that is the entire reason this is a pure type.
- **Tests:** `Tests/QueueEditorTests.swift` — move above/below/onto the current index; remove the current track; remove the last track; insert-next into an empty queue; interaction with the shuffle-restore state in `AudioPlayer`. The existing `Tests/ShuffleRepeatTests.swift` must stay green.
- **View:** `Sources/Features/NowPlaying/UpNextView.swift` — the full queue (not just 5), drag to reorder, swipe to remove. "Play Next" / "Add to Queue" in the track context menu (`Sources/Features/Components.swift`).

### B6 · Playlist editing
- `LibraryStore`: `reorderPlaylist(id:from:to:)`, `removeFromPlaylist(...)`; `renamePlaylist` (line 308) already exists and is unused — wire it up.
- **Logic:** `Sources/Domain/PlaylistEditor.swift` — pure: position renumbering after a move or a removal, guaranteeing contiguity and stability.
- **Tests:** `Tests/PlaylistEditorTests.swift` — reorder to head/tail, remove from the middle, duplicate track IDs in one playlist, empty playlist, positions contiguous after every op. Plus a `LibraryStore` round-trip test through GRDB.
- **View:** `EditButton` reorder + swipe-delete + rename in `PlaylistsView` / `PlaylistDetailView`.

### B7 · Listening stats
- **Logic:** `Sources/Domain/ListeningStats.swift` — pure: `[PlayEvent]` + `[TrackRow]` → top artists/albums/tracks, total time, streaks, per-period rollups. The `play_history` table already exists.
- **Tests:** `Tests/ListeningStatsTests.swift` — empty history, deterministic tie-breaking, DST and timezone boundaries, a year boundary, a single event, deleted tracks referenced by old events.
- **View:** a stats card on `ListenView`; a shareable year-in-review. Doppler ships this and it is cheap retention and virality.

---

# PHASE C — Playback Depth

### C1 · ReplayGain *(free — foobar2000 has it)*
- **Logic:** `Sources/Audio/ReplayGain.swift` — pure: parse `REPLAYGAIN_TRACK_GAIN` / `ALBUM_GAIN` / peak tags (Vorbis comments, ID3 TXXX, iTunes `----`); compute the applied linear gain given mode (off/track/album), preamp, and clipping prevention from the peak.
- **Storage:** migration v10 adds `track.rgTrackGain`, `rgAlbumGain`, `rgTrackPeak`, `rgAlbumPeak`.
- **Mechanism:** apply in the gain stage of `Sources/Audio/EQ/EQAudioTap.swift` — it already owns the audio path, so no new tap is needed.
- **Tests:** `Tests/ReplayGainTests.swift` — all three tag dialects, `"-6.54 dB"` vs `"-6.54"` forms, missing peak, clipping prevention engaging, album mode falling back to track gain, preamp arithmetic, and no-tags = **exactly** unity gain (bit-transparent).

### C2 · Crossfade *(free — VOX charges for this)*
- **Logic:** `Sources/Audio/CrossfadeCurve.swift` — pure: given (position, duration, fade seconds, curve), return the two gain coefficients. Equal-power and linear curves.
- **Tests:** `Tests/CrossfadeCurveTests.swift` — sums to constant power, endpoints exactly 0/1, fade longer than the track, zero-length fade, and **gapless-album detection suppresses crossfade** (the audiophile-correctness case competitors get wrong).
- **Mechanism:** extend the existing `preloadNextItem()` swap in `AudioPlayer`.

### C3 · Sample-accurate gapless *(spike alone — the riskiest item in this plan)*
`docs/opus-pro-unlock/decisions.md` D4 defers true gapless to an `AVAudioEngine` path. With EQ, ReplayGain, and crossfade now all living in the tap, the case for the engine rewrite is much stronger — but it touches the proven `AVPlayer` + resource-loader stack. **Scope it as its own spike before committing. Never bundle it with anything else.**

---

# PHASE D — Platform Surfaces *(free; distribution and retention)*

### D1 · Share extension + URL scheme
FR-2.1 promises share-sheet ingestion of IA URLs; it was never built. New extension target in `project.yml`; register `CFBundleURLTypes`. Reuse `Sources/IA/URLGrammar.swift` **unchanged** — it is already a pure, exhaustively-tested parser, which is exactly why this task is cheap.
- **Tests:** extend `Tests/URLGrammarTests.swift` with share-sheet payload shapes (text vs URL vs attributed).

### D2 · Widgets + Live Activity + Control Center
Now Playing widget, recently-played widget, Lock Screen controls.
- **Logic:** a pure `WidgetSnapshot` builder from `AppState`, testable without WidgetKit.
- **Tests:** `Tests/WidgetSnapshotTests.swift` — nothing playing, artwork missing, very long titles, stale timeline entries.

### D3 · Siri / App Intents / Shortcuts
An `AppIntent` set: play playlist, play artist, resume, sleep timer, add source from URL.
- **Logic:** a pure `IntentResolver` mapping intent parameters → a queue command.
- **Tests:** `Tests/IntentResolverTests.swift` — ambiguous names, no match, multiple matches, empty library.

---

# PHASE E — Pro = Remote Libraries *(the money)*

*The only phase that materially changes revenue. Everything before it is a prerequisite. `CachingResourceLoader` + `CacheStore` + `Source.kind` + `Asset.kind(.remote)` already **are** the engine — what is missing is providers, not architecture.*

### E1 · Generalize the source layer
- **Logic:** `Sources/Remote/RemoteLibraryProvider.swift` — a protocol: `browse(path:) -> [RemoteNode]`, `resolve(node:) -> ResolvedAsset` (an authenticated byte-range URL + headers), `refresh()`. Extract the shape from `Sources/IA/SourceService.swift`; **the IA resolver becomes the first conformer**, which is what proves the abstraction.
- Extend `SourceKind` with the new provider cases (migration v11). Add `Sources/Remote/CredentialStore.swift` — **Keychain only, never `UserDefaults`.**
- **Logic:** `Sources/Remote/RemotePathPolicy.swift` — pure: path normalization, traversal rejection, audio-extension filtering, page-cap enforcement (reuse the 500-member cap discipline already in `CollectionResolver`).
- **Tests:** `Tests/RemoteLibraryProviderTests.swift` (conformance via a fake), `Tests/RemotePathPolicyTests.swift` (`../` traversal, absolute paths, URL-encoded separators, empty segments, non-audio filtering), `Tests/CredentialStoreTests.swift` (round trip, overwrite, delete, missing).
- **Accept — this is the regression gate for the whole phase:** the IA source path is refactored onto the protocol with **zero behavior change**. `Tests/ListResolverTests.swift`, `ListResolverScrapeTests`, `URLGrammarTests`, `FileSelectionPolicyTests`, and `StreamingCacheTests` all stay green **untouched**.

### E2 · Subsonic / Navidrome provider *(ship first)*
One API, a large and passionate audience, **no third-party SDK**, and Symfonium — the best client on Android — has no iOS version. The lane is open.
- **Logic:** `Sources/Remote/Providers/SubsonicProvider.swift` plus a pure `SubsonicAPI` request builder and response decoder (`ping`, `getArtists`, `getAlbum`, `getIndexes`, `stream`), including the salted-token auth scheme.
- **Tests:** `Tests/SubsonicAPITests.swift` — auth-token derivation against known vectors, URL construction, XML **and** JSON response shapes, error codes (auth failed, not found, trial expired), empty library, Navidrome-vs-Subsonic dialect differences, malformed responses. **Fixture-driven; no live network in tests.**
- **View:** an "Add Server" sheet (URL, user, password); the browse tree renders through the existing source detail views.
- **Accept:** point at a live Navidrome instance — browse, play through `tonearm-cache://`, cache fills, offline replay works, credentials live in the Keychain.

### E3 · WebDAV + SMB
Standards-based, no SDK; satisfies the purist wing and keeps `NFR-7`'s dependency budget intact.
- **Logic:** a pure WebDAV `PROPFIND` XML parser and a pure directory-listing model.
- **Tests:** `Tests/WebDAVParserTests.swift` — real-world `PROPFIND` bodies from Nextcloud/Apache/rclone, namespace variance, escaped names, deep nesting, empty collections.

### E4 · Jellyfin, then Plex
Same protocol, same discipline: a pure API builder + decoder + fixture tests, then a thin provider.

### E5 · Cloud drives — Dropbox, Google Drive, OneDrive, pCloud
The volume play — literally Evermusic's 11M-download business. **Accept the OAuth SDK cost here and nowhere else.** Sequenced last in the phase deliberately: E2–E4 ship with zero third-party binaries, so the privacy story is fully intact *and already earning* before any SDK lands.
- **Also required:** update the App Store privacy nutrition label; relax the ATS pin in `Sources/App/Info.plist` (which currently allowlists archive.org / itunes / mzstatic only) to user-supplied hosts — narrowly, and documented.
- **Logic:** a pure `OAuthTokenState` machine (valid / expiring / refresh-required / revoked).
- **Tests:** clock skew, refresh races, revocation mid-request, offline.

### E6 · "Pin" — whole-library offline
The LRU + prefetch machinery already does this. Add a pure `PinPolicy` (what to keep, what to evict, interaction with the cache ceiling) and surface it as *state*, never as a download queue — consistent with the existing FR-3.1 product invariant.
- **Tests:** `Tests/PinPolicyTests.swift` — pin exceeds cache limit, unpin, pinned content is never LRU-evicted, pin during a Pro downgrade.

---

# PHASE F — Pro Tools

### F1 · Smart playlists
- **Logic:** `Sources/Domain/SmartPlaylist.swift` — a pure rule AST (field, operator, value; AND/OR groups; limit; sort), an evaluator over `[TrackRow]`, and a compiler to a GRDB query for large libraries.
- **Tests:** `Tests/SmartPlaylistTests.swift` — heavy. Every field × every operator; nested groups; empty rule set; contradictory rules; limit + sort interaction; **nil field values** (a huge source of bugs); 10k-track evaluation performance. **The AST evaluator and the SQL compiler must agree on every fixture — assert that explicitly.**

### F2 · Tag editor
- **Logic:** `Sources/Domain/TagEdit.swift` — pure: a diff of proposed changes, validation, and a bulk-apply plan (including find/replace and number-from-filename).
- **Tests:** `Tests/TagEditTests.swift` — single and bulk edits, conflicting values across a selection, read-only files, the undo plan, no-op diffs.
- Write-back via `AVAssetExportSession` / direct tag write, **local files only**; remote sources are read-only and the UI must say so.

### F3 · Parametric EQ, crossfeed, convolution, bit-perfect output
Extends `EQEngine`.
- **Logic:** pure biquad coefficient computation per filter type (peaking, shelf, HPF/LPF, notch) with Q and frequency; a crossfeed matrix; an IR convolution setup.
- **Tests:** `Tests/BiquadTests.swift` — coefficient vectors against known references, stability at extreme Q and at Nyquist, unity at 0 dB gain, cascade transparency.

### F4 · Duplicate detection
FR-1.4 — specced and never built.
- **Logic:** pure — `(size, hash of first + last 128 KB)` → duplicate groups.
- **Tests:** identical files, same size but different content, files smaller than 256 KB, empty files, a 5000-file library.

---

# PHASE G — iPad + Mac

Same purchase, universal. `project.yml` is `TARGETED_DEVICE_FAMILY = "1"` and portrait-only today. Directly answers Doppler (which sells its Mac app separately) and justifies the $9.99.

Because Phases B–F put all real logic in pure types, this phase should be **view work only** — and if it isn't, that is the signal that a rule leaked into a view.

---

# PHASE H — Delight *(free)*

### H1 · Synced lyrics via LRCLIB
- **Logic:** a pure LRC parser (timestamped lines, multiple timestamps per line, malformed lines, offset tags) and a pure "current line at time *t*" selector.
- **Tests:** heavy on malformed real-world LRC.
- Strictly opt-in, per the restated privacy line.

### H2 · Scrobbling — Last.fm / ListenBrainz
- **Logic:** a pure `ScrobblePolicy` — the 50%-or-4-minutes rule, minimum track length, dedupe, and an offline queue with replay.
- **Tests:** the boundary at exactly 50%, seeking backwards, pausing, repeat-one, offline-queue flush ordering, duplicate suppression.
- Opt-in, with a plain-language privacy statement.

---

# PHASE Z — CarPlay *(last; blocked on Apple, not on us)*

Sequenced last **by decision**: the CarPlay audio entitlement is Apple's to grant. The application goes in at Task 0, so it is likely approved by the time we arrive.

- A CarPlay scene delegate + `CPNowPlayingTemplate` + browsable list templates over the existing `AppState` / `AudioPlayer` queue. The now-playing and remote-command plumbing (`AudioPlayer.swift:502-545`) already exists, so this is a **UI-surface build, not an engine build**.
- **Logic:** `Sources/CarPlay/CarPlayTree.swift` — pure: library → `CPListTemplate` section model, with Apple's item-count limits enforced.
- **Tests:** `Tests/CarPlayTreeTests.swift` — over-limit truncation, empty library, deep nesting.
- **CarPlay ships free**, and only *then* enters marketing. Until Apple approves, it lives in exactly one place: the README roadmap.
- If approval lands early it can move up. If it never lands, **nothing else in this plan is affected** — which is the entire point of putting it here.

---

## Verification

- **Per task:** `xcodebuild test` green; the new pure-logic test file exists and covers the boundary cases named in that task.
- **Tier contract:** `Tests/FreeTierRegistryTests.swift` is the standing guard — it must fail the build if a free feature is ever re-gated.
- **Paywall honesty:** `Tests/ProPaywallTests.swift` asserts every advertised feature has a reachable entry point and that no `comingSoon` flag exists.
- **StoreKit:** sandbox against `Resources/Tonearm.storekit` — purchase, restore, revoke; all five Pro features move together; Pro survives airplane mode.
- **Phase E regression gate:** the IA test suite passes **untouched** after the provider refactor.
- **End-to-end:** drive the app in the simulator at the end of each phase, not just the test suite. Cellular enforcement (A4) and Navidrome playback (E2) can only be verified on a real device / live server.

## Risks

- **Phase E is the only phase that makes money.** A, B, C, D are prerequisites and enablers. Do not let them expand indefinitely.
- **The privacy repositioning is load-bearing.** `NFR-7` ("dependency budget: GRDB and nothing else") is violated by E5's OAuth SDKs. Sequencing E2–E4 first means revenue starts with the purist story fully intact.
- **Free-tier expansion is a one-way door.** Once cache size, prefetch, folder watch, EQ, and ReplayGain are free, they can never be re-gated. That is the intent, and `FreeTierRegistryTests` enforces it.
- **A3 creates a launch blocker that A5 must close:** removing the locks removes the only path to the paywall. Ship them together or ship neither.
- **C3 (true gapless) is the riskiest item here.** It touches the proven AVPlayer + resource-loader stack. Spike it alone.
- **CarPlay is the one dependency we do not control.** Applying on day one and building it last fully absorbs that risk. The failure mode to avoid is the current one — *selling* CarPlay on a paywall before Apple has said yes.
