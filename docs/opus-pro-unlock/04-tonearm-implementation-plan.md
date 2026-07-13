# 04 — Tonearm Implementation Plan (Pro tier + Opus)

Status: READY TO IMPLEMENT · Supersedes the path/assumptions in `03-handoff.md`
for **this** repository.

## Why this document exists

`00`–`03` were authored against a different repo (`parso-radio-ios-app`, module
layout `ParsoRadio/Core/Services/…`, iOS 17, files named
`MP3AudioFormatSelector`, `ContiguousFileCache`, `CachingResourceLoaderDelegate`,
`InternetArchiveService`, `QueueManager`, `SessionRestoreController`,
`LocalFileImportService`, `ContributionSupportView`). **None of those files or
paths exist here.** This repo is `Tonearm`, layout
`Sources/…`, deployment target **iOS 18.0**, tests in `Tests/` via XCTest, built
with XcodeGen + `xcodebuild` in `.github/workflows/ios.yml`.

Treat `00`–`03` as **product requirements**, not as file-level instructions. The
product intent is unchanged:

- **Free tier** keeps every identity feature: all formats (MP3/FLAC/**Opus**),
  near-gapless, archive.org sources, local import, privacy.
- **Pro tier** ($9.99 one-time, StoreKit 2, on-device verification) sells
  *conveniences*: larger streaming-cache presets, deeper prefetch, folder watch,
  10-band EQ, CarPlay (later).

## Repo mapping (plan term → real file)

| `00`–`03` term | This repo |
|---|---|
| `ContiguousFileCache` / `CacheManager` | `Sources/Audio/CacheStore.swift` (actor) + `Sources/Audio/CachingResourceLoader.swift` |
| `MP3AudioFormatSelector` / `AudioFormatSelection` | `FileSelectionPolicy` in `Sources/IA/ItemResolver.swift` |
| `InternetArchiveService` | `Sources/IA/*` (`ItemResolver`, `SourceService`, `IAClient`) |
| `AudioPlayerService` / `QueueManager` / `SessionRestoreController` | `Sources/Audio/AudioPlayer.swift` (`@MainActor` singleton) |
| `PlaybackResilience` | `Sources/Audio/PlaybackResilience.swift` |
| `LocalFileImportService` | `Sources/Features/Ingest/IngestService.swift` + `Sources/Data/BookmarkVault.swift` |
| `ContributionSupportView` | none — About lives in `Sources/Features/Settings/SettingsView.swift` |
| `Core/Services/Pro/` | new dir `Sources/Pro/` |
| `Playback/Opus/` | new dir `Sources/Audio/Opus/` |
| `Playback/EQ/` | new dir `Sources/Audio/EQ/` |
| test fixtures | `Tests/Fixtures/` (new) |

## Current state (verified 2026-07-12)

- **FLAC already works.** `FileSelectionPolicy` (`ItemResolver.swift:107`) ranks
  FLAC vs MP3, exposes `altFlacURL`; `AudioPlayer.remoteURLString`
  (`AudioPlayer.swift:220`) picks the FLAC alternate when `preferFLAC` is on;
  `CachingResourceLoader.contentType()` (`CachingResourceLoader.swift:89`) maps
  `.flac → org.xiph.flac`. Phase 1 of the old plan is essentially done.
- **Opus is deliberately *excluded* today.** `FileSelectionPolicy.audioExtensions`
  (`ItemResolver.swift:112`) drops `.opus`, and
  `Tests/FileSelectionPolicyTests.testExcludesOpusEntirely` asserts it stays out.
  Enabling Opus **requires updating that test** (documented deviation below).
- **No StoreKit anywhere.** No `.storekit` config, no entitlement type.
- **No EQ.** Playback is a single `AVPlayer`; `AVQueuePlayer`/`AVPlayerLooper`
  are used only for the ambient loop path (`AudioPlayer.swift:414`) and the
  design-system `LoopingVideoView`.
- **Track advance tears down** on `.AVPlayerItemDidPlayToEndTime`
  (`AudioPlayer.swift:230`) → `next()` → `loadCurrent`. No preloaded next item.
- **Cache limit** already user-selectable in Settings with presets 200 MB /
  500 MB / 2 GB / 10 GB (`SettingsView.swift:14`) — but **ungated**. Pro gating
  must hide the 2 GB/10 GB presets behind entitlement.
- **Prefetch depth** is a free `0…5` Stepper (`SettingsView.swift:130`,
  `AppState.prefetchDepth`). Must become free-capped-at-1 with Pro unlocking
  deeper values.
- **Folder watch** field exists (`Playlist.watch`, `IngestService.addFolder`
  `watch:` param) but nothing observes it. Pro folder-watch builds on this.

## Ground rules (unchanged intent)

1. No telemetry, no new network endpoints. On-device StoreKit 2 verification.
2. All Pro gating flows through `ProFeature.isEnabled(_:)`. `import StoreKit`
   permitted **only** under `Sources/Pro/` and the paywall view; add a CI grep
   guard to `.github/workflows/ios.yml`.
3. Never gate: formats, near-gapless, IA sources, local import, privacy.
4. Do not change `CacheStore` actor locking or `CachingResourceLoader.shutdown()`
   / `FileHandle` semantics without re-running `StreamingCacheTests` first — they
   guard the session-invalidation and interleaving crash modes.
5. Deployment target stays **iOS 18.0**.
6. Test fixtures: small public-domain IA files only, in `Tests/Fixtures/`.
7. Tests are **XCTest**, `@testable import Tonearm`, and must pass under the
   existing `TonearmTests` CI job (iPhone 17 Pro simulator).

---

## Phase 0 — Free-tier baseline lock (do first, tiny)

**T0.1 `FreeTierRegistryTests`.** New `Tests/FreeTierRegistryTests.swift`
asserting the free/paid split is what we intend, so later phases can't silently
gate an identity feature. Assert `ProFeature.allCases` contains exactly
`{cachePresets, prefetchDepth, folderWatch, eq, carplay}` (the *only* gated
things), and that a hard-coded list of identity capabilities
(`flac, opus, mp3, nearGapless, iaSources, localImport, privacy`) has **no**
corresponding `ProFeature` case. This test compiles only after T3.1 defines
`ProFeature`; land it in the same PR as Phase 3, but its spec is fixed here.
AC: test present and green in CI.

---

## Phase 1 — FLAC confirmation + selector ranking tests

Phase 1 is largely done; this phase *locks it down* and generalizes naming.

**T1.1 Codec ranking is explicit and tested.** Keep `FileSelectionPolicy` where
it is (do **not** invent a parallel `AudioFormatSelection.swift` — the selector
already lives in `ItemResolver.swift` and is unit-tested). Extend `pickPreferred`
to a clear ranked policy and add tests:
- Wi-Fi + `preferFLAC` on → FLAC chosen when present.
- Default → MP3 chosen, FLAC retained as `altFlacURL`.
- Per-item single-format-family rule preserved (grouping by own stem, see
  `ItemResolver.swift:120` comment).
AC: existing `FileSelectionPolicyTests` stay green; new ranking cases added.

**T1.2 FLAC through the cache path — verify.** Confirm
`CachingResourceLoader.contentType()` handles `.flac` filenames *with query
strings* (IA download URLs can carry `?cnt=…`). The current `pathExtension`
logic on `lastPathComponent` already strips query for path components, but add a
regression test asserting `contentType()` returns `org.xiph.flac` for a URL with
a query string. If it regresses, normalize by stripping query before extension.
AC: unit test for query-string extension mapping; manual device check of 16/44.1
and 24/96 FLAC stream + seek past cached prefix + relaunch resume.

---

## Phase 2 — Opus (free-tier feature)

Opus derivatives from IA are Ogg-encapsulated; AVFoundation won't demux Ogg, but
Opus-in-CAF plays natively. Strategy (from `01`/`decisions.md` D1/D2): **fetch
complete → remux Ogg→CAF → play the local `.caf`**, with an "Opus when ready"
policy so cold taps never wait.

**T2.0 Un-exclude Opus (deviation — update the guard test).**
- Add `opus` back to a *candidate* set in `FileSelectionPolicy`, but keep it out
  of the *cold-playable* set: an Opus-only group yields a track whose primary
  URL is the `.opus`, flagged so playback knows it needs remux-before-play.
- **Update `FileSelectionPolicyTests.testExcludesOpusEntirely`**: rename/rewrite
  to `testOpusAllowedButNotColdStreamed` — Opus now produces a track, but that
  track is not directly streamable (must go through the CAF pipeline). Document
  this reversal in `decisions.md` (new D9).
AC: rewritten test green; MP3+Opus item still prefers instant MP3/FLAC for cold
play but exposes the Opus derivative for the prefetch/remux path.

**T2.1 `Sources/Audio/Opus/OggPageReader.swift`.** Parse Ogg pages (capture
pattern `OggS`, header type / continuation flags, granule position, segment
lacing → packet reassembly). Parse `OpusHead` (channel count, pre-skip, input
sample rate) and skip `OpusTags`. Reject chained streams (multiple BOS) →
surfaced as a remux failure.
AC: `Tests/OggPageReaderTests.swift` over fixtures — multi-page packet reassembly,
nonzero pre-skip parsed, chained-stream rejected.

**T2.2 `Sources/Audio/Opus/CAFOpusWriter.swift`.** Write `caff` header, `desc`
chunk (`kAudioFormatOpus`, 48 kHz), `pakt` (`mNumberValidFrames`,
`mPrimingFrames` = OpusHead pre-skip, `mRemainderFrames` from final-page granule
vs decoded total), then the `data` chunk of concatenated Opus packets.
AC: `Tests/CAFOpusWriterTests.swift` — output opens via `AVAudioFile`; decoded
frame count == granule-derived count for every fixture; `mPrimingFrames` ==
OpusHead pre-skip (guards the start-click and trailing-gap traps in `01 §C`).

**T2.3 `Sources/Audio/Opus/OpusRemuxer.swift` + cache trigger.** Async,
cancellable file→file remux (reader→writer). Trigger points:
- When `CacheStore` marks an `.opus` key `complete` (see
  `CacheStore.recordWrite` completion branch, `CacheStore.swift:91`) **and** in
  the prefetch fetch path, remux to a sibling `.caf` in the same cache dir.
- On success: delete the raw `.opus`, keep the `.caf` (it is the cached
  artifact; `CacheStore.totalCachedBytes()` must account for it).
- On failure/cancel: delete any partial `.caf`, mark Opus session-unavailable
  for that key, fall back per policy. No user-visible error (local counter only).
AC: `Tests/OpusRemuxerTests.swift` — corrupted-fixture fallback; cancellation
mid-remux leaves no partial `.caf`; CAF byte count reflected in cache accounting.

**T2.4 "Opus when ready" policy in `AudioPlayer`.** In `loadCurrent`
(`AudioPlayer.swift:156`): if a remuxed `.caf` exists for the track's Opus key,
load it via `AVPlayerItem(url: file://…caf)` (the existing local-file branch
already handles `file://`). Otherwise cold-play FLAC (Wi-Fi) / MP3 (cellular) via
the current `remoteURLString` path. The free prefetcher (depth 1) fetches the
Opus derivative and remuxes so the *next* play/repeat upgrades to Opus.
AC: policy unit tests over synthetic IA file lists (extend `ItemResolver`/policy
tests); no added latency on cold tap (manual).

**T2.5 Near-gapless transitions.** Replace teardown-on-end with a preloaded next
`AVPlayerItem`:
- Maintain the queue's next item as a preloaded `AVPlayerItem` (cache delegate
  attached) and enqueue it just before the boundary rather than reacting to
  `.AVPlayerItemDidPlayToEndTime` with a fresh player.
- Have the time/end observers and `StallModel` observe the *item swap* rather
  than player teardown; `next()`/`previous()` still work.
- Leave the ambient `AVPlayerLooper` path (`AudioPlayer.swift:402`) untouched.
AC: `PlaybackResilienceTests`, `ShuffleRepeatTests`, `UpNextTests`,
`SleepTimerTests` stay green; manual seam check across MP3→MP3, FLAC→Opus,
Opus→Opus; fast track-skip stress clean (no "track 2 hangs").

---

## Phase 3 — Entitlement + Pro gates

**T3.1 `Sources/Pro/`.**
- `ProEntitlement.swift` — struct with **private init**, constructible only from
  a StoreKit-verified `Transaction` (via `Transaction.currentEntitlements`). No
  scattered booleans; verification is the only path to an instance.
- `ProFeature.swift` — `enum ProFeature: CaseIterable { case cachePresets,
  prefetchDepth, folderWatch, eq, carplay }` + `static func isEnabled(_:) -> Bool`
  reading a cached, UserDefaults-persisted verification result (with periodic
  revalidation) so airplane-mode users keep Pro.
- `ProStore.swift` (or similar) — the StoreKit 2 purchase/restore/observe surface;
  the **only** file besides the paywall that may `import StoreKit`.
- Add `Tonearm.storekit` product config and wire it into `project.yml`
  (Tonearm target resources + a `StoreKitConfiguration` on the test/run scheme;
  XcodeGen `scheme` settings).
AC: `.storekit`-driven `Tests/ProEntitlementTests.swift` — purchase, restore,
revocation, offline cached read.

**T3.2 CI import-boundary guard.** Add a step to the `test` job in
`.github/workflows/ios.yml` that greps `Sources/` for `import StoreKit` and fails
if it appears outside `Sources/Pro/` and the paywall view file.
AC: CI step present; passes on a clean tree, fails if StoreKit leaks.

**T3.3 Paywall sheet** per `tonearm-pro-mockups.html` screen 3. New
`Sources/Features/Settings/ProPaywallView.swift` (allowed to `import StoreKit`):
one-time price, five features, Restore Purchases, a GPL "build Pro from source"
line linking the repo, free-tier-facts footer. Present **only** from gated
touchpoints (never on launch, never interrupts playback). Link from the existing
About/Settings area (there is no `ContributionSupportView`; use the Settings
`aboutCard` region).
AC: snapshot tests light/dark (follow existing test style; if no snapshot infra
exists, assert view-model state instead of pixels); restore verified in
StoreKitTest.

**T3.4 Cache presets gating.** `SettingsView.presets` (`SettingsView.swift:14`)
already lists 200 MB/500 MB/2 GB/10 GB. Gate 2 GB & 10 GB behind
`ProFeature.cachePresets`: tapping a locked preset presents the paywall instead
of setting the limit. Free default stays 500 MB. Downgrade rule: entitlement lost
→ over-budget content evicts **lazily** via the existing
`CacheStore.evictToFit` (`CacheStore.swift:125`); never bulk-delete on launch.
AC: `Tests/CachePresetGateTests.swift` incl. the downgrade (lazy-eviction) case;
locked preset shows paywall.

**T3.5 Prefetch depth gating.** Change the Settings control
(`SettingsView.swift:130`) + `AppState.prefetchDepth` semantics: **free = 1**
(the value that powers near-gapless and Opus-when-ready — deliberately free, per
D7), **Pro = up to N / whole list** with a Wi-Fi-only toggle. Skipping a track
cancels its in-flight fetch (reuse `CachingResourceLoader.shutdown()` — read its
header first). `AudioPlayer.prefetchNext` (`AudioPlayer.swift:253`) already loops
over `prefetchDepth`; clamp to 1 unless `ProFeature.prefetchDepth`.
AC: `Tests/PrefetchDepthTests.swift` — free clamps to 1; Pro honors depth;
skip cancels in-flight; cache budget respected.

**T3.6 Folder watch (Pro).** Extend `IngestService` + `BookmarkVault`: persist
security-scoped bookmarks for watched folders (`Playlist.watch` + `folderBookmark`
already exist), rescan on app foreground, add an `NSFilePresenter` while active.
New files in a watched folder appear in the library without relaunch. Gate the
"watch this folder" toggle in the add-folder UI behind `ProFeature.folderWatch`.
AC: `Tests/FolderWatchTests.swift` — new file appears without relaunch (simulated
rescan); bookmark resolves after a cold start.

---

## Phase 4 — EQ (Pro)

**T4.1 `Sources/Audio/EQ/`.** `MTAudioProcessingTap` attached via
`AVPlayerItem.audioMix` (valid for the progressive/file assets this app plays).
10-band biquad cascade (31 Hz–16 kHz ISO bands), presets Flat / Concert hall /
Spoken / 78 rpm + user presets persisted alongside existing
`@AppStorage`/settings storage. Gate behind `ProFeature.eq`. Detach the tap in
the **same teardown path** that calls `CachingResourceLoader.shutdown()` /
`shutdownLoaders()` (`AudioPlayer.swift:210`); reattach on the preloaded next
item from T2.5 so EQ survives near-gapless swaps.
AC: `Tests/EQTests.swift` — bit-transparent bypass (offline render null test);
engage/disengage without playback interruption; no teardown crash under fast
skip.

---

## Non-goals this cycle

CarPlay implementation (own plan later; the entitlement case ships now) ·
FFmpeg / libopus · subscriptions · sample-accurate gapless / AVAudioEngine
migration.

## Deviations from `00`–`03` (record in `decisions.md`)

- **D9 — Opus is un-excluded.** The existing `testExcludesOpusEntirely` guard is
  rewritten; Opus becomes a free format via the CAF pipeline rather than being
  filtered out.
- **File layout differs.** Selector stays in `ItemResolver.swift` (no separate
  `AudioFormatSelection.swift`); new dirs are `Sources/Pro/`, `Sources/Audio/Opus/`,
  `Sources/Audio/EQ/`, `Tests/Fixtures/`.
- **iOS 18.0**, not 17.0.
- **No `ContributionSupportView`**; paywall links from the Settings About area.
- **Prefetch/cache controls already exist and are currently ungated** — Phase 3
  *adds gates* to existing UI rather than building it from scratch.

## Definition of done

All new tests green in the `TonearmTests` CI job · `FreeTierRegistryTests`
passing · CI StoreKit-import grep guard passing · no new network endpoints ·
`decisions.md` updated with D9 and the layout deviations before merge.
