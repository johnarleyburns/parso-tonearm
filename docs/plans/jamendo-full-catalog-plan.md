# Plan: the whole Jamendo catalog (500,000 tracks) on the phone

Status: plan, not started. Written 2026-10-10.

## Goal

The Mood Starter library ships 4,017 Jamendo tracks with:
- metadata;
- a CLAP sound embedding;
- tempo, key and energy.

That is what lets Build a Mix, mood search and Keep Playing work on a fresh install.

The goal is the same for Jamendo's whole catalog (~500,000 tracks), with three constraints:
- It must fit a phone.
- It must download over cellular without Apple's 200 MB prompt.
- It must keep similar-track quality.

## Where we are (2026-10-10)

- **Starter DB format 3 (`starter-v3`):** one `starter.sqlite` for iPhone and Mac, **3.0 MB** for 4,017 tracks.
  - It was 23.7 MB on iPhone and 108 MB on Mac before format 2.
  - Per-track transition prep is gone. Blends are planned on the device from the audio by the one planner/mixer (`MixDeckPlayer`, `BlendPlanCache`), which takes only the tempo hint from the database.
  - Embeddings ship as 128 principal-component coordinates (`EmbeddingProjection`, `starter_projection`) and are rebuilt to 512 values when read.
- **Embedding quality, 128 coordinates vs the full 512:** measured on all 4,017 tracks.
  - 98.1% of the variance is kept.
  - Rebuilt vectors average cosine 0.994 to the originals (minimum 0.976).
  - 97.5% of each track's top-10 similar tracks are the same.

## Measured size at scale

