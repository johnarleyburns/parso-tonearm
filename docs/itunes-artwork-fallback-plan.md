# Plan: iTunes Search artwork fallback with fuzzy filename matching

## Goal
When a track/album has no embedded art (local) and no IA cover, fall back to Apple's
iTunes Search API (anonymous, Apple-hosted, App Store-friendly) to fetch album art.
Handle noisy/artist-only filenames (e.g. "Stephan Bodzin", "Solomun") with a fuzzy
query parser + confidence gate so we make a best guess when reasonable and show
nothing (per-kind fallback icon) when not. Cached on disk like all other art;
user-toggleable (default on).

## Networking policy (keep guardrails intact)
- Leave `IAClient` archive.org-only. Invariant #3 test (`InvariantTests.swift`) only
  asserts `IAClient.isAllowedHost`, so it stays green.
- New `ArtworkSearchClient` (`Sources/Art/`) with its OWN allowlist:
  `itunes.apple.com` (search JSON) + `*.mzstatic.com` (image CDN). Runtime host guard
  throws on any other host, mirroring `IAClient`. Descriptive User-Agent, short timeout.
- `Info.plist`: add ATS `NSExceptionDomains` for `itunes.apple.com` and `mzstatic.com`;
  keep `NSAllowsArbitraryLoads=false`, TLS enforced.
- Settings toggle "Look up missing artwork" (`@AppStorage("artworkLookup")`,
  default ON), passed into the `ArtworkService` actor via `applySettingsToPlayer()`.
- Update privacy copy: `SettingsView` privacy card, `PrivacyView`, requirements pillar #4.

## Fuzzy query pipeline (pure, testable)

### StringSimilarity (Sources/Art/StringSimilarity.swift)
- Normalized Levenshtein ratio in [0,1]; case/diacritic-insensitive comparison.
- Token-set helpers for artist-token alignment checks.

### FilenameQueryParser (Sources/Art/FilenameQueryParser.swift)
Turns a filename/title into structured query candidates:
1. Strip extension; strip leading track numbers (`^\d+[\s._\-]+`).
2. Convert `_`/`.` separators to spaces; collapse whitespace.
3. Remove noise: bracketed `(...)`/`[...]`/`{...}`, mix/edit qualifiers (Original Mix,
   Remix, Extended, Radio Edit, Live, DJ Mix), quality tags (320, kbps, FLAC), bare years.
4. Diacritic-fold for comparison copies.
5. Split on ` - ` -> artist candidate (left) + title candidate (right). Else the whole
   cleaned string is the artist term (handles bare "Solomun").
Output: `{ artist?, title?, cleanedTerm, tokens }`.

## Query chain in ArtworkSearchClient (first confident hit wins)
1. Tagged album -> `entity=album, term="artist album"`.
2. artist + title -> `entity=musicTrack, limit=5` -> use matched track's album art.
3. Artist-only / single keyword -> `entity=album&attribute=artistTerm&term=<artist>&limit=5`.
4. Last resort -> `entity=musicTrack, term=<cleanedTerm>, limit=5`.
Image URL: `artworkUrl100` upscaled `100x100bb` -> `600x600bb`.

## Confidence gate (REQUIRED: artist-token alignment)
- A pick is only valid if the query's inferred artist token(s) align with a result's
  `artistName` above threshold. Title/collection matches ALONE never qualify (prevents
  a song literally named "Motivation" from matching "workout rocky motivation").
- Score candidates; penalize collab (`&`, `feat`) and `Various Artists`/compilation
  unless the query itself contains them; prefer `collectionType=="Album"` and
  `trackCount>1` over `- Single` when choosing a representative.
- Strong (artist AND album/track align >= threshold): use, cache, PERSIST as the
  source's remembered representative (`artworkTrackId`).
- Weak (only artist aligns): show it, cache to disk, but DO NOT persist as remembered
  (a better signal can override later).
- Below floor: return nil -> existing per-kind fallback icon shows.

## Expected outcomes for the six validated fixtures
1. Stephan Bodzin - Boavista -> STRONG: exact "Boavista" album (skip Synthapella).
2. Solomun -> STRONG: "Nobody Is Not Loved" (skip "Skrillex & Solomun" collab).
3. Nicola Cruz - Boiler Room Tulum -> WEAK: artist matches (live), not persisted.
4. Hozho at Volkswagen Arena Istanbul -> WEAK via artistTerm fallback (track search empty).
5. Trap hip-hop boxing music mix -> NONE (no artist alignment) -> fallback icon.
6. workout music rocky motivation -> NONE (only generic title token) -> fallback icon.

## Integration (no view changes)
- The iTunes fallback lives in the track-row path: `ArtworkService.trackArtwork(forTrackRow:)`
  returns `(image, persistable)`; `artwork(forTrackRow:)` wraps it for existing callers.
  After embedded/IA art fails and if toggle on, run client -> validate (>2048 bytes,
  UIImage, aspect guard; skip spectrogram check). Reuse `store`/`writeDiskCache`/`notFoundSentinel`.
- `artwork(forIdentifier:)` stays IA-only (an IA slug is a poor iTunes term). IA source
  TILES that lack an IA cover fall back in `AppState.resolvedArtwork` to a representative
  track row, so they still get an iTunes cover via the track-row path (same as Now Playing).
- Persistence: only STRONG matches (embedded/IA, or a strong iTunes match) are remembered
  as a source's `artworkTrackId`; weak iTunes guesses are shown but not persisted.
- For local tracks, also read `commonKeyAlbumName` during the existing metadata load to
  build the iTunes term (lookup only; not persisted, not regrouped).
- Surfaces automatically in tiles, Now Playing, Up Next, lock screen via existing
  `SourceArtworkView`/`ArtworkView`. Cleared by existing `ArtworkService.clearAll()`.
- Toggle wiring: `artworkLookup` is `@AppStorage` on MainActor `AppState`; pass value
  into the `ArtworkService` actor via a setter (avoid cross-actor `@AppStorage` reads).

## Tests (pure, no live network)
- StringSimilarityTests: known pairs/thresholds, token alignment.
- FilenameQueryParserTests: pattern zoo (Artist - Title (Original Mix), 01_Artist_Title,
  [Label] Artist - Title, bare Solomun, descriptive mix names).
- ArtworkSearchClientTests: host allowlist (allow itunes.apple.com, is1-ssl.mzstatic.com;
  reject others), term encoding, 100x100bb->600x600bb upscale, entity selection, and the
  confidence gate over the six fixtures decoded from mock JSON (strong/weak/reject).
- Auto-discovered by XcodeGen (Tests dir), so CI picks them up.

## Apply-on-update
- Runtime fallback automatic for existing installs; no migration. Weak guesses stay
  non-persisted so they self-correct.

## Files
- New: `Sources/Art/ArtworkSearchClient.swift`, `Sources/Art/FilenameQueryParser.swift`,
  `Sources/Art/StringSimilarity.swift`, plus `Tests/ArtworkSearchClientTests.swift`,
  `Tests/FilenameQueryParserTests.swift`, `Tests/StringSimilarityTests.swift`.
- Edit: `Sources/Data/ArtworkService.swift`, `Sources/App/AppState.swift`,
  `Sources/Features/Settings/SettingsView.swift`, `Sources/App/Info.plist`,
  `project.yml` (ATS via Info settings if applicable), `TONEARM-requirements-design-v2.md`.

## Verification
- `xcodegen generate` + `xcodebuild build`, run `TonearmTests`, then commit/push, check CI.
