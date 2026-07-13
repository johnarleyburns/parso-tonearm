# Tonearm — Requirements & Design for Agentic Implementation (v2)

**Repo:** `parso-tonearm-ios-app`
**Status:** Handoff-ready pending J's review
**Date:** 2026-07-05
**Supersedes:** PLAN-phono-v1.md (v1 is retained for the licensing decision record; the
download subsystem described there is **deleted** in v2)
**Companion:** `tonearm-mockups-v2.html` (authoritative for visual intent)

---

## 0. Decision records

### 0.1 Not a foobar2000 fork (carried from v1)
foobar2000's core (desktop and mobile) is closed source; only the plugin SDK is
BSD-3. The iOS app ships under a proprietary "foobar2000 mobile license" with no
published source. Tonearm is a clean-room app inspired by fb2k's *values* (format
breadth, gapless, zero telemetry, power-user transparency) — zero code, zero trade
dress, zero use of the strings "foobar"/"fb2k" anywhere (CI-enforced, §9).

### 0.2 Name: **Tonearm**
- App Store search (2026-07): no existing app named "Tonearm." Nearest neighbors are
  vinyl-simulation audio plugins (different products).
- Known same-word uses: "The Tonearm" (online music journal), "Tone Arm" (UK radio
  promotions company). Different goods/services classes; low confusion risk for a
  software music player, but **P7 gate:** manual App Store availability check +
  USPTO TESS search before submission. Fallback candidates, in order: **Stylus Deck**,
  **Shellac** (conflicts with the band; avoid unless legal
  review says otherwise).
- Fit: the tonearm is the component that plays the record you chose — matches the
  product thesis "you bring the records," and the brass/phonograph visual identity.
- Bundle ID: `guru.parso.tonearm`. Marketing line: "You bring the records."

### 0.3 v2 scope changes (this revision)
1. **Downloads removed.** No download buttons, no download manager, no Downloads tab,
   no per-source auto-download. IA audio is stream-only.
2. **Transparent playback cache added.** Streamed bytes are retained on disk in an
   LRU cache, limit user-configurable, **default 500 MB**. A generous limit makes
   played music effectively offline with zero user action. Cache is visible as
   *state*, never as an *action*.
3. **IA public playlists/lists are first-class**, alongside items, favorites pages,
   and collections.
4. **Local ingestion is explicit in the UI:** "Add Folder as Playlist" and
   "Add Audio Files" flows, both reference-in-place.

---

## 1. Product definition

Tonearm is a privacy-first, local-first iOS music player for people who own files,
with stream-only playback of archive.org audio that the user adds by URL.

**Pillars**
1. Local library first — your files, referenced in place, indexed properly.
2. archive.org as a source, not a service — pasted URLs only; streaming only.
3. **No IA search in-app, ever** (hard invariant; see §9). The only IA entry point
   is a URL the user supplies. Mechanical member-enumeration of a user-added list or
   collection is resolution, not search, and must never be exposed as a query UI.
4. No accounts, no server, no ads, no telemetry. Network contact is limited to
   archive.org hosts for sources the user added, plus Apple's iTunes Search API
   (opt-out, default on) solely to look up missing album/track cover art.
5. Modern Apple HIG with Liquid Glass chrome; opaque, legible content layer.

**Non-goals (v2):** IA search/browse/discovery (permanent) · downloads/offline
management UI (permanent — the cache is the only persistence for IA audio) · EQ/DSP ·
UPnP/DLNA · CloudKit sync · iPad-specific layout · IA login or restricted items ·
Android.

**Monetization:** none or tip jar (Lorewave posture). Decide at P7; no architectural
impact.

---

## 2. Functional requirements

Numbered for traceability; agents must reference FR numbers in PR descriptions.

### FR-1 Local library
- **FR-1.1** Import individual audio files via `UIDocumentPicker` (multiple select).
  Files are referenced in place with security-scoped bookmarks; never copied unless
  the source is ephemeral (e.g., Inbox/share-sheet delivery → copy into
  Application Support, flagged `managedCopy`).
- **FR-1.2** "Add Folder as Playlist": pick a folder; enumerate audio files
  (recursively if "Include subfolders" is on); create a Playlist whose order is the
  folder's lexical order when "Keep folder order" is on, otherwise
  discNo/trackNo/title sort. Subfolders become playlist section headers when
  included. Optional "Watch folder": rescan on app launch, diffing by URL + mtime +
  size; additions appended, deletions tombstoned (row shows "file missing").
