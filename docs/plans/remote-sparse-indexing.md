# Remote Sparse Indexing (Download-And-Discard for Non-Downloaded Tracks)

## Agent Handoff Instructions

This document is a **design/feasibility plan, not yet implemented**. Nothing in this repo currently does sparse remote sampling — the shipped behavior as of commit `c4197e0` is "skip indexing entirely for any track whose only asset is remote/undownloaded" (see `DiscoveryReconciler.preferredAsset(from:)`/`assetSelection(trackId:)`). This plan describes the chosen approach for an optional follow-up that would let the indexer sample *just enough* audio from a remote track to embed and analyze it, then discard the audio entirely, without ever writing it to the app's persistent playback cache (`AudioCache`/`SparseCacheStore`, from `ParsoAudioStreaming`) and without a full download: **reuse the app's existing streaming-playback infrastructure** (`ParsoAudioStreaming.CachingResourceLoader`/`SparseCacheStore`, driven through `AVAssetResourceLoaderDelegate`), pointed at an ephemeral, temp-rooted cache store instead of the real persistent one. This covers every container format the app already streams for playback — MP3, MP4/M4A/AAC, ALAC, FLAC, WAV/AIFF — uniformly, with no format gate needed.

**Decision made this session**: an earlier draft of this plan proposed two alternatives — a hand-rolled byte-range-math approach (elementary-stream formats only) and this streaming-infrastructure-reuse approach (all formats). The hand-rolled approach is **rejected** — it only ever covered a subset of real-world formats (never MP4/M4A, likely the single most common remote-library format), would have required a bespoke MP4 parser as a separate follow-up to reach full coverage, and reuses none of the ~1,400 lines of already-tested `ParsoAudioStreaming` code the chosen approach builds on. It is kept, in reduced form, as "Rejected alternative" below purely for the record — do not build it.

Before implementing from this plan:

