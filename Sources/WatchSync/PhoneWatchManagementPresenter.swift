import Foundation
import TonearmWatchProtocol

/// Watch rearchitecture Phase 8 — the iPhone download and storage experience (§9 P1–P5).
///
/// A pure, clockless projection of the phone's watch-download state into the value types the
/// Settings › Apple Watch screens render: pairing/connection, watch-*reported* storage, the live
/// download activity, the downloaded collections, per-collection detail with reference-aware
/// removal, and the compact transfer banner. No I/O — `AppState` gathers the inputs from
/// `PhoneWatchRuntime` and hands them here.
///
/// Truth boundary (§1.6): "downloaded" means the watch manifest lists the track. A queued or sent
/// job is *in progress*, never rendered as on the watch.
public enum PhoneWatchManagementPresenter {

    // MARK: - Pairing

    public enum Pairing: Equatable, Sendable {
        case unsupported
        case notPaired
        case pairedNotReachable
        /// Connected; `since` is when the link was last established, if known.
        case connected(since: Date?)

        public var isConnected: Bool { if case .connected = self { return true } else { return false } }
        public var isPaired: Bool {
            switch self {
            case .unsupported, .notPaired: return false
            case .pairedNotReachable, .connected: return true
            }
        }
    }

    // MARK: - Snapshot

    public struct Snapshot: Equatable, Sendable {
        public var pairing: Pairing
        /// Relative age of the connection ("just now" territory), in seconds, when connected.
        public var connectedForSeconds: TimeInterval?
        public var storage: Storage?
        public var activity: [ActivityRow]
        public var collections: [CollectionRow]
        public var banner: TransferBanner?

        public init(pairing: Pairing, connectedForSeconds: TimeInterval?, storage: Storage?,
                    activity: [ActivityRow], collections: [CollectionRow], banner: TransferBanner?) {
            self.pairing = pairing
            self.connectedForSeconds = connectedForSeconds
            self.storage = storage
            self.activity = activity
            self.collections = collections
            self.banner = banner
        }

        public static let empty = Snapshot(pairing: .unsupported, connectedForSeconds: nil,
                                           storage: nil, activity: [], collections: [], banner: nil)

        /// True when there is nothing to manage — no roots, no jobs. Drives the empty state.
        public var isEmpty: Bool { collections.isEmpty && activity.isEmpty }
    }

    public struct Storage: Equatable, Sendable {
        /// Watch-reported bytes of installed audio.
        public var installedBytes: Int64
        /// Watch total capacity, if the watch has reported it (`0` means unknown).
        public var capacityBytes: Int64
        /// Watch free bytes, if reported.
        public var freeBytes: Int64
        /// Count of tracks the watch manifest lists as ready.
        public var trackCount: Int
        /// Used fraction of capacity, `nil` when capacity is unknown.
        public var usedFraction: Double?
        /// Set when the estimated remaining transfer will not fit in free space (§ H-03).
        public var spaceShortfall: SpaceShortfall?

        public var hasReportedCapacity: Bool { capacityBytes > 0 }
    }

    public struct SpaceShortfall: Equatable, Sendable {
        /// Bytes still to transfer for desired-but-not-installed tracks.
        public var requiredBytes: Int64
        public var freeBytes: Int64
        /// A fixed reserve the watch keeps free on top of the transfer (matches §8.3 step 3).
        public var reserveBytes: Int64
    }

    public enum ActivityStage: String, Equatable, Sendable, CaseIterable {
        case queued
        case resolving
        case transferring
        case waitingForWiFi
        case failed
        case paused

        public var isTerminal: Bool { self == .failed }
    }

    public struct ActivityRow: Equatable, Sendable, Identifiable {
        public var requestID: String
        public var trackID: String
        public var title: String
        public var stage: ActivityStage
        /// Which collections this job serves (root IDs), for grouping / navigation.
        public var rootIDs: [String]
        public var failureMessage: String?
        public var canRetry: Bool
        public var canCancel: Bool

        public var id: String { requestID }
    }

    public enum CollectionKind: String, Equatable, Sendable {
        case track, album, playlist
    }

    public struct CollectionRow: Equatable, Sendable, Identifiable {
        public var rootID: String
        public var title: String
        public var kind: CollectionKind
        public var paused: Bool
        /// Desired track count for this root (live for playlists).
        public var desiredCount: Int
        public var readyCount: Int
        public var waitingForWiFiCount: Int
        public var unavailableCount: Int
        public var failedCount: Int

        public var id: String { rootID }
        public var isFullyReady: Bool { readyCount == desiredCount && desiredCount > 0 }
        public var isPartial: Bool { readyCount > 0 && readyCount < desiredCount }
    }

    public struct TransferBanner: Equatable, Sendable {
        public var activeCount: Int
        public var failedCount: Int
        public var hasFailure: Bool { failedCount > 0 }
    }

    // MARK: - Collection detail

