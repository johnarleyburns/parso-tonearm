# Investigation: Sound Index stuck at 0/2364 with no reason shown

**Report**: TestFlight device, Music tab. "Sound Index says 0/2364 tracks.
After 5+ minutes, not a single track has been indexed — 0 progress the whole
time." Full status screen "just says indexing, 0/2364, nothing about
downloading, waiting, no progress ever evident."

## Method

Read the real launch wiring, scheduler, policy, reconciler, model-resource and
status-UI code end to end; wrote/ran regression tests against the actual
`DiscoveryAssembly`/`IndexScheduler`/`IndexStatusPresentation` types (no
device needed — this subsystem is designed to be fully unit-testable, per its
own doc comments). No source was guessed at; every claim below cites the file
and line read.

## Hypotheses, in the order given, with evidence

### 1. Is the scheduler tick loop actually running? — DENIED (works as designed)

`TonearmApp.swift:106-110`: the `.task` calls `appState.bootstrap()`, then
unconditionally `await DiscoveryRuntimeController.shared.startAfterBootstrap()`
— no guard that could skip it, no scene-phase race (the `.task` runs once per
`WindowGroup` and `startAfterBootstrap()` itself is idempotent via `didStart`).

`DiscoveryRuntimeController.startAfterBootstrap()`
(`Sources/App/DiscoveryRuntimeController.swift:109-132`) calls
`recoverAndReconcileAtLaunch()`, wraps it in `do/catch` (a thrown error is
logged, never silently drops the subsequent `startForegroundTickLoop()`), then
unconditionally calls `startForegroundTickLoop()` and
`startPauseRefreshLoop()`.

`startForegroundTickLoop()` (lines 147-170) is a real `while !Task.isCancelled`
loop that calls `assembly.drainQueue()` every 20s (`Task.sleep(for: .seconds(20))`
at the bottom of the loop), or sleeps 30s and retries if `sampler.isBackground`.
It is restarted on `.active` scene-phase transitions and whenever playback
stops (`observePlayback()`), so a scene-phase cancellation cannot leave it
permanently dead.

**Verdict: no wiring gap. The loop runs.**

### 2. Are jobs actually created for a pre-existing library? — DENIED (no marker bug)

`DiscoveryReconciler.bootstrapAllTracks()`
(`Sources/Discovery/DiscoveryReconciler.swift:39-58`) has **no persisted
"already bootstrapped" flag of any kind** — grepped the whole `Discovery`/App
Discovery surface for `UserDefaults`/`didBootstrap`/similar and found none.
Every call re-runs a `NOT EXISTS` keyset query
(`pageOfTracksNeedingJobs`, lines 63-80) against `discovery_index_job` for the
current `pipelineVersion`, so it is naturally idempotent and correct for the
upgrade scenario (pre-existing tracks, feature added later) — those tracks
simply have no job row yet and get one on the very first
`recoverAndReconcileAtLaunch()` after the upgrade, no special-casing needed.

Confirmed in `Tests/DiscoveryTests/DiscoveryAssemblyTests.swift` with a new
test (`testPersistentPolicyBlockLeavesJobsQueuedAndRecordsTheRealReason`) that
seeds 25 pre-existing tracks with **no prior discovery state at all** and
asserts `recovery.bootstrappedTracks == 25` — matches production
(`DiscoveryRuntimeController.startAfterBootstrap()`'s own log line records
`bootstrapped \(recovery.bootstrappedTracks)`, which for a 2364-track library
upgrading would read "bootstrapped 2364" — job rows really do get created).

**Verdict: no bug. Jobs get created correctly on first launch after upgrade.**

### 3. Does the status UI collapse everything into a generic "indexing" label? — **CONFIRMED, ROOT CAUSE**

`IndexJobRepository.coverage()` (`Sources/Discovery/IndexJobRepository.swift:365-390`)
computes `queuedOrRunning = count(state='queued') + count(state='running')`.

`IndexScheduler.tick()` (`Sources/Discovery/IndexScheduler.swift:59-66`) checks
`IndexPolicy.decide()` **before ever claiming a job**:

```swift
let initialDecision = IndexPolicy.decide(snapshotProvider())
guard case .proceed = initialDecision else {
    if case let .blocked(reason) = initialDecision { return .blocked(reason) }
    return .idle
}
guard let claim = try await jobs.claimNextJob() else { return .idle }
```

When this pre-claim gate is blocked, the job is **never touched** —
`releaseOrMarkWaiting()` (lines 121-134), the only place that ever writes a
`waitingForPower`/`waitingForCooling` job state, is only reachable from
*inside* the per-window loop, i.e. only after a job has already been claimed.
A job blocked at this outer gate stays exactly `.queued` — permanently counted
in `coverage.queuedOrRunning`, with **zero** persisted signal of why.

`DiscoveryAssembly.drainQueue()` (`Sources/Discovery/DiscoveryAssembly.swift`,
pre-fix) then did:

```swift
case .idle, .blocked:
    return completed
```

— discarding the `IndexBlockReason` on the floor. Nothing in
`DiscoveryRuntime`/`IndexStatusSnapshot` ever recorded it. And
`IndexStatusPresentation.make()` (`Sources/Discovery/IndexStatusModel.swift`,
pre-fix) had:

