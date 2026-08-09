# Tonearm Swift 6 Migration Plan

## Goal

Move every Platterhead/Tonearm package and Xcode target to Swift 6 language
mode with complete concurrency checking and no repository-owned build warning.
The package, iPhone app, share extension, widget extension, watch app, unit
tests, and both UI smoke bundles must all use the same Swift 6 contract.

This is a compiler and source-safety migration only. It must not change product
behavior, database or CloudKit schemas, WatchConnectivity payloads, OAuth
formats, stored playback snapshots, entitlements, deployment targets, or
user-visible naming.

## Current State

Tonearm is not currently a Swift 6 project:

- `Package.swift` declares Swift tools version 5.9 and therefore builds
  `TonearmCore` and `TonearmCoreTests` in Swift 5 mode.
- XcodeGen's `project.yml` sets `SWIFT_VERSION: "5.10"`; every Xcode target
  inherits it.
- The generated `Tonearm.xcodeproj` contains `SWIFT_VERSION = 5.10` in Debug and
  Release project configurations.
- Neither build system explicitly enables complete strict-concurrency checking.
- CI runs `swift test` on pull requests, but app/extension/watch compilation is
  deferred to the signed TestFlight job and therefore may be skipped when
  signing secrets are unavailable.

### Target matrix

| Target | Current mode | Required mode |
| --- | --- | --- |
| `TonearmCore` | Swift 5 via tools 5.9 | Swift 6 |
| `TonearmCoreTests` | Swift 5 via tools 5.9 | Swift 6 |
| `Tonearm` | Swift 5.10 | Swift 6 |
| `TonearmShareExtension` | Swift 5.10 | Swift 6 |
| `TonearmWidgetsExtension` | Swift 5.10 | Swift 6 |
| `TonearmWatch` | Swift 5.10 | Swift 6 |
| `TonearmUITests` | Swift 5.10 | Swift 6 |
| `WatchUITests` | Swift 5.10 | Swift 6 |

The local audit used Xcode 26.6 / Swift 6.3.3 and forced Swift 6 with complete
checking in an isolated SwiftPM scratch directory. GRDB 7.11.1 compiled under
that probe, so the existing dependency is not a migration blocker.

### Initial compiler findings

The first Swift 6 package build stops in `TonearmCore` with these owned-code
groups. More diagnostics may appear after these are fixed.

| Area | Diagnostic class | Required direction |
| --- | --- | --- |
| Audio/domain configuration | Immutable static defaults use value types that are not Sendable | Add Sendable through each all-value graph |
| App Intents | Intent metadata and shortcut color are mutable static variables | Use immutable `static let` metadata where protocol requirements permit |
| Remote providers | Actor methods return non-Sendable access/client values | Make credentials, environment, connector, and client snapshots Sendable |
| Playback persistence | Two mutable process-global test overrides are concurrency-unsafe | Replace globals with explicit persistence dependencies |
| Watch catalog/transfer | DTOs and GRDB records are captured by Sendable database closures | Make transfer values Sendable and type the transport boundary |
| AVFoundation EQ tap | `AVAsset` crosses a main-actor boundary; SDK suggests `@preconcurrency` | Isolate player-item control on the main actor and keep realtime state behind its lock |
| App/watch framework delegates | Notification and connectivity callbacks cross actors | Parse immutable values at the callback boundary, then enter the owner actor |
| OAuth tests | `URLProtocol` response fixture is a `nonisolated(unsafe)` static | Use request-scoped or lock-protected test state |
| Existing warnings | Deprecated asset metadata access and two unused results/locals | Update API use and remove dead statements |

The existing source contains no `@unchecked Sendable` conformance and no
`MainActor.assumeIsolated`. Preserve that property. The only current unsafe
annotation is the OAuth test fixture's `nonisolated(unsafe)` static.

## Migration Rules

- Use Swift tools/language version 6.0 as the compatibility contract even when
  development and CI select a newer Swift 6 compiler.
- Preserve SwiftPM's iOS 17, macOS 14, and watchOS 10 platform declarations and
  Xcode's iOS 18/watchOS 11 deployment targets.
- Treat `project.yml` as the Xcode source of truth. Never hand-edit the generated
  `.pbxproj`; regenerate it with XcodeGen and commit both changes.
- Do not enable global default main-actor isolation. Audio processing, network,
  GRDB, sync, cache, and watch-transfer work must retain appropriate background
  execution.
- Prefer immutable Sendable snapshots, actors, and explicit synchronization.
  Do not introduce `@unchecked Sendable`, `nonisolated(unsafe)`,
  `MainActor.assumeIsolated`, or broad `@preconcurrency` imports to silence the
  compiler.
- Permit a narrow `@preconcurrency import` only if a correctly isolated Apple
  framework boundary still fails because of SDK annotations. Document the Xcode
  version, exact boundary, and removal condition beside it.
- Preserve existing serial execution requirements for integration and UI smoke
  tests; language migration must not weaken behavioral or performance coverage.

## Implementation

### 1. Add migration guardrails and establish the baseline

