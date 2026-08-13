# DJ Phase 4 — Real-time engine, audio session & purchase (Milestone M4)

Plan for milestone **M4** of the Platterhead iOS DJ build. Implementation is driven by this file
one commit at a time, on `main`, per handoff §8 and the working agreement in
`docs/plans/tonearm-mvp-ios/HANDOFF.md`.

**Spec:** `docs/plans/tonearm-mvp-ios/PLATTERHEAD_IOS_ARCHITECTURE.md`. Read §48.5 (goal/exit),
Appendix M.5 (manifest + commits), §4.5 (FR-ENG-1..12), §4.5a (FR-SESS-1..5), §4.6 (FR-STORE),
§12 (RT model), §29–35 (graph, clock, time-pitch, sync, cue/loop, latency, session, mixer), §40
(UI pattern + jog model), §41.9/41.9a (iPad workspace + module slot), §42.1/42.6/42.7/42.7a/42.7b
(compact postures + bank drawer), §41.15/41.16 + §42.10 (paywall), §43.5 (memory ceiling), §46.3
(RT guard), §49, Appendix I.4 (PerformanceEngine façade), Appendix T (entitlement). **Appendix
M.5's commit order is authoritative; §49.2's implementation order (pure kernels → façade/actor →
view model → view) is binding.**

## 1 · Milestone goal and exit (spec §48.5)

The Pro launch: a real-time two-deck DJ engine — `AVAudioEngine` graph (§29), master clock and
sample-accurate scheduler (§30), time-stretch / key lock (§31), beat sync (§32), cues/loops with
quantized triggering (§33), and the deck + mixer architecture with 3-band EQ, filter, crossfader
and master limiter (§35) — behind the main-actor `PerformanceEngine` façade (Appendix I.4) with a
lock-free command ring at the RT boundary (§12). The **audio session** (§34A, the highest-risk
work in the plan) lands in the same milestone so its failures surface immediately. Both iPhone
postures (solo deck portrait, twin deck landscape) and the iPad workspace run over **one shared
`WorkspaceModel`**. The contextual paywall and purchase flow (AT-STORE-2: decks unlock with no
relaunch) complete the milestone. The free tier keeps everything it has (§2.4 — the paywall's
non-negotiable line).

**Exit (§48.5):** AT-ENGINE-\*, AT-ENGINE-SYNC-\*, AT-SESS-\*, AT-STORE-\*, AT-TWIN-\* green; a
**60-minute two-deck session inside NFR-THERM-1** (the user-owned shipping gate, deferred to a
post-M4 device pass — §2.4); a purchase that unlocks the decks without a relaunch (AT-STORE-2).
`make test-swift` green; app builds; **ship 3.0 — Pro launch.**

## 2 · Resolved spec-vs-repo decisions (recorded up front)

1. **`guru.parso.tonearm.pro` IS the DJ product — no `.pro.dj`, no Founders grant.**
   The app has never published and has no buyers, so the "retired remote-libraries product" never
   existed in the wild. The user repurposes the existing identifier as the single DJ
   non-consumable (strategy §5.2: $39.99, founding price $24.99, Family Sharing on). Consequences
   to land in commit 4.13:
   - `ProEntitlement.productID` is already `guru.parso.tonearm.pro` — unchanged.
   - `FoundersGrant` collapses: `djProductID == retiredProductID == "guru.parso.tonearm.pro"`,
     and the T.4 decision table becomes one row — *verified ownership of `guru.parso.tonearm.pro`
     ⇒ Pro* (with the family-shared/revoked branches that survive). `FoundersGrantTests` is
     rewritten to the single-product table (the current dual-product rows cannot compile once the
     two IDs are equal). `AT-STORE-4` still covers every row of the new table.
   - `Resources/Tonearm.storekit` carries exactly one product (done in this commit): the
     repurposed `guru.parso.tonearm.pro` at $39.99, "Platterhead DJ".
   - No App Store Connect work is required to start M4 (nothing to create, nothing to retire).
   - `EntitlementStore.Source.purchased`'s doc comment ("bought guru.parso.tonearm.pro.dj") and
     `foundersGrant`'s doc comment are corrected.
2. **Deployment floor raised to iOS 18 / macOS 15 / watchOS 11.** The app target is already iOS
   18.0 (`project.yml`); only the SPM package floor (`Package.swift`) moves, and the spec's
   platform references follow. Reason: the engine's lock-free SPSC command ring (§12.2) uses the
   **stdlib `Synchronization.Atomic`** (`Atomic<Int>`, `Atomic<UnsafeRawPointer?>`) for head/tail
   and the double-buffered snapshot pointer — available from iOS 18 / macOS 15 / watchOS 11. No
   swift-atomics package, no C shim, no new Appendix Q entry. The RT contract is unchanged:
   acquire/release ordering via `Atomic`'s `load(order:)`/`store(order:)`/`compareExchange`,
   pre-allocated ring, never any lock or allocation on the render thread.
3. **`AVAudioSession` lives only in `Sources/DJ/Session/` — the one sanctioned platform-conditional
   module** (§9.2, §49.3.6). The engine core (`Engine/`) is `#if os`-free. `AudioSessionCoordinator`
   is `#if canImport(AVAudioSession)`-guarded internally so the SPM package still builds for the
   `swift test` macOS host; on non-iOS platforms it exposes a minimal stub (the pure decision
   logic is what the tests exercise). macOS has no `AVAudioSession`, so the §34A.3 route-change
   response table (§2.4, commit 4.2) is extracted as a **pure function** tested on every host; the
   thin shell marshals real notifications on iOS.
4. **The §34A route/interruption decision table is pure.** `RouteChange`/`Interruption` →
   `SessionResponse` (pause decks / re-read granted / rebuild graph / restore transports) is a
   deterministic pure mapping in `Sources/DJ/Session/SessionPolicy.swift`, unit-tested as
   `AudioSessionMatrixTests` across every AT-SESS row's *decision* on macOS, with the thin
   `AudioSessionCoordinator` shell doing only notification marshalling + `AVAudioSession` calls on
   iOS. This is what makes AT-SESS-* testable without a device and keeps the coordinator honest.
5. **Offline engine harness = `AVAudioEngine` manual rendering.** `EngineOfflineTests` drive the
   real graph in `enableManualRenderingMode` (no hardware) on the macOS host, inject scripted
   `RTCommand`s, and assert sample-accurate output: a cue lands on the exact frame, a loop wraps
   seamlessly, sync aligns phase, EQ/filter/crossfader/limiter shape the buffer. The RTGuard shim
   (§46.3) runs inside every offline render to catch RT-unsafe calls. This is the §47.2 "engine
   integration, deterministic" tier and it runs in `make test-swift`. The pure math (phase
   correction, jog gestures, quantize targets, limiter) is unit-tested separately.
6. **Stems are architecturally present, functionally M5.** The deck is built as four summed stem
   voices (§35.1) so the graph never needs rewiring when stems land, and the stem-fader UI renders
   the *honest* unavailable state when a track has no prepared stems (FR-ENG-3's full-mix
   fallback, §36.5). `StemSeparator` itself (Demucs Core ML, §36) is M5 — not in this milestone.
   `DeckModuleSlot` still **defaults to `STEMS`** per §41.9a (the slot shows the honest disabled
   faders until M5).
7. **No recording, no hardware, no sync in M4.** §37 recording is M5; §44 MIDI/USB routing and
   §39A Watch are M6. The `PerformanceEngine` façade (Appendix I.4) ships the transport/tempo/
   sync/cue/loop/mixer surface only; the recording/hardware members are stubbed as `fatalError`-free
   `TODO` throws (never called) or omitted until their milestone. M4's graph keeps the cue/mix
   routing architecture (§29.1) so M5/M6 slot in without a rebuild, but only master-out is active.
