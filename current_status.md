# Current Status

Session working from `docs/plans/tonearm-mvp-ios/` — the operating brief is
`HANDOFF.md`, the implementation spec is `PLATTERHEAD_IOS_ARCHITECTURE.md`, and
the commit sequence is **Appendix M.1/M.2** of that spec. The M2 working plan is
`docs/plans/dj-phase-2-semantic.md` (commit sequence §5, audit table §9), the M3
working plan is `docs/plans/dj-phase-3-autoplaylists.md` (commit sequence §5,
audit table §9).

## Milestone

**M4 — the two-deck engine, `AVAudioSession`, and StoreKit** (the 3.0 Pro launch,
spec §48.5, Appendix M.5), working from `docs/plans/dj-phase-4-engine.md`. **In
progress** — plan commit first, then 4.1–4.13. M3 (auto-playlists,
`docs/plans/dj-phase-3-autoplaylists.md`) is **complete** — commits 3.1–3.5 are all
on `main` (AT-PLIST-3 harness in 3.5 closed the last gate); its user-owned ship
gates (AT-PLIST-2 on-device timing, AT-PLIST-7 listening) are deferred to a post-M4
device pass. M2 (CLAP semantic embeddings + tiered vector store,
`docs/plans/dj-phase-2-semantic.md`) is complete; M1 (analysis stages 1–2 + thermal
governor) is fully committed.

## Commits on `main`

- **M4 4.7** — `91580c0` `feat(dj): iPhone portrait solo-deck surface (M4 commit 4.7)`.
- **M4 4.6** — `2bc6d4a` `feat(dj): dual-deck sync + telemetry + iPad workspace (M4 commit 4.6)`.
- **M4 4.5** — `c628e99` `feat(dj): time-stretch/key-lock/key-shift via AVAudioUnitTimePitch (M4 commit 4.5)`.
- **M4 4.4** — `6e3c0e9` `feat(dj): mixer — 3-band EQ, sweep filter, crossfader, master limiter (M4 commit 4.4)`.
- **M4 4.3** — `e595254` `feat(dj): single-deck play/cue/loop, sample-accurate (M4 commit 4.3)`.
- **M4 4.2** — `40903e7` `feat(dj): audio-session decision table and coordinator (M4 commit 4.2)`.
- **M4 4.1** — `211f431` `feat(dj): RT boundary — command ring, snapshot, RTGuard, offline engine harness (M4 commit 4.1)`.
- **M4 gate** — `a7615e5` `test(dj): AT-PLIST-8 gate 2.0s → 2.5s — owner runs Low Power Mode on AC`.
- **M4 plan** — `5e8b731` `docs(dj): M4 plan — real-time engine, audio session, purchase (3.0 Pro launch)`.
  Working plan for milestone M4 per handoff §8. Resolved decisions recorded up front:
  **`guru.parso.tonearm.pro` is repurposed as the single DJ product** — no `.pro.dj`,
  no Founders grant, T.4 collapses to one row (commits in 4.13); **deployment floor
  raised to iOS 18 / macOS 15 / watchOS 11** so the RT command ring uses the stdlib
  `Synchronization.Atomic` (no swift-atomics, no C shim); **`AVAudioSession` lives only
  in `Sources/DJ/Session/`** with a pure route/interruption decision table
  (`SessionPolicy`) so AT-SESS-\* is testable off-device; **offline engine harness =
  `AVAudioEngine` manual rendering** on the macOS host; the user-owned AT-THERM-1 and
  M3 ship gates (AT-PLIST-2/7) deferred to a single post-M4 device pass.
- **M3 (complete):** plan `c2415a5`; 3.1 `87155e5`; 3.2 `94ed3eb`; 3.3 `c7abb86`;
  3.4 `8e6d628`; 3.5 `98825bb` (AT-PLIST-3 shuffle-comparison harness closed the last
  gate). M2 (complete): plan `dbd01df`; model conversion `42cb3fd`; 2.1 `cba52bf`;
  2.2 `a0c1291`; 2.3 `3879013`; 2.4 `b9f5bb4`; 2.5 `45ecc8c`; plus `c6de224`
  (Play at any browse depth + Jellyfin demo onboarding). M1 commits
  `dd9cc35`…`fc81f2e`.

## Working on

**M4 commit 4.7 — iPhone portrait solo-deck surface — complete (`91580c0`).**
The §42.6–42.7 compact posture over the shared `WorkspaceModel` (mockups
`iphone/05a`, `iphone/05b`):