- Add a static guard that fails when `Package.swift` uses tools below 6.0, when
  any package target declares Swift 5, or when `project.yml`/the generated
  project contains a Swift version below 6.0.
- Capture clean SwiftPM, generic iPhone, generic watch, and Release archive logs
  before source changes. Classify diagnostics by value-model, actor, framework,
  persistence, and test boundary.
- Build again after each category is resolved because the compiler can reveal
  later diagnostics only after earlier module-emission errors disappear.

### 2. Migrate the package manifest and pure value graph

- Change the manifest to `// swift-tools-version: 6.0` and explicitly set
  `.swiftLanguageMode(.v6)` on `TonearmCore` and `TonearmCoreTests`.
- Add `Sendable` to immutable or independently copied values used in static
  defaults, tasks, actors, GRDB closures, and watch messages. The first pass
  includes:
  - `AmbientTrack`, `EQPreset`, `EQSettings`, `ProAudioSettings`, and their
    nested parametric-EQ/convolution value types.
  - `BiquadCoefficients`, `CrossfeedMatrix`, `ConvolutionPlan`, ReplayGain tags,
    listening-stat summaries, and tag-edit proposals and nested fields.
  - `ProFeature`, `SourceKind`, `CloudDriveAccess`, Plex/Jellyfin client
    descriptors, remote connector/guide values, and their nested enums.
  - Watch track/playlist DTOs, manifest/transfer records, queue items, origins,
    states, planner inputs, and snapshots.
- Add conformance only when every stored member is Sendable. Split out immutable
  snapshots rather than marking a value Sendable while it contains framework or
  mutable reference objects.
- Convert AppIntent `title`, `description`, `openAppWhenRun`, and shortcut tile
  metadata from `static var` to immutable `static let` values where the App
  Intents protocols expose get-only requirements. Keep `appShortcuts` computed
  if its builder requires it.

### 3. Remove global mutable test seams

- Replace `PlaybackStateFileStore.fileURLOverride` with an explicit file
  location argument/dependency. Production uses the existing app-group then
  Application Support resolution; tests pass their temporary URL directly.
- Replace `PlaybackStateStore.defaultsProvider` with an immutable
  `PlaybackStatePersistence` dependency owned by `PlaybackPositionPersistor`
  and injected into `AudioPlayer`. Its live configuration resolves app-group
  defaults and the normal file URL; tests inject a suite and temporary file.
- Keep convenience static load/save/clear entry points only if they use an
  immutable live configuration and contain no mutable global state.
- Replace `RefreshMockURLProtocol.mockJSON` with request-scoped fixture data or a
  lock-protected registry keyed by the test session/request. Clear it in teardown
  and test concurrent requests with different responses to prove isolation.
- Update playback durability tests to construct dependencies per test instead of
  resetting process-global closures in setup/teardown.

### 4. Repair actor and framework boundaries

- Main-actor isolate the control surface of `EQAudioTap` that consumes
  `AVPlayerItem` and compiles/publishes kernels. Keep its realtime callback
  storage separate and protected by the existing `os_unfair_lock`; callbacks
  must perform no actor hop, allocation, or blocking lock on the audio thread.
- Replace deprecated `formatDescriptions` access with the asynchronous asset
  property-loading API while keeping AVFoundation objects within their owning
  isolation domain.
- Audit `SystemPlaybackBridge`, `AudioPlayer`, artwork, CloudKit, StoreKit,
  widgets, App Intents, and share-extension callbacks. Notification callbacks
  copy primitive/Sendable fields first and then use `Task { @MainActor in ... }`
  before touching UI/player state.
- Make `WatchTransferFileProvider` and `WatchSessionWriter` explicit Sendable
  boundaries, or actor-isolate them when their conformers are UI-owned. Replace
  `[String: Any]` outside the WatchConnectivity adapter with typed Codable,
  Sendable commands and replies.
- Main-actor isolate `PhoneWatchSessionAdapter` state. Its nonisolated
  `WCSessionDelegate` callbacks must decode a typed value and enter the main
  actor without capturing `WCSession` or a heterogeneous dictionary in the
  task.
- Keep `LibraryStore`/GRDB work on its database executor. Values captured by
  `dbQueue.read`/`write` closures and returned to actors must be Sendable; never
  send a database handle or mutable record graph across the closure boundary.

### 5. Remove existing warnings

- Remove the unused `currentKeys` value in `WatchTransferQueue`.
- Replace the unused `try?` result in `WatchTransferController` with deliberate
  error handling or an explicitly discarded result only when failure is part of
  the existing policy.
- Resolve the `ProFeatureAccessError` warning by making `ProFeature` Sendable.
- Update deprecated AVFoundation format-description loading.
- Run clean Debug and Release builds and fix all additional compiler, linker,
  resource, intent-metadata, extension-safety, and localization warnings owned
  by the repository.

### 6. Switch every Xcode target

- Set `SWIFT_VERSION: "6.0"` and `SWIFT_STRICT_CONCURRENCY: complete` in the
  base settings of `project.yml`, covering the app, share extension, widget
  extension, watch app, and both UI-test targets.
