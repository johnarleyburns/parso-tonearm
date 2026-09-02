# Current status — Watch Now Playing reliability round

**Date:** 2026-09-01
**Scope:** watch-local Now Playing playback, audio-session routing, AVPlayer readiness, diagnostics,
tests, and smoke verification.
**Branch:** `main`
**Commit/push policy for this round:** implement the complete plan in one pass; review the final
implementation against every item below; close all actionable gaps; then commit and push.

## Why this round exists

On-device reports are that watch Now Playing sometimes does not start audio, or appears to start but
produces no sound. The current implementation can display a playing state before the audio session is
active, before the `AVPlayerItem` is ready, or before `AVPlayer.rate` is non-zero. The host suite is
green, but it primarily tests the pure engine and directive ordering; it does not prove that a real
watch audio session activated or that a real player item became playable.

The current code has these concrete risk points:

1. `AVPlayerOutput.activateSession()` calls `AVAudioSession.activate()` but discards its returned
   `Bool`. A false activation result can therefore be treated as success.
2. `WatchPlayer` sets `isPlaying` from the pure engine before the platform output confirms playback.
   The same optimistic state is sent to `MPNowPlayingInfoCenter` as playback rate `1.0`.
3. `AVPlayerOutput.load()` observes only the failed item path. It does not make readiness a returned
   success condition, and `play()` has no failure result.
4. Each command starts an independent task. Rapid track replacement, seek-after-start, route
   rebuilding, and interruption recovery can interleave old and new player operations.
5. `hasUsableRoute()` checks `currentRoute.outputs` before activation, rather than using the result of
   the activation request that is responsible for selecting a watchOS route.
6. `retryAudioRoute()` can inspect stale `audioRouteProblem` state because the callback updates it in
   another queued main-actor task.
7. Missing local files return silently, and platform failures are reduced to generic diagnostics such
   as `itemLoadFailed` or `sessionUnavailable`.
8. `rebuildSession()` activates once and then calls `load()`, which activates again.
9. `playLocalTrackIDs()` starts playback and immediately seeks without waiting for the new item.
10. The Now Playing view still exposes a persistent target selector even though the intended product
    model is one active engine with a passive ownership label. This can make “no sound” reports look
    like the user selected the wrong engine.

## Non-negotiable behavior

- A play request is not reported as playing until the intended audio session is active, the intended
  `AVPlayerItem` is `.readyToPlay`, and the player has begun producing a non-zero transport rate.
- A failed or cancelled request cannot overwrite a newer request's item, state, artwork, duration, or
  Now Playing metadata.
- A route activation result of `false` is a real failure, even when no Swift error is thrown.
- No-route and route-loss states park playback safely and preserve the queue. The user gets an
  actionable route message and no false play state.
- Missing/corrupt/unplayable local content produces a visible failure and a privacy-safe diagnostic;
  it never becomes an apparently playing empty state.
- `MPNowPlayingInfoCenter` remains enabled for background transport and system Now Playing. Its
  elapsed time, duration, artwork, and rate reflect confirmed platform state.
- The watch must continue to support supported watchOS 11+ Bluetooth routes and supported built-in
  speaker routes. Do not use `overrideOutputAudioPort(.speaker)` on watchOS.
- The watchOS simulator can verify app state, real `AVPlayerItem` loading, duration, rate, and the
  session result exposed by the app. It cannot prove audible output. Physical-watch checks must be
  reported separately and must not be faked by simulator assertions.
- Existing artwork/storage/protocol work remains intact. This round must not regress the content-
  addressed artwork pipeline or the watch architecture boundary.

## Implementation plan — complete in one pass

### Phase 0 — Baseline and test seams

Before changing behavior:

- Record the current worktree and preserve all intentional existing changes.
- Confirm the watch scheme, watch UI smoke target, package tests, CI guards, and generated project
  workflow.
- Add testable, platform-free value types in `Sources/WatchCore/Playback/` for:
  - session activation outcome (`active`, `unavailable`, `failed`), including a stable reason/code;
  - item load outcome (`ready(duration)`, `failed(errorCode)`, `cancelled`);
  - confirmed transport state (`idle`, `activating`, `loading`, `ready`, `playing`, `paused`,
    `waitingForRoute`, `failed`);
  - a playback request/generation identifier.
- Keep all AVFoundation and WatchConnectivity imports out of these pure decision types.

### Phase 1 — Make audio-session activation truthful

Refactor `AVPlayerOutput` so activation is an explicit operation with a result:

- Configure `.playback`, `.default`, and `.longFormAudio` immediately before activation.
- On watchOS, call `try await session.activate()` and inspect both the returned `Bool` and thrown
  error. `false` must return an unavailable result and include a stable error code.
