# Tonearm — Implementation Audit & Fix Handoff (v2.1)

**Repo audited:** `johnarleyburns/parso-tonearm` @ `8b31daf` ("Implement Platterhead…")
**Against:** TONEARM-requirements-design-v2.md
**Date:** 2026-07-05
**Verdict:** Architecturally faithful skeleton, roughly P0–P4 complete and honest,
P5 (cache) present but **fails its own acceptance criteria** due to one critical
defect. Will demo well in a single session; breaks its core promise across launches.
Do not TestFlight beyond yourself until F1–F6 land.

---

## What's verifiably right (keep)

- Structure mirrors §3 nearly file-for-file (App/Audio/Data/DesignSystem/Domain/
  Features/IA, Chrome isolation for glass, Tests).
- All five grep-level invariants pass today: zero `download` outside
  `archive.org/download/` URL construction, zero `foobar|fb2k`, scrape API confined
  to `CollectionResolver` with an invariant comment, only archive.org hosts in
  source, `IAClient.isAllowedHost` unit-tested including spoof hosts.
- `URLGrammar` is complete and correct: all four FR-2.1 shapes, embed
  normalization, nested filename suffixes, wayback + spoof-host rejection, error
  copy matching spec, 20+ fixtures.
- FR-2.3 list resolution implemented exactly as specified: strategy chain of
  `services/lists/.../members.json` then bounded HTML `/details/` extraction.
- FR-2.4: 500-member cap with `capHit` + true total; favorites via `fav-*` query.
- FR-2.5 file selection: grouping by `original` to dedupe derivatives, FLAC↔MP3
  preference, spectrogram/`_sample` skip, Opus marked unsupported with reason.
- GRDB 7 + FTS5 search, folder ingest with keepOrder/subfolders/watch +
  security-scoped bookmarks + zero-padded sortKey, Settings cache card with
  presets and Clear Cache confirmation showing real bytes, ByteRangeMap with
  correct adjacent/overlap merge + tests.
- CI produces a signed archive and uploads to TestFlight (XcodeGen,
  git-count build numbers, keychain hygiene, log artifact on failure).

## Defects — fix in this order

### F1 (CRITICAL) — Cache keys are not stable across launches
`CachingResourceLoader.key(for:)` uses Swift `Hasher`, which is **randomly seeded
per process**. Every launch produces new keys: no track ever maps back to its
cached bytes, and orphaned files/metas from prior launches squat on the limit
until LRU-evicted. This silently defeats "effectively offline" and fails the P5
acceptance test *kill app mid-cache → resumes*.
**Fix:** `SHA256(url.absoluteString)` via CryptoKit, hex-encoded, keep the
extension suffix. Add a migration that wipes `StreamCache*` once (old keys are
unrecoverable). Add a unit test asserting key stability against a hardcoded
expected digest.

### F2 (CRITICAL) — CI runs zero tests and zero invariant greps
`ios.yml` is ship-only. `URLGrammarTests`, `ByteRangeMapTests`, and
`InvariantTests` never execute anywhere; invariants 1–4 are enforced by nothing.
**Fix:** add a `test` job (simulator destination, `xcodebuild test`) plus a
`invariants` job running the four greps from §9 of the requirements doc; make
`testflight-build` depend on both.

### F3 (HIGH) — `fetchRange` never validates HTTP status → cache poisoning
A 503/404 HTML body or a 200 (server ignoring `Range`) is written into the
sparse file at the requested offset and recorded as valid audio bytes, permanently
corrupting that track's cache.
**Fix:** require status 206 (or 200 only when the request was `bytes=0-` and
lengths match); on anything else throw without writing; verify
`Content-Range` start equals the requested offset.

### F4 (HIGH) — Prefetch is a no-op
`prefetchNext()` constructs a `CachingResourceLoader` and discards it; init does
no I/O. FR-3.5 is decorative.
**Fix:** add `func warm(upTo bytes: Int64)` on the loader that walks the same
cache-filling path at `.background` priority, cancel outstanding warms on queue
change, respect the cellular setting (F5) and the limit.

### F5 (HIGH) — Cellular gating unenforced
`streamOnCellular` is stored and toggled in Settings but read by nothing; no
`NWPathMonitor` exists. FR-2.7 is decorative.
**Fix:** one `NetworkMonitor` (NWPathMonitor, `isExpensive`); gate
`loadCurrent` for uncached remote assets and all prefetch; skip-with-toast per
spec; set `allowsExpensiveNetworkAccess=false` on the loader's URLSession when
gated, as defense in depth.

### F6 (HIGH) — Eviction can delete the currently playing file
`evictToFit(protecting:)` protects only the key being written. A prefetching
track at the limit can evict the playing track mid-stream.
**Fix:** CacheStore gains a `protectedKeys: Set<String>` maintained by the
player (current + active warms); eviction skips them.