8. **The jog is pure and touches the engine only via transport intents** (§40.7.7, FR-ENG-11):
   `JogGestureModel` is a pure value-type state machine (contact-relative rotation, radius split
   fixed at touch-down, sensitivity 0.5–2.0) with no SwiftUI import, and `JogView` renders from
   the `TelemetryPump` via `CADisplayLink`, never from the render thread. AT-TWIN-4 asserts under
   the §46.3 shim.
9. **One `WorkspaceModel` for every performance surface** (Appendix M.5): `SoloDeckView`,
   `TwinDeckView` and the iPad `WorkspaceView` are additional views over the single session VM.
   Orientation is the only mode switch (§42.1); rotating changes no engine state (FR-ENG-10,
   AT-TWIN-1).
10. **The paywall consumes `EntitlementStore.isPro`, never imports StoreKit** (§6.3): `PaywallView`
    (+ model) in `Sources/DJ/Features/Paywall/` reads the injected `@Published isPro` and calls
    `EntitlementStore.purchase()`/`restore()` — the StoreKit-boundary functions added to
    `EntitlementStore` in commit 4.13 (kept in `Sources/Pro/`, the CI allowlist). Copy per §41.16/
    §42.10/T.7: one-time price, "yours forever", Family Sharing, restore, the explicit "everything
    you have now stays free" line, the GPLv3 source note, **no countdown / no strikethrough / no
    scarcity**. The optional single 10-minute trial (FR-STORE-6) is **not** implemented in M4 —
    the paywall is contextual-only, per §40.4 (never on launch, never on a timer, never over
    playback).
11. **The on-device numbers are user-owned and deferred to a post-M4 pass.** AT-THERM-1 (60-minute
    two-deck session, battery, 50% brightness, never `.critical`, §43.7) and the M3 leftovers
    (AT-PLIST-2 on-device timing, AT-PLIST-7 listening) run together on a real device **after** the
    milestone, per the user's decision. The automated proxies land in M4's tests: `MemoryCeiling`
    unit tests against fabricated `task_vm_info` samples, `RenderLoad` math tests, the pure
    §34A decision matrix, and the offline engine render suite.
12. **`RenderLoad` measures inside the render callback with `mach_absolute_time`** (§34.3) and
    publishes one relaxed `Atomic` store; the UI reads it at display cadence. No timing work
    crosses the RT boundary. The 0–1 load is what `WorkspaceView`'s CPU% reads.
13. **No new network host, no new dependency.** Everything is AVFoundation / Accelerate / CoreML /
    Metal / CoreMIDI (already linked in `TonearmDJ`) plus the stdlib `Synchronization` module.
    `Sources/DJ` stays excluded from the app target, so DJ-only additions need **no
    `xcodegen generate`**.
14. **`GlassFeature` and `UIBackgroundModes` already exist** in the app (`project.yml` carries
    `UIBackgroundModes: [audio]`; Liquid Glass is `GlassFeature.isEnabled`, floor now iOS 18).
    M4 adds `isIdleTimerDisabled` scoping (on while any deck plays, restored the moment both stop,
    §34A.6) to the engine, never to a view's lifetime.

## 3 · File manifest (Appendix M.5, paths indicative per handoff §6.4)

New directories: `Sources/DJ/Engine/` (RT core), `Sources/DJ/Session/` (platform-conditional),
`Sources/DJ/Perf/`, `Sources/DJ/Features/{Prep,Workspace,Common,Paywall}/`. Tests under
`Tests/DJTests/`. `Sources/DJ` stays excluded from the app target (handoff §2 trap), so DJ-only
file additions need **no `xcodegen generate`**.

| File | Purpose |
|---|---|
| `Engine/RTCommand.swift`, `CommandRing.swift` | POD `RTCommand` (tag + union), fixed-capacity SPSC ring, `Atomic<Int>` head/tail, acquire/release (§12.2) |
| `Engine/EngineSnapshot.swift` | double-buffered atomic snapshot: `Atomic<UnsafeRawPointer?>` publish/read, off-RT retire list (§12.2) |
| `Engine/RTGuard.swift` | DEBUG RT-assertion shim — thread-local `inRenderContext`, asserts on alloc/lock/log (§46.3) |
| `Engine/AudioGraph.swift` | `AVAudioEngine` graph + source nodes, deck reader, master/cue routing (§29) |
| `Engine/DeckClock.swift`, `Scheduler.swift` | master clock in absolute samples, sample-accurate event scheduling, quantize targets (§30) |
| `Engine/TimePitch.swift` | `AVAudioUnitTimePitch` rate/key-lock/shift wiring (§31) |
| `Engine/SyncEngine.swift` | **pure** `correction(master:synced:at:)` phase/tempo math (§32) |
| `Engine/CueLoop.swift` | cues/loops/quantized triggers — render-side playhead arithmetic (§33) |
| `Engine/Mixer.swift` | 3-band EQ, filter, crossfader, limiter — the §35 DSP in the deck source node / master stage |
| `Engine/RenderLoad.swift` | `mach_absolute_time` render metering, relaxed atomic publish (§34.3) |
| `Engine/PerformanceEngine.swift` | main-actor façade (App. I.4); command-ring enqueue, telemetry stream |
| `Session/AudioSessionCoordinator.swift` | `#if canImport(AVAudioSession)`-guarded coordinator: modes, buffer negotiation, route/interruption handling, graph rebuild (§34A) |
| `Session/SessionPolicy.swift` | **pure** route/interruption → response decision table (§34A.3–34A.4) |
| `Perf/MemoryCeiling.swift` | `task_vm_info` sampling, shed order, refuse-load at 95% (§43.5, NFR-REL-4) |
| `Features/Common/TelemetryPump.swift` | `CADisplayLink` pump, ProMotion-aware, throttled at `.serious` (§40.3) |
| `Features/Prep/TrackPrepView.swift` + model | mockup `ipad/06-track-preparation.html`; grid tools + cue pad row |
| `Features/Workspace/WorkspaceView.swift` + `WorkspaceModel.swift` | mockup `ipad/07-dj-workspace.html`; **the** one session VM |
| `Features/Workspace/SoloDeckView.swift` | iPhone portrait: focus + strip + always-reachable crossfader (§42.6–42.7; `iphone/05a`, `iphone/05b`) |
| `Features/Workspace/TwinDeckView.swift` | iPhone landscape: both decks resident, jog each, momentary banks (§42.7a; `iphone/05c`, `iphone/05d`) |
| `Features/Workspace/JogGestureModel.swift` | **pure** contact-relative rotation → scrub/nudge/hold/release, radius split, sensitivity (§40.7.2–40.7.4) |
| `Features/Workspace/JogView.swift` | `CADisplayLink` render off telemetry; position marker + phase ghost (§40.7.5, §40.7.7) |
| `Features/Workspace/BankDrawer.swift`, `EdgeSlider.swift` | the five modal idioms + two rules (§42.7b); `.defersSystemGestures(on: .bottom)` lives here |
| `Features/Workspace/DeckModuleSlot.swift` | iPad `JOG · STEMS · PADS · FX`, persisted per deck, **default `STEMS`** (§41.9a) |
| `Features/Paywall/PaywallView.swift` + model | mockups `ipad/13a`, `ipad/13b`, `iphone/08` — copy rules per §40.4 + App. T.7 |
| `Tests/DJTests/{EngineOfflineTests,SyncMathTests,AudioSessionMatrixTests,JogGestureModelTests,MemoryCeilingTests}.swift` | offline-render assertions, phase math, AT-SESS-\* matrix, jog purity, memory policy |

## 4 · Data layer — no new migration

M4 adds no tables. The engine reads `track` (for loaded decks: pre-decoded PCM via the existing
decode substrate + `track_embedding` where M2 pooled vectors exist), `cue_point`, `loop`, and
`grid_correction` — all live in `dj_v1` (verified in `DJMigrations+v1.swift`). The DB work in M4
is read-side only (`DJTrackRepository`/`DJLibraryStore` already cover it); grid corrections
(`grid_correction`) are *written* by commit 4.12's Track Prep through the existing
`DJLibraryStore` write path. No `DJMigrations+v5.swift`.