- On non-watch platforms, retain the appropriate `setActive(true)` path behind the platform adapter.
- Capture a privacy-safe route snapshot: output count and port types, not device names or URLs.
- Replace `hasUsableRoute()` as the primary gate. A play transaction should ask the session to
  activate and then trust the activation result.
- Make route retry await the result directly. Do not use a callback plus a second queued task as the
  source of truth.
- Ensure route activation success clears the route error before any resume decision; failure leaves
  the engine paused and the pending request retryable.
- Keep route notifications, interruption notifications, and media-services-reset handling, but route
  all resulting work through the serialized playback executor from Phase 3.

Unit tests:

- activation success with `true`;
- activation returning `false` without throwing;
- activation throwing with a stable mapped error;
- route loss, route return, interruption, and media reset decisions;
- retry success resumes exactly one pending request;
- retry failure leaves the request pending and the player paused;
- no automatic resume after a route merely becomes available.

### Phase 2 — Make AVPlayer item readiness a first-class result

Refactor the output adapter and its protocol:

- `load(url:)` must return a typed result or throw a typed `WatchPlaybackOutputError`.
- After replacing the item, observe `AVPlayerItem.status` and await either `.readyToPlay`,
  `.failed`, cancellation, or a bounded timeout.
- Preserve the underlying AVFoundation error domain/code in diagnostics while keeping user-facing
  text short and actionable.
- Reset duration to zero at the beginning of every new item request. Publish duration only after the
  asset/item provides a finite positive value; retain a zero/unknown state honestly otherwise.
- Observe `AVPlayer.rate` and item status for the current generation only.
- Ensure an old item's callbacks cannot report failure or artwork for a newer item.
- `play()` must return a typed result and must not report success if session activation fails or the
  player remains at rate zero after a bounded confirmation window.
- `pause()` and `stop()` must be idempotent and cancel/retire the relevant readiness waiter.
- Avoid double activation in `rebuildSession()`; rebuild the session and reload through one path.

Tests:

- real `AVPlayerItem` with a bundled playable WAV/CAF fixture reaches `.readyToPlay`;
- missing file and malformed file reach `.failed` with a non-empty error code;
- duration is finite and positive for the playable fixture;
- readiness timeout is surfaced rather than becoming an indefinite spinner;
- cancellation prevents a late ready/failure callback from changing current state;
- rate transitions are emitted for play and pause;
- a failed old item cannot fail a newer item.

### Phase 3 — Serialize local playback transactions

Introduce one main-actor playback transaction in `WatchPlayer` and a pure state machine where useful:

- Replace independent fire-and-forget directive tasks with one cancellable task/executor.
- Increment a generation for every new local-play, next, previous, jump, seek, route rebuild, and
  failure recovery request.
- Cancel/retire the prior generation before replacing the queue or player item.
- For `startLocalPlayback(queue:selectedTrackID:)`:
  1. validate the exact selected track and local file;
  2. publish `loading` for the selected track, not the old track;
  3. pause/retire the prior item;
  4. activate the audio session and handle failure;
  5. load and await the new item becoming ready;
  6. apply a queued seek, if any;
  7. request play and confirm rate;
  8. only then publish playing state and Now Playing metadata.
- Use stable track IDs instead of stale list indexes at all entry points.
- Route playlist, album, search, downloaded-track, App Intent, restore, and Continue-on-Watch starts
  through this transaction.
- Queue a seek made during loading and apply it after readiness; never seek the previous item.
- Reset elapsed, duration, failure, route, and artwork state at the correct transaction boundary.
- If the exact selected file is absent, show a useful failure and leave the existing queue untouched
  or clearly parked according to the request policy.
- `WatchPlayerEngine` may continue to decide queue semantics, but it must not be allowed to claim
  platform playback succeeded without the output result.

Unit tests:

- A→B replacement always ends on B;
- rapid A→B→C leaves only C active;
- a late A readiness/failure callback cannot alter B;
- play/pause during loading has deterministic final state;
- seek during loading applies to the new item only;
- next/previous/jump while loading do not resurrect the old item;
- route failure leaves the queue and selected track truthful;
- item failure skips or stops according to repeat/queue policy without a false playing state;
- restoration loads only after an explicit resume/play request;
- restore cannot overwrite an already active newer request.

### Phase 4 — Truthful Now Playing and remote-command integration

