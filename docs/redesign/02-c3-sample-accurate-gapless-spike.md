# C3 Spike: Sample-Accurate Gapless

## Decision

Do not rewrite playback as part of Phase C. The current `AVPlayer` path should
remain the shipping engine until a dedicated AVAudioEngine implementation task
can prove parity for local files, archive.org streaming, transparent caching,
EQ, ReplayGain, crossfade, background audio, and remote commands.

This spike is intentionally standalone. It does not change playback code.

## Current Engine

- `AudioPlayer` owns a single primary `AVPlayer`.
- Archive playback is served through `CachingResourceLoader` and `CacheStore`.
- FLAC/MP3/AAC/local files use `AVPlayerItem`.
- Opus upgrades are remuxed to CAF and then played as file-backed items.
- EQ and ReplayGain are applied through `MTAudioProcessingTap`.
- Crossfade now uses a secondary `AVPlayer` only during the fade window.
- Repeat-one ambient playback uses the existing `AVQueuePlayer` /
  `AVPlayerLooper` path and should stay separate.

This is near-gapless, not sample-accurate. The remaining boundary error comes
from item-level scheduling and decoder priming/remainder behavior that
`AVPlayerItemDidPlayToEndTime` cannot control at sample-frame precision.

## Why AVAudioEngine Is Required

Sample-accurate transitions need an engine that schedules decoded PCM at exact
sample frames. The practical target is an `AVAudioEngine` graph with one or more
`AVAudioPlayerNode`s, scheduling each track with explicit start frames and frame
counts. That lets the next track begin at the exact sample after the current
track's last audible frame.

`AVPlayer` and `AVQueuePlayer` do not expose enough boundary control for this.
`MTAudioProcessingTap` can transform samples inside an item, but it cannot
schedule the next item sample-accurately.

## Product Rules For The Future Implementation

These rules belong in pure, tested types before any UI or engine wiring:

- `GaplessTimeline`: given tracks, sample rates, durations, encoder delay, and
  padding, produce exact playable frame ranges and next-start frames.
- `GaplessEligibility`: crossfade, sleep-at-end, unsupported assets, and manual
  queue jumps disable sample-accurate scheduling for that boundary.
- `EngineQueueState`: move, remove, repeat, shuffle restore, and queue advance
  must preserve scheduled/current frame state deterministically.
- `DecoderPaddingPolicy`: malformed or missing delay/padding metadata must fall
  back to the full decoded file, never discard guessed audio.

## Implementation Plan For A Dedicated Task

1. Build a local-file-only AVAudioEngine prototype behind an internal runtime
   switch. Schedule two generated fixtures and render the boundary offline.
2. Add pure tests for `GaplessTimeline`, `GaplessEligibility`, and
   `DecoderPaddingPolicy`.
3. Add an offline render test with an impulse immediately before and after the
   boundary; assert no duplicated frame, dropped frame, or inserted silence.
4. Port the existing EQ and ReplayGain math into the engine path without
   changing their pure types.
5. Add complete-cache remote support by resolving a fully cached archive asset
   to its cache file. Keep progressive remote streaming on `AVPlayer` until the
   engine path has a decoder/ring-buffer design.
6. Only after local and complete-cache parity is proven, evaluate progressive
   remote decode with `AVAssetReader` or a small internal PCM ring buffer.

## Required Fixtures

- WAV/AIFF impulse-pair tracks with known sample counts.
- FLAC impulse-pair tracks with the same PCM.
- AAC/MP3 fixtures with known encoder delay and padding.
- Opus-in-CAF fixture from the existing remuxer path.
- One archive-style remote asset that is fully cached before playback.

## Risks

- Progressive remote streaming is the hard part. `AVAudioFile` wants a local
  file, while the current archive path is byte-range and cache-backed.
- Duplicating the current loader behavior in an engine decoder could regress
  startup latency, cellular policy, cache accounting, and Opus upgrade behavior.
- EQ, ReplayGain, and crossfade currently share the AVPlayer tap path. The
  engine graph needs equivalent DSP without splitting product policy.
- Background audio and `MPRemoteCommandCenter` integration must remain identical
  from the user's perspective.

## Exit Criteria For The Future Implementation

- Offline boundary render proves zero inserted/missing samples for generated
  fixtures.
- Existing full `TonearmTests` suite stays green.
- Archive streaming tests stay green without weakening cache semantics.
- A local album can play through adjacent tracks without crossfade and without a
  measurable boundary gap.
- Unsupported or partially cached remote assets fall back to the current
  `AVPlayer` path rather than failing playback.