- **FR-1.3** Metadata extraction via AVFoundation (`AVAsset` common/ID3/iTunes
  keys) with filename-parse fallback; embedded artwork extracted to an artwork
  store (downscaled ≤1024px JPEG).
- **FR-1.4** Duplicate detection by (size, partial content hash of first+last 128 KB).
  Duplicates are linked, not re-imported.
- **FR-1.5** Local search (FTS5) over title/album/artist/filename. This searches the
  user's library only.
- **FR-1.6** Formats: everything AVFoundation decodes — MP3, AAC/ALAC (m4a), FLAC,
  WAV/AIFF, Opus-in-CAF. Files AVFoundation rejects are listed with an
  "unsupported format" row state, never silently dropped.

### FR-2 archive.org sources (stream-only)
- **FR-2.1 URL grammar.** The Add Source sheet accepts, via paste or iOS share
  sheet, exactly these shapes (trailing junk/query params tolerated):
  - `archive.org/details/{identifier}` → **Item**
  - `archive.org/details/{identifier}/{filename}` → Item, pre-scroll to that track
  - `archive.org/details/@{screenname}/lists/{listId}/{slug?}` → **Public list**
  - `archive.org/details/fav-{screenname}` → **Favorites page** (a collection)
  - `archive.org/details/{identifier}` where `mediatype == collection` → **Collection**
  - `archive.org/embed/{identifier}...` → normalize to Item
  Anything else → inline error naming the reason ("This is a Wayback Machine URL",
  "This item is video", "Item not found").
- **FR-2.2 Item resolution.** `GET https://archive.org/metadata/{identifier}`.
  Accept `mediatype` `audio` or `etree`. Map `files[]` → Tracks per the file-selection
  policy (FR-2.5). Item-level metadata → Album fields. Persist `licenseurl`/rights
  and display them in preview and detail.
- **FR-2.3 List resolution.** Lists are the least-stable IA surface; implement as a
  `ListResolver` strategy chain with contract tests against live fixtures:
  1. The JSON endpoint used by the archive.org web app for list members
     (discover exact shape in the P4 spike; the details page loads members via an
     XHR that returns member identifiers).
  2. Fallback: fetch the list details page HTML and extract `/details/{id}` member
     links (bounded, deterministic parse; no JS execution).
  Members resolve lazily as Items (FR-2.2). "Follow list updates" re-resolves on
  pull-to-refresh only — never in the background.
