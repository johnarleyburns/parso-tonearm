import Foundation
import TonearmWatchCore
import TonearmWatchLegacyCore

@MainActor
final class WatchAppAssembly {
    static let shared = WatchAppAssembly()
    let storeBootstrap = WatchStoreBootstrap.open()
    let usesSwiftDataArchitecture = WatchFeatureFlags.swiftDataWatchArchitecture
    let legacyStore = LegacyWatchLibraryStore.shared
    let repository: WatchLibraryRepository?

    private(set) var legacyUpgrade: WatchLegacyUpgradeOutcome?

    private init() {
        if let container = storeBootstrap.container, let audio = storeBootstrap.audioDirectory {
            repository = WatchLibraryRepository(container: container, audioDirectory: audio)
        } else {
            repository = nil
        }
    }

    /// The one-time adoption of the old GRDB watch library, gated on the still-off Phase 1 flag so
    /// the shipped app keeps its existing behavior until the Phase 6 cutover.
    ///
    /// `LegacyWatchLibraryStore` supplies the snapshot from here rather than from inside
    /// `TonearmWatchCore`, which is what keeps GRDB out of the new architecture's product closure.
    func runLegacyUpgradeIfNeeded() async {
        guard usesSwiftDataArchitecture, legacyUpgrade == nil, let repository else { return }
        let store = legacyStore
        do {
            legacyUpgrade = try await WatchLegacyUpgrade(repository: repository).run {
                try await store.migrationSnapshot()
            }
        } catch {
            // The store itself refused the write; the next launch retries. Audio is untouched either way.
            legacyUpgrade = nil
        }
    }
}
