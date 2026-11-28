# Build and testing comparison: Tonearm vs Voxglass

Audit date: 2026-11-17. Changes prepared locally on `perf/ci-validation-builds`.

## Executive summary

Tonearm's recent successful PR validation takes approximately twice as long as Voxglass's. The largest immediately addressable difference is that Tonearm compiles both Intel and ARM simulator architectures, while Voxglass uses device builds (one phone architecture). Tonearm also has substantially more application code, more tests, and additional discovery/database/neural dependencies.

The optimization implemented here replaces simulator compilation with unsigned generic iOS/watchOS device builds, matching Voxglass and the owner's CI/CD policy. Expected PR wall-clock savings: **2–3 minutes**, approximately **14–21%** of the recent 14.5-minute median. This is an estimate pending a real macOS CI run. PR verification is also consolidated into the required `validate` job (saving 4–9 macOS runner-minutes per PR); redundant local IPA export is removed (saving an estimated 45–70 seconds per release). The device-only validation change does not speed the separate release archive directly.

## Measurement method and limitations

Read both local repositories and GitHub Actions logs/job-step timestamps. Sample: the latest five successful `pr-validation.yml` runs and five successful push-triggered `ios.yml` runs per repository at audit time (20 runs). Samples are recent successes, not a controlled benchmark; hardware, source revisions, cache warmth and shared-runner contention differ. Queue time is excluded from job durations. End-to-end workflow times include scheduling between jobs, but exclude Apple's subsequent build processing.

| Metric, median of five successes | Tonearm | Voxglass |
|---|---:|---:|
| Required PR validation job | 14m 28s | 6m 59s |
| Main workflow elapsed to completion | 20m 06s | 11m 39s |
| Main host test job | 6m 44s | 4m 17s |
| Main release job | 13m 02s | 6m 42s |
| Archive step alone | 7m 46s | 4m 55s |
| TestFlight upload/export-upload step | 4m 16s | 1m 18s |

Tonearm additionally exports the IPA in a separate step (median 63s), so its upload-step duration is not an exactly equivalent phase. Voxglass has a 72.3-minute workflow outlier whose active jobs total much less; queue/scheduling delay matters independently of build speed. The latest Tonearm main run took only 14m 01s, so the full gap varies considerably.

Sample run IDs:
- Tonearm PR: 44136321780, 44017547802, 43978345908, 43976051002, 43975429181.
- Voxglass PR: 44136486806, 44009354120, 43925808035, 43793169544, 43609190515.
- Tonearm main: 44139564104, 44019126540, 43980548003, 43978154441, 43974066106.
- Voxglass main: 44010303853, 43927188744, 43800876818, 43610024473, 43470135712.

## Detailed comparable PR runs

Both validation jobs selected Xcode 27.2 and ran on the `xcode-27` runner label.

| Phase | Tonearm, run 44136321780 | Voxglass, run 44136486806 |
|---|---:|---:|
| Initial guards/setup before package tests | 31s | 50s |
| First SwiftPM invocation, including planning/build/tests | 237s, production harness | 149s, all logic tests |
| Additional full SwiftPM invocation | 230s | none |
| Xcode/project preparation after tests | 19s | <1s |
| Phone scheme build, including embedded Watch dependencies | 409s | 134s |
| Explicit Watch scheme build | 20s | 11s |

Tonearm's first filtered invocation compiles the package test graph, not only eight harness methods. Its subsequent full test run performs a warm build (4.29s compiler report), then runs the discovery and core XCTest suites mostly sequentially. Do not mistake the entire first 237 seconds for duplicate harness execution that could simply be removed: most is necessary build work. The actual eight harness tests take roughly 0.05 seconds on their duplicate run.