## 5 · Commit sequence (Appendix M.5)

### Commit 4.1 — RT boundary + guard + offline engine harness

- `Engine/RTCommand.swift` + `CommandRing.swift` (§12.2): POD `RTCommand` (tag + deck + i0/f0/f1
  + optional `UnsafeRawPointer` for an armed source), fixed power-of-two SPSC ring with
  `Atomic<Int>` head/tail (stdlib `Synchronization`, §2.2), producer `tryPush` / consumer `drain`
  with release/acquire ordering, pre-allocated, never grows.
- `Engine/EngineSnapshot.swift`: double-buffered `Atomic<UnsafeRawPointer?>` publish, off-RT
  retire list (§12.2).
- `Engine/RTGuard.swift` (§46.3): DEBUG thread-local flag + `assertRTSafe`; the offline harness
  wraps every render in it.
- `Engine/RenderLoad.swift` (§34.3): `mach_absolute_time` measured render time, one relaxed
  atomic store, `loadRatio` = time/period.
- `Tests/DJTests/EngineOfflineTests.swift`: the manual-rendering `AVAudioEngine` harness —
  an offline `AudioGraph` with a known sine-buffer source, scripted commands through the ring,
  RTGuard active; assert frame-exact command application, ring full/empty behaviour, and
  no-RT-unsafe-call under the shim. 30k-style load sanity: the harness renders a long offline
  buffer with no overrun.
- **FR-ENG-1, NFR-PERF-1, NFR-PERF-2; the RT half of AT-ENGINE-\*.**

### Commit 4.2 — `AudioSessionCoordinator` + route/interruption matrix

- `Session/SessionPolicy.swift` (§2.4): **pure** `Response(for routeChange:)` /
  `Response(for interruption:)` per §34A.3's table — `.oldDeviceUnavailable` ⇒ pause both decks;
  `.newDeviceAvailable` ⇒ re-read `Granted`, re-negotiate buffer, notify cue router; category/
  override/config-change ⇒ re-read + re-assert; sample-rate change ⇒ rebuild graph; `.began` ⇒
  flush segment + capture playheads + interrupted banner; `.ended` with `.shouldResume` ⇒
  re-activate, rebuild if rate/channel changed, restore paused (never auto-play), open new
  recording segment.
- `Session/AudioSessionCoordinator.swift` (`#if canImport(AVAudioSession)`): three modes
  (listening / performing / performing+talkover, §34A.1), ordering **category → preferences →
  activate → read back → build graph** (§34A.2), `Granted` always read back (FR-SESS-2), route/
  interruption notification marshalling, `mediaServicesWereReset` ⇒ rebuild path (§34A.4),
  Bluetooth-while-performing ⇒ FR-SESS-4 warning with measured `roundTripMillis`.
- Tests: `AudioSessionMatrixTests` — every §34A.3/34A.4 row's decision, plus Bluetooth,
  `Granted.roundTripMillis` math, never-auto-play after interruption.
- **FR-SESS-1/2/3/4/5, AT-SESS-\*** (decision matrix; the physical route events are user-owned on
  a device — §2.11).

### Commit 4.3 — single-deck play/cue/loop, sample-accurate

- `Engine/AudioGraph.swift` + `DeckClock.swift` + `Scheduler.swift` + `CueLoop.swift` (§29–30,
  §33): one source node reading pre-decoded PCM, master clock in absolute samples, scheduler
  checks `[frameStart, frameStart+frameCount)` against loop/cue boundaries each callback and
  splits the buffer at the exact frame (§30.2). Transport: play/pause/cue/seek. Hot cues (from
  `cue_point`), temporary CDJ-style cue (press-jump-preview / release-return), loops with
  `[start,end)` wrap, quantized targets from the deck's grid snapshot.
- `Engine/PerformanceEngine.swift`: the main-actor façade gains `load/play/pause/cue/seek` +
  `setQuantize`, all enqueuing RT commands (never blocking).
- Tests: `EngineOfflineTests` — a cue scheduled at frame N lands exactly at N; a loop wraps
  `end→start` frame-exact; quantized trigger lands on the grid boundary; playhead telemetry is
  exact; deck-with-no-buffer renders silence, not garbage (§46.2).
- **FR-ENG-1/5, AT-ENGINE-\*.**

### Commit 4.4 — mixer: EQ / filter / crossfader / limiter

- `Engine/Mixer.swift` (§35): 3-band isolator EQ (Linkwitz–Riley splits, full kill, ±6 dB),
  state-variable HP/LP sweep filter (bypassed exactly at centre), channel fader (trim),
  crossfader (constant-power / linear / sharp, §35.4), master brickwall limiter (lookahead,
  soft-knee, §35.5). Smoothing = one-pole ramp on gains so fader moves never click.
- Graph: deck source node runs the deck's EQ/filter chain in its render block; master bus →
  limiter → output (recording tap architecture stubbed for M5, §2.7).
- Tests: offline render with known inputs — EQ unity at 12 o'clock is flat, kill is −∞, filter
  centre is bypass, crossfader constant-power sums to constant magnitude, limiter never lets
  output exceed ceiling. Pure unit tests for the DSP blocks + `crossfaderGains`.
- **FR-ENG-2, FR-ENG-7 (master path), AT-ENGINE-\*.**

### Commit 4.5 — time-stretch / key lock / key shift

- `Engine/TimePitch.swift` (§31): `AVAudioUnitTimePitch` per deck — `rate` = 1 + percent/100
  (tempo), `pitch` = `1200·log2(rate)` cents when key-lock off, held constant when on; ±N
  semitone key shift via `pitch` with rate held (§31.3). Parameters set for music
  (transient-preserving, §31.2).
- Tests: offline render of a known-frequency tone — with key lock on, tempo change preserves
  pitch (frequency constant over a measured window); key lock off, pitch follows rate; a +1
  semitone shift moves the measured frequency by the expected ratio. Pure math assertions for the
  cent conversions.
- **FR-ENG-6, AT-ENGINE-\*.**

### Commit 4.6 — dual-deck sync + telemetry + iPad workspace

- `Engine/SyncEngine.swift` (§32): **pure** `correction(master:synced:atMasterSample:)` —
  targetRate = masterBPM/syncedBPM, phase delta in (−0.5, 0.5], sample shift from
  `samplesPerBeat`, downbeat-aware option (§32.2). `PerformanceEngine` gains `sync/unsync`
  (continuous rate tracking while engaged) applying the correction as a scheduled sample-accurate
  jump (§32.1).
- `Engine/EngineSnapshot.swift` publishes the `MasterClock` snapshot read once per callback
  (§30.1). `EngineTelemetry` (deck playheads, effective BPM, phase, levels, renderLoad) via
  atomics → `AsyncStream` (§40.3, App. I.4).
- `Features/Common/TelemetryPump.swift` (§40.3): `CADisplayLink`, ProMotion-aware, throttled to
  30 Hz at `.serious`, suspended backgrounded.
- `Features/Workspace/WorkspaceModel.swift` + `WorkspaceView.swift` (mockup `ipad/07`): the single
  session VM; two decks, centre mixer (vertical EQ stacks, filter, crossfader, master meter,
  limiter indicator, beat-phase meter, thermal + buffer readout), transport + sync + loop per
  deck, `.defersSystemGestures(on: .bottom)`, idle-timer scoping (§2.14). Gated by
  `ProCapability.isEnabled(.decks)` — free users see the real dimmed surface with the lock chip
  (§40.4, §41.15).
- Tests: `SyncMathTests` (phase math vs known grids, downbeat alignment, determinism),
  `EngineOfflineTests` (sync aligns beats on the master grid), model tests with a fake engine
  (states, gate).
- **FR-ENG-1/2/4, FR-SESS, FR-ENG-9; AT-ENGINE-SYNC-\*.**

