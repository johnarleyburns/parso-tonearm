import Foundation
import GRDB
import TonearmWatchProtocol

/// GRDB persistence for the phone download subsystem (§8.1: "persist roots and jobs in GRDB using
/// a new migration"). Every state transition is written here *before* the manager schedules the
/// external transfer, so a crash mid-flight is recoverable at launch.
///
/// Backed by the main library database — the schema `v15` migration owns its tables. Existing
/// phone downloads live in unrelated tables and are untouched (§8.1 "preserve existing phone
/// downloads independently from watch roots").
public actor PhoneWatchDownloadStore {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public init(library: LibraryStore) {
        self.dbQueue = library.dbQueue
    }

    // MARK: - Roots

    public func roots() throws -> [PhoneWatchDownloadRoot] {
        try dbQueue.read { db in
            try WatchDownloadRootRecord.order(Column("createdAt"), Column("rootID")).fetchAll(db).map(\.value)
        }
    }

    /// Replace the entire root set in one transaction. Roots are a complete revision, never a delta.
    public func replaceRoots(_ roots: [PhoneWatchDownloadRoot]) throws {
        try dbQueue.write { db in
            try WatchDownloadRootRecord.deleteAll(db)
            for root in roots { var r = WatchDownloadRootRecord(root); try r.insert(db) }
        }
    }

    public func upsertRoot(_ root: PhoneWatchDownloadRoot) throws {
        try dbQueue.write { db in
            var r = WatchDownloadRootRecord(root)
            try r.save(db)
        }
    }

    public func deleteRoot(rootID: String) throws {
        _ = try dbQueue.write { db in try WatchDownloadRootRecord.deleteOne(db, key: rootID) }
    }

    // MARK: - Jobs

    public func jobs() throws -> [PhoneWatchDownloadJob] {
        try dbQueue.read { db in
            try WatchDownloadJobRecord.order(Column("createdAt"), Column("requestID")).fetchAll(db).map(\.value)
        }
    }

    public func activeJobs() throws -> [PhoneWatchDownloadJob] {
        try jobs().filter(\.isActive)
    }

    public func upsertJob(_ job: PhoneWatchDownloadJob) throws {
        try dbQueue.write { db in
            var r = WatchDownloadJobRecord(job)
            try r.save(db)
        }
    }

    public func upsertJobs(_ jobs: [PhoneWatchDownloadJob]) throws {
        try dbQueue.write { db in
            for job in jobs { var r = WatchDownloadJobRecord(job); try r.save(db) }
        }
    }

    public func deleteJob(requestID: String) throws {
        _ = try dbQueue.write { db in try WatchDownloadJobRecord.deleteOne(db, key: requestID) }
    }

    /// Drop settled jobs (sent/cancelled/failed) that are done being useful: the track is either on
    /// the watch already or no longer wanted. A failed-but-still-desired job is kept so its error
    /// stays visible and an explicit retry has something to reset. Housekeeping so the table does
    /// not grow without bound.
    public func pruneSettledJobs(installedTrackIDs: Set<String>, desiredTrackIDs: Set<String>) throws {
        try dbQueue.write { db in
            let all = try WatchDownloadJobRecord.fetchAll(db)
            for record in all {
                let job = record.value
                guard job.state == .sent || job.state == .cancelled || job.state == .failed else { continue }
                if desiredTrackIDs.contains(job.trackID) && !installedTrackIDs.contains(job.trackID) { continue }
                _ = try WatchDownloadJobRecord.deleteOne(db, key: job.requestID)
            }
        }
    }

    // MARK: - Watch-reported manifest

    public func manifestEntries() throws -> [PhoneWatchManifestEntry] {
        try dbQueue.read { db in try WatchDownloadManifestEntryRecord.fetchAll(db).map(\.value) }
    }

    public func installedTrackIDs() throws -> Set<String> {
        Set(try manifestEntries().map(\.trackID))
    }

    /// Replace the manifest with the watch's latest report. The watch owns this truth entirely
    /// (§1.6), so a full replace is correct — a missing entry means the file is gone.
    public func replaceManifest(_ entries: [PhoneWatchManifestEntry]) throws {
        try dbQueue.write { db in
            try WatchDownloadManifestEntryRecord.deleteAll(db)
            for entry in entries { var r = WatchDownloadManifestEntryRecord(entry); try r.insert(db) }
        }
    }

    // MARK: - Revision

    public func currentRevision() throws -> Int64 {
        try dbQueue.read { db in
            try WatchDownloadRevisionRecord.fetchOne(db, key: 1)?.value ?? 0
        }
    }

    @discardableResult
    public func bumpRevision() throws -> Int64 {
        try dbQueue.write { db in
            let next = (try WatchDownloadRevisionRecord.fetchOne(db, key: 1)?.value ?? 0) + 1
            try db.execute(sql: "UPDATE watchDownloadRevision SET value = ? WHERE id = 1", arguments: [next])
            return next
        }
    }
}
