import Foundation
import TonearmWatchProtocol

/// Whether a desired track can actually be transferred, and how big it is (§8.1).
public enum PhoneWatchTransferability: Equatable, Sendable {
    /// A local asset exists (or can be resolved) and is a codec the watch plays.
    case ready(bytes: Int64?, sha256: String?)
    /// The track exists but its container/codec is not watch-playable — never queued.
    case unsupported(reason: String)
    /// No local asset and no resolvable remote source right now.
    case unavailable
}

/// §8.1 priority buckets, highest first. The planner stamps each job with one so the scheduler
/// can order dispatch without re-deriving intent.
public enum PhoneWatchDownloadPriority: Int, Codable, Sendable, Comparable, CaseIterable {
    case currentTrack = 0     // user-selected current-track download
    case userRetry = 1        // retries the user explicitly asked for
    case trackOrAlbumBatch = 2
    case playlistSync = 3     // playlist background synchronization
    case artwork = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PhoneWatchPlannedJob: Equatable, Sendable {
    public var trackID: String
    public var rootIDs: [String]
    public var priority: PhoneWatchDownloadPriority
    public var expectedBytes: Int64?
    public var expectedSHA256: String?
}

/// Pure reconciliation of desired roots + installed truth + existing jobs into a deterministic
/// plan. No I/O, no clock — the caller supplies `transferability` and `explicitRetryTrackIDs`.
public enum PhoneWatchDownloadPlanner {
    public struct Plan: Equatable, Sendable {
        public var toCreate: [PhoneWatchPlannedJob] = []
        /// Request IDs of active jobs whose track is no longer desired.
        public var toCancel: [String] = []
        /// Request IDs of failed-retryable jobs the caller should reset to `queued`.
        public var toReset: [String] = []
        /// Sum of `expectedBytes` for tracks not yet installed on the watch.
        public var estimatedBytes: Int64 = 0
        /// Desired tracks the watch cannot play — surfaced, never queued.
        public var unsupported: [String] = []
        /// Desired tracks with no resolvable source right now.
        public var unavailable: [String] = []
        /// How many roots reference each desired track (E-04/E-05).
        public var referenceCounts: [String: Int] = [:]
    }

    public static func plan(roots: [PhoneWatchDownloadRoot],
                            installedTrackIDs: Set<String>,
                            existingJobs: [PhoneWatchDownloadJob],
                            transferability: (String) -> PhoneWatchTransferability,
                            explicitRetryTrackIDs: Set<String> = [],
                            currentTrackID: String? = nil) -> Plan {
        var plan = Plan()

        // Desired set + reference counts. Order is deterministic: first appearance across roots
        // sorted by (priority-of-kind, createdAt, rootID).
        let orderedRoots = roots.sorted {
            let a = kindPriority($0.kind), b = kindPriority($1.kind)
            if a != b { return a < b }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.rootID < $1.rootID
        }
        var desiredOrder: [String] = []
        var seen: Set<String> = []
        var rootsByTrack: [String: [String]] = [:]
        var basePriority: [String: PhoneWatchDownloadPriority] = [:]
        for root in orderedRoots {
            let rootPriority: PhoneWatchDownloadPriority = root.kind == .playlist ? .playlistSync : .trackOrAlbumBatch
            for track in root.desiredTrackIDs {
                plan.referenceCounts[track, default: 0] += 1
                rootsByTrack[track, default: []].append(root.rootID)
                basePriority[track] = min(basePriority[track] ?? .artwork, rootPriority)
                if seen.insert(track).inserted { desiredOrder.append(track) }
            }
        }
        let desired = seen

        let jobsByTrack = Dictionary(existingJobs.map { ($0.trackID, $0) },
                                     uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })

        for track in desiredOrder {
            if installedTrackIDs.contains(track) { continue }

            switch transferability(track) {
            case .unsupported(let reason):
                plan.unsupported.append(track)
                _ = reason
                continue
            case .unavailable:
                plan.unavailable.append(track)
                continue
            case .ready(let bytes, let sha):
                plan.estimatedBytes += bytes ?? 0

                if let job = jobsByTrack[track] {
                    if job.isActive { continue }
                    if job.state == .sent { continue } // sent but not yet in manifest — wait
                    if job.state == .failed {
                        // `explicitRetryTrackIDs` is the caller's decision — it folds in both the
                        // user's explicit retries and transient failures whose backoff timer has
                        // elapsed (the planner has no clock, so the manager computes that).
                        if explicitRetryTrackIDs.contains(track) {
                            plan.toReset.append(job.requestID)
                        }
                        continue
                    }
                    if job.state == .cancelled {
                        plan.toCreate.append(planned(track, rootsByTrack, basePriority, bytes, sha,
                                                     explicitRetryTrackIDs, currentTrackID))
                        continue
                    }
                }
                plan.toCreate.append(planned(track, rootsByTrack, basePriority, bytes, sha,
                                             explicitRetryTrackIDs, currentTrackID))
            }
        }

        for job in existingJobs where job.isActive && !desired.contains(job.trackID) {
            plan.toCancel.append(job.requestID)
        }

        return plan
    }

    private static func planned(_ track: String, _ rootsByTrack: [String: [String]],
                                _ basePriority: [String: PhoneWatchDownloadPriority],
                                _ bytes: Int64?, _ sha: String?,
                                _ explicitRetry: Set<String>, _ current: String?) -> PhoneWatchPlannedJob {
        var priority = basePriority[track] ?? .trackOrAlbumBatch
        if explicitRetry.contains(track) { priority = min(priority, .userRetry) }
        if track == current { priority = min(priority, .currentTrack) }
        return PhoneWatchPlannedJob(trackID: track, rootIDs: rootsByTrack[track] ?? [],
                                    priority: priority, expectedBytes: bytes, expectedSHA256: sha)
    }

    private static func kindPriority(_ kind: WatchRootKind) -> Int {
        switch kind {
        case .track: return 0
        case .albumBatch: return 1
        case .playlist: return 2
        }
    }
}
