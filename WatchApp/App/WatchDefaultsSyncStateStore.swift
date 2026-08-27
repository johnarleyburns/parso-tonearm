import Foundation
import TonearmWatchProtocol
import TonearmWatchCore

/// `UserDefaults`-backed `WatchSyncStateStore`. The coordinator has to know who the watch is bound
/// to and how far it has caught up *before* the SwiftData store is open — a recovered launch still
/// negotiates — so this identity lives outside the store, in defaults, exactly as §6.3 wants.
actor WatchDefaultsSyncStateStore: WatchSyncStateStore {
    private let defaults: UserDefaults
    private let pairedKey = "watch.sync.pairedLibraryID"
    private let revisionKey = "watch.sync.lastAppliedPhoneRevision"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPairedLibraryID() async -> WatchPairedLibraryID? {
        defaults.string(forKey: pairedKey).map(WatchPairedLibraryID.init)
    }

    func savePairedLibraryID(_ id: WatchPairedLibraryID) async {
        defaults.set(id.rawValue, forKey: pairedKey)
    }

    func loadLastAppliedPhoneRevision() async -> Int64 {
        Int64(defaults.integer(forKey: revisionKey))
    }

    func saveLastAppliedPhoneRevision(_ revision: Int64) async {
        defaults.set(Int(revision), forKey: revisionKey)
    }
}