    public struct CollectionDetail: Equatable, Sendable {
        public var rootID: String
        public var title: String
        public var kind: CollectionKind
        public var paused: Bool
        /// Playlist roots re-expand and auto-sync new members; track/album roots are frozen.
        public var autoSyncs: Bool
        public var desiredCount: Int
        public var readyCount: Int
        public var waitingForWiFiCount: Int
        public var unavailableCount: Int
        public var failedCount: Int
        /// The safe, typed reason for the first unavailable track, if any (never a URL/path).
        public var unavailableReason: String?
        public var estimatedRemainingCount: Int
        public var estimatedRemainingBytes: Int64
        /// Tracks that leave the watch if this root is removed now.
        public var releasedTrackCount: Int
        /// Tracks kept because another still-desired root also wants them (E-04/E-05).
        public var retainedSharedTrackCount: Int
    }

    // MARK: - Build

    public static func snapshot(pairing: Pairing,
                                roots: [PhoneWatchDownloadRoot],
                                jobs: [PhoneWatchDownloadJob],
                                manifestEntries: [PhoneWatchManifestEntry],
                                watchManifest: WatchManifestPayload?,
                                now: Date) -> Snapshot {
        let installed = Set(manifestEntries.map(\.trackID))
        let titles = trackTitleIndex(roots: roots)

        // Storage
        var storage: Storage?
        if pairing.isPaired {
            let installedBytes = watchManifest?.installedBytes
                ?? manifestEntries.reduce(0) { $0 + $1.bytes }
            let capacity = watchManifest?.capacityBytes ?? 0
            let free = watchManifest?.freeBytes ?? 0
            let remaining = estimatedRemainingBytes(jobs: jobs, roots: roots, installed: installed)
            let reserve: Int64 = 100 * 1024 * 1024
            var shortfall: SpaceShortfall?
            if free > 0, remaining > 0, remaining + reserve > free {
                shortfall = SpaceShortfall(requiredBytes: remaining, freeBytes: free, reserveBytes: reserve)
            }
            storage = Storage(
                installedBytes: installedBytes,
                capacityBytes: capacity,
                freeBytes: free,
                trackCount: installed.count,
                usedFraction: capacity > 0 ? min(1, max(0, Double(capacity - free) / Double(capacity))) : nil,
                spaceShortfall: shortfall)
        }

        // Activity — non-settled jobs, plus failed jobs, active first then failed, stable by createdAt.
        let pausedRootIDs = Set(roots.filter(\.paused).map(\.rootID))
        let activity: [ActivityRow] = jobs
            .filter { $0.isActive || $0.state == .failed }
            .sorted { lhs, rhs in
                let l = activityRank(lhs.state), r = activityRank(rhs.state)
                if l != r { return l < r }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.requestID < rhs.requestID
            }
            .map { job in
                let allRootsPaused = !job.rootIDs.isEmpty && job.rootIDs.allSatisfy { pausedRootIDs.contains($0) }
                let stage = activityStage(job.state, paused: allRootsPaused)
                return ActivityRow(
                    requestID: job.requestID,
                    trackID: job.trackID,
                    title: titles[job.trackID] ?? job.trackID,
                    stage: stage,
                    rootIDs: job.rootIDs,
                    failureMessage: job.state == .failed ? job.message : nil,
                    canRetry: job.state == .failed || job.state == .cancelled,
                    canCancel: job.isActive)
            }

        // Collections
        let collections = roots
            .sorted { rootSortKey($0) < rootSortKey($1) }
            .map { root -> CollectionRow in
                let s = rootStatus(root, jobs: jobs, installed: installed)
                return CollectionRow(
                    rootID: root.rootID, title: root.title, kind: kind(for: root.kind),
                    paused: root.paused, desiredCount: root.desiredTrackIDs.count,
                    readyCount: s.ready, waitingForWiFiCount: s.waiting,
                    unavailableCount: s.unavailable, failedCount: s.failed)
            }

        // Banner
        let activeCount = jobs.filter(\.isActive).count
        let failedCount = jobs.filter { $0.state == .failed }.count
        let banner = (activeCount > 0 || failedCount > 0)
            ? TransferBanner(activeCount: activeCount, failedCount: failedCount)
            : nil

        return Snapshot(
            pairing: pairing,
            connectedForSeconds: connectedForSeconds(pairing: pairing, watchManifest: watchManifest, now: now),
            storage: storage,
            activity: activity,
            collections: collections,
            banner: banner)
    }

