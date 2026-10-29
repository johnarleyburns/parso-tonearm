# CLAUDE.md

## Swift 6 hard rule

Tonearm is fully on Swift 6 language mode with complete strict-concurrency checking and is kept as warning-free as the selected toolchain permits. Do not introduce or permit any deviation, mixed Swift modes, warning suppression, or unexplained concurrency escape hatch. A commit runs `swift test` only; a push runs no tests. The UI smoke/simulator suite is run by hand before a release (see below), not on every commit.

Read [`docs/plans/tonearm-mvp-ios/HANDOFF.md`](docs/plans/tonearm-mvp-ios/HANDOFF.md) for the full operating brief. **§0 of that file is how to start a session** — the one-commit-per-task session model and the kickoff prompts.

## Three rules that get broken by being helpful

- **Work on `main`; do not create a branch.** The owner's explicit preference — agents kept opening branches and abandoning them. Commit to `main` one task per commit, and **ask before `git push`**: pushing triggers CI and a TestFlight build, so push is the approval gate, not the branch.

- **CI runs `swift test` only.** The UI regression suite (`make test-ui-regression`) is run by hand before a release. It needs Docker, a simulator and third-party demo servers. Do not wire it into CI, a git hook, or `make test-swift`. It lives in its own target and scheme (`TonearmUIRegressionTests` / `TonearmUIRegression`) so the smoke path cannot reach it — keep that separation.
- **Never commit `.test-credentials`.** Real values live there and it is gitignored; `.test-credentials.example` carries key names only. No credential belongs in a test, a compose file, a script, or a spec.
- **Jamendo starter taxonomy and eligibility are fixed contracts.** `Sources/Remote/Providers/JamendoGenreProvider.swift` is the sole genre/subgenre authority. Generate `tools/starter-catalog/jamendo_taxonomy_v1.json` from it with `python3 -I tools/starter-catalog/generate_taxonomy.py --tree Sources/Remote/Providers/JamendoGenreProvider.swift --out tools/starter-catalog/jamendo_taxonomy_v1.json`; do not hand-curate a reduced subset or query a leaf with a parent-plus-leaf AND filter. Every Jamendo track is approved for Tonearm's free open-source use: retain any source license metadata for attribution, but **never exclude a starter candidate by license or missing license URL**. Eligibility is limited to a resolvable/downloadable track with valid identity, title, artist, duration, and the node's verified leaf tag.
- **Never use `git commit --no-verify` on your own initiative.** The commit hook is mandatory; fix the underlying failure or stop and report the blocker. The one exception: the owner may explicitly ask, in the moment, for a specific commit to skip it (e.g. to avoid re-running the ~5 minute local suite when it was already run by hand immediately before) — that is the owner's call to make, not a standing permission, and it does not carry over to later commits without asking again each time.
- **Test the requested behavior before and after implementation:** for every non-UI issue, first add or strengthen a focused automated test that fails for the reported defect, then make that same test pass with the implementation. If a behavior cannot be covered automatically, explain why in the PR and add the narrowest reliable alternative verification.
- **Automated issue-intake worker contract:** in the non-interactive issue-to-PR workflow, save the requested source and test edits in the worktree. Do not personally commit, push, or open the PR because the wrapper publishes a validated saved diff. Before responding, run `git diff --check`, report `git diff --name-only`, run required tests in the foreground (never background them), and audit the actual saved diff against the issue. A prose-only description is not a deliverable.
- **Perform a completion audit before committing a PR:** re-read the entire issue and compare every requirement and acceptance criterion against the actual diff and tests. Fix every gap found, then repeat the audit until no gaps remain. Do not commit, open, or update a PR while a known issue requirement is unaddressed.
- **TestFlight labels are a state machine, not human QA:** `testflight-uploaded` means Apple accepted the binary; `testflight-processing` means Apple has not finished; `ready-for-qa` means App Store Connect reports the exact build `VALID`; `testflight-distribution-confirmed` is extra group evidence; and `testflight-access-unverified` means only that the group lookup was unavailable or empty. Never add `ready-for-qa` merely because an upload command succeeded.
- **Human QA belongs on the issue:** after installing the exact version/build, record device, OS, issue-specific scenario, and pass/fail in the issue checklist. A failure starts a repair cycle and must not be hidden by TestFlight labels.

## Mandatory production-regression workflow (red → green)

`make tonearm-production-regression` (`scripts/run-production-regression.sh`) runs the hermetic
`TonearmProductionRegressionTests` target: production queue actions, player-adapter call
verification, deterministic render/baseline comparison, accessibility strings and resource-lease
checks. No Docker, network, model download, signing secret or device. `scripts/ci-validate.sh` (used by
PR validation and the issue worker) runs it, so a failing assertion fails the PR; a generic
`swift test` pass is not evidence for issue work. It is separate from the Docker UI regression suite.