- **FR-2.4 Collection & favorites resolution.** Enumerate via the scrape API
  (`/services/search/v1/scrape?q=collection:{id}&fields=identifier,title,mediatype`),
  filtered to audio mediatypes, paged, hard-capped at **500 members** with the cap
  stated in the preview ("This collection has 3,214 items; Tonearm adds the first
  500 — add sub-collections or lists for the rest"). Members resolve lazily.
- **FR-2.5 File-selection policy** (within an item's `files[]`):
  - Preference: FLAC original → MP3 VBR derivative → other AVFoundation-playable.
    Setting "Prefer FLAC over MP3" (default on) flips the first two.
  - Skip: non-audio, spectrograms, samples (`_sample`), derivatives duplicating an
    already-selected original (match on the `original` field).
  - Do not trust mime alone: IA `.ogg` may report `application/ogg`
    (verified in parso-pdaudio) — decide by `format` field + extension.
  - Opus-only items: tracks marked unsupported with reason (no FFmpeg in v2).
- **FR-2.6 Streaming.** Playback via `https://archive.org/download/{id}/{file}`
  (redirects to datanodes; range requests). All playback of remote assets flows
  through the caching layer (FR-3). User-Agent: `Tonearm/{v} (parso.guru)`.
  Etiquette: ≤2 concurrent resolutions, exponential backoff on 429/5xx, metadata
  JSON cached with `lastResolvedAt`, refresh only on user pull.
- **FR-2.7** "Stream on cellular" toggle (default **on**; cached tracks always play
  regardless). When off and on cellular, uncached tracks show a "Wi-Fi only" row
  state and are skipped by queue advance with a toast.

### FR-3 Transparent playback cache (replaces downloads)
- **FR-3.1 Contract.** Every byte streamed for playback is written to a per-track
  cache file. When a track's bytes are complete, the track is *cached*: it plays
  offline, instantly, until evicted. The user never initiates, cancels, or manages
  per-track cache state. There is no "download" concept anywhere in UI, strings,
  or code identifiers (`grep -ri download Sources/ → 0 hits`, §9).
- **FR-3.2 Limit.** User-configurable cap: presets 200 MB / **500 MB (default)** /
  2 GB / 10 GB / Custom (numeric entry, floor 100 MB, ceiling 80% of free disk at
  time of setting). Enforced by the cache actor after each write batch.
- **FR-3.3 Eviction.** LRU by `lastAccessedAt` (playback touch), complete files and
  stale partials alike; never evict the currently playing or prefetching track.
  Partial segments older than 7 days are garbage-collected regardless of LRU.
  Lowering the limit evicts immediately to fit.
- **FR-3.4 Mechanism.** `CachingResourceLoader`: an `AVAssetResourceLoaderDelegate`
  behind a custom URL scheme (`tonearm-cache://`), backed by a sparse data file +
  persisted range map per asset. Serves cached ranges from disk, fetches misses via
  a single shared `URLSession` (which also fills the cache), handles
  contentInformation (type, length, byte-range support). When the range map covers
  the full length, promote to *complete* and mark `cachedFully`. Known pitfalls to
  handle: correct UTI for FLAC/MP3, 302-to-datanode redirects resolved *outside*
  the loader (pre-resolve final URL per session), servers omitting Content-Length.
  **Build this inside `parso-audio-engine`** as a new `CachingAssetProvider` module —
  Lorewave and Acalum are future consumers; do not implement it app-side.
- **FR-3.5 Prefetch.** While playing, warm the next N queue tracks (setting,
  default 2) through the same cache path, network-idle-priority. Prefetch respects
  the cellular toggle and the cap.
- **FR-3.6 Surfacing.** Cache state appears only as: row glyph (○ none / ◔ filling /
  ● cached), "cached" word in mini-player subtitle, cached-bytes layer in the
  Now Playing scrubber, cache % in the codec chip, and the Settings cache card
  (usage bar, count, limit picker, Clear Cache with byte count). Nothing else.
- **FR-3.7 Airplane-mode behavior.** Offline: cached tracks play; uncached remote
  tracks show dimmed rows with an offline glyph; queue advance skips them silently.
  Local files unaffected.

### FR-4 Playlists
- **FR-4.1** Manual playlists: create, rename, reorder (drag), add from any track
  context menu, delete.
- **FR-4.2** Folder playlists (FR-1.2) are playlists with a `folderBookmark`; they
  support the watch/rescan behavior and show a folder glyph.
- **FR-4.3** IA lists imported via FR-2.3 appear under **Sources**, not Playlists
  (provenance stays honest); their track lists behave identically otherwise.
- **FR-4.4** Playlists may freely mix local and IA tracks.

### FR-5 Playback
- **FR-5.1** Queue with up-next editing; gapless for back-to-back tracks (engine
  requirement); shuffle; repeat off/all/one.
- **FR-5.2** Background audio, interruption handling, route changes,
  `MPNowPlayingInfoCenter` + remote commands, AirPlay.
- **FR-5.3** Now Playing shows codec, sample rate, and cache % (fb2k transparency
  tell). Scrubbing into uncached regions issues a range fetch through the cache.

### FR-6 Settings
Streaming cache card (FR-3.6) · Stream on cellular · Prefer FLAC over MP3 ·
Prefetch depth · Clear Cache · Privacy screen (static text: no accounts, no ads,
no analytics, network = archive.org only) · Licenses (GPLv3 + third-party) · About.

## 2b. Non-functional requirements
- **NFR-1** Cold launch to interactive Library < 800 ms on iPhone 13 with a
  10k-track library.
- **NFR-2** Import throughput ≥ 10 files/s for metadata extraction (batched, off-main).
- **NFR-3** Cache bookkeeping adds < 3% CPU overhead during playback (measure in P5).
- **NFR-4** Memory ceiling 250 MB during 1k-item collection resolution (lazy pages).
- **NFR-5** All list/library screens 60 fps on iPhone 12; artwork decoded off-main.
- **NFR-6** Accessibility: full VoiceOver labels (cache glyphs get spoken values:
  "cached", "caching, 62 percent", "not cached"), Dynamic Type through XXL, Reduce
  Transparency swaps glass for opaque fills, Reduce Motion disables dock spring.
- **NFR-7** Zero third-party analytics/network SDKs. Dependency budget: GRDB,
  parso-audio-engine, and nothing else without a decision record.

---

## 3. Architecture

```
TonearmApp (SwiftUI, iOS 18 floor, Liquid Glass on iOS 26 via GlassFeature flag)
 ├─ Features/            Library, Playlists, Sources, Settings, NowPlaying, Ingest
 ├─ Domain/              entities + use-cases (no UIKit/SwiftUI imports)
 ├─ Data/
 │   ├─ LibraryStore     GRDB (WAL) + FTS5; single writer actor
 │   ├─ ArtworkStore     file-backed, LRU-trimmed
 │   └─ Bookmarks        security-scoped bookmark vault
 ├─ IA/  (extract as ParsoIAKit SPM package during P4)
 │   ├─ URLGrammar       FR-2.1 parser (pure, unit-tested exhaustively)
 │   ├─ ItemResolver     metadata endpoint client (from Lorewave)
 │   ├─ ListResolver     strategy chain per FR-2.3
 │   └─ CollectionResolver  scrape API, paging, cap
 └─ parso-audio-engine (SPM)
     ├─ existing: player, queue, now-playing bridge
     └─ NEW: CachingAssetProvider  (FR-3.4)  + CacheStore actor (FR-3.2/3.3)
```

### 3.1 Data model (GRDB tables)
```
source        id, kind(local|iaItem|iaList|iaCollection|iaFavorites),
              iaIdentifier?, originalURL?, title, addedAt, lastResolvedAt?,
              followUpdates(bool), licenseText?, memberCapHit(bool)
album         id, sourceId, title, artist, year?, artworkId?
track         id, albumId, sourceId, title, trackNo?, discNo?, durationSec?,
              codec, sampleRate?, bitDepthOrBitrate?, sortKey
asset         id, trackId, kind(localRef|managedCopy|remote),
              bookmark?/relPath?/remoteURL?, sizeBytes?, unsupportedReason?
cache_entry   assetId, relPath, totalBytes?, byteRanges(blob), complete(bool),
              lastAccessedAt, createdAt
playlist      id, title, kind(manual|folder), folderBookmark?, watch(bool)
playlist_item playlistId, position, trackId, sectionTitle?
```
Rules: deleting a Source cascades albums/tracks/assets and their cache entries
(files removed by CacheStore); library queries never join network state; FTS5
mirrors track/album/artist.

### 3.2 Playback path
`Track` → preferred `Asset`: localRef/managedCopy play direct; remote plays via
`tonearm-cache://` URL through `CachingAssetProvider`. Complete cache entries are
served entirely from disk (AVURLAsset still goes through the loader for
uniformity). Engine emits cache-progress events; UI derives ○/◔/● from
`cache_entry`.

### 3.3 Design system
As mockups v2: brass `#E3A44B` on dark, SF Pro only, four glass-dock tabs
(Library / Playlists / Sources / Settings), provenance badges, three-layer
scrubber, one-card cache contract in Settings. Glass is chrome-only; content
opaque; concentric radii; ≥44pt targets. Copy rules: cache language is always
passive ("cached", "streams from archive.org"), never imperative ("download",
"save offline").

---

## 4. Implementation phases

Each phase: one `plans/PN-*.md`, one PR, acceptance criteria gate.

**P0 — Bootstrap.** Project, GRDB + engine SPM, CI (build/test/SwiftLint +
invariant greps §9), GPLv3, tab scaffold + glass dock, GlassFeature flag plumbing.
*Accept:* CI green; tabs + docked mini-player placeholder render on iOS 18 & 26 sims.

**P1 — Schema & domain.** §3.1 migrations, FTS5, LibraryStore actor, cascade
tests, URLGrammar parser with exhaustive fixture table (every FR-2.1 shape + 20
rejection cases).
*Accept:* model coverage ≥95%; URLGrammar fixtures all pass.

**P2 — Local ingest & Library UI.** FR-1 complete: file picker, folder-as-playlist
sheet (order/subfolders/watch toggles), bookmarks vault, metadata + artwork
extraction, dupe detection, missing-file tombstones, Library + Playlists tabs,
local FTS search.
*Accept:* 124-file folder imports < 15 s preserving order; revoke-and-relaunch
shows tombstones not crashes; watch-folder diff test passes.

**P3 — Playback.** Engine wiring: queue, gapless, background, remote commands,
Now Playing sheet (without cache layers yet), mini-player.
*Accept:* gapless fixture verified; 30-min background playback; remote commands.

**P4 — IA resolution & streaming.** ItemResolver (port from Lorewave),
CollectionResolver with cap, **ListResolver spike then implementation** (strategy
chain + recorded live fixtures for the known CC0 Bach items, one public list, one
fav-* page), Add Source sheet with preview/license/error states, Sources tab,
direct streaming (pre-cache) to prove the pipeline.
*Accept:* all four URL shapes resolve end-to-end against recorded fixtures + one
live smoke test; error copy matches spec; no IA call originates outside `IA/`.

**P5 — CachingAssetProvider (in parso-audio-engine).** FR-3 complete: resource
loader, sparse file + range map, CacheStore actor (limit, LRU, GC), prefetch,
cellular gating, cache UI states (row glyphs, scrubber layers, codec chip,
Settings card, Clear Cache).
*Accept:* play 3 tracks → airplane mode → all 3 replay offline; fill past limit →
oldest evicted, player unaffected; scrub into uncached region streams correctly;
kill app mid-cache → partial resumes or GCs cleanly; CPU overhead < 3% (NFR-3);
engine-level tests run in the engine repo.

**P6 — Liquid Glass & polish.** iOS 26 native glass, material fallbacks,
accessibility passes (NFR-6), empty states, app icon (tonearm mark, brass on dark),
performance passes (NFR-1..5).
*Accept:* screenshot review both OS generations; a11y audit clean; perf numbers met.

**P7 — Ship.** Name gate (§0.2): App Store availability + USPTO check; App Store
metadata (privacy label: no data collected), TestFlight, tip-jar decision.

---

## 9. Invariants (CI-enforced)

1. **No IA search.** No user-facing text field may feed any IA request. Grep gate:
   `advancedsearch`, `scrape?q=` appear only in `IA/CollectionResolver*`.
2. **No downloads.** Grep gate: case-insensitive `download` appears in Sources/
   only inside `IA/` URL construction (`archive.org/download/` paths) and nowhere
   in UI strings, view code, or type names.
3. **No telemetry.** URL-layer unit test: allowlist `archive.org`,
   `*.us.archive.org`; any other host fails the suite.
4. **No fb2k identifiers.** Grep gate: `foobar`, `fb2k` → zero hits in source,
   strings, metadata.
5. **Cache is passive.** No public API on CacheStore initiates caching of a track
   the player/prefetcher didn't request. Review checklist item + API surface test.
6. **Glass is chrome-only.** `AdaptiveGlass` modifier restricted to components under
   `Features/Chrome/`; lint rule.

---

## 10. Risks & open questions

- **R1 — IA list endpoint instability (highest).** User lists have no documented
  public API and were disrupted in the 2024 IA incident. Mitigation: strategy chain
  (FR-2.3), recorded fixtures, graceful "couldn't refresh this list" state that
  keeps previously resolved members playable from metadata + cache. Spike is the
  first task of P4; if both strategies prove unworkable, descope lists to
  favorites-pages-only and flag to J before proceeding.
- **R2 — AVAssetResourceLoader edge cases.** Redirect handling, missing
  Content-Length, FLAC UTI. Mitigation: pre-resolve datanode URLs; contract tests
  with a local stub server in the engine repo; fallback of last resort is
  full-file staging into cache before play (correct, slower first-play).
- **R3 — App Store review.** Stream-only + transparent cache is the same posture
  as every streaming app; stronger position than v1's downloader. Keep cache copy
  passive; privacy label empty.
- **R4 — Name clearance.** §0.2 gate at P7; fallbacks listed.
- **R5 — Cache vs. FLAC sizes.** 500 MB default holds ~10–12 FLAC album-sides or
  ~100 MP3 tracks. Acceptable for a default; the 2 GB/10 GB presets exist precisely
  for the "effectively offline" use. No action needed, just expectation-setting in
  the Settings copy.
- **Q1** Should folder playlists copy files when the folder lives in iCloud Drive
  (eviction risk)? Current answer: no — rely on `NSFileCoordinator` download-on-read;
  revisit if TestFlight feedback shows pain.
- **Q2** GRDB confirmed over SwiftData? Veto closes at P1 start.
