# 03 — Agentic Coding Handoff

Execute phases in order. Paths are real (verified against the repo on
2026-07-09). Read `PLAYBACK-DESIGN.md` and the header comments of
`CachingResourceLoaderDelegate.swift` and `ContiguousFileCache.swift` before
touching the playback path — they document crash modes (session invalidation
SIGABRT, FileHandle interleaving) that MUST NOT regress.

## Ground rules
1. No telemetry, no new network endpoints. StoreKit verification on-device.
2. All Pro gating flows through `ProFeature.isEnabled(_:)`; `import StoreKit`
   only under `ParsoRadio/Core/Services/Pro/` and the paywall view (add CI
   grep to `.github/workflows`).
3. Never gate: formats, near-gapless, IA sources, local import, privacy.
4. Do not modify `ContiguousFileCache` locking or
   `CachingResourceLoaderDelegate` shutdown semantics without reproducing
   their existing tests first (`Core/Tests/ContiguousFileCacheTests.swift`,
   `CachingResourceLoaderDelegateTests.swift`).
5. Deployment target stays iOS 17.0.
6. Test fixtures: small public-domain IA files only, checked into
   `ParsoRadio/Core/Tests/Fixtures/`.

## Phase 1 — FLAC (fastest win)

**T1.1 Generalize format selection.**
New `Core/Services/Playback/AudioFormatSelection.swift` with `AudioCodec`
ranking and per-codec accepted-format sets; refactor
`MP3AudioFormatSelector.swift` call sites (grep for its uses in
`InternetArchiveService.swift` and view models) to the new policy. Preserve
the per-item single-format-family rule (see comment at
`InternetArchiveService.swift:448`).
AC: existing `AudioFormatPolicyTests` + new ranking tests green; IA item with
MP3+FLAC picks FLAC on simulated Wi-Fi, MP3 on cellular.

**T1.2 FLAC through parsocache.**
Verify `CachingResourceLoaderDelegate` UTI mapping handles `.flac` with query
strings; add if missing.
AC: device/manual — 16/44.1 and 24/96 FLAC stream, seek past cached prefix,
resume mid-track after relaunch (SessionRestoreController path).

## Phase 2 — Opus

**T2.1 `Opus/OggPageReader.swift`.**
AC: fixtures — multi-page packet, nonzero pre-skip, chained-stream rejection.

**T2.2 `Opus/CAFOpusWriter.swift`.**
AC: output opens via `AVAudioFile`; decoded frame count == granule-derived
count for every fixture; `mPrimingFrames` == OpusHead pre-skip.

**T2.3 `Opus/OpusRemuxer.swift` + trigger.**
Hook: when `ContiguousFileCache` completes for a `.opus` resource (and in the
prefetch fetch path), remux to sibling `.caf` in the same pool, delete raw
`.opus` on success, delete partial `.caf` on failure and mark Opus
session-unavailable for that file.
AC: corrupted-fixture fallback test; cancellation mid-remux leaves no partial
`.caf`; `CacheManager.streamingCacheBytes()` accounts the CAF.

**T2.4 "Opus when ready" policy + free-tier pin.**
Wire `DerivativePolicy` (01 §A) into track load: cached CAF → local-file
branch of `AudioPlayerService.load`; cold → FLAC/MP3 per network.
Add `FreeTierRegistryTests`: asserts `flac, opus, mp3, nearGapless,
iaSources, localImport` require no entitlement.
AC: policy unit tests over synthetic IA file lists; registry test in CI.

**T2.5 Near-gapless.**
Preloaded next `AVPlayerItem` enqueued on `AVQueuePlayer` before boundary;
`PlaybackResilience`, `SessionRestoreController`, `WholeItemController`,
`QueueManager` observe item swap, not player teardown. Repeat-one
(`AVPlayerLooper`) path untouched.
AC: existing playback tests green; manual seam check on a continuous live
set across MP3→MP3, FLAC→Opus, Opus→Opus; fast track-skip stress (the
"track 2 hangs" regression) clean.

## Phase 3 — Entitlement + gates

**T3.1 `Core/Services/Pro/`** — `ProEntitlement` (private init from verified
`Transaction`), `ProFeature.isEnabled`, cached offline entitlement.
AC: `.storekit` config tests: purchase, restore, revocation, offline read.

**T3.2 Paywall sheet** per mockup screen 3, presented only from gated
touchpoints; Restore Purchases; GPL build-from-source line; link with
`ContributionSupportView`.
AC: snapshot tests light/dark; restore verified in StoreKitTest.

**T3.3 Cache presets.** `CacheManager` budget: free 500 MB, Pro 2 GB/10 GB;
lazy downgrade eviction (never bulk-delete on launch).
AC: eviction tests incl. downgrade case.

**T3.4 Prefetch depth.** Free depth-1 (also feeds Opus-when-ready); Pro
depth-N/whole-list, Wi-Fi-only toggle; skip cancels in-flight (reuse
`shutdown()` pattern — read its header comment first).
AC: cancellation test; budget respected.

**T3.5 Folder watch.** Extend
`Core/Services/Download/LocalFileImportService.swift`: security-scoped
bookmarks, foreground rescan, `NSFilePresenter`.
AC: new file appears without relaunch; bookmark survives reboot.

## Phase 4 — EQ

**T4.1 `Playback/EQ/`** — `MTAudioProcessingTap` via `AVPlayerItem.audioMix`,
10-band biquads, presets + user presets, gated by `ProFeature.eq`. Detach tap
in the same teardown path as delegate `shutdown()`; reattach on preloaded
next item.
AC: bit-transparent bypass (offline render null test); engage/disengage
without playback interruption; no teardown crash under fast skip.

## Non-goals this cycle
CarPlay (own plan folder later) · FFmpeg/libopus · subscriptions ·
sample-accurate gapless / AVAudioEngine migration · parso-audio-engine
extraction.

## Definition of done
All ACs green in CI · `FreeTierRegistryTests` passing · no new network
endpoints (verify via existing integration harness) · `decisions.md` updated
with any deviations before merge.
