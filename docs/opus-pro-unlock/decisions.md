# Decisions

**D1 — Opus via Ogg→CAF remux, fetch-complete-then-play.**
AVFoundation won't demux Ogg; Opus-in-CAF plays natively (verified in
parso-pdaudio). The resource loader serves original bytes by range and CAF's
mandatory `pakt` table is unknowable until the full Ogg scan, so progressive
remux through `parsocache` is infeasible. Rejected: libopus/FFmpeg decode
(new C dependency, standalone constraint), synthesized-CAF resource loader
(length/pakt unknowable).

**D2 — "Opus when ready" selection policy.**
Cold taps stream FLAC (Wi-Fi) or MP3 (cellular) instantly via the existing
path; the prefetcher completes+remuxes Opus so transitions and repeat plays
upgrade. Rejected: blocking cold start on Opus fetch (adds seconds of
latency); background re-fetch upgrade after an MP3 play (doubles data).

**D3 — FLAC ships through the existing parsocache path, first.**
Native AVPlayer FLAC + existing `org.xiph.flac` mapping means selector work
only. Highest value per line of code; ships before any Opus code.

**D4 — Near-gapless now; sample-accurate gapless deferred.**
Preloaded `AVQueuePlayer` item swap gets transitions to inaudible-for-most-
material without touching the proven AVPlayer + resource-loader stack.
Sample-accurate requires an AVAudioEngine playback path — a separate,
larger plan, and the natural moment to revisit shared-engine extraction.

**D5 — One-time $9.99 Pro; no subscription.**
No recurring costs exist (no server, no accounts); the audience is
subscription-averse (Doppler's $9 one-time model and its reviews are the
market evidence). Gates are conveniences (cache presets, prefetch depth,
folder watch, EQ, CarPlay); identity features stay free and CI-pinned.

**D6 — Standalone: no parso-audio-engine.**
All new components live under `ParsoRadio/Core/Services/` (Playback/Opus,
Playback/EQ, Pro). The `AudioEffectChain`-style protocol abstraction is
dropped from scope; if extraction happens later it happens then.

**D7 — Free prefetch stays at depth 1.**
It powers both near-gapless and Opus-when-ready, i.e. free-tier identity
quality. Pro sells depth, not the mechanism.

**D8 — Entitlement gating uses the private-init pattern.**
`ProEntitlement` constructible only from a verified StoreKit transaction;
single `ProFeature.isEnabled` surface; CI-linted StoreKit import boundary.
Same discipline as the workout app's evidence-gated `Prescription` type.

**D9 — Opus is un-excluded (reverses the old guard test).**
The prior `FileSelectionPolicyTests.testExcludesOpusEntirely` asserted Opus
never appeared as a track. Opus is now a free format via the fetch→remux→CAF
pipeline (D1), so that guard is rewritten to
`testOpusAllowedButNotColdStreamed`: a mixed item still cold-plays the instant
MP3/FLAC but exposes the Opus derivative (`ResolvedTrack.opusURL`) for the
prefetch/remux upgrade; an Opus-only group yields a track flagged
`requiresRemux`. `FileSelectionPolicy` keeps Opus in a *candidate* set but
ranks it last so it never wins a mixed group's cold-play pick.

## Layout deviations from `00`–`03` (this repo)

- **Selector stays in `ItemResolver.swift`** (`FileSelectionPolicy`); no separate
  `AudioFormatSelection.swift`.
- **New dirs:** `Sources/Pro/` (`ProEntitlement`, `ProFeature`, `ProStore`,
  `ProGating`), `Sources/Audio/Opus/` (`OggPageReader`, `CAFOpusWriter`,
  `OpusRemuxer`), `Sources/Audio/EQ/` (`EQEngine`, `EQPreset`, `EQAudioTap`),
  `Tests/Fixtures/` (public-domain-style generated Opus tones).
- **iOS 18.0**, not 17.0.
- **No `ContributionSupportView`** — the paywall (`ProPaywallView`) links from the
  Settings cache/prefetch touchpoints; About area unchanged.
- **Prefetch/cache controls already existed and were ungated** — Phase 3 *adds*
  gates (`ProGating`) to existing UI rather than building it from scratch.
- **Opus CAF specifics:** the writer emits a `kuki` magic cookie + `chan` layout
  and a fully-variable `pakt` table (byte size AND frame count per packet), which
  is what CoreAudio itself requires to *decode* Opus-in-CAF (validated against
  `AVAudioFile` for mono and stereo; a minimal table opens but won't decode).