- Read it completely, especially "Phase 0 — investigation findings" and "Prerequisite (blocks this plan entirely)". A second research pass resolved the open questions from the first draft with hard evidence (traced every provider's `resolve(node:)`, the actual remote-track persistence path, and the `ParsoAudioStreaming` package). The one thing that research pass could **not** confirm — and that remains the real risk before this plan is worth committing engineering time to — is whether `AVAssetReader` seeking to ~13 scattered time windows over-fetches bytes compared to the sequential-from-the-start pattern normal playback uses. See "specific risks and the validation step" below; do that measurement before writing the rest of this feature.
- Re-read `Sources/Discovery/AnalysisAssetResolver.swift`, `Sources/Discovery/BoundedIndexWorker.swift`, `Sources/Discovery/WindowedAudioReader.swift`, `Sources/Discovery/DiscoveryReconciler.swift`, `Sources/Remote/RemoteLibraryProvider.swift`, `Sources/Remote/RemotePlaylistIngest.swift`, `Sources/App/AppState+Downloads.swift`, and (in the sibling `parso-audio-engine` repo) `Sources/ParsoAudioStreaming/CachingResourceLoader.swift` + `SparseCacheStore.swift` + `StreamCacheKeying.swift` — the summary below reflects their state as of this plan's writing, and they may have moved on since.
- Preserve existing user work; do not revert unrelated changes.
- This feature has a real, ongoing cost (cellular data, battery) for the user — it must ship gated behind an explicit, off-by-default setting, never silently enabled by the existing "index downloaded tracks" behavior.
- If implementation discovers a mismatch or a better minimal design, update this plan file with the final decision rather than leaving the handoff stale.
- Update the "Implementation Audit" section at the bottom once implemented.

## Why this plan exists

Real user question after the "only index downloaded/on-device tracks" fix shipped: "how could we efficiently index tracks not on-device without adding them to the cache — do we only sample part of the track and then discard the audio used for indexing, keeping only the indexed data?" That is exactly the shape of what's described here: partial, ranged fetches; a short-lived temp file, never the persistent cache; discard the bytes immediately after the embedding/analysis pass; keep only the resulting vector and musical-analysis rows.

## Goals / Non-Goals

**Goals**
- Let a track hosted on a remote library (Subsonic, WebDAV, Jellyfin, Plex, a cloud drive, SMB, Internet Archive) get indexed (embedding + musical analysis) without the user ever downloading or "making offline" the whole file.
- Never persist the fetched audio bytes beyond one bounded unit of work — no `AudioCache`/`SparseCacheStore` entry is created by this path.
- Be honest about coverage: a track that genuinely cannot be sparsely sampled (wrong container format, provider doesn't support ranged reads, re-authentication fails) must say so, not sit silently in a stuck state — this plan exists in the same spirit as the just-shipped fix for the "2631 tracks waiting" report, and must not reintroduce that failure mode in a new form.
- Reuse the existing embedding/analysis pipeline (`SemanticPreprocess`, `FullAnalysis`) completely unchanged downstream of the point where a window's PCM samples become available — the only real new code is how those samples get produced for a remote asset (a new `AVAssetReader`-based reader, described below) and how the byte fetching underneath it stays ephemeral.

**Non-goals (explicitly out of scope for this plan)**
- A bespoke, hand-written MP4 box parser — the chosen approach (below) covers MP4/M4A/ALAC without one, by reusing the app's existing `AVAssetResourceLoaderDelegate`-based streaming infrastructure instead. See "The MP4/M4A container blocker" below for why a parser would otherwise be needed, and "Rejected alternative" for the approach that would have needed one.
- Changing the existing manual "Make Offline" / per-track "Download" actions (`AppState.makeOffline(source:)`, `AppState.download(rows:)`) — those already do a full download into `AudioCache` by design; this plan is additive, not a replacement.
- Guaranteeing 100% remote-library coverage. Some tracks, formats, and providers will remain "not sparsely indexable" even after this ships (a provider without range support, an unreachable re-auth), and that must be visible, not hidden.

## Current architecture (verified this session)

- `DiscoverySamplingPolicy.windowStarts(durationSeconds:)` (`Sources/Discovery/DiscoveryVersions.swift`) picks up to 12 embedding windows of `BoundedIndexWorker.embeddingWindowSeconds` (10s each), spread evenly from the track's start to `duration - 10`. For a track longer than ~2 minutes this is already the maximum 12 windows — up to 120 seconds of audio for embedding alone.
- `BoundedIndexWorker.musicalAnalysisMaxSeconds` = 60s, read once, centered on the middle of the track (`duration/2 - scope/2`).
- So a full analysis of one track can require up to ~180 seconds of decoded audio, in up to 13 separate reads (12 embedding windows + 1 analysis window) under the current stage design — not "a few small samples," a real amount of data. Any byte-budget estimate for this feature must start from that number, not from a smaller assumption.
- `WindowedAudioReader.readWindow(url:startSeconds:windowSeconds:)` / `.duration(url:)` (`Sources/Discovery/WindowedAudioReader.swift`) operate on a local file `URL` (AVFoundation-based). They cannot read directly from a remote HTTP URL — whatever resolves a `URL` for these calls must be a local (even if short-lived/temporary) file.
- `AnalysisAssetResolver.withResolvedURL(for:body:)` (`Sources/Discovery/AnalysisAssetResolver.swift`) is the seam these calls go through today. It currently only resolves genuinely local assets (bookmark → resolve; `file://` remoteURL; app-support-relative `relPath`) and returns `.assetUnavailable` for anything else. Its own doc comment already flags a related, still-open gap: it does not consult `AudioCache`'s "complete cache" tier at all (would need `ParsoAudioStreaming`, which `TonearmDiscovery` doesn't currently depend on).
- As of commit `c4197e0` (this session), `DiscoveryReconciler.preferredAsset(from:)` never selects a bare `.remote` asset as a track's preferred asset at all — a track whose only assets are remote gets **no index job**, full stop. This plan is exactly the case that changes that: a remote asset on a provider that supports ranged reads should become eligible again, but through sparse sampling, never through the old "select it and let it sit in `waitingForAsset` forever" behavior that fix removed.
- `Asset.remoteURL` is genuinely persisted (`Sources/Domain/Entities.swift`). `Asset.transientRemoteHeaders` and `Asset.transientRemoteSupportsByteRanges` are explicitly documented as **not persisted** — "Runtime-only headers for browsed remote-library queue rows... credentials remain in the Keychain/provider layer." Confirmed by tracing `LibraryStore.tracks(forSource:)` → `hydrate(_:db:)`: it is a plain DB fetch, with no call back into a `RemoteLibraryProvider` to refresh headers. **Resolved in the Phase 0 findings below (item 1): confirmed real for every provider except possibly Subsonic** — see the provider table there.
- `RemoteLibraryProvider.resolve(node: RemoteNode) async throws -> ResolvedAsset` (`Sources/Remote/RemoteLibraryProvider.swift`) is the one place that reliably produces a fresh, authenticated `URL` + `headers` + `supportsByteRanges` for a track. It takes a `RemoteNode` (an `id`/`path` pair from browsing), not a persisted `trackId`. **Resolved in the Phase 0 findings below (item 2): confirmed absent — traced all the way to the exact line that discards it (`relPath: nil` in `RemotePlaylistIngest.persist`).** `RemoteTrackRowFactory` (`Sources/Remote/RemoteTrackRowFactory.swift`), which builds the in-memory `TrackRow`/`Asset` used during live browsing, assigns browse-preview tracks **negative** synthetic ids, reinforcing that the live-browse path and the persisted-track-row path are not the same thing — confirmed in Phase 0 item 4 below.
- `AudioCache` (`ParsoAudioStreaming`) is the existing persistent, disk-backed, URL-keyed cache used by "Make Offline" and manual per-track "Download" (`AudioCache.key(for:)`, `AudioCache.fileURL(for:)`, `AudioCache.shared.adoptCompleteFile(...)`). This plan must never write sampled bytes there — that would silently turn "index-only sampling" into "downloaded," which is exactly the outcome the user explicitly said they don't want ("I don't necessarily want to download ALL the files in my library").

## The MP4/M4A container blocker (why a naive byte-range approach doesn't work)

`WindowedAudioReader` ultimately opens whatever `URL` it's given via AVFoundation's file-based audio reading. Two different situations follow from that:

- **Elementary-stream / self-synchronizing codecs** — plain MP3 (with or without ID3 tags), raw ADTS AAC, OGG (Vorbis/Opus), WAV/AIFF — encode audio as a sequence of self-contained frames with sync codes. A decoder can start mid-stream, skip a truncated leading frame, and decode everything after it correctly. A contiguous byte range chopped from the middle of one of these files, written alone to a temp file, is independently decodable (modulo losing the very first partial frame, which the padding described below already accounts for).
- **MP4/M4A-container codecs** — AAC-in-M4A (very likely the single most common remote-library format in real libraries, since it's iTunes/Apple Music's native export/rip format), ALAC, and MP4 generally — are **not** frame-independent. Interpreting *any* byte range requires the file's `moov` atom: the sample table (`stco`/`co64` chunk offsets, `stsz` sample sizes, `stts` timing) that maps time to byte position in the first place. A byte range taken from the middle of an M4A file, without also having `moov`, is not "lower quality" — it is not decodable at all by AVAudioFile or any standard decoder. Worse, `moov`'s position is encoder-dependent: "faststart"-encoded files put it at the front, but many common encoders put it at the end, so even fetching "just the moov atom" requires either a size-aware tail fetch or a scan.

**Consequence**: a naive manual byte-range fetch (chop out a middle slice, decode it directly) is only viable for elementary-stream formats, and would need to explicitly gate on codec/container and skip M4A/MP4/ALAC entirely — that's the "Rejected alternative" approach below, and exactly why it was rejected rather than built. The chosen design (below) removes this limitation entirely by reusing the app's existing streaming-playback infrastructure instead of parsing MP4 boxes by hand.

## Rejected alternative: hand-rolled byte-range fetch (not being built)

**Not the chosen approach — kept for the record only.** This was the first design considered: manually compute byte ranges for each sampling window, fetch them, decode from a flat temp file. It only ever covered elementary-stream formats (see "The MP4/M4A container blocker" above) and would have needed a second, separate MP4-parsing effort to reach full format coverage — the chosen design (below) covers every format the app already streams for playback in one piece of work, by reusing existing infrastructure instead. The design that follows in this section is preserved as originally written, for context on what was considered and why it lost out — do not implement it.

### 1. Format gate

Before attempting sparse sampling for a `.remote` asset, classify it by container/codec (from `Track.codec`, the `remoteURL`'s file extension, or provider-reported metadata — whichever is most reliable turns out to be, confirm during implementation). Eligible: MP3, raw/ADTS AAC, OGG Vorbis, OGG Opus, WAV, AIFF. Ineligible (falls through to the existing "no eligible local asset" path, unchanged): M4A, MP4, ALAC, FLAC-in-non-seekable-container if that turns out to be an issue, and anything unrecognized — default to ineligible, never assume a format is safe.

### 2. A new resolver path for eligible remote assets

Add either a new mode to `AnalysisAssetResolver` or a sibling type (e.g. `RemoteSparseAssetResolver`) that, given an eligible `.remote` `Asset`:

1. **Re-authenticate.** Obtain a fresh, working `URL` + headers for the asset. Exactly how depends on Phase 0's findings — either a live `RemoteLibraryProvider.resolve(node:)` call (if a `trackId → RemoteNode` mapping exists or is added) or, for providers confirmed to embed all auth in the URL itself, the persisted `remoteURL` directly with a preflight request. Treat a 401/403/expired-token response as `.waitingForAsset` (retryable), never a hard failure — a token can legitimately need a refresh the app doesn't currently have a background trigger for.
2. **Confirm range support.** Check for `Accept-Ranges: bytes` or probe with a real ranged request expecting `206 Partial Content`. If unsupported, treat the same as an ineligible format (skip, don't retry indefinitely).
3. **Compute byte ranges.** For each needed time window (the embedding windows plus the one musical-analysis window), estimate `byteOffset ≈ (timeSeconds / durationSeconds) × sizeBytes`, using `Asset.sizeBytes`/`Track.durationSec`. Pad generously on both sides (e.g. enough bytes for ~2 extra seconds of audio at a conservative low-bitrate assumption) to absorb VBR estimate error and frame misalignment at the edges.
4. **Coalesce requests.** Up to 13 separate small ranged HTTP requests per track (12 embedding windows + 1 analysis window) is a lot of round-trip/TLS overhead for what's actually needed. Merge windows whose padded ranges are close together (or overlapping) into a single larger ranged request before issuing anything over the network — this is a meaningful part of "efficient" in the original ask, not an optional nicety.
5. **Fetch to a temp file, never the cache.** Write each fetched range to `FileManager.default.temporaryDirectory` (a unique, per-job-or-per-window file), explicitly *not* `AudioCache.fileURL(for:)` — that's the whole point of this design versus just calling the existing download path.
6. **Reuse the existing reader unchanged.** Hand the temp file's `URL` to `WindowedAudioReader.readWindow`/`.duration` exactly as today — no changes needed downstream of this resolution step. This is the design's central simplification: everything past "here is a local file" (`SemanticPreprocess.logMel`, the encoder, `FullAnalysis`) stays exactly as-is.
7. **Discard immediately.** Delete the temp file (in a `defer`, mirroring `AnalysisAssetResolver`'s existing security-scope cleanup pattern) right after each window read completes, success or failure — never let it accumulate, never let a crash mid-job leave it behind (consider a startup sweep of this temp directory too, the way stale leases are already reset at launch).

### 3. Duration source

`resolvedDuration` (`BoundedIndexWorker.swift`) already prefers `track.durationSec` (core metadata) before ever touching the asset for a real media read. For remote tracks this is normally already known from provider-reported metadata at browse/import time, so this path rarely needs its own network round trip. If it's ever missing, a small ranged read (or, as a lower-confidence fallback, a `sizeBytes`-only estimate against an assumed bitrate) is enough — never fetch the whole file just to measure its length.

### 4. New job/coverage semantics

- A successfully sparse-sampled track completes normally (`.complete`) — same terminal state as a local track. `IndexJobRepository.coverage()`'s math needs no change for this case.
- A track that's remote, an eligible format, but currently unreachable (re-auth failed, range request failed, network down) is genuinely `.waitingForAsset` — retryable, same state the local case already uses.
- A track that's remote and an **ineligible** format/provider should not retry forever. Reusing the existing `.unsupported` stage state (already used for undecodable local files) for "this remote codec/provider can't be sparsely sampled" is the natural fit — confirm during implementation that this reads correctly on the status surface (it should not be lumped in with genuine decode failures without a distinguishing reason, given the status-surface work already shipped this session for exactly this kind of "say what's actually wrong" principle).
- `DiscoveryReconciler.assetSelection(trackId:)` (added in `c4197e0`) needs a third outcome, not just "eligible (local)" / "not eligible (skip)": **eligible via sparse remote sampling**. The scheduler/worker path for this case is new; the reconciler's job-creation decision is a small, additive change on top of what's already there.

### 5. Policy gating — this has a real, ongoing cost

Even sparse, ~180 seconds of audio per track (see the architecture section above) at, say, 192kbps is roughly 4.3 MB before padding/request overhead — multiplied across a library of thousands of remote tracks, that's real cellular data and battery, not a rounding error. This must ship:

- **Off by default**, as an explicit new setting (e.g. "Index remote tracks over Wi-Fi"), separate from and in addition to the existing "index downloaded tracks" behavior — a user should never be surprised by data usage this feature causes.
- **Gated the same way existing conditions are**: add a new `IndexBlockReason` case (e.g. `.remoteSamplingRequiresWiFi`) wired through `IndexPolicy.decide(_:)` exactly the way `.chargingOnlyRequired` already is, so the status-surface work from this session (`IndexStatusPresentation`'s real-reason detail text) covers this case for free rather than needing its own bespoke UI.
- **Probably budgeted**, not just gated on network type — a per-day or per-session byte cap is worth considering so a user's first launch after enabling this doesn't try to sample their entire remote library's worth of tracks in one go over Wi-Fi they didn't expect to be metered (guest Wi-Fi, a mobile hotspot, etc.).

## Phase 0 — investigation findings (confirmed this session, follow-up research pass)

The first pass of this plan left four items as open questions. A second research pass traced every provider's `resolve(node:)` implementation, the actual remote-track ingest path, and the existing `ParsoAudioStreaming` package (shared with `parso-audio-engine`/`pae-cdj3000`). All four are now answered with hard evidence, not hedges — and one of them (#2) turns out to be a genuine, concrete blocker for this whole plan. See "Prerequisite" below.

1. **Does `Asset.remoteURL` alone (no headers) work once read back from a plain DB row? — No, not reliably, for any provider except possibly Subsonic.** Traced every `RemoteLibraryProvider.resolve(node:)` implementation in `Sources/Remote/Providers/`:

   | Provider | Auth carried in | Persisted `remoteURL` alone reusable later? |
   |---|---|---|
   | Subsonic (`SubsonicProvider`) | URL query params (client-salted token), `headers: [:]` | Likely yes — the salt/token is client-generated per request and not a server-issued expiring credential in the standard Subsonic API, so a URL built once should keep working. Not 100% guaranteed across every Subsonic-compatible server implementation (Navidrome, Airsonic, etc. may differ) — worth a real confirmation, but this is the one provider where the current design might already work unmodified. |
   | WebDAV (`WebDAVProvider`) | `Authorization: Basic ...` **header**, plain URL | **No.** The URL carries no credentials at all; the header is mandatory and is exactly the field documented as non-persisted. |
   | Jellyfin (`JellyfinProvider`) | `authHeaders()` — a token header | **No**, same shape as WebDAV. |
   | Plex (`PlexProvider`) | `authHeaders()` — `X-Plex-Token` header | **No**, same shape. Also note `resolve(node:)` makes a live metadata API call (`data(for: .metadata(ratingKey:))`) before it can even build the URL — there is no way to reconstruct the playable URL from `node.path` alone without that call. |
   | Google Drive / OneDrive (`CloudDriveProvider`) | OAuth Bearer **header**, refreshed via `accessProvider.access()` | **No.** The access token is short-lived by design (OAuth access tokens are typically ~1 hour) and the provider already has to call `accessProvider.access()` (a refresh-token-backed refresh flow) before every `resolve(node:)`. |
   | Dropbox / pCloud (`CloudDriveProvider`) | The **resolved URL itself** is short-lived — `resolve(node:)` calls a live "get temporary link" style API (`CloudDriveAPI.decodeResolvedAsset`) that returns a signed, time-limited download URL (Dropbox's documented pattern: ~4 hour expiry) | **No, definitely not.** Even if headers weren't the issue, the URL string itself goes stale. |
   | SMB (`SMBProvider`) | None (mounted filesystem, security-scoped bookmark via `withRootAccess`) | Not a real HTTP-range question at all — see item 3 below. |

   Conclusion: **every provider except (possibly) Subsonic requires a live `resolve(node:)` call to get a currently-working URL/headers.** A raw `Asset.remoteURL` string read from the DB cannot be assumed reusable. This also means `AppState.makeOffline(source:)`/`download(rows:)` (`Sources/App/AppState+Downloads.swift`), which read `track.asset?.remoteURL`/`transientRemoteHeaders` straight off a `store.tracks(forSource:)` DB reload with no re-resolution step, look like a **real, separate, pre-existing bug** for every non-Subsonic provider today — not just a theoretical risk for this plan. Worth flagging to product/QA independently of whether this plan proceeds; it means "Make Offline" may already silently fail (or fail with an auth/expired-link error) for WebDAV, Jellyfin, Plex, Dropbox, Google Drive, OneDrive, and pCloud libraries whenever it's invoked outside a session that just finished browsing that source. **Not fixed as part of this plan** — noted here because this plan's design depends on the same re-resolution step that bug also needs, so fixing one is most of the way to fixing the other.

2. **Is there a persisted mapping from a `track`/`asset` row back to a `RemoteNode`? — No. Confirmed absent, not just unconfirmed.** Traced the actual persistence path: `AppState.persistRemoteTrack(_:)` → `RemotePlaylistIngest.persist(nodes:resolve:source:store:)` (`Sources/Remote/RemotePlaylistIngest.swift`). The inserted `Asset` row is built as:
   ```swift
   Asset(id: nil, trackId: trackID, kind: .remote, bookmark: nil, relPath: nil,
         remoteURL: url, altRemoteURL: nil, sizeBytes: ..., unsupportedReason: nil)
   ```
   `relPath: nil` — the provider-native `RemoteNode.id`/`.path` (e.g. Subsonic's `songID`, Jellyfin's `itemID`, Plex's `ratingKey`, the cloud-drive `fileID`) is **never persisted anywhere**. Only the already-resolved `remoteURL` string survives. Worse, look at how `persistRemoteTrack` itself reconstructs a `RemoteNode` when it needs one for `RemotePlaylistIngest.persist`'s `resolve` closure:
   ```swift
   let node = RemoteNode(id: "now-playing-\(abs(row.id))", title: row.track.title,
                         path: rawURL, kind: .audio, ...)
   ```
   `path: rawURL` — it puts the **resolved URL itself** into the node's `path`, and a synthetic placeholder into `id`. This is a one-way construction that only works because the very next step is `resolve: { _ in resolved }` (a pass-through closure that ignores the node entirely and just returns the already-resolved asset it was given) — it is not a real, re-callable provider node reference. **There is no code path today that can take a persisted `trackId` and produce a real `RemoteNode` a provider's `resolve(node:)` could act on.** This is the concrete, load-bearing prerequisite — see the dedicated section below.

3. **Which providers actually support ranged reads — now includes one concrete "no."** `SMBProvider.resolve(node:)` explicitly returns `supportsByteRanges: false` — SMB is a mounted network filesystem accessed via `withRootAccess`/a security-scoped bookmark, not an HTTP object store, so "ranged HTTP GET" isn't the right operation for it at all; a true SMB implementation of this plan would read via `FileHandle.seek(toOffset:)`/`read(upToCount:)` directly against the mounted share (trivially "sparse" already, no ranged-HTTP machinery needed) rather than going through the byte-range design below. For the HTTP-based providers (Subsonic, WebDAV, Jellyfin, Plex, the cloud drives, Internet Archive), `Asset.transientRemoteSupportsByteRanges` defaults to `true` in most `resolve(node:)` implementations, which is a claim, not a tested guarantee — but the existing `ParsoAudioStreaming.CachingResourceLoader` (see "Proposed design" below) already has a battle-tested fallback for servers that lie about range support (`RemoteStreamingResponsePolicy.probeResult`/`dataResponse` treat an unexpected `200`/chunked response as `.fullBody`, degrading gracefully rather than failing) — reusing that machinery gets this handled for free instead of needing fresh live-server testing per provider.

4. **How did the "2631 tracks" get their rows? — Confirmed: one track at a time, via play/playlist-add, never a bulk catalog sync.** No code path was found anywhere in this repo that eagerly imports a remote source's entire catalog into the core `track`/`asset` tables. The only persistence path found is `AppState.persistRemoteTrack(_:)` (invoked when a browsed/previewed remote track — negative synthetic id — gets played or otherwise needs to become "durable"), which calls `RemotePlaylistIngest.persist` one node at a time. That fully explains the shape of the original bug report: a large remote library, browsed and played over time, accumulates real `track`/`asset` rows one at a time, each carrying only the URL that happened to be valid at the moment it was persisted — with no way to refresh it later. It also means this plan's Phase 0 item 2 gap (no persisted `RemoteNode` reference) applies uniformly to every one of those rows, not just new ones going forward.

## Prerequisite (blocks this plan entirely)

Before this plan's fetch logic can re-authenticate a remote asset in the background, `Asset` (or a related table) needs a genuinely persisted, re-resolvable reference to the track's origin — not just the once-resolved `remoteURL`. Concretely:

- Add a persisted field — e.g. `Asset.remoteNodeID: String?` and `Asset.remoteNodePath: String?` (or a single opaque `remoteNodeReference: String?` if a provider's node is fully identified by one string) — populated at the point of `RemotePlaylistIngest.persist`/`persistRemoteTrack` from the **real** `RemoteNode` that was browsed (not the placeholder currently constructed in `persistRemoteTrack`).
- A background re-authentication step becomes: reconstruct the owning `RemoteLibraryProvider` from the track's `Source` row (`AppState.remoteProvider(for:)` already does this), reconstruct a `RemoteNode` from the persisted id/path, call `provider.resolve(node:)`, get a fresh `URL`/headers/range-support back.
- This is genuinely worth landing on its own, independent of sparse indexing — it's also what fixes the `makeOffline()`/`download()` gap identified in Phase 0 item 1 above for background/cold-reload cases. **Status: this prerequisite (the persisted node reference plus the `makeOffline()`/`download()` re-resolve-before-fetch fix) is being implemented now, ahead of and independent of the sparse-indexing feature itself — see the Implementation Audit at the bottom once it lands.**
- Scope note: this is real, if fairly small, schema + provider-plumbing work (a migration, a factory-method change, updates to every `resolve(node:)` call site that currently discards the node). It should be its own implementation step before this plan's fetch logic is written, not something the rest of this plan quietly assumes.

## Proposed design (chosen approach — reuse the existing streaming-cache infrastructure)

The rejected alternative above hand-rolls byte-range math and only works for elementary-stream formats because it feeds a flat, manually-assembled temp file to `WindowedAudioReader`'s `AVAudioFile`-based reading, which cannot make sense of a raw mid-file slice of an MP4 container. This approach takes a completely different, and better-grounded, path: **reuse the app's own existing remote-playback streaming infrastructure**, which already solves "sparsely fetch exactly the byte ranges a demuxer needs from a remote URL, including MP4/M4A" — because it already does this in production for playback.

### The key discovery

This repo's `Package.swift` depends on `ParsoAudioStreaming` (product of the sibling `parso-audio-engine` package, at `~/github/parso-audio-engine/Sources/ParsoAudioStreaming/`). Tonearm's own live playback path (`Sources/Audio/AudioPlayer+Loading.swift`, `Sources/Audio/AudioCache.swift`) already streams remote tracks — MP3 **and M4A/MP4 alike** (`RemoteAudioURL.contentTypeUTI(for:)` explicitly maps `m4a`/`mp4`/`aac` to `public.mpeg-4-audio`, alongside `mp3`, `flac`, `wav`, `aiff` — all first-class today) — via:

- `CachingResourceLoader` (`Sources/ParsoAudioStreaming/CachingResourceLoader.swift`): an `AVAssetResourceLoaderDelegate` that answers an `AVURLAsset`'s loading requests by fetching only the byte ranges actually requested, serving from a sparse on-disk cache (`SparseCacheStore`) when already fetched, and issuing a real ranged HTTP GET (with a graceful full-body fallback via `RemoteStreamingResponsePolicy` for servers that don't honor ranges) otherwise.
- `SparseCacheStore` (`Sources/ParsoAudioStreaming/SparseCacheStore.swift`): an `actor` tracking which byte ranges of a cache-keyed file are present on disk (`cachedContiguousBytes(for:from:)`, `recordWrite(range:for:)`, `totalBytes(for:)`), constructible against **any** root directory (`public init(evictableRoot: URL, durableRoot: URL? = nil, limitBytes: Int64 = ...)`) — it is not hard-wired to the app's real persistent cache location.
- `RemoteAudioURL` (`Sources/ParsoAudioStreaming/StreamCacheKeying.swift`): rewrites a remote `https://` URL to a custom scheme (`cacheURL(for:scheme:)`) so an `AVURLAsset` built from it hands loading requests to a registered `CachingResourceLoader`, and reverses it (`networkURL(for:customScheme:)`) for the loader's own outgoing requests.

Critically: **AVFoundation's own MP4 demuxer, driven through `AVAssetResourceLoaderDelegate`, already knows how to locate and request exactly the byte ranges it needs — `moov`, wherever it is in the file, then only the specific sample data for whatever time range is being read — entirely on its own.** This is exactly the problem "The MP4/M4A container blocker" section identifies as needing real, custom MP4-parsing engineering to solve by hand. This approach doesn't solve that problem with new code — it sidesteps it entirely by using the same general-purpose mechanism Apple's own frameworks use for network-seekable playback, which this codebase has already integrated and already exercises in production for these exact container formats.

### Design

1. **An ephemeral (never-persistent) cache store per job.** Construct a throwaway `SparseCacheStore(evictableRoot: <unique temp subdirectory>, limitBytes: <small cap, e.g. 8–16 MB — comfortably above the ~180s/track worst case from the architecture section above>)`, rooted under `FileManager.default.temporaryDirectory`, scoped to one bounded indexing work unit (or reused across the ~13 window reads for one track, then discarded). This is the mechanism that satisfies "never touches the persistent cache" — it is a structurally different `SparseCacheStore` instance than `AudioCache.shared`'s, pointed at a directory nothing else reads from.
2. **A distinct custom URL scheme**, e.g. `"tonearm-index-scratch"` — deliberately different from the live playback scheme (`AudioCache.scheme`, `"tonearm-cache"`) so index-time and playback-time resource loading are trivially distinguishable in logs/diagnostics and never share any implicit state (`AVAssetResourceLoaderDelegate` registration is per-`AVURLAsset`-instance already, so this isn't a correctness requirement, just good hygiene).
3. **Re-authenticate and build the `AVURLAsset`.** Using the prerequisite's `remoteNodeID`/`remoteNodePath`, get a fresh `ResolvedAsset` from the provider. Build a `CachingResourceLoader(originalURL: resolved.url, store: <the ephemeral store>, config: CachingResourceLoaderConfig(scheme: "tonearm-index-scratch", headers: resolved.headers))`, then an `AVURLAsset` from `CachingResourceLoader.cacheURL(for: resolved.url, scheme: "tonearm-index-scratch")` with `resourceLoader.setDelegate(theLoader, queue: ...)`.
4. **A new windowed reader for asset-based reading.** `WindowedAudioReader` is built on `AVAudioFile(forReading:)`, which does not support custom schemes/resource loaders — that's exclusively an `AVURLAsset`/`AVAssetReader` capability. This needs a parallel type (e.g. `AssetBackedWindowedAudioReader`, or an alternate initializer on the existing one) that, given the `AVURLAsset`, uses `AVAssetReader` + `AVAssetReaderTrackOutput` with `timeRange` set to the requested window, decodes via `CMSampleBufferGetAudioBufferList`/an `AVAssetReaderAudioMixOutput` with the same target PCM format `WindowedAudioReader` already produces (mono Float32 at `targetSampleRate`), so `SemanticPreprocess.logMel` and everything downstream still needs zero changes. This is real new code — the `AVAssetReader` API shape (async-ish, sample-buffer-based) is meaningfully different from `AVAudioFile.read(into:frameCount:)` — but it is a bounded, well-precedented piece of AVFoundation code, not exploratory format-parsing work.
5. **Discard.** After the reads for a track complete (or the job's bounded unit ends, success or failure), call `loader.shutdown()`, then delete the ephemeral store's entire root directory (`store.clearAll()` plus `FileManager.removeItem(at: evictableRoot)`) — nothing from this path ever survives past one bounded unit of work.

### Why this is the chosen approach over the rejected hand-rolled alternative

This approach handles elementary-stream and MP4-container formats uniformly (through the same resource-loader mechanism), and reuses ~1,400 lines of already-tested production code (`CachingResourceLoader`, `SparseCacheStore`, `RemoteStreamingResponsePolicy`, `RemoteAudioURL`) instead of hand-rolling byte-range/padding/coalescing math and a bespoke temp-file lifecycle for a format-limited subset. The one thing the rejected alternative had going for it was *certainty*: a manual byte-range fetch is simple enough to reason about completely by inspection, while this approach's "AVFoundation only fetches what it needs" claim — though strongly supported by the fact that this exact mechanism already streams these exact formats in production for playback — has not been directly measured for the specific access pattern this plan needs (seeking to ~13 disjoint, often-small time windows spread across a track, rather than the mostly-sequential-from-the-start access pattern normal playback does). That gap is real and is exactly what the validation step below exists to close — treat it as a go/no-go gate on this plan, not a formality.

### Specific risks and the validation step that should gate building this

- **Unverified over-fetch risk (the main open question — a real go/no-go gate, not a formality).** Sequential playback and "seek to 13 scattered 10-second windows" are different access patterns. It is plausible (though not confirmed either way this session) that `AVAssetReader` seeking to a new, far-away `timeRange` triggers more than the minimal "moov + this window's samples" — e.g. some demuxer implementations may prefetch further ahead, or re-fetch overlapping index structures per seek, or not release/reuse a prior seek's cached ranges efficiently within one job. **Before writing the rest of this feature, instrument `CachingResourceLoader`/`SparseCacheStore` (it already exposes `store.totalBytes(for:)`/cache accounting) to measure actual bytes fetched for a representative multi-window read against a real remote M4A file, and compare that to the theoretical minimum (moov size + ~13 × 10s of sample data).** If the measured overhead is small, proceed as designed. If it's large, this plan needs a redesign (e.g. widening the reused-window heuristic, or falling back to a manual approach for elementary-stream formats specifically) before it's worth shipping — do not skip this measurement and hope it's fine.
- **`AVAssetReader` lifecycle cost**: constructing an `AVURLAsset`/`AVAssetReader` per window (or per track) has real CPU/memory overhead beyond `AVAudioFile` — measure this against the "bounded, cheap unit of work" expectation the rest of `BoundedIndexWorker` is designed around before assuming it's free.
- **`limitBytes` sizing**: the ephemeral `SparseCacheStore`'s eviction behavior under its `limitBytes` cap needs checking against `SparseCacheStoreAccounting.swift` — if the cap is hit mid-job (e.g. moov turned out to be unusually large, or coalesced ranges overlapped more than expected), confirm eviction doesn't silently drop bytes the current window read still needs.
- **Custom scheme + `AVAssetResourceLoaderDelegate` on a background actor**: confirm `CachingResourceLoader`'s existing concurrency model (it's already `@unchecked Sendable` with its own `NSLock`) is safe to drive from `BoundedIndexWorker`'s actor context without adding contention with a concurrently-playing track's own loader instance — they're separate instances, but confirm nothing (e.g. `URLSession` configuration, a shared cache directory) is accidentally shared.

## Risks / open questions

- **Cloud-drive rate limits/costs**: Dropbox/Google Drive/OneDrive/pCloud may rate-limit or bill many small ranged requests differently than one larger sequential read — check each provider's API terms before enabling this for that provider.
- **Visibility**: this entire feature must be honestly surfaced, not just a background behavior change — the Sound Index screen should be able to say "downloaded, indexed" vs. "remote, sampled" vs. "remote, not indexable (provider)" for a track, in the same spirit as the real-reason-surfacing fix already shipped this session (never a generic, uninformative status).
- See also the "Specific risks and the validation step" subsection above — the over-fetch question there is the central open risk for this whole plan, not a secondary one.

## Implementation plan

0. **Prerequisite first.** Land the persisted `remoteNodeID`/`remoteNodePath` field and the re-authentication step described in "Prerequisite" above, including a real fix for the `makeOffline()`/`download()` gap that section surfaces — this is shared groundwork this plan depends on.
1. **Run the validation step** (measure real over-fetch against a live M4A file, per "Specific risks" above) before writing the rest of this feature — it can still change the design.
2. Add the ephemeral `SparseCacheStore`/`CachingResourceLoader` wiring (temp-rooted store, distinct URL scheme, re-authenticate via the prerequisite's node reference).
3. Add the new `AVAssetReader`-based windowed reader described above.
4. Extend `DiscoveryReconciler.assetSelection`/`preferredAsset` for the new "eligible via sparse remote sampling" outcome.
5. Extend `IndexStatusPresentation`/`IndexStatusView` to say which state applies (downloaded / sampled / not-indexable), reusing the real-reason machinery already in place from this session's `waitingBreakdown` work.
6. Add the Settings toggle + copy explaining the real data-usage tradeoff plainly. Gate behind the new `IndexPolicy` Wi-Fi-only reason.

## Tests

- Unit: the prerequisite's node-reference persistence — round-trip a `RemoteNode` through persist → reload → reconstruct, per provider.
- A stubbed-`URLSession` integration test driving `CachingResourceLoader` against an ephemeral `SparseCacheStore` for a synthetic MP4 fixture, asserting (a) the resulting PCM window matches a directly-decoded reference, and (b) the ephemeral store's directory is empty/removed after the job completes. This is also where the over-fetch validation measurement (see "specific risks" above) should become a real, repeatable test/benchmark, not a one-off manual check.
- Integration: fetch → decode → embedding produced; confirm no bytes survive on disk past the bounded work unit, in both the success and failure paths.
- `IndexPolicy` tests: the new Wi-Fi-only gate behaves exactly like the existing `.chargingOnlyRequired` gate (blocks on cellular, proceeds on Wi-Fi/local network).
- `DiscoveryReconciler` tests: extend the "downloaded-only" test suite added in `c4197e0` with the new eligible-via-sparse-sampling case, distinct from remote + ineligible → still skipped exactly as today.
- A real-device manual test against at least one live server per provider actually shipped (start with Subsonic and WebDAV), to validate against a real, non-mocked network before considering this done.

## Acceptance criteria

- A remote track on a range-supporting provider gets indexed (embedding + musical analysis) without ever appearing in `AudioCache`/`SparseCacheStore` and without the user tapping "Make Offline"/"Download" — regardless of container format (MP3, M4A/AAC, ALAC, FLAC, WAV/AIFF all covered by the chosen approach).
- No bytes fetched by this path survive past the bounded work unit that created them, including on a crash/force-quit mid-job (verify via a startup sweep, not just the happy-path cleanup).
- A track this feature can't handle (a provider without range support, a track whose re-authentication fails) never sits in an unexplained stuck state — it reads as a specific, real reason on the status surface, never a generic "waiting."
- The feature is off by default; enabling it clearly states the real data-usage tradeoff before the user turns it on.
- The prerequisite's `makeOffline()`/`download()` interaction (Phase 0 item 1) is fixed alongside this work, not left as a silent gap while this plan's own re-authentication step quietly fixes only the sparse-indexing path.
- `swift test` stays green; the new tests above are added, not just planned.

## Implementation Audit

- **Prerequisite: landed (`0a80ff8`, "fix(remote): persist a re-resolvable node reference; fix
  stale Make Offline/Download auth").** `Asset.remoteNodeID`/`remoteNodePath` are now genuinely
  persisted (migration v22) from the real `RemoteNode` at ingest time, and `makeOffline()`/
  `download()` re-resolve through the provider before fetching instead of trusting a possibly
  stale `remoteURL`/`transientRemoteHeaders`. This closes the "blocks this plan entirely" gap and
  the independently-real `makeOffline()`/`download()` bug Phase 0 item 1 found. Not yet confirmed:
  whether this was verified against a live server per provider, or only by code inspection/unit
  test — check before relying on it for the sparse-indexing fetch path below.
- **Core feature landed without the live validation step — an explicit, owner-approved deviation
  from this plan's original instructions.** The owner was told the validation step (measuring
  real `AVAssetReader` over-fetch against a live remote M4A file) could not be run from this
  session (no device/network access), and chose to ship the feature with instrumentation instead
  of waiting: `BoundedIndexWorker.releaseRemoteSession` logs real
  `fetchedBytes`/`estimatedBytes` per track via `os.Logger` (subsystem `guru.parso.tonearm`,
  category `RemoteSparseIndexing`) every time a remote-sparse job's session closes. **Before
  trusting this feature's real-world data cost, check that log against actual device usage** —
  if the measured over-fetch is large relative to `RemoteIndexingByteEstimate.perTrackBytes`,
  the design (widening window reuse, or a manual byte-range fallback for elementary-stream
  formats) needs revisiting, per "Specific risks and the validation step" above, which otherwise
  still applies unchanged.
- **What landed**: the Wi-Fi-only gate + Settings toggle (`4031e6c`) and, in a second commit, the
  rest — `RemoteSparseAssetResolver` (ephemeral `SparseCacheStore`/`CachingResourceLoader`
  wiring, re-authenticating via `RemoteAssetRefetch.resolve` + the prerequisite's persisted node
  reference; SMB explicitly excluded, matching Phase 0 item 3's "concrete no"),
  `AssetBackedWindowedAudioReader` (`AVAssetReader`-based, matching `WindowedAudioReader`'s
  output contract exactly), `BoundedIndexWorker` wired to use both for `.remote` assets (one
  session reused across a job's embedding + musical-analysis windows, released — and its bytes
  logged — when the job's work on that asset is done), `DiscoveryReconciler.assetSelection`
  extended with a third outcome (remote-sparse-eligible, gated on the Settings toggle and on the
  asset actually having a persisted node reference), and a startup sweep
  (`RemoteSparseAssetResolver.sweepStaleEphemeralDirectories()`) for any ephemeral directory a
  crash left behind. `IndexStatusView`'s explanatory text now reflects whichever mode is active.
- **Not done in this pass**: the dedicated stubbed-`URLSession` integration test the plan's
  "Tests" section calls for (asserting a decoded PCM window matches a reference, and that the
  ephemeral store's directory is genuinely empty after a job) — coverage so far is at the
  `DiscoveryReconciler`/`IndexPolicy`/`IndexScheduler` level (asset-selection eligibility, the
  Wi-Fi gate, session-reuse-across-windows bookkeeping), not an end-to-end fetch-through-decode
  test against a fixture. A real-device manual test per provider (the plan's last "Tests" bullet)
  also still hasn't happened. Both remain open before calling this feature fully verified.