### F7 (MED) — No gapless playback
Single `AVPlayer` + `replaceCurrentItem` on DidPlayToEnd = audible gap; FR-5.1.
**Fix:** migrate to `AVQueuePlayer` keeping one item ahead enqueued (pairs
naturally with F4's warmed cache).

### F8 (MED) — Loader lifecycle leaks and ignored cancellation
`loaders` array grows forever (each with its own URLSession);
`AVAssetResourceLoadingRequest.isCancelled` is never checked, so seek churn
keeps dead fetch loops running.
**Fix:** retain only current+prefetch loaders keyed by cacheKey; share one
URLSession; check `isCancelled` each loop iteration and bail.

### F9 (MED) — Watch-folder rescan never runs
The `watch` flag is captured and persisted; nothing rescans on launch (FR-1.2).
**Fix:** on app foreground, for playlists with `watch=true`, resolve bookmark,
diff by URL+mtime+size, append/tombstone as specced.

### F10 (MED) — Dead "Custom" cache preset
`presetButton("Custom", -1)` guards `bytes > 0` and silently does nothing.
**Fix:** alert with numeric field; clamp to [100 MB, 80% free disk] per FR-3.2.

### F11 (LOW) — Naming split-brain
Bundle/project/code say Tonearm; `CFBundleDisplayName`, User-Agent, and the
commit message say Platterhead. Also User-Agent omits the version (FR-2.6).
**Fix:** pick one (default: Tonearm), set display name accordingly, User-Agent
`Tonearm/{MARKETING_VERSION} (parso.guru)` from Bundle info.

### F12 (LOW) — Missing vs plan, acknowledged debt
Duplicate detection (FR-1.4) absent; Swift pinned 5.10 not 6; cache lives in
`Caches/` (system-purgeable — actually a defensible, review-friendly choice;
document it as a decision rather than "fixing" it); Reduce
Transparency/VoiceOver passes unverified (P6 anyway); `parso-audio-engine` not
used — Audio/ is app-side with a comment noting the engine extraction, which is
acceptable for a standalone repo but schedule the extraction before Lorewave
needs caching.

## Testing feedback (v2.1 → v2.2) — product-facing

Handoff addendum from live testing. These are UX/product corrections layered on
top of the F-series engineering fixes above.

- **TF1** — Remove the "Field Recordings" demo junk and its tracks entirely; do
  not seed fake local content on first run.
- **TF2** — The Sources add menu entry "Paste archive.org Link" (list/collection
  path) must read **"Add Archive.org Collection/List"** and must actually work
  (list resolution currently errors). Add unit tests covering list/collection
  member parsing so regressions are caught.
- **TF3** — The Sources add menu entry "Add Folder as Playlist" must read
  **"Add Local Folder"** (and the sheet title likewise).
- **TF4** — When a new source is added, **all** of its tracks are added to the
  library immediately. Nothing is cached at add time — caching happens only when
  a non-local track is actually played.
- **TF5** — The starter playlist is named **"Classical Piano Sonatas"** and
  contains every IA track selected during onboarding.
- **TF6** — The **+** button on Playlists opens a minimal create sheet: a
  playlist-name field plus an optional multi-select drawn from a single long list
  of all library tracks. Nothing else.
- **TF7** — Rename the **Library** tab to **Listen**. Remove "Pinned". Add a
  **Jump Back In** row backed by listening history, and below it a **Favorites**
  list of tracks the user has favorited.
- **TF8** — Add a dedicated **Library** tab *after* Playlists: a fast,
  scrollable, searchable list of all music in the library.
- **TF9** — Add an onboarding flow that explains the app across several screens
  and, on the final screen, offers a checkbox (checked by default) for each of
  these public-domain / CC0 sources to add:
  - https://archive.org/details/musopen-chopin
  - https://archive.org/details/lp_the-complete-piano-sonatas-on-thirteen-dis_ludwig-van-beethoven-artur-schnabel_0
  - https://archive.org/details/The_Open_Goldberg_Variations-11823
  - https://archive.org/details/bach-well-tempered-clavier-book-1

## Suggested agent run order
F1+F3 (one PR: cache correctness) → F2 (CI gates, so regressions get caught) →
F5+F4+F6 (one PR: network policy + prefetch + protection) → F7+F8 → F9+F10+F11.

## Verification gates (rerun after F-series)
1. Play 3 IA tracks → force-quit → relaunch → airplane mode → all 3 play. (F1)
2. Stub server returns 503 mid-track → track still plays after retry, cache file
   contains no HTML bytes. (F3)
3. Play with prefetch=2 on Wi-Fi → next 2 tracks reach ● before current ends. (F4)
4. Cellular + toggle off → uncached track skipped with toast, cached plays. (F5)
5. Set limit 200 MB, play FLAC album → playing track never evicted. (F6)
6. CI red when any invariant grep or unit test fails. (F2)
