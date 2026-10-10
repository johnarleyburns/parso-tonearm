# Fallback blend executor on AVAudioEngine: research (2026-10-09)

Scope: an AVAudioEngine-based two-deck executor inside Tonearm. It would play the lab's approved "dj2" blends
if ParsoDJEngine can't. No repo files were changed. The experiments below are Swift programs in
`scratchpad/exp/` (`latency.swift`, `sched.swift`, `sched2.swift`, `xover.swift`, `params*.swift`, `rt.swift`).
They ran on this Mac (macOS 26 / Darwin 25.5) at 48 kHz, offline and in realtime with the output muted.
**The numbers need re-checking on an iPhone**, but the behaviour is the same AudioToolbox units.

## TL;DR

1. **Don't run TimePitch live. Pre-render the incoming track once, offline,** with exactly the lab's chain
   (`apple-stretch/main.swift`: TimePitch at floor(r·512)/512 → Varispeed r/rep, or Varispeed only within
   ±0.2 %). Write it to a temp CAF and play it on a plain `AVAudioPlayerNode`.
   - The live graph then has no rate-changing units. Every player's timeline is the engine's sample
     timeline, and placement is plain integer sample arithmetic.
   - The phone also plays bit-for-bit what the lab measured.
   - It fits the algorithm, because the incoming track is tempo-matched ONCE and stays there.
2. Live TimePitch is workable but full of traps (measured below):
   - Realtime latency is 56–113 ms. It depends on the rate, differs from the unit's reported `latency`
     by up to 20 ms, and varies about ±0.5 ms from run to run.
   - Offline it is 0, so offline renders don't predict live timing.
   - The player's timeline runs at r× engine time, so `play(at:)` with an engine time lands about 95 ms
     off at r = 1.04.
3. **A real LR4 crossover is possible with stock `AVAudioUnitEQ`.** Its `.lowPass`/`.highPass` bands are
   exactly RBJ Butterworth (Q = 0.7071). Two cascaded bands per branch, fanned out and summed, give
   0.00 dB at every frequency, so the sum is all-pass.
   - Per-band gain automation with stock nodes is **not** sample-accurate. Mixer volume is de-zippered
     over about 1,000–1,500 samples, the `rampDuration` of scheduled events is broken, and
     AVAudioUnitEQ ignores scheduled events.
   - → Use one small **in-process AUv3 "DeckXover" effect**: LR4 split, plus band gains computed from
     the render timestamp against a published, precomputed blend plan. This is also where the DSP
     from `ProAudioTools.swift` gets reused.
4. Integration is the big cost, not the DSP:
   - Replace the AVPlayer path for the length of a mix: transport, time, Now Playing, interruptions,
     route/config changes, and a full local decode.
   - Lose AirPlay 2 enhanced buffering, unless the hybrid in §3.6 is used (offline engine →
     `AVSampleBufferAudioRenderer`).
5. Offline verification of the six lab pairs through `enableManualRenderingMode(.offline)` is
   straightforward. Caveat: it verifies the *pre-render design* exactly, but a *live-TimePitch* design
   only up to the latency differences above.

---

## 1. Graph design

### 1.1 Recommended graph (pre-rendered stretch)

```
deck A: AVAudioPlayerNode(scheduleSegment from track A [already at mix tempo]) ─▶ DeckXover AU (A) ─┐
deck B: AVAudioPlayerNode(scheduleSegment from stretched CAF of track B)       ─▶ DeckXover AU (B) ─┼▶ mainMixer ─▶ [Master ProAudio AU] ─▶ output
```