- `Features/Workspace/SoloDeckView.swift` — one focused deck full-width
  (header pills, playhead + BPM readout, waveform, CUE/PLAY/SYNC/LOOP
  transport, hot-cue pads, bank chips `Stems · EQ · Filter · Cues · Jog`),
  the other deck in a **72 pt strip** (identity, BPM, state, playhead,
  play/pause); **swipe-up or tap swaps focus — view-only**, both decks stay
  live in the engine, no engine state changes (FR-ENG-10, §42.1). The
  crossfader lives in the **always-visible bottom bar** (the whole strip is a
  1:1 relative drag surface) and the browse-while-performing crate sheet may
  never cover it: the sheet renders *behind* the bar and its height is bounded
  by the model's pure `WorkspaceModel.crateSheetMaxHeight` rule. 44 pt min
  targets, haptic confirm via the new `Features/Common/Haptics.swift`
  (NFR-A11Y-3). Free users see the real dimmed surface + lock chip (§40.4).
- `WorkspaceModel` gains the compact-posture state — `focusedDeck` +
  `swapFocus` (no engine call), `isCrateSheetPresented` raise/dismiss, and the
  static `crossfaderBarHeight`/`crateSheetMaxHeight` geometry bound.
  `WorkspaceEngine` gains `sampleRate` so playheads render as clock time; the
  iPad workspace's `TransportButton`/`Pill`/`EQGroup`/`EQKnob`/`VerticalSlider`
  are shared across both surfaces (promoted to internal).
- Tests: 3 new `WorkspaceModelTests` — focus swap is view-only (engine records
  zero calls, telemetry untouched), the sheet never covers the crossfader over
  a spread of container heights, raising the sheet changes no engine state.
  Full suite 1132 green (1129 baseline + 3). Swift 6 guard OK. No
  `xcodegen generate`. **FR-ENG-9/10, §42.6–42.7.**
- **Decision (recorded):** the crate-sheet track rows (gig crate ranked by the
  §28A.2 transition cost against the playing deck) and track titles/keys are
  deferred — the workspace has no library data seam yet — so the sheet carries
  the honest placeholder like the waveform/stems baselines; the normative
  geometry rule is what this commit ships.

- **M4 commit 4.6 — dual-deck sync + telemetry + iPad workspace — complete.** The
§32 sync engine, the §40.3 telemetry pipeline, and the single session VM over
the `ipad/07` workspace:

- `Engine/SyncEngine.swift` — the pure §32.3 kernel: `SyncClock` (playhead +
  grid + rate), `SyncCorrection`, and `correction`/`downbeatCorrection`/
  `continuousRate`. `DeckGrid` gains `beatPhase(at:)`/`barPhase(at:)`.
  `PerformanceEngine.sync/unsync`: the pure correction is applied as a rate
  command + a scheduled sample-accurate nudge (`RTCommand.syncNudge`), then
  `.sync` engages **continuous rate tracking** — the render thread re-derives
  the synced deck's rate every callback so a master pitch change moves the
  synced deck with it (§32.1).
- Telemetry: the graph publishes per-callback relaxed atomics — deck
  rate/level (peak measured in the deck chain and the post-limiter bus)/
  playing/synced, plus the `MasterClock` components (master sample, effective
  BPM, downbeat phase) — assembled by `AudioGraph.masterClock` (the §30.1
  snapshot). `EngineTelemetry` + `EngineTelemetryStream` (atomics →
  `AsyncStream`, newest-1); `PerformanceEngine.sampleTelemetry/pushTelemetry/
  telemetry`. `Features/Common/TelemetryPump.swift` — `CADisplayLink` (iOS) /
  `NSScreen.displayLink` (macOS test host), ProMotion 60–120 Hz, throttled to
  30 Hz at `.serious`, paused backgrounded.
- `Features/Workspace/` — `WorkspaceModel` (the one session VM over the
  `WorkspaceEngine` protocol, mixer control state, idle-timer scoping §34A.6
  driven from telemetry) + `WorkspaceView` (two decks, centre mixer: vertical
  EQ stacks, filter sliders, crossfader, master meter, limiter indicator,
  beat-phase meter, thermal/buffer readout; SYNC tap=beat/hold=downbeat),
  gated by `ProCapability.isEnabled(.decks)` — free users see the real dimmed
  surface + lock chip (§40.4). **Decision (recorded):** the `MasterClock`
  snapshot is three relaxed atomics assembled control-side (a ≤1-callback skew
  is harmless for a relative nudge + display-rate readouts), not a
  reverse-direction double-buffered pointer — the render thread cannot
  allocate/lock.