- Run `xcodegen generate`, then inspect the generated project diff. It should
  contain the expected Swift setting changes and deterministic regeneration
  only.
- Build the package, iPhone scheme, watch scheme, extensions, and UI-test bundles
  in Debug. Then build/archive Release, where whole-module compilation can expose
  diagnostics not seen incrementally.
- Verify App Intents metadata extraction, widget timelines, share-extension
  activation, audio playback, and watch transfers still compile under their
  separate extension/process isolation rules.

### 7. Enforce Swift 6 in CI

- Run XcodeGen and a generated-project drift check on every pull request.
- Add unsigned generic iOS and watch compile jobs that always run, independent
  of TestFlight secrets. Building the `Tonearm` scheme must cover its embedded
  share, widgets, and watch products; also build the watch scheme directly.
- Keep `swift test` as the headless logic gate and retain the existing local
  iPhone/watch UI smoke suite.
- Capture build logs and fail on repository-owned warnings. Any unavoidable
  Apple-generated diagnostic requires an exact allowlist entry with toolchain
  version, rationale, and removal condition; do not add broad warning flags or
  suppressions.
- Keep the signed TestFlight archive as the final Release validation after the
  unsigned compile and test jobs pass.

## Public Contract Changes

Swift 6 concurrency annotations are source-visible. Expected deliberate changes
include:

- Pure audio, domain, remote-provider, GRDB record, and watch-transfer values
  gain `Sendable`.
- Cross-task closures gain `@Sendable`; UI/player callbacks gain `@MainActor`
  where appropriate.
- Watch transfer provider/writer protocols gain an explicit actor or Sendable
  contract shared by production and test conformers.
- Playback persistence becomes an injected immutable dependency instead of
  relying on process-global test overrides.
- App Intent metadata becomes immutable.

Do not alter Codable keys, raw values, OAuth endpoints, database columns,
WatchConnectivity field names, file names, app-group identifiers, or public
product behavior while making these source-level changes.

## Test Plan

Add focused coverage for:

- Each migrated value graph crossing an actor/task or GRDB closure.
- Concurrent playback persistence using separate test suites and temporary
  files without state leakage.
- Concurrent OAuth mock sessions returning their own response fixtures.
- EQ kernel publication under contention, plus a realtime-path assertion that
  processing performs no blocking actor hop or allocation.
- App Intent metadata/perform paths and main-actor interaction with app state.
- Phone/watch typed message decoding, malformed payload rejection, catalog
  transfer, retry/cancel, and manifest persistence.
- Background delegate callbacks for audio routes, interruptions, CloudKit,
  widgets, and WatchConnectivity entering the correct actor exactly once.

Run the full acceptance matrix from a clean checkout:

```sh
# Manifest/project guards and generation
xcodegen generate
git diff --exit-code Tonearm.xcodeproj
bash scripts/verify-ui-smoke-tests.sh

# Package build and tests
swift build
swift test

# Generic Debug builds
xcodebuild build -project Tonearm.xcodeproj -scheme Tonearm \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
xcodebuild build -project Tonearm.xcodeproj -scheme TonearmWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO

# Existing local smoke suite
bash scripts/run-local-test-suite.sh full

# Unsigned Release archive
xcodebuild archive -project Tonearm.xcodeproj -scheme Tonearm \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath /tmp/Tonearm-Swift6.xcarchive CODE_SIGNING_ALLOWED=NO
```

Run Thread Sanitizer during development for the EQ realtime handoff, playback
persistence, OAuth fixture registry, GRDB/watch transfer, and any framework
adapter that retains synchronized mutable state. Sanitizer runs supplement the
normal deterministic tests rather than replacing them.

## Acceptance Criteria

- `Package.swift` uses tools 6.0 and explicitly declares Swift 6 for every
  source/test target.
- `project.yml` and the generated project contain Swift 6.0 and complete
  concurrency settings, with no Swift 5 setting remaining.
- SwiftPM build/tests, generic iPhone/watch builds, share and widget extensions,
  UI smoke suites, and the Release archive all pass.
- Clean logs contain zero repository-owned warning.
- No `nonisolated(unsafe)`, `MainActor.assumeIsolated`, or
  `@unchecked Sendable` is introduced or remains.
- Any `@preconcurrency` use is narrowly documented and proven to be an Apple SDK
  annotation boundary.
- CI rejects Swift 5 configuration drift and always compiles app/watch targets
  without depending on signing secrets.
- Persistence, CloudKit, WatchConnectivity, OAuth, export, entitlement,
  deployment-target, and user-visible behavior remain unchanged.

## Delivery and Rollback

Implement on a dedicated branch in reviewable commits: guards/baseline, package
and value graph, persistence/test seams, framework/watch boundaries, Xcode
switch, then CI/documentation. Keep each commit buildable where practical and
merge only after the entire Swift 6 acceptance matrix is green.

The migration has no schema or wire-format change, so rollback is a revert of
the migration merge. Do not partially return individual targets to Swift 5;
mixed modes would weaken the cross-target concurrency contract this migration
is intended to establish.