Sources: [Tonearm PR run](https://github.com/johnarleyburns/parso-tonearm/actions/runs/44136321780), [Voxglass PR run](https://github.com/johnarleyburns/parso-voxglass/actions/runs/44136486806).

## Findings and savings estimates

### 1. Build device targets instead of simulators — implemented locally

Tonearm logs show every phone compilation targeting both `arm64-apple-ios…-simulator` and `x86_64-apple-ios…-simulator`; Watch likewise compiles both simulator architectures. Voxglass phone compilation targets ARM device code. This doubles architecture-specific compilation work in Tonearm, although shared resolution, assets and other tasks prevent an exact 50% wall-time saving.

`scripts/build-apps-for-validation.sh` uses `generic/platform=iOS` and `generic/platform=watchOS` with `CODE_SIGNING_ALLOWED=NO`, matching Voxglass. Both app schemes are checked with the default device architectures; neither host-CPU overrides nor simulator builds are used. No physical device is required for compilation. `scripts/ci-validate.sh` calls the driver. Release archive settings are untouched. Simulator compatibility is outside CI coverage by explicit owner preference.

Estimate: save **2–3 minutes per PR validation**, from the observed 429-second phone-plus-Watch build phase. This can also reduce local/issue-worker/repair validation time when they use the same script. Hosted `ios.yml` test and archive jobs do not call this script, so their durations are unchanged.

### 2. Avoid duplicate harness execution — implemented locally

The dedicated production regression command remains mandatory and runs first, retaining its artifact and nonzero-test checks. The following full suite excludes only `TonearmProductionRegressionTests`, which already passed.

Estimate: **less than a few seconds**; primarily removes redundant work and makes coverage accounting clearer. This does not avoid the cold compilation or a SwiftPM invocation.

### 3. Adopt parallel test execution selectively — next priority

Voxglass has 1,242 Swift Testing tests across 165 suites in its detailed run, executing in 21.35 seconds after compilation. Tonearm's latest hosted run executes 1,892 XCTest tests (21 skipped) in 137.5 seconds, plus Swift Testing tests; its detailed validation run spends approximately 206 seconds inside the two large XCTest targets. Suite size, test type and host performance all differ.

Apple documents that Swift Testing runs tests concurrently by default, whereas XCTest's default is sequential. Start by profiling/parallelizing isolated discovery and pure-domain suites, using bounded XCTest workers as a smaller first experiment before a wholesale migration. Audit Keychain accounts, singleton mutation, URLProtocol registration, fixed temp filenames and shared resource fixtures first. For example, `PhoneWatchDownloadTests.swift` has fixed temporary artwork filenames. Do not blindly enable parallelism for the full suite.

Estimate: **1–2 minutes per PR**, **45–90 seconds per hosted test run**, after isolation and tuning. These are modeled ranges, not measured results. Macro expansion and extra worker processes may offset some runtime savings. Keep scale/correctness tests: the 20k-track test guards an SQL-variable-limit regression and is not merely a benchmark to skip.

### 4. Stop validating the same PR in two independent full test jobs — implemented locally

Tonearm runs SwiftPM tests in both `pr-validation.yml` and the `ios.yml` PR test job. The latest duplicate hosted job costs approximately eight runner-minutes; recent main test jobs range roughly four to nine minutes. Voxglass also duplicates work between its required validation and separate compile/logic jobs, so this is not a practice worth copying.

The change removes the `pull_request` trigger from `ios.yml`. `pr-validation.yml` keeps the required `validate` job, production harness, full Swift suite and platform compilation. Main pushes and manual dispatches retain the existing test job and `testflight-build` dependency, verifying merged code before signing/upload. Live ruleset inspection confirmed that `validate` is the only required check. Workflow names and job IDs remain stable for release-repair and delivery automation; no branch-rule edits are needed.

Estimate: **4–9 runner-minutes saved per PR**, generally **little immediate wall-clock benefit**, because the longer validation job is already the merge gate. Reduces contention on scarce macOS runners.

### 5. Cache the actual SwiftPM work, with toolchain/platform separation

Tonearm's existing hosted cache includes `~/.swiftpm` and Xcode `SourcePackages`, but not the CLI package `.build` directory. Required PR validation has no explicit Actions cache. Voxglass has no magic cache advantage here either. There is an opportunity in both repos.

Measure cache hits, fetch/resolution time and compile time separately. Start with resolved dependency checkouts/downloads; pilot a dedicated host-test `.build` cache keyed by OS, architecture, exact Xcode/Swift version, dependency lockfiles and a source revision, with compatible restore keys. Never share signed archives or simulator/device compiled products across incompatible environments. Cache transfer cost and Xcode's file timestamps can erase expected incremental gains.

Estimate: **30–90 seconds on warm compatible host-test runs**, potentially more on cold dependency work; low confidence until measured. Do not add this estimate mechanically to parallelism savings. Release build caches need a separate pilot.

### 6. Control release packaging and upload overhead

Tonearm's median archive is 171 seconds longer than Voxglass's. It links GRDB, discovery and audio analysis code, and ships the stems model; Voxglass consumes the streaming/playback engine products and its hand-rolled SQLite layer. Tracked production Swift is roughly 70.7k lines/412 files versus 45.8k/233 files (includes app/extensions/Watch, excludes tests/scripts/tools); this is not a like-for-like app size.

Tonearm's model fetch was only 9 seconds in the detailed release, so caching the model download is not the highest-return task. Its upload/export-upload step is 178 seconds slower at the median. In the detailed release, actual upload progress occupies only about six seconds near the end of a 256-second step; it would be incorrect to label all of that network transfer. Collect Xcode distribution timing and IPA/dSYM/model sizes before proposing a packaging change. Confirmed: the standalone `Export IPA` command exports to `./output`, then the upload step runs `xcodebuild -exportArchive` again against `./build/Tonearm.xcarchive`, using the same export-options plist with `destination=upload`. No downstream consumer reads the intermediate IPA; delivery metadata comes from the archived app. Voxglass already exports/uploads directly from the archive. Removed the standalone export, preserving upload-mode packaging/signing options, retry policy, transport diagnostics and delivery traceability.

Estimate: **45–70 seconds per release**, based on the removed export step (five observed durations: 47, 47, 70, 66, 63 seconds). No reliable estimate yet for archive/compiler or Apple-service preparation savings. Moving bundled models to ODR is a product/offline-availability change and is not part of a build optimization.

### 7. Improve observability using Voxglass's test driver pattern

Voxglass's `ci-logic-tests.sh` uses a pseudo-terminal for unbuffered output and samples hung test processes before its watchdog stops them. Tonearm's detailed PR log delays test output by over a minute; embedded test timestamps differ from log arrival time. Borrow the streaming/watchdog pattern, and emit per-phase elapsed times plus `xcodebuild -showBuildTimingSummary`. This improves diagnosis; it is not a claimed speedup for successful runs.

## Recommended rollout and combined expectation

1. Measure the locally implemented device-only build change in macOS PR CI. Expected median PR reduction: **14.5 → 11.5–12.5 minutes**.
2. Pilot bounded parallelism on isolated tests. With step 1, a reasonable provisional target is **9.5–11.5 minutes**; verify repeatability and no shared-state flakes before enabling broadly.
3. Measure the implemented PR workflow consolidation (expected 4–9 runner-minutes per PR), then pilot compatible compilation caching. Keep host tests, unsigned device compilation and release archive measurements separate.
4. Verify direct archive export/upload on the next release; removal of the duplicate export should save **~1 minute**. PR-only changes above do not improve main-to-TestFlight time directly.

All ranges are estimates; compare at least three similar runs before/after, recording architecture, CPU/RAM, toolchain, cache hit, source revision and queue delay. Do not promise a six-minute PR merely because Voxglass achieved one.

## Validation of local changes

- Added `scripts/tests/test-ci-build-efficiency.sh` first; it failed because the build driver did not exist.
- Green: mocked execution of the real build driver: both generic device destinations, signing disabled, no simulator destinations or architecture/global SDK overrides, failure propagated without running the second build.
- Green: parsed-workflow tests for one PR verification path and merged-code test gating; one archive export/upload with signing/traceability contracts; retry-policy behavior; production-harness wiring regression; complete `scripts/ci-validate.sh --fast`; shell syntax; `git diff --check`.
- Full Apple compilation and Swift tests cannot run on this Linux host. The required production regression command was attempted; platform/dependency compilation fails before tests. Real timing improvements remain unverified until macOS CI.
- No changes made to Voxglass. All changes are prepared as one local PR candidate; no branch or PR pushed by this audit.

References: [Apple: test migration and parallelism](https://developer.apple.com/documentation/testing/migratingfromxctest), [Apple: Go further with Swift Testing](https://developer.apple.com/videos/play/wwdc2024/10195/).