- Tests: 12 pure `SyncMathTests` + 4 new `EngineOfflineTests` (sync aligns
  beats on the master grid, continuous rate tracks a master pitch change then
  unsync freezes, bar sync aligns downbeats, telemetry/master-clock readouts
  exact) + 8 `WorkspaceModelTests` (gate, lifecycle, forwarding, the
  atomics→stream pipeline). Full suite 1129 green (1105 baseline + 24). No
  `xcodegen generate`. **FR-ENG-1/2/4, FR-ENG-9; AT-ENGINE-SYNC-\*.**

- **M4 commit 4.5 — time-stretch / key lock / key shift — complete (`c628e99`).**
The §31 time-pitch wiring, with a per-deck `AVAudioUnitTimePitch` in the graph
and a pure cent-math core:

- `Engine/TimePitch.swift` — `TimePitchMath` (pure `rateFromPercent`,
  `centsFromRate` = 1200·log2(r), `semitoneCents`,
  `pitchCents(rate:keyLock:keyShiftSemitones:)`), `TimePitchSettings` (per-deck
  rate/keyLock/keyShift → `unitPitchCents`, plus `effectiveKeyShiftSemitones`
  for the UI's Camelot hint), `TimePitchUnit` (`AVAudioUnitTimePitch` wrapper,
  music parameters — transient-preserving mode asserted, RT-safe `apply` that
  skips unchanged values so an idle deck costs no parameter traffic).
- `Engine/RTCommand.swift` — `setKeyLock`/`setKeyShift` tags; `DeckState`
  gains the keyLock/keyShift state; `PerformanceEngine` gains
  `setKeyLock`/`setKeyShift` on the same lock-free command path.
- `Engine/AudioGraph.swift` — `Configuration.timePitch` engages a §29.1-shape
  per-deck `source → unit → main mixer` topology (the offline pitch tier).
  Both deck source nodes drain the ring (first drain applies every command,
  second finds it empty) so application is independent of engine pull order;
  the master clock advances in `render()` so both decks read the same
  pre-advance `frameStart` within a callback. **Decision (recorded):** the deck
  reader stays the tempo authority (frame-exact, per the 4.4 decision) and the
  unit carries only the key compensation — `unitRate` held 1.0,
  `unitPitch` = (keyLock ? −1200·log2(rate) : 0) + 100·semitones — so every
  frame-exact reader test stays bit-exact while FR-ENG-6 holds observably
  (spike-verified: reader 528 Hz + unit −316¢ → 440 Hz).
- Tests: 8 pure `TimePitchTests` (golden cent conversions; keyLock holds,
  vinyl follows, semitone-ratio rules) + 6 new `EngineOfflineTests` on the
  time-pitch graph that measure the **dominant frequency by zero crossings**
  over a steady window (keyLock on at rate 1.2 holds 440 Hz; keyLock at unity
  transparent; keyLock off follows rate to 528 Hz; ±1 semitone at `2^(±1/12)`;
  keyShift compounds under keyLock to 440·2^(1/12), not 528·2^(1/12)). Full
  suite 1105 green. No `xcodegen generate`. **FR-ENG-6, AT-ENGINE-\*.**

- **M4 commit 4.4 — mixer: EQ / filter / crossfader / limiter — complete (`6e3c0e9`).**
The §35 mixer DSP, wired into the deck render path and the master bus:

