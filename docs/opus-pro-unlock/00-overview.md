# Opus + FLAC + Pro Unlock — Overview

Status: PROPOSED · Target: `plans/opus-pro-unlock/2026-07-09/`
Repo: `johnarleyburns/parso-radio-ios-app` · Standalone — **no parso-audio-engine
dependency**; all new components live in `ParsoRadio/Core/Services/Playback/`.

## What ships

| Tier | Contents |
|---|---|
| Free | **FLAC streaming (new)** · **Opus playback (new)**, preferred over MP3 when available · near-gapless transitions (hardened) · everything already free stays free |
| Pro, $9.99 one-time | Streaming-cache presets 2 GB / 10 GB · prefetch depth (N tracks / whole list) · folder watch · 10-band EQ · CarPlay when it ships |

No subscription, no accounts, on-device StoreKit 2 verification only.

## Architecture facts this plan is built on (verified in repo)

1. Playback is **AVPlayer** with an `AVAssetResourceLoader` delegate
   (`CachingResourceLoaderDelegate`, custom `parsocache` scheme) over
   `ContiguousFileCache` — a per-file contiguous **prefix cache** whose
   completed file "doubles as the offline copy"
   (`Core/Services/Playback/ContiguousFileCache.swift`).
2. The resource loader serves **original bytes by byte range**. Any transform
   that changes byte identity (e.g. remuxing) cannot live inside this path.
3. Format selection is MP3-only today (`MP3AudioFormatSelector`), but the
   delegate's content-type mapping already knows `org.xiph.flac`.
4. Deployment floor is **iOS 17.0** (`project.pbxproj`).
5. Looping uses `AVPlayerLooper` on `AVQueuePlayer`; track advance is
   `AVPlayerItemDidPlayToEndTime`-driven.
6. `CacheManager` tracks two pools: `Documents/audio` (offline copies) and
   `Caches/StreamingCache` (prefix cache), with xattr-based last-access.
7. No StoreKit anywhere; `ContributionSupportView` exists (support view).
8. Plans convention: `plans/<feature>/<date>/00-overview.md`, numbered docs,
   `decisions.md` — this folder follows it.

## The two headline consequences

**FLAC is nearly free.** AVPlayer decodes FLAC natively on iOS 17 and it
streams as original bytes, so FLAC rides the existing `parsocache` path
untouched. The work is generalizing `MP3AudioFormatSelector` into a ranked
multi-codec selector plus UTI/extension plumbing. Do this first.

**Opus cannot stream through the resource loader.** IA Opus derivatives are
Ogg-encapsulated; AVFoundation won't demux Ogg. Opus-in-CAF plays natively
(verified previously in parso-pdaudio), and the remux is a pure container swap
— but a remuxed CAF has different bytes and an unknowable final length until
the whole Ogg file is scanned, so it can't be range-served through
`parsocache`. Therefore: **fetch-complete → remux → play as local CAF file**,
with an "Opus when ready" selection policy so the user never waits. Details in
`01-opus-flac-playback.md`.

## Selection policy ("Opus when ready")

- Cold tap, nothing cached: Wi-Fi plays **FLAC** (instant, native streaming);
  cellular plays **MP3** (instant, existing path). No added latency, ever.
- Prefetcher (free: next queued track) fetches the **Opus** derivative through
  `ContiguousFileCache`; on prefix completion it remuxes to a sibling `.caf`.
- Any track whose remuxed CAF exists plays Opus via `file://` URL — the
  existing local-file branch in `AudioPlayerService.load` already handles this.
- Net effect: transitions and repeat plays get Opus; first cold plays get
  FLAC/MP3. Data cost on cellular drops toward Opus over normal listening.

## Gapless (honest scope)

AVPlayer cannot do sample-accurate gapless across distinct items. This plan
hardens to **near-gapless**: preload the next `AVPlayerItem` from
cache/prefetch and enqueue on `AVQueuePlayer` before the boundary, instead of
tearing down on `DidPlayToEndTime`. The remaining inter-item gap is typically
inaudible for live sets but not sample-accurate; a future AVAudioEngine
playback path is the fix and is explicitly out of scope here (`decisions.md`
D4). The CAF remux must still carry Opus priming/remainder frames correctly or
Opus tracks click at start/end regardless.

## Docs in this folder

- `01-opus-flac-playback.md` — selector generalization, Ogg→CAF remuxer,
  cache integration, policy.
- `02-pro-unlock.md` — StoreKit 2 entitlement, gates, paywall, pricing,
  EQ + folder watch + cache presets.
- `03-handoff.md` — agentic coding handoff: ordered tasks, file paths,
  acceptance criteria.
- `decisions.md` — locked decisions with rationale.
- Mockups: `tonearm-pro-mockups.html` (Now Playing signal path, Source
  Quality, Pro sheet, EQ).
