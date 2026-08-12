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

**M4 commit 4.1 — RT boundary + RTGuard + offline engine harness — complete
(`211f431`).** All under `Sources/DJ/Engine/` (no `xcodegen generate` needed, DJ
target excluded from the app):

- `RTCommand.swift` — POD command (tag + deck + i0/f0/f1 + `UnsafeRawPointer?` armed
  source), tags `play`/`pause`/`setPitch`/`loadArm`, `@unchecked Sendable` + Equatable.
- `CommandRing.swift` — fixed power-of-two SPSC ring, stdlib `Atomic<Int>` head/tail,
  release/acquire `tryPush`/`drain` (count-returning), pre-allocated, never grows.
- `EngineSnapshot.swift` — double-buffered `Atomic<UnsafeRawPointer?>` publish/read,
  control-side retire list (`retire`/`drainRetired`), never freed on the render thread.
- `RTGuard.swift` — DEBUG thread-local render-context flag (`withRenderContext`,
  `checkRTSafe`, `assertRTSafe`); RELEASE compiles out entirely.
- `RenderLoad.swift` — `mach_absolute_time` start/end ticks in the callback, one
  relaxed atomic store, `lastRenderNanos` + `loadRatio(periodNanos:)`.
- `AudioGraph.swift` — offline manual-rendering `AVAudioEngine` harness: sine source,
  drains the ring each callback, reads the snapshot, wraps in `RTGuard`, meters with
  `RenderLoad`; `Configuration` (sample rate/channel/ring capacity/initial state);
  render block captures the ring/snapshot/load/probe/state (not `self`) so the graph
  lifetime is not tied to the engine's. DEBUG `guardWasActive` probe.
- `Tests/DJTests/EngineOfflineTests.swift` — 12 tests green: ring FIFO / full→false /
  empty no-op / pointer round-trip; snapshot publish/read/retire; RTGuard flag +
  `checkRTSafe` + nested context; RenderLoad measure/reset; offline render vs a
  sample-referenced sine; pause-mute + frozen-phase resume; **setPitch applies at the
  exact frame boundary** (frame 100, ±5e-4); RTGuard wraps the render; 10 s /
  512-frame long render with a 21-command burst per chunk (ring overflows softly)
  renders every frame, bounded output, load ratio < 1.0. **FR-ENG-1, NFR-PERF-1,
  NFR-PERF-2; the RT half of AT-ENGINE-\*.**

**Gate adjustment (`a7615e5`, owner decision):** the AT-PLIST-8 30k-candidate beam
gate was **2.0 s → 2.5 s**. Root cause found: not load — the owner's **Low Power Mode
on AC** caps CPU clocks on this M2. Measured 1235 ms with LPM off, 2040–2073 ms with
LPM on, identical across load averages 63 → 2. Owner keeps LPM on sometimes, so the
gate sits at 2.5 s (still under the 3 s budget).

## Next

- **M4 commit 4.2** — `Session/SessionPolicy.swift` (pure route/interruption decision
  table, §34A.3) + `AudioSessionCoordinator` (the one sanctioned `#if canImport`
  module) + `AudioSessionMatrixTests`. Then 4.3 (single-deck play/cue/loop,
  sample-accurate) … 4.13 (paywall + purchase + memory ceiling). Ship gates
  AT-ENGINE-\*, AT-SESS-\*, AT-STORE-\*, AT-TWIN-\*; **AT-THERM-1 is the user-owned
  shipping gate**, run after the milestone on a real device (deferred per decision 4
  of the M4 kickoff).

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