    public static func collectionDetail(rootID: String,
                                        roots: [PhoneWatchDownloadRoot],
                                        jobs: [PhoneWatchDownloadJob],
                                        manifestEntries: [PhoneWatchManifestEntry]) -> CollectionDetail? {
        guard let root = roots.first(where: { $0.rootID == rootID }) else { return nil }
        let installed = Set(manifestEntries.map(\.trackID))
        let s = rootStatus(root, jobs: jobs, installed: installed)

        let missing = root.desiredTrackIDs.filter { !installed.contains($0) }
        let jobsByTrack = Dictionary(jobs.map { ($0.trackID, $0) },
                                     uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        let remainingBytes = missing.reduce(Int64(0)) { $0 + (jobsByTrack[$1]?.expectedBytes ?? 0) }

        let firstUnavailable = missing.first { track in
            switch jobsByTrack[track]?.failureClass {
            case .sourceUnavailable, .needsAuth, .fileUnsupported: return true
            default: return false
            }
        }
        let reason = firstUnavailable.flatMap { jobsByTrack[$0]?.message }

        let release = tracksReleasedByRemoving(rootID: rootID, roots: roots, installed: installed)

        return CollectionDetail(
            rootID: root.rootID, title: root.title, kind: kind(for: root.kind), paused: root.paused,
            autoSyncs: root.kind == .playlist,
            desiredCount: root.desiredTrackIDs.count,
            readyCount: s.ready, waitingForWiFiCount: s.waiting,
            unavailableCount: s.unavailable, failedCount: s.failed,
            unavailableReason: reason,
            estimatedRemainingCount: missing.count, estimatedRemainingBytes: remainingBytes,
            releasedTrackCount: release.released.count,
            retainedSharedTrackCount: release.retainedShared.count)
    }

    /// E-04/E-05: which installed tracks a root removal actually frees, and which are kept because
    /// another still-desired root also wants them.
    public static func tracksReleasedByRemoving(rootID: String,
                                                roots: [PhoneWatchDownloadRoot],
                                                installed: Set<String>)
        -> (released: [String], retainedShared: [String]) {
        guard let target = roots.first(where: { $0.rootID == rootID }) else { return ([], []) }
        let others = roots.filter { $0.rootID != rootID && !$0.paused }
        let stillWanted = Set(others.flatMap(\.desiredTrackIDs))
        var released: [String] = []
        var retained: [String] = []
        for track in target.desiredTrackIDs where installed.contains(track) {
            if stillWanted.contains(track) { retained.append(track) } else { released.append(track) }
        }
        return (released, retained)
    }

    // MARK: - Internal

    private struct RootStatus { var ready = 0; var waiting = 0; var unavailable = 0; var failed = 0 }

    private static func rootStatus(_ root: PhoneWatchDownloadRoot,
                                   jobs: [PhoneWatchDownloadJob],
                                   installed: Set<String>) -> RootStatus {
        let jobsByTrack = Dictionary(jobs.map { ($0.trackID, $0) },
                                     uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        var status = RootStatus()
        for track in root.desiredTrackIDs {
            if installed.contains(track) { status.ready += 1; continue }
            switch jobsByTrack[track]?.state {
            case .waitingForWiFi:
                status.waiting += 1
            case .failed:
                if case .some(let cls) = jobsByTrack[track]?.failureClass, !cls.isRetryable {
                    status.unavailable += 1
                } else {
                    status.failed += 1
                }
            default:
                break
            }
        }
        return status
    }

    private static func estimatedRemainingBytes(jobs: [PhoneWatchDownloadJob],
                                                roots: [PhoneWatchDownloadRoot],
                                                installed: Set<String>) -> Int64 {
        let desired = Set(roots.filter { !$0.paused }.flatMap(\.desiredTrackIDs))
        return jobs
            .filter { desired.contains($0.trackID) && !installed.contains($0.trackID)
                && $0.state != .sent && $0.state != .cancelled }
            .reduce(0) { $0 + ($1.expectedBytes ?? 0) }
    }

    private static func trackTitleIndex(roots: [PhoneWatchDownloadRoot]) -> [String: String] {
        // Track/album-batch roots carry a title for the whole root; single-track roots name the
        // track. Playlist members have no per-track title here, so the id is the fallback.
        var index: [String: String] = [:]
        for root in roots where root.kind == .track {
            if let only = root.desiredTrackIDs.first, index[only] == nil { index[only] = root.title }
        }
        return index
    }

    private static func activityRank(_ state: PhoneWatchJobState) -> Int {
        switch state {
        case .transferring: return 0
        case .resolving: return 1
        case .queued: return 2
        case .waitingForWiFi: return 3
        case .failed: return 4
        case .sent, .cancelled: return 5
        }
    }

    private static func activityStage(_ state: PhoneWatchJobState, paused: Bool) -> ActivityStage {
        if paused { return .paused }
        switch state {
        case .queued: return .queued
        case .resolving: return .resolving
        case .transferring: return .transferring
        case .waitingForWiFi: return .waitingForWiFi
        case .failed: return .failed
        case .sent, .cancelled: return .queued
        }
    }

    private static func kind(for kind: WatchRootKind) -> CollectionKind {
        switch kind {
        case .track: return .track
        case .albumBatch: return .album
        case .playlist: return .playlist
        }
    }

    private static func rootSortKey(_ root: PhoneWatchDownloadRoot) -> String {
        let k: String
        switch root.kind {
        case .playlist: k = "0"
        case .albumBatch: k = "1"
        case .track: k = "2"
        }
        return k + "\u{1}" + root.title.lowercased() + "\u{1}" + root.rootID
    }

    private static func connectedForSeconds(pairing: Pairing,
                                            watchManifest: WatchManifestPayload?,
                                            now: Date) -> TimeInterval? {
        guard case .connected(let since) = pairing else { return nil }
        if let since { return max(0, now.timeIntervalSince(since)) }
        if let generated = watchManifest?.generatedAt { return max(0, now.timeIntervalSince(generated)) }
        return nil
    }
}