- Build Now Playing metadata from confirmed state, not the engine's requested state.
- Use actual duration once available; never publish `-0:00` as if it were authoritative.
- Use confirmed `AVPlayer.rate` for `MPNowPlayingInfoPropertyPlaybackRate`.
- Re-publish metadata after readiness, duration, artwork, play, pause, stop, failure, and track change.
- Clear metadata only for an intentional stop/end-of-queue or a confirmed failed request; do not clear
  it during a transient loading transition if the UI is still presenting the same request.
- Keep remote command handlers, but return/represent failure honestly where the command API permits;
  do not return an apparent success for a known-unavailable route or missing item.
- Add a passive `On Apple Watch`/`On iPhone` ownership label if needed, but remove the persistent
  target selector and its confirmation dialog from the Now Playing surface. Target selection must not
  be the user's way to recover from an audio failure.
- Preserve Crown volume for local playback and the supported system/remote behavior for iPhone
  playback. Remove any visible control that implies a second unsupported volume path if it remains.

Unit/UI contract tests:

- requested-playing but rate-zero renders loading/failure, not playing;
- ready paused renders paused with correct duration;
- confirmed playing renders rate `1.0` and advancing elapsed time;
- duration changes after readiness update system metadata;
- failure clears or replaces stale metadata correctly;
- remote command/Now Playing metadata follows the active engine;
- no target selector remains if the automatic-routing decision is shipped;
- accessibility identifiers and labels remain stable for artwork, title, elapsed, remaining,
  play/pause, previous, next, route failure, and close.

### Phase 5 — Route, interruption, background, and charging behavior

- Keep the app-owned route card, but make it a projection of the real activation result.
- Test the watchOS route matrix where the environment supports it:
  - paired Bluetooth headphones connected;
  - headphones disconnected;
  - route picker presented and accepted;
  - route picker dismissed;
  - supported watch built-in speaker;
  - watch charging, where long-form built-in speaker playback may be unavailable;
  - route removed during loading and during playback;
  - interruption begin/end with and without `shouldResume`;
  - media-services reset.
- On route loss, pause the platform player immediately, update confirmed state, persist position, and
  preserve the queue. Do not start a second engine.
- On interruption/media reset, rebuild once, re-load the current item through the transaction, and
  resume only when the policy and session result allow it.
- Verify background audio mode remains present and does not hide a failed activation.

### Phase 6 — Diagnostics and observability

Extend the privacy-safe diagnostics model with coarse, useful fields:

- request generation and hashed track correlation ID;
- request phase and final state;
- activation result: active/false/threw plus stable error domain/code;
- route output count and port types;
- item status and error domain/code;
- duration result and player rate;
- whether the app was foreground/background and whether a retry was user initiated.

Add a DEBUG-only diagnostics surface/identifiers for UI smoke and on-device testing:

- `watch.now.debugSession` — activation result;
- `watch.now.debugItemState` — item readiness state;
- `watch.now.debugRate` — actual AVPlayer rate;
- `watch.now.debugError` — short mapped failure, absent when healthy.

Do not include URLs, credentials, device names, or raw library identities in exported diagnostics.

Tests:

- every failure path records one useful event;
- a successful start records activation, ready, and playing transitions;
- cancellation does not leave a false terminal failure;
- exported diagnostics remain redacted and bounded.

### Phase 7 — Real AVFoundation tests and smoke changes

Attempt the strongest executable platform verification available:

1. Add a watchOS unit/runtime test target if Xcode can link it cleanly. Exercise the production
   `AVPlayerOutput`/adapter against a bundled playable fixture and a malformed fixture, asserting real
   `AVPlayerItem.status`, duration, and rate transitions.
2. Exercise the production `AVAudioSession` activation path on the watch simulator and record its
   actual result. The test must accept that the simulator cannot prove audible output; it must still
   catch ignored `false`, thrown activation errors, and route-state regressions.
3. If direct watchOS unit linking is not supported by this project/toolchain, retain the same
   production code path behind DEBUG test hooks and assert it through `WatchSmokeUITests`; document
   the limitation instead of substituting a fake AVAudioSession.
4. Add/extend the physical-device check to run the same diagnostics while listening for audible
   output. This is the only gate for “I can hear it.”

Update `WatchUITests/WatchSmokeUITests.swift` so the single smoke test:

- boots with seeded audio;
- starts a local track and waits for `debugItemState=ready`, a non-zero `debugRate`, advancing
  elapsed time, and non-zero duration;
- pauses and verifies rate/elapsed freeze, then resumes and verifies rate/elapsed advance;
- performs rapid track replacement and verifies the selected title and elapsed reset belong to the
  newest request;
- exercises album, playlist, search, restore, and Continue-on-Watch entry points where practical;
- exercises the route-failure UI only when the simulator reports no route, without requiring audible
  output;