### Commit 4.7 — iPhone portrait solo-deck surface

- `Features/Workspace/SoloDeckView.swift` (§42.6–42.7, mockups `iphone/05a`, `iphone/05b`): one
  focused deck full-width (waveform, transport, cues, bank chips incl. **Jog**), the other deck in
  a 72-pt strip, swipe/tap swap (view-only, both live), always-visible crossfader bottom bar,
  browse-while-performing crate sheet that may never cover the crossfader (§42.7). Over the shared
  `WorkspaceModel`. 44 pt minimum targets, haptic confirm (NFR-A11Y-3).
- Tests: `WorkspaceModel` compact-state tests — focus swap is view-only, engine state unchanged;
  sheet never covers crossfader frame.
- **FR-ENG-9/10, §42.6–42.7.**

### Commit 4.8 — `JogGestureModel` (pure) + `JogView`

- `Features/Workspace/JogGestureModel.swift` (§40.7.2–40.7.4): pure value-type state machine —
  contact-relative angular displacement, radius split (platter 58% = position/scratch-nudge,
  ring 42% = pitch bend) **fixed at touch-down** (a drag crossing the boundary must not change
  mode), sensitivity 0.5–2.0, emits `scrub/nudge/hold/release` intents only. No SwiftUI import.
- `Features/Workspace/JogView.swift` (§40.7.5, §40.7.7): `CADisplayLink` render off the telemetry
  pump, position marker + phase ghost (other deck's beat), Core Haptics detents (iPhone).
- Tests: `JogGestureModelTests` — rotation→scrub/nudge, radius split fixed across a boundary-
  crossing drag, sensitivity scaling, release, determinism; AT-TWIN-4 under the RTGuard shim
  (no jog code on the render thread).
- **FR-ENG-11, AT-TWIN-4.**

### Commit 4.9 — `TwinDeckView` + orientation switch

- `Features/Workspace/TwinDeckView.swift` (§42.7a, mockup `iphone/05c`): both decks resident,
  jog each (168 pt), stacked waveforms on one shared playhead, 202-pt mixer column (beat-phase
  meter, channel faders, SYNC tap=beat/hold=downbeat, crossfader), 54×54 transport, filter edge
  sliders, `.defersSystemGestures(on: .bottom)`.
- Orientation is the only switch (§42.1): portrait → `SoloDeckView`, landscape → `TwinDeckView`,
  both over the one `WorkspaceModel`; rotating mid-playback changes **no** engine state.
- Tests: `WorkspaceModel` orientation tests — rotation preserves transport/playhead exactly
  (AT-TWIN-1); twin-deck view frames.
- **FR-ENG-10, AT-TWIN-1.**

### Commit 4.10 — bank drawers, edge sliders, bottom-edge crossfader surface

- `Features/Workspace/BankDrawer.swift` + `EdgeSlider.swift` (§42.7b, mockup `iphone/05d`): the
  five modal idioms with their rules — momentary drawer (may cover only its own jog+transport),
  screen-edge filter slider (never occluded), release-to-commit flyout for LOOP/CUE, bottom-edge
  relative crossfader drag surface (1:1, 40 pt), half-height crate sheet (never over the
  crossfader). Spring-loading (hold raises, release dismisses within one frame), tap pins with
  12 s idle self-dismiss (AT-TWIN-3). `EQ · STEMS · PADS · CUES` banks; STEMS shows two live
  faders on iPhone (§2.1). Nothing modal covers the crossfader, both waveforms, the beat-phase
  meter or the opposite jog (FR-ENG-12, AT-TWIN-2).
- Tests: model tests — spring-load release restores jog in one frame, pinned drawer dismisses
  after idle, every idiom leaves the shared controls hit-testable; AT-TWIN-4 under the shim.
- **FR-ENG-12, AT-TWIN-2/3/4.**

### Commit 4.11 — iPad deck module slot, default `STEMS`

- `Features/Workspace/DeckModuleSlot.swift` (§41.9a, mockup `ipad/07b`): per-deck module slot
  `JOG · STEMS · PADS · FX`, persisted per deck, **default `STEMS`** (honest disabled stem faders
  until M5, §2.6), jog module at 248 pt with ± pitch-bend buttons and vinyl/CDJ mode shown inside
  the platter, jog sensitivity in the centre column, `LOOP` release-to-commit flyout identical to
  the compact idiom.
- Tests: slot persistence + default, module swap leaves engine state untouched.
- **§41.9a, FR-ENG-1 (jog as a slot), AT-TWIN-2 (module slot never occludes shared controls).**

### Commit 4.12 — Track Prep + grid corrections

- `Features/Prep/TrackPrepView.swift` + model (mockup `ipad/06`): waveform with pinch-zoom, cue
  pad row, grid tools (tap-to-set downbeat, tempo tap, correction undo). Writes through
  `DJLibraryStore`'s existing `grid_correction` path (authoritative override log, immutable
  analysis preserved — §23.3). Free users see the analysis readout only (FR-PREP-4); the grid
  tools are gated by `ProCapability.isEnabled(.preparation)` (Appendix T.3).
- Tests: `GridCorrectionTests` — a correction overrides without mutating analysis, persists,
  feeds the deck's grid snapshot; view-model states via a fake repository.
- **FR-PREP (grid), AT-GRID-\*.**

### Commit 4.13 — paywall + purchase flow + memory ceiling

- **Purchase flow:** `EntitlementStore` gains `purchase()`/`restore()` (StoreKit stays in
  `Sources/Pro/`); `PaywallView` + model in `Sources/DJ/Features/Paywall/` per §2.10 consume
  `isPro` and never import StoreKit. **Product repurpose** (§2.1): `FoundersGrant` collapses to
  the single `guru.parso.tonearm.pro` product and `FoundersGrantTests` is rewritten to the
  one-row table (AT-STORE-4 still covers every row); `EntitlementStore.Source` docs corrected.
  Purchase flips `isPro`, decks unlock with **no relaunch** (AT-STORE-2 — already structurally
  supported by the `Transaction.updates` observer). Free-tier registry unchanged.
- `Perf/MemoryCeiling.swift` (§43.5, NFR-REL-4): `task_vm_info` footprint sampling every 2 s +
  on deck load, shed order (waveform LODs → non-focused deck's cached tails → on-demand
  separation → analysis), **refuse the next deck load at 95%** with an honest message.
- Tests: `MemoryCeilingTests` — shed order from fabricated samples, refuse-at-95%, ceiling per
  device class; paywall model tests — contextual presentation, no relaunch flip, restore,
  no-nagging dismissal; `FoundersGrantTests` (rewritten); `EntitlementStoreTests` (purchase path
  with the fake source).
- **FR-STORE-1/2/3/5/6/7, AT-STORE-2/4, NFR-REL-4, AT-MEM-1 (device run deferred — §2.11).**

**Sequencing note (Appendix M.5).** Commits 4.8–4.11 are the compact twin-deck surface —
presentation-only, no engine/schema/analysis change — and sit at the end deliberately: if
AT-SESS-\* or AT-THERM-1 eat the schedule, they move to M6 at zero rework cost (they share
`WorkspaceModel` with the 4.6 iPad workspace). Order is otherwise §49.2's: views last.

## 6 · Testing strategy (spec §47, Appendix R)

- **RT / engine (integration, deterministic):** offline `AVAudioEngine` manual rendering on the
  macOS host — scripted commands, sample-accurate assertions, RTGuard active (§47.2 engine tier).
  This is the new harness; it runs in `make test-swift` (no hardware needed).
- **Pure kernels:** `SyncEngine.correction` (§32.3), `JogGestureModel`, `SessionPolicy` decision
  table, crossfader laws, limiter/EQ DSP blocks, quantize targets, `MemoryCeiling` policy — all
  deterministic, golden-pinned, no device.
