import Foundation
import CloudKit

/// Production `PlaybackCloudBackend` that pushes/pulls a singleton
/// `playback-state` CloudKit record, mirroring the `appSettings` pattern.
/// Uses the same zone as the main sync engine for data co-location.
public final class CloudPlaybackBackend: PlaybackCloudBackend {
    private let container: CKContainer
    private let zoneID: CKRecordZone.ID

    public init(containerID: String = CloudSyncEngine.containerID) {
        self.container = CKContainer(identifier: containerID)
        self.zoneID = CKRecordZone.ID(
            zoneName: "TonearmLibrary", ownerName: CKCurrentUserDefaultName)
    }

    public func load() async -> PlaybackStateSnapshot? {
        let recordID = CKRecord.ID(
            recordName: RecordMapping.playbackStateRecordName, zoneID: zoneID)
        do {
            let record = try await container.privateCloudDatabase.record(for: recordID)
            return RecordMapping.playbackState(from: record)
        } catch {
            // .unknownItem on first pull is expected (no dev-schema step needed).
            return nil
        }
    }

    public func save(_ snapshot: PlaybackStateSnapshot) {
        let record = RecordMapping.record(from: snapshot, zoneID: zoneID)
        Task {
            do {
                _ = try await container.privateCloudDatabase.save(record)
            } catch {
                // Fire-and-forget: reconcile catches up later.
            }
        }
    }
}