These are real SQLite files: the starter rows replicated with new IDs, about 8 artists per 100 tracks (Jamendo's ratio), and lookup tables for license, genre and artist. "lzfse" is the compressed download size.

| Tracks | 512-value embeddings | 128-value embeddings |
|---|---|---|
| 4,017 | 2.8 MB (2.3 MB lzfse) | 1.0 MB (0.7 MB) |
| 100,000 | 68.6 MB (56.6 MB) | 23.4 MB (17.5 MB) |
| 500,000 | 343 MB (283 MB) | **118 MB (88 MB)** |

- Per track this is about 686 B at 512 values and 235 B at 128. Total size is linear in the track count.
- Add the projection: 0.26 MB (a 128 × 512 float matrix plus the mean).
- Binary (1-bit) embeddings would halve the 128-value size again, but they keep only 68% of each track's top-10 similar tracks, so they are rejected.

## Design

### 1. Catalog file: format 4 (the "C" layout)

- **Integer primary key:** the Jamendo track ID (`jamendo-123` → `123`), so there's no text key or text index.
- **Lookup tables:** `artist`, `genre` and `license` tables referenced by integer IDs. There are ~5 licenses, ~150 genres and ~40k artists. `license_url` is derived from the license.
- **Artwork:** store the album ID, not the URL. Every artwork URL fits one template; only the album ID varies.
- **Stream:**
  - First check whether Jamendo's `from=` token expires (open question 1).
  - If it does, resolve the stream URL through the Jamendo API by track ID at play/prefetch time. That saves 82 B/track but needs the client ID and one API call per play.
  - Otherwise store the token as 32 raw bytes and drop the stream URL's UNIQUE index (145 B/track).
- **Integer columns:**
  - bpm × 100;
  - Camelot key as a small integer;
  - energy quantized to a byte;
  - duration in deciseconds.
- **Embedding:** 128 int8 coordinates plus a scale, and one projection for the file.
- **Pages and compression:** 8 KB SQLite pages save another ~7%. Ship it lzfse-compressed and decompress once after download.

### 2. Two tiers

| Tier | Contents | Size | Delivery |
|---|---|---|---|
| Starter (bundled) | ~4k curated tracks, today's `starter.sqlite` | ~1–3 MB | in the app bundle |
| Catalog (optional) | all ~500k tracks | ~88 MB compressed, ~118 MB on disk | downloaded in the app (Background Assets), never in the bundle |

- Optionally, the catalog could be split by genre shards (~20). A user who only mixes house downloads a few MB.
- Each shard is a self-contained file with the same schema and the same projection.

### 3. Don't merge 500k rows into the library

The starter tracks are merged into the library database today (`LibraryStore.mergeStarterLibrary`). That does not scale: 500k rows plus 512-value embeddings would be ~0.4 GB of library database, plus index rebuild time.

Instead:
- **Read in place:** the catalog file is opened read-only and queried in place, the way `StarterLibrary` already reads its own file.
- **Copy on use:** a catalog track is copied into the library only when the user plays, likes or adds it.
- **Similarity search in the 128-d space:**
  - Text and audio query vectors are projected with the same `EmbeddingProjection`.
  - Vectors are not rebuilt to 512, which would be 256 MB for 500k tracks.
  - A brute-force int8 dot product over 500k × 128 is ~64 MB of reads per query: too slow for typing-as-you-search.
  - So add a coarse index (IVF: ~700 k-means centroids; probe the nearest 8–16 lists).
  - Alternatively, sqlite-vec with a partitioned index. Measure both on device (open question 4).
- **Build a Mix candidates:** the mix planner needs bpm + key + energy for candidates. A covering index on (genre, bpm) gives the filtered candidate set without scanning.

### 4. Building the catalog (Mac / server, offline)

- **Listing:** page through the Jamendo API (`/tracks`, 200 per call, ~2,500 calls). Respect the rate limit, store the raw responses, and keep the run resumable.
- **Audio:** `BuiltInAnalyzer` and `BuiltInEmbedder` already analyse a 60 s mid-track window.
  - Fetch only that window with HTTP range requests where the CDN allows it: ~1 MB per track, ~0.5 TB total, instead of ~2.5 TB for whole files.
- **Compute (estimate, to be measured on a 1k sample first):**
  - CLAP embedding plus the musical stages take a few seconds per track.
  - That's ~125× the starter run: on the order of a week of one Mac, or a day spread over 8 machines or cloud workers.
  - The run is embarrassingly parallel and resumable per track, like today's tools.
- **Projection:** fit the PCA on a uniform sample of ≥50k tracks, not on the 4k starter set. Then re-check variance and top-10 overlap on a held-out sample.
  - Keep one projection per catalog version: changing it invalidates every stored vector.
- **Updates:** Jamendo adds and removes tracks.
  - Version the catalog (content hash in `starter_meta`).
  - Ship deltas per shard (added and removed IDs) rather than whole files.
  - Treat a 404 at play time as "removed": hide the track and mark it.

### 5. App behaviour (CLAUDE.md: visible, in the user's control)

- **Settings → Library → "Jamendo catalog":**
  - size before download;
  - Wi-Fi only (on by default);
  - download / pause / cancel / delete;
  - progress with real bytes;
  - the specific reason when it can't proceed (no network, Wi-Fi only, low disk, paused).
- **Searching before the catalog is ready:** search and Build a Mix use the starter tier, and say so ("Searching 4,017 starter tracks — the full catalog isn't downloaded").
- **Disk:** check free space before downloading (catalog plus decompression headroom), and allow deleting the catalog without touching the library.

### 6. Licensing and terms

- Keep each track's license; ~5 distinct CC licenses.
- Decide whether NC (non-commercial) tracks may appear in a paid app (open question 2).
- Show attribution as today.
- Check the Jamendo API terms for bulk listing and caching metadata.

## Milestones

1. **Measure:**
   - 1k-track sample through the full pipeline: real analysis time per track, window range-request support, token expiry.
   - Search latency of a brute-force vs IVF query over a synthetic 500k × 128 file on the oldest supported iPhone.
2. **Format 4:**
   - normalized schema, integer keys, album-ID artwork, stream resolution;
   - writer and reader in `StarterLibrary` (or a new `CatalogLibrary`), with tests;
   - the starter is re-cut in format 4 (~1 MB).
3. **Pipeline:** resumable listing, window fetch, analysis and embedding at scale; PCA on a 50k sample; shard writer.
4. **App:**
   - catalog download service with the Settings surface;
   - in-place catalog queries;
   - 128-d search with a coarse index;
   - Build a Mix over catalog candidates;
   - copy-on-use into the library.
5. **Ship:** first a 100k-track catalog (~17.5 MB compressed), then the full 500k.

## Open questions

1. Does Jamendo's stream `from=` token expire? This decides whether to store it or resolve it through the API.
2. Are NC-licensed tracks acceptable in the app, and are there any per-track restrictions in the API terms?
3. Current catalog size and churn: the 500k figure is Jamendo's 2016 number.
4. On-device search: IVF in Swift or sqlite-vec? Pick by measured latency and memory on the oldest supported iPhone.
5. Does the PCA fitted on ≥50k tracks keep ≥97% top-10 overlap catalog-wide? If not, try 192 coordinates (~+64 B/track).