- `Engine/Mixer.swift` — `LinkwitzRiley` (LR4: two cascaded 2nd-order Butterworth
  biquads per band; the low/high sum is an exact all-pass — flat magnitude at
  unity, phase-coherent kills), `ThreeBandEQ` (200 Hz / 2 kHz splits, smoothed
  gains, `knobToGain` maps −1 kill … 0 unity … +1 = +6 dB), `SweepFilter`
  (state-variable HP/LP, hard-bypassed at centre, 12 kHz → 300 Hz sweep),
  `crossfaderGains` + `CrossfaderCurve` (constantPower / linear / sharp, the
  spec's §35.4 function verbatim), `SmoothedGain` one-pole ramps so fader moves
  never click, `LookaheadLimiter` (delay-line lookahead, soft-knee gain that
  provably never exceeds the ceiling, instant attack / slow release), and the
  graph wiring `DeckMixer` (per-channel EQ→filter→fader→crossfader chain) +
  `MasterStage` (crossfader position/curve + per-channel limiter).
- `Engine/RTCommand.swift` — `setEQ`/`setFilter`/`setFader`/`setCrossfader` tags
  and an `f2` payload slot for the three band gains.
- `Engine/AudioGraph.swift` — each deck's chain runs per sample in `readChunk`;
  the master stage applies crossfader gains per deck each callback and the
  limiter over the summed bus. `Configuration` gains `limiterCeiling`/
  `limiterLookaheadFrames`.
- `Engine/PerformanceEngine.swift` — `setEQKnobs` (knob→gain), `setFilter`,
  `setChannelFader`, `setCrossfader` — all enqueue lock-free commands.
- Tests: 16 pure `MixerTests` (crossfader laws + power identity, smoothed gain,
  EQ magnitude-flat/kill/knob anchors, filter bypass/LP/HP/cutoff, limiter
  ceiling/lookahead/transient-prediction/brickwall) + 5 new `EngineOfflineTests`
  (EQ kill silences the graph, filter bypass frame-identical, fader halves the
  deck, constant-power crossfader blend at full-A/full-B/centre, master limiter
  clamps the graph output). Full suite 1091 green. No `xcodegen generate`.
  **Decisions:** the deck chain is a bit-exact pass-through until a control is
  touched (EQ idle until `setEQ`, filter bypassed at centre, crossfader idle
  until positioned) so the 4.3 frame-exact reader harness stays valid; the
  limiter is out of the path unless a ceiling is configured (reader harness
  runs without it, mixer tests configure it). **FR-ENG-2, FR-ENG-7 (master
  path), AT-ENGINE-\*.**

- **M4 commit 4.3 — single-deck play/cue/loop, sample-accurate — complete (`e595254`).**
The deck reader replaces the 4.1 sine scaffold (§29–30, §33), driven only through
the command ring:

- `Engine/DeckClock.swift` — `DeckClock` (absolute master sample, §30.1), `DeckGrid`
  (beat grid for quantize), `QuantizeResolution`, and `DeckSource` — a **pure-value**
  pre-decoded PCM source that crosses the RT boundary as a raw pointer: no ARC, no
  lock, no allocation (§12.3).
- `Engine/Scheduler.swift` — pure `quantizedBoundary(after:resolution:grid:)` and
  `triggerFrame(...)`: the exact master-timeline frame a trigger lands on (§30.3).
- `Engine/CueLoop.swift` — pure loop end/wrap math + the `TempCueState`
  press-jump-preview / release-return machine (§33).
- `Engine/AudioGraph.swift` — two `DeckState` readers over a zeroed baseline
  (both decks sum; paused/unloaded decks render **silence, not garbage**, and bump
  the §46.2 starved counter). Loop wrap and quantized cue jumps **split the buffer
  at the exact frame** (§30.2). Master clock + per-deck playheads publish via
  relaxed atomics (§30.1). `RTCommand` gained seek/setCue/cuePress/cueRelease/
  triggerHotCue/setLoop/exitLoop/setQuantize, an `i1` slot, and `setPitch` →
  `setRate` (§31.1).
- `Engine/PerformanceEngine.swift` — the `@MainActor` façade (App. I.4):
  `load/play/pause/cue/seek` + `setQuantize`, hot cues, CDJ-style loops — all
  enqueue lock-free commands, none block on audio. `load` boxes the `DeckSource`
  (the §12.2 ownership-transfer marker) and owns the box lifetime.
- `EngineOfflineTests` — 25 green on the macOS host: a hot cue lands on the exact
  frame; a loop wraps end→start frame-exact; a **quantized trigger lands on the
  grid boundary mid-buffer** (sample 24 000, split inside a 4096 chunk); playhead
  telemetry exact; temp-cue press/release returns to the pre-preview position;
  dual-deck sum + pause-freeze; no-buffer renders silence (§46.2); pure
  quantize/loop/cue math; 10 s render never overruns. **FR-ENG-1/5, AT-ENGINE-\***
  (offline-render tier; physical timing is user-owned — plan §2.11). Full suite
  1070 green; no `xcodegen generate` (DJ excluded from app target).

- **M4 commit 4.2 — `SessionPolicy` + `AudioSessionCoordinator` — complete
  (`40903e7`).** Pure §34A route/interruption decision table (mode buffers,
  granted round-trip, every §34A.3/34A.4 row, never-auto-play) + the thin
  `#if canImport(AVAudioSession)` coordinator shell (category→prefs→activate→
  read-back, Bluetooth refusal, media-services reset). 20 `AudioSessionMatrixTests`
  green. **FR-SESS-1/2/3/4, AT-SESS-\* decision matrix.**

- **M4 commit 4.1 — RT boundary + RTGuard + offline engine harness — complete
  (`211f431`).** `RTCommand` (POD, `@unchecked Sendable`) + `CommandRing` (fixed
  power-of-two SPSC, stdlib `Atomic<Int>` head/tail, release/acquire, never grows);
  `EngineSnapshot` (double-buffered `Atomic<UnsafeRawPointer?>` publish/read, control-side
  retire list); `RTGuard` (DEBUG thread-local render flag, RELEASE compiles out); `RenderLoad`
  (`mach_absolute_time`, one relaxed atomic store); `AudioGraph` (offline manual-rendering
  `AVAudioEngine` harness; render block captures ring/snapshot/load/probe/state, not `self`).
  `EngineOfflineTests`: 12 green — ring FIFO/full→false/empty/pointer round-trip; snapshot
  publish/read/retire; RTGuard flag + nested context; RenderLoad measure/reset; offline render
  vs sample-referenced sine; pause-mute + frozen-phase resume; **setPitch at exact frame 100
  (±5e-4)**; RTGuard wraps the render; 10 s/512-frame render with 21-command bursts renders
  every frame, bounded output, load < 1.0. **FR-ENG-1, NFR-PERF-1, NFR-PERF-2; the RT half of
  AT-ENGINE-\*.**

**Gate adjustment (`a7615e5`, owner decision):** the AT-PLIST-8 30k-candidate beam
gate was **2.0 s → 2.5 s**. Root cause found: not load — the owner's **Low Power Mode
on AC** caps CPU clocks on this M2. Measured 1235 ms with LPM off, 2040–2073 ms with
LPM on, identical across load averages 63 → 2. Owner keeps LPM on sometimes, so the
gate sits at 2.5 s (still under the 3 s budget).

## Next

- **M4 commit 4.8** — `JogGestureModel` (pure) + `JogView`: the pure
  contact-relative rotation state machine (radius split fixed at touch-down,
  sensitivity 0.5–2.0, `scrub/nudge/hold/release` intents only, no SwiftUI
  import) + the `CADisplayLink`-rendered jog off the telemetry pump, Core
  Haptics detents, position marker + phase ghost (§40.7; FR-ENG-11, AT-TWIN-4).
  The `Jog` bank chip on the 4.7 solo deck swaps in the real jog. Then 4.9
  (TwinDeckView + orientation switch) … 4.13 (paywall + purchase + memory
  ceiling). Ship gates AT-ENGINE-\*, AT-SESS-\*, AT-STORE-\*, AT-TWIN-\*;
  **AT-THERM-1 is the user-owned shipping gate**, run after the milestone on a
  real device (deferred per decision 4 of the M4 kickoff).

## After M4

- **2.6 — Tier B sqlite-vec** (deferred): blocked on the user-owned §50.3
  real-device FR-SEM-3 measurement.
- **M1 exit-gate leftovers** (blocked, user-owned): paid products in App Store
  Connect; Plex claim token + cloud OAuth registrations into `.test-credentials`.

## Standing rules in play

Work on `main`, one commit per numbered task, no `Co-Authored-By` trailer (owner
preference). **Ask before `git push`** (push triggers CI + TestFlight). Every commit
runs the full local suite in the pre-commit hook (allow ~5 min). `xcodegen generate`
after project.yml changes (DJ-only file additions under `Sources/DJ/**` need no regen —
the app target excludes `DJ/**`; TonearmDJ is the SPM target). No new network hosts,
no new dependencies, no StoreKit outside `Sources/Pro/`, no `#if os(...)` around DJ
core modules. Swift 6 language mode + strict concurrency, warning-free.

**Known flakes / environmental gates:**
- `OnsetTests.testNoiseDoesNotProduceSpuriousPeaks` (DSPTests.swift:174) uses
  `SystemRandomNumberGenerator`, so `peaks.count < 3` is nondeterministic — blocked
  one commit attempt (3 vs 3) then passed on retry. Worth a separate seed-fix commit.
- `SequencerTests.testThirtyThousandCandidateBeamStaysInsideBudget` — gate raised
  2.0 s → 2.5 s (`a7615e5`, owner decision). Root cause was Low Power Mode capping
  CPU clocks (1235 ms off, ~2.05 s on), not load; measured stable across load
  averages 63 → 2. At the 2.5 s cap it passes in both states.