- dismisses/reopens the app-owned Now Playing surface without stopping playback;
- terminates cleanly and leaves no stale debug state.

Keep the smoke test shape guard satisfied: exactly one method named as a smoke test in the watch UI
test directory. Update identifiers and helper methods together with the view.

Run the relevant commands:

- `swift test`;
- `make ci-guards`;
- `scripts/verify-ui-smoke-tests.sh`;
- `xcodebuild test -project Tonearm.xcodeproj -scheme TonearmWatch -destination 'platform=watchOS Simulator,name=Watch-Large' -only-testing:WatchUITests/WatchSmokeUITests`;
- any new watch runtime test target on the available simulator;
- the repository's normal local suite before commit. The iOS UI regression suite remains separate and
  must not be wired into CI or the pre-commit hook.

### Phase 8 — Final review, gap closure, commit, and push

Before declaring completion:

- Review every plan item above against the final diff, not only the test output.
- Search for and eliminate all remaining optimistic playback claims, ignored activation results,
  independent directive tasks, stale target-selector assumptions, silent missing-file returns, and
  generic-only AV failures.
- Confirm the artwork pipeline and watch architecture guards still pass.
- Confirm there are no generated build artifacts, credentials, unrelated files, or accidental project
  regeneration changes.
- Run `git diff --check` and inspect `git diff --stat` plus the full relevant diff.
- Run the full `swift test` to completion and record exact counts below.
- Run the watch simulator smoke and record exact result below.
- Run the strongest real AVAudioSession/AVPlayerItem checks available and clearly distinguish
  simulator/platform evidence from physical audible-output evidence.
- Only after all actionable gaps are closed, create one commit on `main` with a descriptive message.
- Push `main` to the configured origin. If push or its remote checks fail, preserve the exact failure
  and do not claim completion.

## Verification record — fill only with actual evidence

### Host/unit tests

- `swift test` (final run 2026-09-01 22:06): **1,790 executed, 8 skipped, 0 failures**.
- Compiler warning audit: **0** `warning:` diagnostics in the final Swift build/test log. The
  package manifest's invalid/missing excludes and existing Swift 6 warning debt were corrected.
- Focused playback set: **38 tests**, covering `WatchAVPlayerItemTests`, directive ordering,
  runtime-state transitions, and `WatchPlayerEngine`; all passed in the full run.
- Real `AVPlayerItem` checks: **2 passed**. A real remuxed watch-audio fixture reached
  `.readyToPlay` with finite duration; a malformed fixture reached `.failed` with a mapped code.
- Direct `AVAudioSession` unit linking was not available for the app-private watch adapter in this
  package/toolchain. The production activation path was exercised by the watch simulator smoke;
  the app exposed the actual session/phase result and reached confirmed playing. No fake session
  result was substituted.

### Simulator/smoke

- `make ci-guards`: **passed** (Swift 6 contract, StoreKit boundary, codename leak, watch
  architecture/protocol boundaries).
- `scripts/verify-ui-smoke-tests.sh`: **passed**.
- Watch simulator build: **succeeded with 0 compiler warnings and 0 errors**.
- Watch simulator smoke (final source, 2026-09-01 22:13): **1 test, 0 failures**, 89.482 seconds.
  It asserted ready item state, positive AVPlayer rate, positive duration, advancing/frozen clock,
  pause/resume, rapid next/previous, route-card behavior when applicable, ownership label, close
  without stopping, browsing, and clean termination. Xcode's metadata extractor emitted one
  environment/tool warning about no `AppIntents.framework` dependency; no source compiler warning
  was emitted.
- iOS smoke/regression: run only if relevant and environment permits; do not conflate it with watch
  audio output.

### Physical-watch evidence

Still pending until run on a paired physical watch. The simulator cannot prove audible output.
Record watch model, watchOS version, route, charging state, and whether audio was audibly heard for:

- Bluetooth headphones connected before play;
- route picker selection after play;
- supported built-in speaker;
- charging with no Bluetooth route;
- route removal/reconnection;
- background/wrist-down playback;
- interruption and media-services reset;
- rapid track replacement;
- system Now Playing duration, artwork, controls, and Crown behavior.

### Final review sign-off

- [x] All implementation phases completed in one pass.
- [x] Copious pure unit tests added and passing.
- [x] Real AVPlayerItem path exercised.
- [x] Real AVAudioSession activation result exercised through the production simulator path; direct
  standalone app-private adapter linking limitation documented above.
- [x] Watch smoke updated and passing.
- [x] Full suite and CI guards passing.
- [x] Final diff reviewed against this plan and actionable gaps closed.
- [ ] Commit created only after review.
- [ ] Push completed and remote result recorded.