- **Façade/actor:** `PerformanceEngine` tested through the ring (command application, telemetry
  stream) in the offline harness; `EntitlementStore`/`FoundersGrant` with the fake
  `EntitlementSource` (existing pattern).
- **View models:** `WorkspaceModel`/`TrackPrepModel`/paywall model with fake engine/repository
  seams; views are thin and covered by model tests + the app-smoke lane (the M2/M3 convention).
  UI regression lanes (§53) are **not** extended in M4.
- **AT-THERM-1 / AT-MEM-1 / physical AT-SESS-\*:** user-owned on-device, post-M4 (§2.11) — the
  milestone's automated proxies are the pure matrix + offline render + memory-policy tests.

## 7 · Definition of done (per commit, §49.4)

Tests green · acceptance IDs named in the message · no new dependency without an Appendix Q entry
(none — stdlib `Synchronization` only) · no new network host (none) · mockup coverage contract
satisfied (mockups `ipad/06, 07, 07b, 13a, 13b`, `iphone/05a, 05b, 05c, 05d, 08` already exist) ·
no `xcodegen generate` needed for DJ-only files (§3) · StoreKit boundary intact (CI guard) ·
`#if os` confined to `Sources/DJ/Session/` (§2.3) · CHANGELOG-style tier note (free-tiers intact;
the engine/purchase is Pro). **Ask before pushing** (3.0 is a release gate).

## 8 · Session protocol

One commit per numbered task (4.1–4.13), each a fresh session reading this plan + the spec
sections the commit names. Commit on `main`, allow ~5 min for the pre-commit suite. **Ask before
pushing** (push triggers CI + TestFlight; 3.0 is a ship gate). No `Co-Authored-By` trailer (owner
preference).

## 9 · Implementation Audit

_To be filled in as commits land: files changed, tests run, intentional deviations._

