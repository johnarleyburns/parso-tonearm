import TonearmWatchCore
import TonearmWatchLegacyCore

@MainActor
final class WatchAppAssembly {
    static let shared = WatchAppAssembly()
    let storeBootstrap = WatchStoreBootstrap.open()
    let usesSwiftDataArchitecture = WatchFeatureFlags.swiftDataWatchArchitecture
    let legacyStore = LegacyWatchLibraryStore.shared
    private init() {}
}