- **Stretch job:** a second `AVAudioEngine` in `.offline` manual rendering mode. It is
  `apple-stretch/main.swift` almost line for line.
  - It runs on a background task as soon as the next track is known and its file is fully local.
  - Output: Float32 or Int16 CAF in Caches.
  - Trim the chain's constant head offset. Measured offline: Varispeed adds exactly 48 samples
    (1.000 ms, `vs.latency` = 0.001). TimePitch adds +0.16…+1.34 ms in total depending on r, with
    ±0.3 ms jitter (from `latency.swift`). The lab already absorbed this, because groove placement was
    measured on the rendered CAF. On device, run the placement and groove check on the **same rendered
    file**, then nothing needs compensating.
  - Cost: disk is about 92 MB per 6-minute track as Float32 stereo at 44.1 kHz (46 MB as Int16).
    CPU is roughly a few seconds per track; benchmark on the oldest supported iPhone.
  - Per CLAUDE.md "no silent/magic background work", this job needs a visible status ("Preparing
    blend: stretching *Track* ×1.0145") with cancel and retry.
- **Players:** `AVAudioPlayerNode.scheduleSegment(_:startingFrame:frameCount:at:)` streams from file on
  AVFAudio's own threads, so no file I/O happens on the render thread. Memory is small: no whole-track
  buffers.
- **Placement:** start both players with one `play(at: AVAudioTime(sampleTime: T0, atRate: sr))`. The
  players then share the engine timeline exactly. Verified in `sched2.swift`: a varispeed-free deck
  scheduled at player time E produced its click at E, with no drift over 12 clicks.
  - The incoming segment is scheduled at
    `at: AVAudioTime(sampleTime: blendStartEngineSample - T0 + shiftSamples, atRate: sr)`.
  - Because both decks sit on one hardware clock, they cannot drift apart over minutes. The only drift
    left is inside the pre-rendered file, which the lab measured at under 0.005 ms/s with the n/512
    fix.
- **Sample-rate caveat:** the hardware runs at 48 kHz (sometimes 44.1 kHz on a route change). Render
  the CAF at the engine's output rate, or let the player node's implicit SRC convert. Both decks see
  the same converter, so relative timing holds. Re-measure once on device.

### 1.2 Live-stretch graph (if pre-rendering is rejected)

`player → AVAudioUnitTimePitch → AVAudioUnitVarispeed → DeckXover AU → mainMixer`. Measured
consequences:

- **Two player timelines.** A player behind rate units runs at r× engine rate. After 480,256 engine
  samples, `b.lastRenderTime.sampleTime` was 503,625 at r = 1.04.
  - `play(at:)` / `scheduleBuffer(at:)` times are in the **player's** timeline.
  - Passing an engine time gave −94.9 ms at r = 1.04, +104 ms at r = 0.96, and −2.75 ms at r = 1.0015
    (`sched.swift`).
  - Fix: start both players at a common engine time T0, then schedule at `P = r_eff·(E − T0)`, where
    `r_eff = rep·(r/rep)` computed exactly as the units receive it (Float). Offline this gave
    +1.0 ms ± 0.3 (`sched2.swift`).
- **Realtime latency** (`rt.swift`, muted): extra delay of the stretched deck against the plain deck.

  | r | measured | reported `tp.latency` |
  |---|---|---|
  | 0.95 | 113 ms | |
  | 0.97 | 101.5 ms | 86.7 ms |
  | 1.00 (TimePitch bypassed) | 86.3 ms | |
  | 1.0015 (bypassed) | 85.5 ms | |
  | 1.02 | 75.4 ms | |
  | 1.04 | 64.6–65.6 ms across runs | 83.7 ms |
  | 1.06 | 55.9 ms | |

  - The delay follows roughly 86 − 510·(r − 1) ms. The reported latency does not match it, so it
    **cannot be compensated from the unit's `latency` property**.
  - It also moved about 1 ms between identical runs.
  - **Bypassing TimePitch does not remove its latency in realtime.** That is useful for consistency:
    a deck can't change latency mid-stream by toggling bypass. It also means varispeed-only decks
    still carry about 85 ms.
  - Offline, the same units reported and added **0** latency (`latency.swift`). This matches the
    ~90 ms forum report only for realtime
    ([Apple Forums 708168](https://developer.apple.com/forums/thread/708168)).
- **Required consequences:**
  - Every deck goes through the same TimePitch + Varispeed chain, including the outgoing one.
  - Run a per-session **calibration render**: a click through the live chain into a tap, at the
    actual r.
  - Or measure B against A on taps during the first, inaudible bars of the blend (incoming highs at
    gain 0) and correct by a tiny varispeed trim before it becomes audible, as RESEARCH.md §6c
    describes.
  - All of this exists only to recover the ≤1 ms placement the pre-render gives for free.

### 1.3 LR4 crossover: options checked

| Option | Verdict |
|---|---|
| `AVAudioUnitEQ` ×2 per deck: 2×`.lowPass` @150 Hz, 2×`.highPass` @150 Hz, fan-out with `connect(_:to:[AVAudioConnectionPoint]…)`, each branch into a submixer | **Filters are correct.** The impulse response matches RBJ LR4 to 7 digits. Each band is −6.02 dB at 150 Hz; the sum is 0.00 dB from 20 Hz to 15 kHz with phase going through −180° at 150 Hz, i.e. a true all-pass (`xover.swift`). **Gains are the problem:** submixer `outputVolume` changes are block-quantized and de-zippered by a fixed linear ramp of about 1,000–1,500 samples (`sched2.swift`, `params2.swift`). `scheduleParameterBlock` on the mixer hits the sample time (±5 samples) but ignores `rampDuration` (it stalled at 0.95). On AVAudioUnitEQ, scheduled `globalGain` events did nothing. Good enough for the 4-bar highs fades if driven at ~50 Hz. Not good enough for the downbeat bass swap (a quarter-beat ramp completing ON the downbeat, ~110 ms at 128 BPM), and render quanta reach ~93 ms when the screen is locked (QA1606, below). |
| **Custom in-process AUv3 (`AUAudioUnit` subclass, `AUAudioUnit.registerSubclass`, `AVAudioUnit.instantiate`)** | **Recommended.** One effect per deck: LR4 split (4 biquads per channel, coefficients from `BiquadCoefficients.make(type: .lowPass/.highPass, frequency: 150, q: 0.70710678, sampleRate:)` in `Sources/Audio/EQ/ProAudioTools.swift:30,124-147`). Then `out = lo·gLo(t) + hi·gHi(t)`, with t = `timestamp.mSampleTime + i` (the render timeline downstream of any rate units = engine time). The blend plan (blend start sample, beat length in samples, curve kinds and positions, incoming gain) is a small POD published to the render thread lock-free. Curves are evaluated per sample, so the lab's `smooth()` (smoothstep) curves from `lock.mix_variants` (`lock.py:452-471`) reproduce exactly. In the idle state gains are 1 and 1, but the filter still runs: the deck is **always** in the crossover from its first sample, as the lab requires (README "Owner's verdict…"). |
| `AVAudioSourceNode` as the whole deck | Possible: ParsoDJEngine already does this (`parso-audio-engine/Sources/ParsoDJEngine/ParsoDJEngine.swift:217-259`). But then we own file streaming (a ring buffer fed off-thread, never disk on the render thread) and lose `scheduleSegment`. That is the start of re-writing ParsoDJEngine; avoid it. |
| `AVAudioSinkNode` | Input/sink only (WWDC19 510); can't sit mid-chain. Not applicable. |
| `MTAudioProcessingTap` (the existing `EQAudioTap.swift`) | **AVPlayerItem only** (it is attached through `audioMix`; `EQTapInstaller` in `parso-audio-engine/Sources/ParsoAudioPlayback/EQTapInstaller.swift`). It can't attach to engine nodes. **Reuse the DSP, not the tap:** `ProAudioRealtimeProcessor` (`Sources/Audio/EQ/ProAudioRealtimeProcessor.swift:17-81`) already follows the `RealtimeAudioProcessor` protocol, `processRealtime(AudioBufferListPointer, frameCount:)`, with main-thread compile → `os_unfair_lock` publish → render-thread `trylock` adopt. A second tiny AU "MasterProAudio" after the main mixer can call `processRealtime` directly, so the user's EQ, ReplayGain, crossfeed and convolution survive in engine mode. |

### 1.4 Real-time safety under Swift 6

- Build every render block in a `nonisolated static` factory that captures only raw pointers or
  `@unchecked Sendable` boxes.
  - A closure formed in a `@MainActor` context gets an isolation check that traps on the IO thread.
    The owner's own engine hit this (comment at `ParsoDJEngine.swift:233-245`).
  - `AudioPlayer` is `@MainActor` (`Sources/Audio/AudioPlayer.swift:8`), so nothing from it may be
    captured.
- The `AUAudioUnit` subclass is `@unchecked Sendable`. `internalRenderBlock` returns a block that
  captures an `UnsafeMutablePointer<DeckState>` allocated at init.
  - Keep `Biquad` state in fixed tuples or pointer memory. The existing `Biquad`
    (`Sources/Audio/EQ/EQEngine.swift:20-67`) keeps state in `[Double]` arrays; that is CoW-safe but
    does retain/release per sample, so don't copy that pattern into a new kernel.
  - Or write the 30-line kernel in C, in the existing `TonearmObjCSupport` target, which keeps Swift
    out of the hot path entirely. This matches CLAUDE.md's "no escape hatch without explanation" rule:
    document the `@unchecked Sendable` in place.
- Plan hand-off: copy the `ProAudioRealtimeProcessor` pattern (publish under `os_unfair_lock`, adopt
  with `trylock`).
  - Plans are tiny structs, so an atomic index into a double buffer (Swift `Synchronization.Atomic`,
    iOS 18+) is also fine.
- Events back to main (blend finished, segment ended) go through a lock-free flag polled by the
  existing 20 Hz ticker, like `DJEngine.pollEvents()`. Never post notifications from render.
- `scheduleSegment` completion handlers run on an internal AVFAudio thread. Hop to `@MainActor` with
  `Task { @MainActor in … }`. **Never stop a player inside its completion handler: it can deadlock**
  ([Apple Forums 72875](https://developer.apple.com/forums/thread/72875)). Use
  `completionCallbackType: .dataPlayedBack` for "track really finished" (WWDC17 501).
- Set `maximumFramesToRender` on the custom AUs to ≥ 4096: the screen-locked IO size
  ([QA1606](https://developer.apple.com/library/ios/qa/qa1606/_index.html)). AVAudioEngine normally
  propagates this, but a custom AU must allocate scratch for it at `allocateRenderResources`.

## 2. Sample-accurate scheduling

- **Pre-render design:** placement is integer arithmetic on one timeline. Measured: a buffer scheduled
  at player sample X with no rate units produced its first click at exactly X (+48 samples when a
  varispeed sat in the path, +0 without one).
  - `incomingStartPlayerSample = blendStartOutgoingPlayerSample + groove shift`, where the groove shift
    is the djmix `shift` (`djmix.py:155-166`, `shift = round(shift_t·SR)`).
  - The lab works at 44.1 kHz (`blend.py:16`). Rescale to the engine rate as a Double and round once.
  - The 1 ms requirement is about 44 samples, so integer rounding is irrelevant.
- **No drift for minutes:** one engine = one clock, and both player nodes are pulled in the same
  render cycle. The only drift is inside the stretched file: under 0.005 ms/s after the n/512 fix,
  versus 0.6–0.8 ms/s without it (README). Measured offline here: raw rate 1.01641 drifted +12 ms
  over 18 s; exact (n/512 + varispeed) drifted −0.19 ms. **Never put a stock `AVAudioUnitTimePitch.rate`
  on a deck without the n/512 split.**
- **Live-stretch design:** see §1.2. Schedule in each player's own timeline (P = r·(E − T0)). Calibrate
  the 56–113 ms rate-dependent latency on device, apply it to both decks, and re-calibrate after every
  configuration change, sample-rate change, or rate change.
- **Gain automation timing:** computed in DeckXover from the render timestamp, so it is sample-exact
  regardless of IO buffer size. Stock mixer-volume automation driven from the main actor lands at the
  next render quantum: 5–23 ms in the foreground, ~93 ms locked
  ([QA1606](https://developer.apple.com/library/ios/qa/qa1606/_index.html)), then smears over a
  ~25–30 ms ramp. Pinning `setPreferredIOBufferDuration` small keeps the quantum small even locked
  (same QA), at a battery cost.

## 3. Integration with Tonearm's AVPlayer-based `AudioPlayer`

Current state:
- `AudioPlayer` is a `@MainActor` singleton around `var player = AVPlayer()` (`AudioPlayer.swift:146`).
- It has a second `crossfadePlayer` for transitions (`:173`), a 0.5 s periodic observer
  (`AudioPlayer+Observers.swift:11-50`), `timeControlStatus` as the playing truth (`:57-88`), and a
  20 Hz `transitionTicker` (`AudioPlayer+Crossfade.swift:156-167`).
- Today's "beatmatched blend" uses `setRate(_:time:atHostTime:)` with `.spectral` time-pitch
  (`AudioPlayer+Transition.swift:144-150`, `TransitionPlayerControl.swift:37-43`) plus a rate-nudging
  drift loop (`AudioPlayer+Crossfade.swift:132-154`). That loop is exactly what the lab showed can't
  reach 1 ms. AVPlayer's `.spectral` is very likely affected by the same n/512 truncation (README:
  "likely … untested").

### 3.1 Hand-over model

Introduce a `MixEngineSession`, a `@MainActor` owner of the engine, decks and plans. `AudioPlayer`
delegates to it **for the whole mix queue** (`queueSource == .mix(...)`, or the "smart transitions
everywhere" path when an edge has a blend plan). Don't switch per transition:

- Switching from AVPlayer to the engine mid-track would need its own sample-exact hand-over, which
  AVPlayer can't do.
- The crossover must be in the path from the first sample.

So when a mix starts, the **first track already plays from the engine** (deck A); every track
alternates A/B. The `AudioPlayer` surface stays the same:
- `isPlaying`, `currentTime` and `duration` are published from the session's poll: `currentTime` =
  (`player.playerTime(forNodeTime: lastRenderTime)` − segment start) / sr.
- `next`/`previous`/`seek` map to stop + reschedule of the active deck. Seek within a deck is
  `stop()` + `scheduleSegment(startingFrame:)` + `play()`. A seek during a blend cancels the blend
  (fall back to a cut).

Seams to touch:
- `loadCurrent` (`AudioPlayer+Loading.swift:14-94`) branches to the session for mix queues.
- The `updateCrossfade`/`prepareCrossfadePlayer`/`finishCrossfade` family (`AudioPlayer+Crossfade.swift`)
  becomes AVPlayer-only.
- `handleTimeControlChange` gets an engine equivalent ("stalled" = the decode/stretch for the next deck
  isn't ready by the prepare deadline → downgrade to a phrase cut or plain fade, shown in UI as
  `transitionPrepState`, like `shouldDowngradeTransition` at `AudioPlayer+Transition.swift:136`).

### 3.2 Now Playing / remote commands

`PlaybackPlatformBridge` (`Sources/Audio/PlaybackPlatformBridge.swift:10-48`) is already transport
agnostic. `SystemPlaybackBridge.refreshNowPlaying` reads only `player.currentTrack`, `duration`,
`currentTime` and `isAdvancing` (`Sources/App/SystemPlaybackBridge.swift:101-144`), so it keeps working
if the session feeds those `@Published` values.

- With AVPlayer gone, iOS no longer infers elapsed time. Publish `MPNowPlayingInfoPropertyElapsedPlaybackTime`
  on every state change and at the track flip, which `refreshNowPlayingTime` already does.
- Set `MPNowPlayingInfoCenter.playbackState` explicitly (needed on macOS; harmless on iOS).
- When does Now Playing switch to the incoming track: at the bass swap (musically "the new track") or
  at blend end? Pick the swap; persistence (`AudioPlayer+Persistence.swift`) should record the incoming
  track at the same point.

### 3.3 Session, interruptions, route and configuration changes

- The session stays `.playback` (`SystemPlaybackBridge.swift:21-25`). Add
  `routeSharingPolicy: .longFormAudio` only if going the §3.6 route.
- Interruptions: the existing observer calls `pausePlayback`/`resumePlayback`
  (`SystemPlaybackBridge.swift:78-98`). With an engine, iOS **stops the engine** on interruption. On
  `.ended` you must reactivate the session, `engine.start()`, and re-`play()` the players. Their
  schedules survive a pause but **not a stop**.
- `AVAudioEngineConfigurationChange` (route or sample-rate change, AirPlay or CarPlay connect,
  headphones): the engine is stopped and its nodes uninitialized. **Player nodes are reset and
  every scheduled buffer and segment is purged; the player timeline returns to 0**
  ([forum 769907](https://developer.apple.com/forums/thread/769907),
  [772380](https://developer.apple.com/forums/thread/772380);
  [AVAudioPlayerNode docs](https://developer.apple.com/documentation/avfaudio/avaudioplayernode)).
  The session must therefore:
  1. snapshot each deck's source-frame position;
  2. rebuild and reconnect at the new output format;
  3. reschedule both segments from those positions with a common T0;
  4. re-publish the blend plan rebased to the new T0.

  The pre-render design makes this easy, because positions are plain frame indices into fixed files.
  In the live-stretch design you must also re-calibrate latency.
- If a route change happens **inside** a blend, resuming mid-blend sample-exact is possible
  (pre-render), but the glitch from the route change itself is unavoidable. Accept it.
- `routeShouldPause` (headphones out) already pauses (`SystemPlaybackBridge.swift:54-76`). Map it to
  `engine.pause()` (keeps schedules), not `stop()`.

### 3.4 AirPlay / CarPlay

- CarPlay is just an output route (`Sources/App/CarPlay/CarPlaySceneDelegate.swift` keeps state in
  `AudioPlayer`), so the engine works; handle the config change above.
- **AirPlay:** an AVAudioEngine app outputs to AirPlay as a realtime route, without AirPlay 2
  **enhanced buffering**. Enhanced buffering needs AVPlayer/AVQueuePlayer or
  `AVSampleBufferAudioRenderer` + `AVSampleBufferRenderSynchronizer` with the session's
  `.longFormAudio` route-sharing policy
  ([WWDC17 509](https://nonstrict.eu/wwdcindex/wwdc2017/509/),
  [Playing custom audio with your own player](https://developer.apple.com/documentation/avfaudio/playing-custom-audio-with-your-own-player),
  [WWDC23 10238](https://developer.apple.com/videos/play/wwdc2023/10238/)). Expect more dropouts on
  weak Wi-Fi than the AVPlayer path has. Relative deck timing is unaffected: both decks are mixed
  before output.
- `AirPlayButton.swift` (`AVRoutePickerView`) keeps working.

### 3.5 Streaming remote tracks, decode and memory

- AVAudioFile/ExtAudioFile **can't read from the network** or through the `CachingResourceLoader`
  (an `AVAssetResourceLoader` delegate on `tonearm-cache://` URLs, `AudioPlayer+Loading.swift:116-140`).
  The engine needs a **complete local file** for both decks before the blend's prepare deadline.
  Paths:
  - Already local: managed `relPath`, bookmarks, built-ins, complete cache blobs
    (`AudioCache.completeCacheExists`, `Sources/Audio/AudioCache.swift:59-61`), and remuxed Opus CAFs
    (`AudioCache.cafURL(forRemoteOpus:)`, `:65-67`).
  - **Pitfall:** complete cache blobs are **extensionless** (Jamendo `format=mp32`;
    `AudioPlayer+Loading.swift:119-131`). AVPlayer plays them only via `AVURLAssetOverrideMIMETypeKey`,
    and `AVAudioFile(forReading:)` may refuse to sniff them. Use
    `AVAudioFile(forReading:commonFormat:interleaved:)` on a hard-link or copy with the right extension,
    or decode through `AVAssetReader` (which accepts the MIME-overridden `AVURLAsset`) into the
    stretch job.
  - Opus CAF: AVAudioFile reads Opus-in-CAF on iOS 17+ (verify on the minimum OS). Otherwise decode
    with `AVAssetReader`.
  - The stretch job (§1.1) is the natural place for this decode, so its input can be any of these.
  - Not yet downloaded: force a full prefetch of the next track. `prefetchNext`
    (`AudioPlayer+Prefetch.swift`) and `protectCacheKeys` already exist. If it isn't complete by
    T − (stretch time + margin), downgrade that edge to the AVPlayer-style plain fade or a phrase cut,
    and say why in `transitionPrepState`.
- **Priming:** AAC/MP3 encoder delay must be handled the same way the analysis did. AVAudioFile trims
  AAC priming (TN2258); the lab decodes with ffmpeg. RESEARCH.md §6a already flags this. A mismatch is
  a constant offset per file of up to about 26 ms, which **is** a train wreck at the 1 ms target.
  Either analyse on device with the same decoder, or store `decoderOffsetSamples`. Pre-rendering and
  then measuring on the rendered file sidesteps it for the incoming deck; the outgoing deck's grid
  must still come from the same decoder.
- **Memory:** with `scheduleSegment` from files, the decks hold only AVFAudio's internal read-ahead
  (a few hundred KB). Whole-track `AVAudioPCMBuffer`s would be 6 min × 48k × 2 ch × 4 B = 138 MB each,
  ~276 MB for two decks: avoid them. Disk: one or two stretched CAFs alive at a time; delete them once
  played.
- **Watch is not affected:** all of `AudioPlayer` is `#if !os(watchOS)` (`AudioPlayer.swift:1`). The
  watch uses its own `WatchApp/WatchPlayer.swift` on AVPlayer. The macOS app (`MacPlaybackBridge.swift`)
  would get the engine path too; it has no AVAudioSession, so interruption handling is a no-op there.

### 3.6 Optional hybrid: keeps AirPlay 2 buffering and removes realtime-thread risk

- Run the whole two-deck graph (players, DeckXover AUs, mixer) in an engine in **offline** manual
  rendering mode, pulled by our own serial queue a few seconds ahead.
- Wrap the rendered PCM into `CMSampleBuffer`s and enqueue them into an `AVSampleBufferAudioRenderer`
  under an `AVSampleBufferRenderSynchronizer`.
- Gains:
  - Sample-exact by construction, and the same code path as offline verification.
  - AirPlay 2 enhanced buffering, plus the synchronizer timebase for Now Playing.
  - Route and config changes don't purge anything: the offline engine isn't attached to hardware.
- Costs:
  - Pause, seek and skip need `flush`/re-render, with latency of whatever is enqueued ahead.
  - The user's ProAudio EQ changes take effect late by that lead (keep the lead around 1–2 s).
  - More code than a plain realtime engine.
- **Worth prototyping if AirPlay matters to the owner.**

## 4. Offline verification (six lab pairs)

- **Feasible, with a small lab change.** `out/dj2/summary.json` stores marks and the check result, but
  not the executor inputs. Have `djmix.py` emit a per-pair plan JSON: `a_path`, `b_stretched`
  (the apple-chain CAF), `shift` (samples at 44.1 kHz), `exit_s`, `n_ov`, `pa`, `gain`, the curve
  times, and style (bass-swap, double-drop, or phrase-cut for techno and deep-house).
- A Swift CLI (sibling of `apple-stretch`) builds the **exact production graph**:
  - two `AVAudioPlayerNode`s;
  - `DeckXover` AUs, registered in-process with `AUAudioUnit.registerSubclass` — usable from a CLI,
    since registration is per process;
  - main mixer.
- It enables `enableManualRenderingMode(.offline, format: 44.1k stereo Float32, maximumFrameCount: 4096)`,
  schedules exactly as the app would, `renderOffline` loops to the end, and writes a **16-bit WAV**.
  That format matters: `djmix.check_mix` reads `<i2` via `wave` (`djmix.py:189-200`). Then run
  `check_mix` / `groove.offset` on it and compare against the dj2 files: a sample diff should be
  ≈ 0 apart from the filter implementation (ffmpeg `acrossover` vs RBJ cascade), and groove offset
  should be PASS ≤ 3 ms.
- **Caveats:**
  1. Offline TimePitch has **0 latency**; realtime has 56–113 ms. Offline renders validate the
     pre-render design fully, but don't validate live-TimePitch placement.
  2. In manual rendering, `play()` without a time started 256 samples late against `play(at:)`
     (`sched.swift`). Always use explicit `AVAudioTime(sampleTime:)` starts in both modes.
  3. The engine must not be running in realtime when manual rendering is enabled. Use a separate
     `AVAudioEngine` instance, as `apple-stretch` does.
  4. Offline mode needs every node to be pull-able: no input node.
  5. ffmpeg's `acrossover order=4th` (LR4) and the RBJ cascade differ slightly in coefficients and
     warping near Nyquist: −186 vs −179 dB at 15 kHz in the low band. Inaudible, but compare by
     groove and click metrics, not bit-exactness.
  6. Apple docs: [Performing offline audio processing](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing);
     [WWDC17 501 "What's New in Audio"](https://nonstrict.eu/wwdcindex/wwdc2017/501/) introduced
     manual rendering.
- The same CLI can render **realtime-mode-equivalent** checks for the live-stretch design only through
  `.realtime` manual rendering driven by a thread. That still isn't the hardware IO path, so the
  calibration in §1.2 would need a device test anyway.

## 5. Effort, risks, pitfalls

**Effort** (one experienced engineer, pre-render design):

| Item | Days |
|---|---|
| Stretch/decode job with visible status and cancel (CLAUDE.md) | 2–3 |
| DeckXover AUv3 + C kernel + plan publish | 2–3 |
| `MixEngineSession`: decks, scheduling, A/B alternation, seek/skip/pause, completion events | 4–6 |
| `AudioPlayer` delegation for mix queues; Now Playing, time and persistence parity | 3–4 |
| Interruptions, config change, route change, CarPlay and AirPlay testing | 3–5 |
| Offline verification CLI + lab plan JSON | 1–2 |
| Device tuning (latency re-checks, older phones, background IO size, thermal) | 2–4 |
| **Total** | **~3–5 weeks** |

The §3.6 hybrid adds about 1–2 weeks. Live-stretch instead of pre-render saves the stretch job but adds
calibration and re-calibration, about the same total, and carries more risk.

**Against ParsoDJEngine:**
- ParsoDJEngine already has decks, a mixer, EQ, keylock (Signalsmith, MIT), a headless offline
  renderer (`HeadlessDJEngine`, `ParsoDJEngine.swift:754-835`), graph recovery on config change
  (`recoverGraph`, `:168-181`), and an `AVAudioSourceNode` host that is Swift-6-safe.
- Its risks are integration and maturity (a C engine in the app, a 4-deck default profile, and the
  Signalsmith 6.6/11.3 ms jitter versus Apple's 6.4/10.2 ms).
- The AVAudioEngine fallback's advantages: zero new native dependencies, a stretcher the owner has
  already **approved by ear** (dj2 was rendered through this exact Apple chain), and lab parity when
  pre-rendering.
- Its disadvantages: more glue code on the Swift side, and AirPlay buffering unless §3.6.
- The integration work in §3 (hand-over, Now Playing, interruptions, local decode, priming) is
  **shared by both executors**. Do it once, behind an executor protocol, and the fallback costs mostly
  §1–2.

**Apple API pitfalls (most were verified here):**
1. `AVAudioUnitTimePitch.rate` is truncated to n/512 (lab). Re-verified: +12 ms drift over 18 s at
   ×1.01641 raw, −0.19 ms with the split.
2. Realtime TimePitch latency is about 56–113 ms and rate-dependent. It ≠ the reported `latency`,
   jitters about 1 ms between runs, is **kept when bypassed**, and is **0 offline**.
3. Player timeline behind rate units = source frames (r× engine). `play(at:)` / `scheduleX(at:)` take
   player time.
4. `play()` without a time starts at an unspecified render boundary: +256 samples offline here.
5. Stopping a player purges schedules and resets its timeline to 0. A configuration change stops the
   engine and does the same to every player.
6. Never stop or reschedule a player from inside its completion handler (deadlock).
7. Mixer `outputVolume` is de-zippered over ~1k samples, is block-quantized, and its scheduled
   `rampDuration` is non-functional. AVAudioUnitEQ ignores scheduled parameter events. Its
   `.lowPass`/`.highPass` are correct Butterworth biquads (an LR4 from two cascaded is exact).
8. The IO buffer grows to 4096 frames when the screen locks unless `preferredIOBufferDuration` is set.
   Custom AUs must handle `maximumFramesToRender` ≥ 4096.
9. Swift 6: render and completion closures formed in `@MainActor` context trap on the audio thread.
   Use `nonisolated static` factories (pattern at `ParsoDJEngine.swift:233-259`).
10. AirPlay 2 enhanced buffering isn't available to a realtime AVAudioEngine; only AVPlayer or
    sample-buffer renderers with `.longFormAudio`.
11. AVAudioFile needs local, sniffable files: extensionless cache blobs and resource-loader URLs don't
    work.
12. Decoder priming must match between analysis and playback (TN2258); otherwise expect a constant
    offset per file.
13. `MTAudioProcessingTap` (the existing EQ path) doesn't exist in the engine world. Port the
    `RealtimeAudioProcessor` DSP into an AU instead.

## Sources
- [Apple Developer Forums 708168: AVAudioUnitTimePitch latency ~0.09 s](https://developer.apple.com/forums/thread/708168)
- [Forums 769907: AVAudioEngineConfigurationChange clearing AVAudioPlayerNode](https://developer.apple.com/forums/thread/769907)
- [Forums 772380: Handling AVAudioEngine configuration change](https://developer.apple.com/forums/thread/772380)
- [Forums 72875: scheduleBuffer / completion-handler deadlock](https://developer.apple.com/forums/thread/72875)
- [AVAudioPlayerNode documentation](https://developer.apple.com/documentation/avfaudio/avaudioplayernode)
- [Technical Q&A QA1606: IO buffer 4096 frames when screen locked](https://developer.apple.com/library/ios/qa/qa1606/_index.html)
- [WWDC17 501 What's New in Audio (manual rendering)](https://nonstrict.eu/wwdcindex/wwdc2017/501/)
- [Performing offline audio processing](https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing)
- [WWDC19 510 What's New in AVAudioEngine (source/sink nodes)](https://developer.apple.com/videos/play/wwdc2019/510/)
- [WWDC17 509 Introducing AirPlay 2](https://nonstrict.eu/wwdcindex/wwdc2017/509/)
- [WWDC23 10238 Tune up your AirPlay audio experience](https://developer.apple.com/videos/play/wwdc2023/10238/)
- [Playing custom audio with your own player (AVSampleBufferAudioRenderer)](https://developer.apple.com/documentation/avfaudio/playing-custom-audio-with-your-own-player)
- Tonearm lab: `tools/blend-lab/README.md` (n/512, crossover-from-first-sample, dj2 groove), `RESEARCH.md` §5–6
