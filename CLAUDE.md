# CLAUDE.md

## Swift 6 hard rule

Tonearm is fully on Swift 6 language mode with complete strict-concurrency checking and is kept as warning-free as the selected toolchain permits. Do not introduce or permit any deviation, mixed Swift modes, warning suppression, or unexplained concurrency escape hatch. A commit runs `swift test` only; a push runs no tests. The UI smoke/simulator suite is run by hand before a release (see below), not on every commit.

Read [`docs/plans/tonearm-mvp-ios/HANDOFF.md`](docs/plans/tonearm-mvp-ios/HANDOFF.md) for the full operating brief. **§0 of that file is how to start a session** — the one-commit-per-task session model and the kickoff prompts.

## Three rules that get broken by being helpful

- **Work on `main`; do not create a branch.** The owner's explicit preference — agents kept opening branches and abandoning them. Commit to `main` one task per commit, and **ask before `git push`**: pushing triggers CI and a TestFlight build, so push is the approval gate, not the branch.

- **CI runs `swift test` only.** The UI regression suite (`make test-ui-regression`) is run by hand before a release. It needs Docker, a simulator and third-party demo servers. Do not wire it into CI, a git hook, or `make test-swift`. It lives in its own target and scheme (`TonearmUIRegressionTests` / `TonearmUIRegression`) so the smoke path cannot reach it — keep that separation.
- **Never commit `.test-credentials`.** Real values live there and it is gitignored; `.test-credentials.example` carries key names only. No credential belongs in a test, a compose file, a script, or a spec.
- **Never use `git commit --no-verify` on your own initiative.** The commit hook is mandatory; fix the underlying failure or stop and report the blocker. The one exception: the owner may explicitly ask, in the moment, for a specific commit to skip it (e.g. to avoid re-running the ~5 minute local suite when it was already run by hand immediately before) — that is the owner's call to make, not a standing permission, and it does not carry over to later commits without asking again each time.

## Git hook timeouts

- The pre-commit hook runs `swift test` only now; a normal command timeout is enough.
- `git push` needs no extra timeout; the pre-push hook runs no tests by repository policy. The pre-commit hook is the gate, so nothing is skipped by pushing.

## Xcode build and Watch AppIcon catalog — do not regress this

`Tonearm` is a multi-platform scheme: it builds the iOS app and embeds the
`TonearmWatch` watchOS app. Never pass `-sdk iphonesimulator` or `-sdk iphoneos`
to that scheme. That global override forces the embedded Watch target through
the iOS SDK; `actool` then reports the misleading error:

```
The stickers icon set, app icon set, or icon stack named "AppIcon" did not have any applicable content.
```

The catalog at `WatchApp/Assets.xcassets/AppIcon.appiconset` is intentionally
watchOS-specific. Do not add iOS icon idioms or replace its watch entries just
to silence an iOS-SDK build. Use destinations so Xcode selects each target's
platform correctly:

**Absolute command rule: never run `xcodebuild -scheme Tonearm ... -sdk
iphonesimulator...` or `... -sdk iphoneos...`, even when validating the iOS 27
app.** The global SDK flag is invalid for this composite scheme. If an iOS
destination is unavailable, fix/select the destination or build the standalone
`TonearmWatch` scheme with a watchOS destination; do not add the global SDK
override.

```sh
xcodebuild build -project Tonearm.xcodeproj -scheme Tonearm \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Tonearm.xcodeproj -scheme TonearmWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Before changing the catalog, run `bash scripts/verify-watch-icon-catalog.sh`.
It invokes the real watchOS `actool` compiler and fails if the icon set is
missing, malformed, references a missing PNG, or has no applicable watchOS
content. `swift test` also runs `WatchAppIconCatalogTests`, which checks the
catalog contents and invokes watchOS `actool`; therefore a catalog regression
fails the normal commit test with the repair instructions in the failure text.
`make ci-guards` and CI run the standalone compiler check automatically. If the error
appears again, first inspect the logged `actool` command: if it says
`--platform iphonesimulator` while compiling `WatchApp/Assets.xcassets`, fix
the build invocation to use a destination; only if it says `--platform
watchos` should the JSON or icon files be repaired. If `project.yml` changes,
regenerate with `make project` and rerun both platform-specific builds.

Run every iOS/watchOS build and simulator test command sequentially, never
concurrently: do not background an `xcodebuild`, use `&`, launch two
destinations, or use a parallel build/test wrapper. They resolve shared
SwiftPM packages and can otherwise race while creating or replacing the same
DerivedData/checkouts, producing misleading package checkout or permission
failures. The only valid order is iOS build/test first, then watchOS build/test,
then any package tests.

SwiftPM package tests are the exception: run `swift test` with its normal
parallel test execution so the suite finishes in a reasonable time. The local
test runner (`scripts/run-local-test-suite.sh`) remains single-flight at the
runner level—it waits for any existing invocation to finish—but its Swift test
phase must not add `--no-parallel`. The runner still executes the iPhone and
watch smoke tests one after the other. `make test-integration` should likewise
use the default parallel SwiftPM test execution. Do not run multiple
independent `swift test` processes concurrently against the same checkout.

## No silent/magic background work — always visible, always in the user's control

Any background or automatic behavior (indexing, downloading a model, syncing, migrating data, retrying) must tell the user what is happening in the moment it's happening, not just eventually succeed or fail silently. Concretely:

- If the UI shows a count or progress number, it must reflect real, current work — never a number that looks like progress while nothing is actually advancing (e.g. "Indexing 2,693 tracks…" while the real blocker is an unmet precondition upstream of any indexing actually starting). When work can't proceed, say the specific reason (downloading a model, waiting for power/charging, thermal, paused, an error) — never collapse a real blocked/waiting state into a generic in-progress label.
- Every such state must be inspectable from Settings (or the relevant status screen): what's running, why, and since when — not just a spinner.
- The user must be able to stop, pause, retry, or undo the action from the same surface that reports it — a "magic" action nothing can interrupt or reverse is not acceptable, even if it usually finishes fine.
- When adding a new automatic/background feature, design its status surface and its stop/retry control in the same change that adds the feature — not as a follow-up.
