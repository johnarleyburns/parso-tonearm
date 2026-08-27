# Phase 6 — Watch file installation and offline cutover (working log)

Landed as one commit (owner: "strictly one commit"). Nothing landed until the whole tree
compiled and the SPM suite + both simulator smoke lanes passed.

## Work items — all complete

### A. Protocol / Core (SPM, `swift test`)
- [x] `Sources/WatchProtocol/WatchAudioFileMetadata.swift`
- [x] `Sources/WatchCore/Sync/WatchFileInstaller.swift`
- [x] `Sources/WatchCore/Sync/WatchSyncActor.swift`
- [x] `WatchLibraryRepository.removeTracks`
- [x] `WatchConnectivityCoordinator.receiveFile` → observer
- [x] `WatchConnectivityObserver.didReceiveAudioFile`
- [x] `Tests/WatchFileInstallerTests.swift` (12), `Tests/WatchSyncActorTests.swift` (5)

### B. Delete TonearmWatchLegacyCore
- [x] `Package.swift`: product, target, `TonearmCoreTests` dep, `Sources/WatchLegacy` exclude
- [x] `rm -rf Sources/WatchLegacy`
- [x] `project.yml`: dropped `TonearmWatchLegacyCore` dep on `TonearmWatch`
- [x] `rm WatchApp/WatchSyncHandler.swift WatchApp/WatchSessionAdapter.swift`
- [x] `Tests/WatchArchitectureBoundaryTests.swift` rewritten to `TonearmWatchProtocol` only
- [x] `Tests/PhoneWatchDownloadTests.swift:151` kept (phone-side GRDB table name)

### C. Watch app (Xcode `TonearmWatch`, watchOS build)
- [x] `WatchApp/App/WatchFeatureFlags.swift` **deleted** — SwiftData is unconditional
- [x] `WatchApp/App/WatchLibraryModel.swift` (NEW) — `@MainActor` observable, `[WatchTrackSnapshot]`
      / `[WatchPlaylistSnapshot]` / storage / derived albums
- [x] `WatchApp/App/WatchAppAssembly.swift` — assembles repository + installer + coordinator +
      transport adapter + sync actor + fanout observer + model; one-time legacy-audio migration
- [x] `WatchApp/App/WatchDefaultsSyncStateStore.swift` (NEW) — persistent `WatchSyncStateStore`
- [x] `WatchApp/App/WatchConnectivityObservers.swift` (NEW) — fanout + reachability observers
- [x] `WatchApp/PlatterheadWatchApp.swift` — drops WatchSyncHandler + legacy import + legacy upgrade
- [x] `WatchApp/WatchPlayer.swift` — `WatchTrackSnapshot`; local file URL from the store audio dir;
      no streaming path; fetch overlay removed
- [x] `WatchApp/WatchFixtureSeeder.swift` — `repository.markAsset` + two playlists; robust bundle
      lookup
- [x] `WatchApp/Views/*` (7) + `WatchComponents.swift` — snapshot types + shared model; all
      accessibility IDs preserved; still exactly one watch UI smoke method
- [x] `WatchNav` enum — associated values are `String` IDs
- [x] `WatchApp/Views/WatchFetchOverlay.swift` **deleted** (no fetch-from-phone path offline)

### D. Phone side (`Sources/App`, Xcode iOS build)
- [x] `Sources/App/Watch/PhoneWatchDownloadAdapter.swift` — `PhoneWatchSessionFileTransfer` sends
      `WatchAudioFileMetadata` over the §5 transport seam
- [x] `Sources/App/Watch/PhoneWatchRuntime.swift` (NEW) — the phone coordinator + download manager
      stack, and the `AppState` glue
- [x] `Sources/App/AppState.swift` — `watchRuntime` replaces `PhoneWatchSessionAdapter` +
      `WatchTransferController`; all public watch methods kept and rewired
- [x] `rm Sources/App/PhoneWatchSessionAdapter.swift`
- [x] `Sources/Features/Settings/WatchSettingsView.swift` — reads runtime-derived `AppState` state
- [x] `Sources/WatchSync/PhoneWatchProjection.swift` — `playlistRowID` / `albumRowID` public seams

### E. Guards + project + tests
- [x] `scripts/check-ci-guards.sh` — `TonearmWatchLegacyCore` now forbidden; any watch-linked GRDB
      fails; `Sources/WatchLegacy` must not exist; `WatchFeatureFlags.swift` must not exist
- [x] `make project` + `git add -f Tonearm.xcodeproj/project.pbxproj`
- [x] `rm -rf .build && swift test`
- [x] `make ci-guards`
- [x] iPhone 16 + Watch-Large simulator builds; iPhone + watch UI smoke lanes

### F. Docs
- [x] `IMPLEMENTATION_PLAN.md` §15 Phase 6 entry + deferred rows
- [x] `current_status.md` Phase 6 → done, Phase 7 next