| Commit | Status | Notes |
|---|---|---|
| Plan doc | committed | `5e8b731`. Decisions: product repurposed to `guru.parso.tonearm.pro` (single DJ product, no `.pro.dj`, no Founders grant — §2.1); deployment floor raised to iOS 18/macOS 15/watchOS 11 so the RT ring uses stdlib `Synchronization.Atomic` (§2.2); `Resources/Tonearm.storekit` carries the single repurposed product; the user-owned AT-THERM-1 + M3 ship gates deferred to a post-M4 device pass (§2.11). `current_status.md` updated to M4. |
| 4.1 | committed | `211f431`. RT boundary + RTGuard + offline engine harness. 12 offline tests green (EngineOfflineTests); full suite green (1037 tests). Gate note: AT-PLIST-8's 2.0 s gate was raised to 2.5 s in `a7615e5` (owner decision) — root cause was the owner's Low Power Mode capping CPU clocks (~2.05 s on, ~1.23 s off), not load; subsequently raised to 4.0 s (owner decision) so it cannot fail in a clock-capped state. |
| 4.2 | committed | `40903e7`. `SessionPolicy` pure decision table (mode buffers, granted round-trip math, §34A.3/34A.4 rows, never-auto-play) + `#if canImport(AVAudioSession)`-guarded `AudioSessionCoordinator` shell (normative category→prefs→activate→read-back order, notification marshalling, Bluetooth refusal with measured round-trip). 20 `AudioSessionMatrixTests` green on the macOS host; 314 DJ tests green. No `xcodegen generate` (DJ excluded from app target). |
| 4.3 | committed | `e595254`. Single-deck play/cue/loop, sample-accurate. Deck reader replaces the 4.1 sine scaffold: `DeckClock`/`DeckGrid`/`QuantizeResolution`/`DeckSource` (pure-value PCM source crossing the RT boundary with no ARC/lock/alloc — §12.3), `Scheduler` (pure quantized boundary + trigger frame, §30.3), `CueLoop` (loop wrap + CDJ temp-cue state machine, §33), `RTCommand` extended (seek/setCue/cuePress/cueRelease/triggerHotCue/setLoop/exitLoop/setQuantize; setPitch → setRate; i1 slot), `AudioGraph` rebuilt as two `DeckState` readers over a zeroed baseline — loop wrap and quantized cue jumps split the buffer at the exact frame (§30.2), starved counter (§46.2), master-clock + per-deck playhead relaxed atomics; `PerformanceEngine` main-actor façade (load/play/pause/cue/seek + setQuantize, hot cues, CDJ loops — all enqueue lock-free). 25 `EngineOfflineTests` green (cue lands exactly at frame N, loop wraps end→start frame-exact, quantized trigger lands on the grid boundary mid-buffer, playhead telemetry exact, temp-cue press/release, dual-deck sum, no-buffer renders silence, 10 s no-overrun); full suite 1070 green. No `xcodegen generate` (DJ excluded from app target). |
| 4.4 | committed | `6e3c0e9`. Mixer — EQ/filter/crossfader/limiter (§35). `Engine/Mixer.swift`: `LinkwitzRiley` (LR4 — two cascaded 2nd-order Butterworth biquads per band, low/high sum an exact all-pass), `ThreeBandEQ` (200 Hz / 2 kHz, smoothed gains, `knobToGain` −1 kill…0 unity…+1 = +6 dB), `SweepFilter` (state-variable HP/LP, hard-bypassed at centre, 12 kHz→300 Hz sweep), `crossfaderGains` + `CrossfaderCurve` (constantPower/linear/sharp, spec §35.4 verbatim), `SmoothedGain` one-pole ramps, `LookaheadLimiter` (delay-line lookahead, soft-knee dB-interpolated gain, instant attack / slow release, provably never exceeds ceiling), `DeckMixer` per-channel chain + `MasterStage` (crossfader + per-channel limiter). `RTCommand` gains setEQ/setFilter/setFader/setCrossfader + f2 slot; `AudioGraph` runs the deck chain per sample and the master limiter over the summed bus; `PerformanceEngine` gains setEQKnobs/setFilter/setChannelFader/setCrossfader. 16 pure `MixerTests` + 5 new `EngineOfflineTests` (EQ kill silences the graph, filter bypass frame-identical, fader halves the deck, constant-power crossfader blend, limiter clamps output); full suite 1091 green. **Decisions recorded:** the deck chain is a bit-exact pass-through until a control is touched (EQ idle until `setEQ`, filter bypassed at centre, crossfader idle until positioned) so the 4.3 frame-exact reader harness stays valid; `AudioGraph.Configuration.limiterCeiling` defaults to `nil` (limiter out of the path) — the reader harness runs without it and mixer tests configure it explicitly. No `xcodegen generate`. |
| 4.5 | committed | `c628e99`. Time-stretch/key-lock/key-shift (§31). `Engine/TimePitch.swift`: `TimePitchMath` (pure `rateFromPercent`, `centsFromRate` = 1200·log2, `semitoneCents`, `pitchCents(rate:keyLock:keyShiftSemitones:)`), `TimePitchSettings` (per-deck rate/keyLock/keyShift → `unitPitchCents` + `effectiveKeyShiftSemitones` for the Camelot hint), `TimePitchUnit` (`AVAudioUnitTimePitch` wrapper, rate held 1.0, music parameters — transient-preserving asserted, RT-safe `apply` that skips unchanged). `RTCommand` gains setKeyLock/setKeyShift; `DeckState` gains keyLock/keyShift; `PerformanceEngine` gains setKeyLock/setKeyShift. **Graph: `Configuration.timePitch` engages a §29.1-shape per-deck `source → unit → main mixer` topology** (both blocks drain the ring — first drain applies every command, second finds it empty — so application is pull-order independent; master clock advanced in `render()` so both decks see the same pre-advance frameStart; master stage not in this topology). **Decision (recorded, deviation from plan's literal wording):** the deck reader stays the tempo authority (frame-exact, §30.2/4.4 decision) and the unit carries only the key compensation — `unitRate = 1.0`, `unitPitch = (keyLock ? −1200·log2(rate) : 0) + 100·semitones`. This keeps every frame-exact reader test bit-exact while satisfying FR-ENG-6 observably (spike-verified: reader 528 Hz + unit −316¢ → 440 Hz). Tests: 8 pure `TimePitchTests` (golden cent conversions, keyLock/vinyl/shift rules) + 6 new `EngineOfflineTests` on the time-pitch graph measuring the **dominant frequency by zero crossings** over a steady window (keyLock on at rate 1.2 holds 440 Hz; keyLock at unity transparent; keyLock off follows rate to 528 Hz; ±1 semitone at `2^(±1/12)`; keyShift compounds under keyLock to 440·2^(1/12) not 528·2^(1/12)). Full suite 1105 green. No `xcodegen generate`. |
| 4.6 | committed | `2bc6d4a`. Dual-deck sync + telemetry + iPad workspace. **Sync (§32):** `Engine/SyncEngine.swift` — pure `SyncClock` (playhead + grid + rate; `effectiveBPM`, `beatPhase`, `barPhase`, `phaseDifference` in (−0.5, 0.5]), `SyncCorrection`, and `correction`/`downbeatCorrection`/`continuousRate` (the §32.3 pure kernel); `DeckGrid` gains `beatPhase(at:)`/`barPhase(at:)`. `PerformanceEngine.sync/unsync`: the pure correction is applied as a rate command + a **scheduled sample-accurate nudge** (`RTCommand.syncNudge` → `PendingJump` at the callback's frame 0), then `.sync` engages **continuous rate tracking** — the render thread re-derives the synced deck's rate every callback (`RenderGraphState.applyContinuousSync`) so a master pitch change moves the synced deck with it (§32.1). **Telemetry (§30.1, §40.3, App. I.4):** the graph publishes per-callback relaxed atomics — deck rate/level (peak measured in the deck chain and the post-limiter bus)/playing/synced, plus the `MasterClock` components (master sample, effective BPM, downbeat phase); `AudioGraph.masterClock` assembles them; `EngineTelemetry` + `EngineTelemetryStream` (atomics → `AsyncStream`, newest-1); `PerformanceEngine.sampleTelemetry/pushTelemetry/telemetry`. `Features/Common/TelemetryPump.swift` — `CADisplayLink` (iOS) / `NSScreen.displayLink` (macOS test host), ProMotion 60–120 Hz, throttled to 30 Hz at `.serious` (pure `samplingFactor`/`preferredRange`), paused backgrounded. **Workspace (§41.9, mockup `ipad/07`):** `Features/Workspace/{WorkspaceModel,WorkspaceView,IdleTimerScope}.swift` — the one session VM over the `WorkspaceEngine` protocol (`PerformanceEngine` conforms; tests inject a recording fake), owning the mixer control state and idle-timer scoping (§34A.6) driven from telemetry; the view is two decks + a centre mixer (vertical EQ stacks, filter sliders, crossfader, master meter, limiter indicator, beat-phase meter, thermal/buffer readout, SYNC tap=beat/hold=downbeat, `.defersSystemGestures(on: .bottom)` on iOS), gated by `ProCapability.isEnabled(.decks)` — free users see the real dimmed surface with a lock chip (§40.4). **Decision (recorded):** the `MasterClock` snapshot is published as three relaxed atomics and assembled on the control side rather than as a reverse-direction double-buffered pointer — the render thread cannot allocate/lock, so a reverse snapshot would need control-side reclamation; a ≤1-callback skew is harmless for a relative nudge and display-rate readouts. Tests: 12 pure `SyncMathTests` (golden phase math, ±0.5 wrap, tempo + phase correction, bar sync, continuous rate, determinism) + 4 new `EngineOfflineTests` (sync aligns beats on the master grid, continuous rate tracks a master pitch change then unsync freezes, bar sync aligns downbeats, telemetry/master-clock readouts exact) + 8 `WorkspaceModelTests` (gate free/pro, lifecycle, transport/sync/EQ forwarding, atomics → stream against a fake and the real offline engine). Full suite 1129 green (1105 baseline + 24). No `xcodegen generate`. **FR-ENG-1/2/4, FR-ENG-9; FR-SESS; AT-ENGINE-SYNC-\*, AT-TWIN (gate), App. T.3.** |
| 4.7 | committed | `91580c0`. iPhone portrait solo-deck surface (§42.6–42.7, mockups `iphone/05a`, `iphone/05b`). `Features/Workspace/SoloDeckView.swift` over the shared `WorkspaceModel`: one focused deck full-width (header pills, playhead + BPM readout, waveform, CUE/PLAY/SYNC/LOOP transport, hot-cue pads, bank chips `Stems · EQ · Filter · Cues · Jog`), the other deck in a 72 pt strip (identity, BPM, state, playhead, play/pause); swipe-up or tap swaps focus — a **view-only** change, both decks stay live (FR-ENG-10, §42.1). The crossfader lives in the always-visible bottom bar (the whole strip is a 1:1 relative drag surface) and the browse-while-performing crate sheet may never cover it: the sheet renders *behind* the bar and its height is bounded by the model's pure `crateSheetMaxHeight`. `WorkspaceModel` gains the compact-posture state (`focusedDeck` + `swapFocus` — no engine call; `isCrateSheetPresented` raise/dismiss; static `crossfaderBarHeight`/`crateSheetMaxHeight`); `WorkspaceEngine` gains `sampleRate` so playheads render as clock time; the iPad workspace's `TransportButton`/`Pill`/`EQGroup`/`EQKnob`/`VerticalSlider` are shared (promoted to internal); `Features/Common/Haptics.swift` — NFR-A11Y-3 confirm, no-op off iOS. **Decision (recorded):** the crate-sheet track rows (gig crate ranked by the §28A.2 transition cost against the playing deck) and track titles/keys are deferred — the workspace has no library data seam yet — so the sheet carries the honest placeholder like the waveform/stems baselines; the normative geometry rule is what this commit ships. Tests: 3 new `WorkspaceModelTests` (focus swap is view-only — engine records zero calls, telemetry untouched; the sheet never covers the crossfader over a spread of container heights; raising the sheet changes no engine state). Full suite 1132 green (1129 baseline + 3); Swift 6 guard OK. No `xcodegen generate`. **FR-ENG-9/10, §42.6–42.7.** |
| 4.8 | committed | `fce2b16`. `JogGestureModel` (pure) + `JogView` (§40.7; FR-ENG-11, AT-TWIN-4). **`Features/Workspace/JogGestureModel.swift`** — the pure contact-relative rotation state machine (§40.7.2–40.7.4): `JogPoint` (Double coords, no SwiftUI/UIKit), rotation measured from wherever the finger lands, radius split (platter inner 58% / ring outer 42%) **fixed at touch-down** — a boundary-crossing drag never changes mode, sensitivity 0.5–2.0 clamped, ring bend saturates at ±16% across ±π, emits **only** `hold`/`scrub(radians:)`/`nudge(rate:)`/`release`. **`Features/Workspace/JogView.swift`** — the rendered platter off the telemetry pump (the model's `@Published telemetry`, display-cadence via the 4.6 pump — no second display link): position marker + phase ghost (§40.7.5), hub readout, `JogDetentDriver` (light-per-beat / heavy-per-downbeat while the platter is held, master clock = the audible beat), and `JogTransport` — the jog's only engine contact, mapping intents onto the existing transport (hold→pause / release→resume a playing deck, scrub = relative seek one beat per revolution, nudge = setRate off `deckRate` base), guarded by `RTGuard.assertRTSafe`. **Decisions (recorded):** the spec's App. I.4 façade does **not** actually define `scrub/nudge/hold/release` (FR-ENG-11/§40.7.7's "already defines" is aspirational in the spec itself), so `JogTransport` maps the four intents onto the engine's real transport surface, documented in the file; `WorkspaceEngine`/`WorkspaceModel`/`PerformanceEngine` gain the read-only `deckRate(_:)` seam (the graph already publishes it) as the pitch-bend base. The 4.7 `Jog` bank chip swaps in the real `JogView`. Tests: 21 `JogGestureModelTests` (rotation→scrub/nudge, boundary-crossing split fixed both ways, sensitivity scaling + clamp, contact-relative displacement, release, golden deterministic script, bend saturation, one-beat-per-revolution scrub math, detent decision, AT-TWIN-4 under the §46.3 shim, FR-ENG-11 transport wiring incl. non-unity base + never-starting-a-paused-deck). Full suite 1153 green (1132 baseline + 21); pre-commit suite incl. app/watch smoke lanes green. No `xcodegen generate`. **FR-ENG-11, AT-TWIN-4, §40.7.** |
| 4.9 | committed | `113e8b7`. `TwinDeckView` + orientation switch (§42.7a, mockup `iphone/05c`; FR-ENG-10, AT-TWIN-1). **`Features/Workspace/TwinDeckView.swift`** — the landscape twin-deck surface: 168 pt `JogView` per deck (transport on each deck's inner side: CUE · PLAY/PAUSE · LOOP 54×54, jog intents through a lazily-created `JogTransport` per deck, AT-TWIN-4), stacked waveforms on **one shared playhead** (beat ticks positioned from each deck's telemetry phase so a synced pair shows coincident grids — the honest baseline until the deck-prep waveform render, per the 4.6/4.7 convention), the 202 pt mixer column (signed beat-phase meter + "locked · ±ms" readout, channel faders A/B, SYNC tap=beat/hold=downbeat, crossfader — **no EQ**, it is a bank), a passive bank tab per deck (the §42.7b drawer is 4.10), and a continuous screen-edge filter slider on each edge that costs zero layout width and is never occluded. The layout consumes `WorkspaceModel.TwinGeometry` — §42.7a's budget verbatim (`734 = 30 │ 168 │ 6 │ 54 │ 8 │ 202 │ 8 │ 54 │ 6 │ 168 │ 30`), the 59 pt sensor-housing dead bands carry nothing interactive. **Orientation switch:** `CompactPerformanceView` maps `verticalSizeClass` (`.compact` = landscape = twin, `.regular` = portrait = solo) onto the model's view-only `compactPosture` and renders `SoloDeckView`/`TwinDeckView` over the **one** `WorkspaceModel`; the container owns the engine lifecycle (begin/end, scene-phase pump, `.defersSystemGestures`), so rotating never stop/starts the engine — `SoloDeckView` gains a `managesLifecycle` flag (default true, false when embedded) to make that possible. **Model additions:** `channelA`/`channelB` published fader state (unity default, the §35.4 transparent-until-touched convention), `compactPosture` + `setPosture` (view-only), pure `beatPhaseError`/`beatPhaseErrorMillis` (the signed circular difference; `ms = error × 60000/bpm` — the sample rate cancels out of the samples→ms conversion), and `TwinGeometry`. Tests: 6 new `WorkspaceModelTests` — rotation is view-only, rotation preserves transport/playhead exactly (AT-TWIN-1), channel-fader state mirrors the engine, golden phase-error + ms math, the §42.7a budget sums to 734 and a deck column decomposes exactly. Full suite 1159 green (1153 baseline + 6); Swift 6 guard OK; no `xcodegen generate`. **FR-ENG-10, AT-TWIN-1, §42.1/42.7a.** |
| 4.10 | committed | *this commit*. Bank drawers, edge sliders, bottom-edge crossfader surface (§42.7b, mockup `iphone/05d`; FR-ENG-12, AT-TWIN-2/3/4). **`Features/Workspace/BankDrawer.swift`** — the momentary 228×206 drawer over one deck's jog + transport: `EQ · STEMS · PADS · CUES` seg (EQ = three 44 pt knobs with kill/boost readouts + a TRIM fader; STEMS = **two** live faders per §2.1's iPhone budget, honest-unavailable until M5; PADS = four 44 pt pads; CUES = four hot-cue pads), a grab handle + pinned-drawer dismiss button, and the **spring-loading** state machine: press springs, release dismisses within one frame (AT-TWIN-3), a tap pins and the pinned drawer self-dismisses after 12 s idle (injectable duration); **`LoopReleaseToCommitButton`** — §42.7b idiom 3's release-to-commit flyout anchored to LOOP (the §41.9a beat counts 1/2/4/8/16/32 + EXIT; release over a chip commits, release outside cancels — the loop never changes on the way out; the flyout stays within that deck's column so it never covers the mixer/waveforms/beat-phase meter/opposite jog); **`BottomEdgeCrossfader`** — §42.7a idiom 4's full-width 40 pt 1:1 **relative** drag surface over the vertical slack + home indicator (double-tap slams to a side); **`EdgeSlider.swift`** — rule 2's 24 pt screen-edge filter slider that no modal idiom can occlude. **Model:** `TwinBank`, `DrawerState` (idle/spring/pinned), `springDrawer`/`releaseDrawer`/`pinDrawer`/`dismissDrawer`/`selectDrawerBank`/`noteDrawerActivity` (all view-only), pure `springReleasePins` (tap threshold 0.35 s), `DrawerGeometry` (228×206 = exactly one deck column; dead band 59, edge slider 24), `drawerXRange`/`mixerXRange` (the drawer's range in the §42.7a usable space never intersects the mixer or the opposite deck), `relativeCrossfader` (1:1, clamped), and `LoopFlyout` (pure chip layout + `releasedAction(at:)`). `TwinDeckView` wires the tabs (spring/pin/toggle-off), the drawer overlay over the owning deck's column, the LOOP flyout, the bottom-edge surface and the `EdgeSlider`s; the surface gains `.ignoresSafeArea()` so the §42.7a canvas (852×393) and the bottom-edge band land exactly. **Decisions (recorded):** CUE keeps its existing §33.1 press-jump-preview / release-return — the same release-to-commit semantics for a cue — rather than a second flyout with invented engine calls; the bank tab's 44 pt hit region is a bottom-aligned overlay so it overlaps the jog's lower rim per §42.7a without breaking the 206 pt band. Tests: 12 new `WorkspaceModelTests` (spring-release restores the jog in one frame; pinned drawer self-dismisses after idle — and does **not** before; touch inside the pinned drawer resets the clock; spring-release-pins threshold; the drawer never covers the shared controls across both decks + the edge-slider clearance; drawer interaction changes no engine state; springing one deck replaces another's pinned drawer; per-deck bank memory; flyout release resolution golden incl. the cancel paths + the §41.9a beat set; the 1:1 relative-crossfader mapping). Full suite 1171 green (1159 baseline + 12); Swift 6 guard OK; no `xcodegen generate`. **FR-ENG-12, AT-TWIN-2/3/4, §42.7b.** |
| 4.11 | committed | `726884a`. iPad deck module slot, default `STEMS` (§41.9a, mockup `ipad/07b`; FR-ENG-1 — jog as a slot, AT-TWIN-2 — a module never occludes shared controls). **`Features/Workspace/DeckModuleSlot.swift`** — the per-deck slot: a `JOG · STEMS · PADS · FX` seg (the compact drawer's idiom) over the module content. STEMS (the default) = the four honest-unavailable stem faders until M5 (plan §2.6); PADS = the four pads; FX = honest-unavailable FX pads. **A module is a layout member of its own deck column, never an overlay** — swapping modules changes no engine state and structurally cannot reach the mixer column, either waveform, the beat-phase meter or the opposite deck (AT-TWIN-2). The JOG module is the §41.9a **248 pt** jog (≈48 mm — a whole-hand control) flanked by ± **pitch-bend buttons** (a momentary 0.4% bend routed through the jog's own `.nudge`/`.release`, so a button bend is byte-for-byte a ring bend), with the **vinyl/CDJ platter action** selectable above the jog and **shown inside the platter** so the mode is never a guess. **`JogGestureModel`** gains `JogMode` (vinyl = scratch / CDJ = nudge) — a CDJ platter rotation emits `.nudge`, not `.scrub` (§40.7.3) — and `setSensitivity` (clamped to §40.7.4's 0.5–2.0). **`JogView`** gains `mode`/`sensitivity`/`showsModeReadout` params (phone surfaces unchanged via defaults); the iPad hub renders the mode pill + BPM + a pure `barBeat` bar/beat readout (§40.7.4's iPad compensation for no Taptic engine). **`WorkspaceModel`** gains `DeckModuleSlot` + per-deck jog mode/sensitivity state, with the slot and mode **persisted per deck** through injectable `UserDefaults` (default `STEMS` / vinyl, §41.9a's "remembered per deck"), and `ModuleGeometry` (`jogSize` 248, `jogModuleWidth` = jog + two bend columns + gaps; the §41.9 `1fr 268px 1fr` deck column on the 1180 canvas). **`WorkspaceView`** — the deck column's lower third is the module slot; LOOP is now the **release-to-commit flyout identical to the compact idiom** (§42.7b idiom 3); the mixer column gains the per-deck jog-sensitivity faders (§40.7.4, §41.9a). Tests: 6 `WorkspaceModelTests` (default `STEMS`, per-deck slot + jog-mode persistence across model instances, module/mode/sensitivity swap changes **no** engine state, sensitivity clamps, `jogModuleWidth` fits the deck column) + 6 `JogGestureModelTests` (vinyl default, CDJ platter nudges not scratches, ring still bends in CDJ, nudge saturation, `setSensitivity` clamp, `barBeat` golden). Full suite 1183 green (1171 baseline + 12); Swift 6 guard OK; no `xcodegen generate`. |
| 4.12 | committed | `ea66d33`. Track Prep + grid corrections (§41.8, mockup `ipad/06`; FR-PREP-5, FR-ANL-5, AT-GRID-*, §23.3). **`Data/GridCorrectionRepository.swift`** — `TrackPrepSnapshot` (identity + the **free** readout per FR-PREP-4: BPM/key/LUFS/DR/grid confidence, phrase map, first-downbeat) and the authoritative `DeckGrid` a deck loads (detected `beat_grid` + replayed corrections); `GridCorrectionRepository` over the pool + the `DJLibraryStore` actor, plus the `TrackPrepRepositing` seam for fake-repository VM tests. **`Domain/DJLibraryStore.swift`** — `gridCorrections`/`appendGridCorrection`/`undoLastGridCorrection`, each one GRDB transaction (NFR-REL-1). **`Engine/DeckClock.swift`** — `GridReplay`, the pure §23.3 kernel next to `DeckGrid` (whose doc comment already promised it): nudge/shift add a sample delta, setDownbeat/setBPM are absolute (the newest wins), ×2/÷2 scale tempo, malformed entries skipped, order by `(appliedAt, id)` so the input array order can never matter (NFR-DET). **`Features/Prep/TrackPrepModel.swift`** — the one gate (`ProCapability.isEnabled(.preparation)`, App. T.3) + the one-thumb tools (nudge, tap-to-set-downbeat, ×2/÷2, setBPM, undo) that append to the log and re-read the snapshot, plus the pure `TempoTapper` (median-interval tempo tap — robust to one mistimed tap). **`Features/Prep/TrackPrepView.swift`** — the mockup surface: readout pills, the gated grid-tool chips (locked + PRO for free users, §40.4), a waveform with **real pinch-zoom over the grid's bar/beat markers** (honest baseline bars until the pyramid render), drag-to-nudge / tap-to-set-downbeat committing **once** on release with haptic confirm (NFR-A11Y-3), and the free "What we heard" panel; cue pads/loops render the honest unavailable state until their repositories land (the FR-PREP-2/3 convention). Tests: 18 `GridCorrectionTests` — replay golden + determinism + malformed-skip + nil-base; **DB tests assert a correction overrides without mutating `beat_grid` (bpm/source/firstBeatSample untouched), persists across a fresh repository, and feeds the authoritative deck grid; undo pops the newest only**; the readout rows; the VM gate refuses free edits at the intent boundary and forwards Pro ones through the fake; TempoTapper math. Full suite 1201 green (1183 baseline + 18); Swift 6 guard OK; no `xcodegen generate` (DJ excluded from app target). **Decisions recorded:** `GridReplay` has one non-optional entry (`authoritativeGrid`) plus `authoritativeGridIfAnalyzed` for the not-analyzed state — a correction without a grid to correct is meaningless, so the surface reports the honest "no grid yet"; `valueInt` is `Int64` (sample positions are engine-sized); `beatsPerBar` stays the base grid's 4 (downbeat-derived bars are a later refinement). |
| 4.13 | committed | `01d4acb`. Paywall + purchase flow + memory ceiling (§41.15/41.16, §42.10, mockups `ipad/13a`, `ipad/13b`, `iphone/08`, §43.5; FR-STORE-1/2/3/5/6/7, AT-STORE-2/4, NFR-REL-4). **Purchase flow (§2.10):** `EntitlementSource` gains `purchase()`/`restore()` (default no-ops so read-only fakes need no change); `StoreKitEntitlementSource.purchase()` buys `guru.parso.tonearm.pro` via `Product.purchase()`, `restore()` = `AppStore.sync()`; `EntitlementStore` gains `purchase()`/`restore()` that re-derive from `currentEntitlements` so `isPro` flips in-process with **no relaunch** (AT-STORE-2). **`Features/Paywall/PaywallModel.swift`** — consumes `isPro`, calls `purchase()`/`restore()`, **never imports StoreKit** (App. T.3); presentation is contextual-only via `present()` (FR-STORE-5, §40.4 rule 3 — never on launch/timer/over playback), dismissal is final for the session (FR-STORE-6, T.7), a successful purchase auto-dismisses the sheet, a failed one keeps it up with an honest message; `displayPrice` pinned to the storekit's $39.99. **`Features/Paywall/PaywallView.swift`** — the §41.16 sheet in compact/regular form: price, the §2.4 green "everything you have now stays free" panel, GPLv3 build-it-yourself note, visible Restore, buy button with `isPurchasing`; no countdown/strikethrough/scarcity, no trial (plan §2.10). The lock chip on **all three** performance surfaces (`WorkspaceView`, `SoloDeckView`, `TwinDeckView`) now presents the sheet; `WorkspaceModel.store` is exposed for the paywall to buy through the same store that unlocks the decks. **Product repurpose (§2.1):** `FoundersGrant` collapses to the single `guru.parso.tonearm.pro` — one-row T.4 (verified ⇒ `.purchased`, family-shared ⇒ `.familyShared`, revoked ⇒ none; unverified never grants), `FoundersGrantTests` rewritten, `EntitlementStore.Source` docs corrected (`foundersGrant` survives only as a legacy cache row). **`Perf/MemoryCeiling.swift`** — pure §43.5 policy (device class from total RAM, ceilings 1.4/1.0/2.0 GB, 80% shed / 95% refuse bands, normative shed order), a Darwin `task_vm_info.phys_footprint` provider (no `#if os`), and a `MemoryCeilingMonitor` that samples every 2 s + on deck load and refuses the next load at 95% with an honest message (AT-MEM-1 device run deferred — §2.11). Tests: 8 `PaywallModelTests` + 15 `MemoryCeilingTests` + purchase/restore path in `EntitlementStoreTests` + one-row `FoundersGrantTests` (AT-STORE-4). Full suite 1224 green (1201 baseline + 23); Swift 6 guard OK; StoreKit boundary intact (only `Sources/Pro/` imports it); no `xcodegen generate` (DJ-only additions). **M4 complete — AT-ENGINE-\*, AT-SESS-\*, AT-STORE-\*, AT-TWIN-\* green; AT-THERM-1 is the user-owned shipping gate (deferred, decision 4 of the M4 kickoff).** |