```swift
} else if c.queuedOrRunning > 0 {
    phase = .indexing
    detail = "Indexing \(number(c.queuedOrRunning)) track…"
}
```

— which fires whenever `queuedOrRunning > 0`, **with no way to tell "jobs are
actually running" apart from "jobs are queued and the scheduler is
permanently gated before ever claiming one."** For a freshly-bootstrapped
2364-track library sitting behind any scheduler-level gate (thermal, battery,
playback, missing background grant — see hypothesis 5), this produces exactly
`headline = "Sound index: 0 / 2,364 tracks"`, `phase = .indexing`,
`detail = "Indexing 2,364 tracks…"` — a UI that looks like something is
happening, forever, with zero real evidence and no way to distinguish it from
genuine progress. This is a byte-for-byte match to the user's report ("just
says indexing, 0/2364, nothing about downloading, waiting").

Even the "Activity" section of the full status screen
(`Sources/Features/Discovery/IndexStatusView.swift`, `activityCard`) only
shows `runtime.lastStopReason`, which is set **once, at launch**
(`DiscoveryRuntimeController.startAfterBootstrap()`:
`"launch: reset \(...) leases, bootstrapped \(...), drained \(...)"`) and is
never updated by the ongoing tick loop — so even that fallback text goes
stale the moment the first blocked tick happens and never reflects "why is
this still stuck 5 minutes later."

**Verdict: confirmed root cause. Fixed below.**

### 4. Model ODR tag mismatch in CI archives? — DENIED

`Sources/App/DiscoveryModelResources.swift`: `audioTag = "clap-audio"`,
`textTag = "clap-text"`. `scripts/generate-project.sh:46-47` and the generated
`Config/models-odr.yml` (regenerated on this host by running the relevant
part of `make project`'s pipeline) both use exactly `clap-audio` / `clap-text`
— checked string-for-string, no pluralization/hyphen/case mismatch. If the
model packages are simply absent from a given archive (`Resources/Models/...`
not present on the build host), the *documented, tested* honest-absence path
applies (`ModelManager.Resources.unavailable` → jobs park at
`.waitingForModel`, which — after this fix — is correctly distinguished from
"queued behind a policy block").

**Verdict: no tag mismatch found; this is not the cause of the reported "just
says indexing" (a genuine model-missing job reaches `.waitingForModel`, which
already had a specific, correct status message before this fix — see
`testWaitingForModelWhenResourcesAbsent`).**

### 5. Is `IndexPolicy.decide` blocking everything without saying so? — PARTIALLY CONFIRMED (real, but environment-dependent; now visible)

`IndexPolicy.decide()` (`Sources/Discovery/IndexPolicy.swift:107-149`) is a
straightforward, deterministic gate — read start to finish, no logic bug
found in the gate conditions themselves. But one gate is worth flagging as a
plausible real-world trigger for "stuck for 5+ minutes":

```swift
if s.thermalState == .fair || s.continuousNominalSeconds < thermalFairRecoverySeconds {
    return .blocked(reason: .thermalFair)
}
```

`thermalFairRecoverySeconds = 60`. `continuousNominalSeconds` is derived
(`Sources/Discovery/DiscoverySchedulingInputs.swift:74-79`) from a
`nominalSince` timestamp that `SchedulingSampler` resets to `nil` every time
real thermal state leaves `.nominal`
(`Sources/App/DiscoverySchedulingSampler.swift:153-162`). A real device doing
a heavy TestFlight-install unpack/first-launch (2364-track library scan, on
top of app install itself) can plausibly keep nudging `ProcessInfo`'s thermal
state away from `.nominal` intermittently for longer than any single 60s
window, which would keep re-blocking indexing indefinitely without ever being
a "critical" gate the user could self-diagnose. Low battery
(`lowBatteryThreshold = 0.30`, unplugged) or the phone simply not being on
charger while `chargingOnlySetting` happens to be on are equally plausible,
ordinary explanations.