For every issue:
1. Reproduce the failing behavior: add/strengthen a harness test (or baseline) and run the command; it must fail with the screen/state/assertion named.
2. Implement the fix.
3. Rerun `make tonearm-production-regression` until green. Failures leave the actual render and diff in `.build/production-regression-artifacts` (override with `TONEARM_HARNESS_ARTIFACT_DIR`).
4. Audit production call sites (the shipping code must call the new path, not only a helper) and re-read the issue checklist.
5. Record requirement → production call site → test evidence in the PR.

Baselines live in `Tests/ProductionRegression/Baselines`; re-record only deliberately with
`TONEARM_HARNESS_RECORD=1` and review the diff. Launch keys (`TONEARM_HARNESS_ROUTE`,
`..._ACCESSIBILITYCATEGORY`, `..._COLORSCHEME`, `..._REDUCEMOTION`, `..._BASELINEDIR`, or
`-TonearmHarness<Key>` arguments) inject the configuration.

TestFlight upload is delivery only. It is not validation, and physical-device QA must never be fabricated or inferred from the harness or an upload.

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

Both apps get `AppIcon` from the designer's Icon Composer file
`Resources/AppIcon.icon`: iOS uses its squares, and `TonearmWatch` (which lists
it in its `project.yml` sources) uses its watchOS circle, the 1088 canvas. There
is intentionally **no** `WatchApp/Assets.xcassets/AppIcon.appiconset`; do not
re-add one or any PNG icon set, because two icons named `AppIcon` clash. Edit
the icon only in Icon Composer. Use destinations so Xcode selects each target's
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

Before changing the icon or the Watch catalog, run
`bash scripts/verify-watch-icon-catalog.sh`. It fails if a Watch appiconset
reappears, then compiles `WatchApp/Assets.xcassets` + `Resources/AppIcon.icon`
with the real watchOS `actool` and fails unless it writes
`CFBundleIconName = AppIcon`. `swift test` also runs `WatchAppIconCatalogTests`,
which checks the `.icon` declares the watchOS circle, is in the `TonearmWatch`
sources, and compiles with watchOS `actool`; therefore an icon regression
fails the normal commit test with the repair instructions in the failure text.
`make ci-guards` and CI run the standalone compiler check automatically. If the error
appears again, first inspect the logged `actool` command: if it says
`--platform iphonesimulator` while compiling `WatchApp/Assets.xcassets`, fix
the build invocation to use a destination; only if it says `--platform
watchos` should `AppIcon.icon` be repaired (in Icon Composer, with watchOS enabled). If `project.yml` changes,
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

After a pushed change has green CI, regularly clean local build products so
stale DerivedData and SwiftPM artifacts do not accumulate or mask a clean-build
problem. Only remove the exact repository `.build` directory and this
repository's `Tonearm-*` DerivedData directory; do not remove shared
`ModuleCache.noindex` or other projects' caches. Cache cleanup may run in the
background only after all local builds/tests have exited, and its completion
must be verified before starting another build:

```sh
find .build -mindepth 1 -depth -delete 2>/dev/null || true
rmdir .build 2>/dev/null || true
find "$HOME/Library/Developer/Xcode/DerivedData/Tonearm-<exact-id>" \
  -mindepth 1 -depth -delete
rmdir "$HOME/Library/Developer/Xcode/DerivedData/Tonearm-<exact-id>"
```

## No silent/magic background work — always visible, always in the user's control

Any background or automatic behavior (indexing, downloading a model, syncing, migrating data, retrying) must tell the user what is happening in the moment it's happening, not just eventually succeed or fail silently. Concretely:

- If the UI shows a count or progress number, it must reflect real, current work — never a number that looks like progress while nothing is actually advancing (e.g. "Indexing 2,693 tracks…" while the real blocker is an unmet precondition upstream of any indexing actually starting). When work can't proceed, say the specific reason (downloading a model, waiting for power/charging, thermal, paused, an error) — never collapse a real blocked/waiting state into a generic in-progress label.
- Every such state must be inspectable from Settings (or the relevant status screen): what's running, why, and since when — not just a spinner.
- The user must be able to stop, pause, retry, or undo the action from the same surface that reports it — a "magic" action nothing can interrupt or reverse is not acceptable, even if it usually finishes fine.
- When adding a new automatic/background feature, design its status surface and its stop/retry control in the same change that adds the feature — not as a follow-up.
