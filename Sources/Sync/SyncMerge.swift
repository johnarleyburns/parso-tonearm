import Foundation

/// Pure conflict-resolution rules for iCloud sync, kept out of the CloudKit
/// engine so `SyncMergeTests` can assert them without a live connection.
///
/// Default policy is **last-writer-wins** by record `modificationDate` for
/// library/playlist/favorite/settings records. Play history is **additive**
/// (union by `syncID`) so listening across devices accumulates rather than one
/// device clobbering another. Deletions are honored via CloudKit tombstones.
public enum SyncMerge {

    /// Decides which side wins for a scalar (last-writer-wins) record.
    /// A `nil` date sorts oldest so a freshly-created local record without a
    /// server modification date doesn't beat a real server change.
    public static func winner<T>(local: T, localModified: Date?,
                          remote: T, remoteModified: Date?) -> T {
        let l = localModified ?? .distantPast
        let r = remoteModified ?? .distantPast
        return r >= l ? remote : local
    }

    /// True when the remote change should overwrite local (LWW).
    public static func remoteWins(localModified: Date?, remoteModified: Date?) -> Bool {
        (remoteModified ?? .distantPast) >= (localModified ?? .distantPast)
    }

    /// Additive merge for play history: union by `syncID`, preserving every
    /// distinct event from both sides. Order is by `playedAt` ascending.
    public static func mergePlayHistory(local: [PlayEvent], remote: [PlayEvent]) -> [PlayEvent] {
        var byID: [String: PlayEvent] = [:]
        for event in local + remote {
            guard let id = event.syncID else { continue }
            byID[id] = event
        }
        return byID.values.sorted { $0.playedAt < $1.playedAt }
    }

    /// Applies deletion tombstones: removes any local record whose `syncID`
    /// appears in the set of server-deleted record syncIDs.
    public static func applyDeletions(local: [String], deleted: Set<String>) -> [String] {
        local.filter { !deleted.contains($0) }
    }
}