**This is not a code bug** — `IndexPolicy` is working exactly as designed
(never index during real thermal/battery/playback pressure). It is a genuine
environmental cause that could not be confirmed or denied without the user's
device telemetry. **The actionable fix is hypothesis 3's**: whatever the real
reason turns out to be on a given device, it must now be visible in the
status UI instead of silently discarded — which is what was fixed. If this
recurs, the fixed status screen will directly name the reason (e.g. "Waiting
for the device to cool down before indexing continues"), which turns any
future report into a five-second diagnosis instead of another blind
investigation.

## Root cause (confirmed)

Hypothesis 3: `IndexScheduler`'s pre-claim `IndexPolicy` block is real and
correct scheduling behavior, but the reason it returns was **thrown away** at
every layer above it — `DiscoveryAssembly.drainQueue()` discarded
`TickOutcome.blocked`/`.jobPreempted`'s `IndexBlockReason`, and
`IndexStatusPresentation.make()` had no field to receive it even if it had
been kept, so any indefinitely-blocked queue (any real `IndexPolicy` gate)
rendered as an indistinguishable, permanently-generic "Indexing N tracks…"
label with zero diagnostic value — exactly the reported symptom.

## Fix applied

1. **`Sources/Discovery/DiscoveryAssembly.swift`**: added
   `public private(set) var lastBlockReason: IndexBlockReason?`, an in-memory
   (process-lifetime) field updated by `drainQueue()`:
   - `.blocked(reason)` / `.jobPreempted(_, reason)` → record the reason.
   - `.idle` / `.jobCompleted` / `.jobWaiting` / `.jobFailed` → clear it (a
     job was genuinely claimed and run, or there is genuinely nothing
     eligible — either way, whatever blocked things before no longer
     applies, so a stale reason must not linger).
   `statusSnapshot()` now includes it.

2. **`Sources/Discovery/IndexStatusModel.swift`**:
   - `IndexStatusSnapshot` gained `schedulerBlockReason: IndexBlockReason?`
     (defaulted `nil`, source-compatible with existing callers/tests).
   - `IndexStatusPhase` gained `.blockedByPolicy`.
   - `IndexStatusPresentation.make()`: when `coverage.queuedOrRunning > 0`
     **and** a non-`.userPaused` `schedulerBlockReason` is present (userPaused
     already has its own higher-priority `.paused` phase via
     `snapshot.isPaused`), the phase is `.blockedByPolicy` with a specific
     detail string per reason (thermal/battery/playback/memory/charging/
     background-grant) instead of the generic "Indexing…" label. Genuine
     progress (no recorded block reason) still shows `.indexing` exactly as
     before.

No change was needed to `DiscoveryReconciler`, `IndexPolicy`, `IndexScheduler`,
`DiscoveryModelResources`, or the launch wiring — all of those were read in
full and are correct.

## Tests added

- `Tests/DiscoveryTests/DiscoveryAssemblyTests.swift`:
  `testPersistentPolicyBlockLeavesJobsQueuedAndRecordsTheRealReason` —
  reproduces the exact real-world scenario (pre-existing library, real launch
  sequence via `recoverAndReconcileAtLaunch()`, repeated `drainQueue()` ticks
  exactly like the production foreground loop) with a scheduler persistently
  gated by a real `IndexPolicy` condition; asserts jobs are created, stay
  `.queued`, coverage shows `0/N` complete, `lastBlockReason` is recorded, and
  it clears once the gate resolves.
- `Tests/DiscoveryTests/IndexStatusPresentationTests.swift`:
  - `testBlockedSchedulerNeverShownAsGenericIndexing` — the literal 0/2364
    repro at the presentation layer; asserts `.blockedByPolicy` (not
    `.indexing`) and a real reason string, headline unchanged.
  - `testEachPolicyBlockReasonHasADistinctNonGenericDetail` — all 8
    `IndexBlockReason` cases produce `.blockedByPolicy` with non-empty,
    mostly-distinct detail text.
  - `testStaleUserPausedBlockReasonDoesNotOverrideNormalIndexing` — a stale
    `.userPaused` block reason (already handled by the dedicated `.paused`
    phase) does not create a redundant/confusing second phase.

### Before/after evidence

Confirmed the new tests fail against the pre-fix code (compile-time, since
the pre-fix types lack the new field/case entirely — reverted
`DiscoveryAssembly.swift`/`IndexStatusModel.swift` to their pre-fix content
and re-ran: build fails with "extra argument 'schedulerBlockReason'" /
"has no member 'blockedByPolicy'" / "has no member 'lastBlockReason'").

Additionally isolated the **logic** regression specifically (not just the
type surface) by keeping the new field/case but removing only the new
`if`-branch in `IndexStatusPresentation.make()`: the two new presentation
tests then fail at the assertion level, e.g.

```
XCTAssertEqual failed: ("indexing") is not equal to ("blockedByPolicy") - thermalFair
XCTAssertEqual failed: ("indexing") is not equal to ("blockedByPolicy") - playbackActive
... (all 8 reasons)
```

— i.e. exactly the bug: every real block reason rendered as generic
"indexing". Restoring the branch turns all of them green.

### Full verification (after fix)

- `swift build`: clean.
- `swift test --filter TonearmDiscoveryTests`: **196/196** (192 baseline + 4
  new), 0 failures.
- `swift test --skip PlaylistCrateImporterTests` (full repo): **1791
  executed, 8 skipped, 0 failures** (152.7s).
- `scripts/check-ci-guards.sh`: all guards OK.

## Not fixed / flagged, not guessed at

- The *specific* real-world condition that gated this particular user's
  device for 5+ minutes (thermal-fair-recovery flapping vs. low battery vs.
  playback vs. missing background grant) could not be determined without
  device telemetry, and per the task instructions was not "fixed" by
  weakening `IndexPolicy` — that policy's gates are intentional and correct.
  The fix instead makes whichever real reason applies immediately visible in
  the status UI, so a future occurrence is a one-glance diagnosis rather than
  a multi-hour blind investigation. If the user can reproduce this again and
  report exactly what the (now-fixed) status screen says, that will settle
  which specific `IndexPolicy` gate is actually responsible on their device.
