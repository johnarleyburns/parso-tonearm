import Foundation
import GRDB
import TonearmCore

/// Turns core catalog state (and the `discovery_change` outbox) into
/// `discovery_index_job` rows, without ever materializing the whole catalog
/// on the caller's thread (plan §4: "At launch and after outbox changes,
/// reconcile in bounded pages (200 tracks) ... using indexed keyset
/// pagination, not a full catalog materialization").
///
/// This type does no decode/inference/network work itself — it only
/// ensures the job queue accurately reflects the core catalog. The actual
/// audio work is `IndexWorker` (C04, not implemented this session).
public actor DiscoveryReconciler {
    public static let bootstrapPageSize = 200

    private let writer: any DatabaseWriter
    private let jobs: IndexJobRepository
    private let pipelineVersion: Int
    private let clock: () -> Date
    /// Whether a track whose only assets are remote/cloud should get a job
    /// anyway (sparse sampling — docs/plans/remote-sparse-indexing.md), read
    /// fresh on every `assetSelection` call rather than cached at init, so a
    /// user flipping the Settings toggle takes effect on the very next
    /// reconcile pass without needing this actor recreated.
    private let remoteIndexingEnabled: @Sendable () async -> Bool

    public init(
        writer: any DatabaseWriter,
        jobs: IndexJobRepository,
        pipelineVersion: Int = DiscoveryPipelineVersion.pipeline,
        clock: @escaping () -> Date = Date.init,
        remoteIndexingEnabled: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.writer = writer
        self.jobs = jobs
        self.pipelineVersion = pipelineVersion
        self.clock = clock
        self.remoteIndexingEnabled = remoteIndexingEnabled
    }

    /// Bootstrap every existing core track that has no job yet for the
    /// current pipeline version, in ascending-id keyset pages of 200. Safe
    /// to call repeatedly (idempotent: `enqueueOrRestart` is a no-op for a
    /// track that already has a job). A track whose assets are all
    /// remote/cloud (never downloaded) is skipped entirely — see
    /// `assetSelection` — so it never occupies a permanent `waitingForAsset`
    /// slot; it becomes eligible on its own the next time this runs, the
    /// moment it has a real local asset.
    @discardableResult
    public func bootstrapAllTracks() async throws -> Int {
        var lastID: Int64 = 0
        var enqueued = 0
        while true {
            let page = try await pageOfTracksNeedingJobs(afterId: lastID)
            if page.isEmpty { break }
            for trackId in page {
                let selection = try await assetSelection(trackId: trackId)
                guard selection.eligible else { continue }
                try await jobs.enqueueOrRestart(
                    trackId: trackId,
                    selectedAssetId: selection.assetId,
                    assetRevision: selection.assetId == nil ? nil : 1,
                    pipelineVersion: pipelineVersion)
                enqueued += 1
            }
            lastID = page.last!
            if page.count < Self.bootstrapPageSize { break }
        }
        return enqueued
    }

    /// One-time-per-track cleanup for installs that already accumulated
    /// `waitingForAsset` jobs before this change: a job whose track's only
    /// assets are remote/cloud (never downloaded) sat there permanently,
    /// since nothing was ever going to make it locally resolvable on its
    /// own (real report: "2631 tracks waiting on their audio file... I want
    /// to only index downloaded/on-device tracks"). Deletes those job rows
    /// outright rather than marking them `.unsupported` — a track skipped
    /// this way is not "known but unsupported", it's simply outside the
    /// index's scope right now — so `coverage.total` reads as an honest
    /// count of tracks actually candidate for indexing, not inflated by
    /// permanently-waiting cloud tracks. The very next `bootstrapAllTracks()`
    /// pass (always run immediately after this, at launch) then naturally
    /// re-creates a real job for any of these the moment it has a local
    /// asset — no separate "asset became available" event is needed.
    @discardableResult
    public func pruneJobsForUndownloadedTracks() async throws -> Int {
        var pruned = 0
        while true {
            let batch = try await writer.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT j.id AS jobId, j.trackId AS trackId
                        FROM discovery_index_job j
                        WHERE j.pipelineVersion = ? AND j.state = ?
                        LIMIT ?
                        """,
                    arguments: [pipelineVersion, DiscoveryJobState.waitingForAsset.rawValue,
                        Self.bootstrapPageSize])
            }
            if batch.isEmpty { break }

            let trackIds = batch.map { $0["trackId"] as Int64 }
            let assetsByTrack = try await writer.read { db in
                try Asset.filter(trackIds.contains(Column("trackId"))).fetchAll(db)
            }.reduce(into: [Int64: [Asset]]()) { result, asset in
                result[asset.trackId, default: []].append(asset)
            }

            // Read once per batch, not per track — a track that's genuinely
            // eligible via remote sparse sampling (the setting is on AND it
            // has a real node reference) must never be pruned here, or every
            // launch would delete and immediately recreate the same jobs.
            let remoteEnabled = await remoteIndexingEnabled()
            let idsToDelete: [String] = batch.compactMap { row in
                let trackId: Int64 = row["trackId"]
                let assets = assetsByTrack[trackId] ?? []
                // No asset rows at all is a different, still-eligible case
                // (a local import still writing its asset) — only prune
                // when every asset that DOES exist is remote/undownloaded
                // AND (when remote indexing is on) not sparse-eligible.
                guard !assets.isEmpty, DiscoveryReconciler.preferredAsset(from: assets) == nil,
                    !(remoteEnabled
                        && DiscoveryReconciler.remoteSparseEligibleAsset(from: assets) != nil)
                else { return nil }
                return row["jobId"] as String
            }
            guard !idsToDelete.isEmpty else {
                // Nothing in this batch qualified; a batch this size never
                // recurs identically, so stop rather than loop forever.
                break
            }
            try await writer.write { db in
                try db.execute(
                    sql: """
                        DELETE FROM discovery_index_job
                        WHERE id IN (\(idsToDelete.map { _ in "?" }.joined(separator: ",")))
                        """,
                    arguments: StatementArguments(idsToDelete))
            }
            pruned += idsToDelete.count
            if batch.count < Self.bootstrapPageSize { break }
        }
        return pruned
    }

    /// One page of trackIds with `id > afterId` that do not yet have a job
    /// for `pipelineVersion`, using indexed keyset pagination (no OFFSET
    /// scan). The preferred asset is resolved per track by `preferredAssetId`.
    private func pageOfTracksNeedingJobs(afterId: Int64) async throws -> [Int64] {
        try await writer.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT t.id
                    FROM track t
                    WHERE t.id > ?
                      AND NOT EXISTS (
                          SELECT 1 FROM discovery_index_job j
                          WHERE j.trackId = t.id AND j.pipelineVersion = ?
                      )
                    ORDER BY t.id
                    LIMIT ?
                    """,
                arguments: [afterId, pipelineVersion, DiscoveryReconciler.bootstrapPageSize])
        }
    }

    /// Drain the `discovery_change` outbox, translating each entry into a
    /// job mutation, then delete the processed rows. Content replacement
    /// restarts the job (new revision); metadata edits and deletions do not
    /// re-embed audio (plan §4: "Do not make every metadata edit
    /// re-embed audio").
    @discardableResult
    public func processOutbox(pageSize: Int = 200) async throws -> Int {
        let changes = try await writer.read { db in
            try DiscoveryChange.order(Column("id")).limit(pageSize).fetchAll(db)
        }
        guard !changes.isEmpty else { return 0 }

        for change in changes {
            switch change.kind {
            case .trackInserted:
                if let trackId = change.trackId {
                    let selection = try await assetSelection(trackId: trackId)
                    if selection.eligible {
                        try await jobs.enqueueOrRestart(
                            trackId: trackId,
                            selectedAssetId: selection.assetId,
                            assetRevision: selection.assetId == nil ? nil : 1,
                            pipelineVersion: pipelineVersion)
                    }
                    // Ineligible (remote-only) tracks are skipped, not
                    // enqueued — see `bootstrapAllTracks`'s doc.
                }
            case .assetContentReplaced:
                if let trackId = change.trackId {
                    let selection = try await assetSelection(trackId: trackId)
                    let existing = try await jobs.job(
                        trackId: trackId, pipelineVersion: pipelineVersion)
                    if !selection.eligible {
                        // The replacement made this track remote-only (e.g.
                        // its local file was removed/swapped for a
                        // cloud-only original) — drop any stale job rather
                        // than leave it parked on an asset that no longer
                        // qualifies.
                        if let existing {
                            try await jobs.deleteJob(id: existing.id)
                        }
                    } else if let existing {
                        let nextRevision = (existing.assetRevision ?? 0) + 1
                        try await jobs.enqueueOrRestart(
                            trackId: trackId,
                            selectedAssetId: selection.assetId,
                            assetRevision: nextRevision,
                            pipelineVersion: pipelineVersion,
                            restart: true)
                    } else {
                        try await jobs.enqueueOrRestart(
                            trackId: trackId,
                            selectedAssetId: selection.assetId,
                            assetRevision: selection.assetId == nil ? nil : 1,
                            pipelineVersion: pipelineVersion)
                    }
                }
            case .trackDeleted, .sourceDeleted:
                // FK cascades already removed the job/derived rows; nothing
                // further to reconcile.
                break
            case .trackMetadataUpdated:
                // Presentation-only; does not touch analysis/embeddings.
                break
            }
        }

        let lastId = changes.last?.id ?? 0
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM discovery_change WHERE id <= ?", arguments: [lastId])
        }
        return changes.count
    }

    /// Count of tracks whose only assets are remote/cloud (never downloaded
    /// locally) — i.e. currently excluded from indexing by `assetSelection`
    /// below. Used to give the Settings remote-indexing confirmation dialog
    /// a real, current number to base its data-cost estimate on, not a
    /// stale or made-up one.
    public func remoteOnlyTrackCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM track t
                    WHERE EXISTS (SELECT 1 FROM asset a WHERE a.trackId = t.id)
                      AND NOT EXISTS (
                          SELECT 1 FROM asset a
                          WHERE a.trackId = t.id AND a.kind != ? AND a.needsReimport = 0
                            AND a.unsupportedReason IS NULL
                            AND (a.bookmark IS NOT NULL OR a.relPath IS NOT NULL)
                      )
                    """,
                arguments: [AssetKind.remote.rawValue])
                ?? 0
        }
    }

    /// A track's index-job eligibility plus (when eligible) its preferred
    /// asset id. Field report: "I don't necessarily want to download ALL
    /// the files in my library, it's too many, I want to only index
    /// downloaded / on-device tracks" — a track whose assets are all
    /// remote/cloud (never downloaded locally) is NOT eligible; a track
    /// with no asset rows at all yet (e.g. a local import still writing
    /// its asset) IS still eligible with a `nil` asset id, exactly as
    /// before this change, so the normal `.assetContentReplaced` outbox
    /// event can still fill it in.
    struct AssetSelection {
        let assetId: Int64?
        let eligible: Bool
    }

    private func assetSelection(trackId: Int64) async throws -> AssetSelection {
        let assets = try await writer.read { db in
            try Asset
                .filter(Column("trackId") == trackId)
                .order(Column("id"))
                .fetchAll(db)
        }
        if assets.isEmpty { return AssetSelection(assetId: nil, eligible: true) }
        if let preferred = DiscoveryReconciler.preferredAsset(from: assets) {
            return AssetSelection(assetId: preferred.id, eligible: true)
        }
        // No local/downloaded asset — eligible only via remote sparse
        // sampling, and only when the user has explicitly turned that on
        // (off by default — real, ongoing network-data cost).
        if await remoteIndexingEnabled(),
            let sparse = DiscoveryReconciler.remoteSparseEligibleAsset(from: assets)
        {
            return AssetSelection(assetId: sparse.id, eligible: true)
        }
        return AssetSelection(assetId: nil, eligible: false)
    }

    /// Best-effort backfill for `.remote` assets that predate
    /// `remoteNodeID`/`remoteNodePath` persistence (commit `0a80ff8`, 2026-
    /// 09-16). Real report: "the button doesn't do anything, no tracks are
    /// queued from my 2,600+ remote tracks" — every remote asset added
    /// before that commit has `remoteNodePath == nil`, so
    /// `remoteSparseEligibleAsset` (below) rejects all of them regardless of
    /// the remote-indexing setting, no matter how many times bootstrap runs.
    ///
    /// Internet Archive sources (by far the most likely source of a
    /// multi-thousand-track remote library in this app — a second, deeper
    /// root cause found auditing the first fix) get a direct, network-free
    /// path: `RemoteLibraryProviderFactory.provider(for:)` never supported
    /// `.iaItem`/`.iaList`/`.iaCollection`/`.iaFavorites` at all (it throws
    /// `.unsupportedURL` for them — see the fix alongside this one), so the
    /// generic crawl-and-match path below could never have worked for them
    /// regardless of matching quality, and neither could analysis-time
    /// re-authentication (`RemoteSparseAssetResolver.makeSession`, which
    /// calls the same factory). IA's persisted `remoteURL` is already a
    /// permanent, unauthenticated archive.org download link — exactly what
    /// `IARemoteLibraryProvider.browse` would itself produce as a node's
    /// `path` — so the node reference for these is just `remoteURL` back
    /// out, self-referentially, with no round trip needed.
    ///
    /// Every other supported provider (WebDAV/SMB/Jellyfin/Plex/Subsonic/
    /// CloudDrive/Jamendo) crawls its tree ONCE per source (not once per
    /// track — that would be thousands of round trips) and matches existing
    /// tracks to freshly-browsed nodes by size (primary) or normalized
    /// title (fallback), persisting the node reference on a match. Only
    /// runs when remote indexing is enabled (real, ongoing network cost);
    /// a source whose provider can't be constructed (revoked credential,
    /// unsupported kind) is skipped, not treated as an error — the next
    /// run naturally retries it.
    @discardableResult
    public func backfillRemoteNodeReferences(
        providerFactory: @Sendable (Source) throws -> any RemoteLibraryProvider = {
            try RemoteLibraryProviderFactory.provider(for: $0)
        }
    ) async -> Int {
        guard await remoteIndexingEnabled() else { return 0 }

        struct Candidate {
            let assetId: Int64
            let sourceId: Int64
            let title: String
            let sizeBytes: Int64?
            let remoteURL: String?
        }
        let candidates: [Candidate] = ((try? await writer.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT a.id AS assetId, t.sourceId AS sourceId, t.title AS title,
                           a.sizeBytes AS sizeBytes, a.remoteURL AS remoteURL
                    FROM asset a
                    JOIN track t ON t.id = a.trackId
                    WHERE a.kind = ? AND a.remoteNodePath IS NULL
                      AND a.unsupportedReason IS NULL AND a.needsReimport = 0
                    """,
                arguments: [AssetKind.remote.rawValue])
        }) ?? []).map { row in
            Candidate(assetId: row["assetId"], sourceId: row["sourceId"],
                title: row["title"], sizeBytes: row["sizeBytes"], remoteURL: row["remoteURL"])
        }
        guard !candidates.isEmpty else { return 0 }

        var backfilled = 0
        for (sourceId, group) in Dictionary(grouping: candidates, by: { $0.sourceId }) {
            guard let source = try? await writer.read({ db in try Source.fetchOne(db, key: sourceId) })
            else { continue }

            if Self.isArchiveOrgKind(source.kind) {
                for candidate in group {
                    guard let url = candidate.remoteURL else { continue }
                    let didUpdate = (try? await writer.write { db -> Bool in
                        guard var asset = try Asset.fetchOne(db, key: candidate.assetId) else { return false }
                        asset.remoteNodeID = url
                        asset.remoteNodePath = url
                        try asset.update(db)
                        return true
                    }) ?? false
                    if didUpdate { backfilled += 1 }
                }
                continue
            }

            guard RemoteLibraryProviderFactory.supports(source.kind),
                let provider = try? providerFactory(source)
            else { continue }

            let nodes = await Self.crawlRemoteNodes(provider: provider)
            guard !nodes.isEmpty else { continue }

            var bySize: [Int64: [RemoteNode]] = [:]
            var byTitle: [String: [RemoteNode]] = [:]
            for node in nodes {
                if let size = node.sizeBytes { bySize[size, default: []].append(node) }
                byTitle[Self.normalizedTitle(node.title), default: []].append(node)
            }

            var usedNodeIDs = Set<String>()
            for candidate in group {
                var match: RemoteNode?
                if let size = candidate.sizeBytes {
                    let sizeMatches = (bySize[size] ?? []).filter { !usedNodeIDs.contains($0.id) }
                    if sizeMatches.count == 1 { match = sizeMatches[0] }
                }
                if match == nil {
                    let titleMatches = (byTitle[Self.normalizedTitle(candidate.title)] ?? [])
                        .filter { !usedNodeIDs.contains($0.id) }
                    if titleMatches.count == 1 { match = titleMatches[0] }
                }
                guard let node = match else { continue }
                usedNodeIDs.insert(node.id)
                let didUpdate = (try? await writer.write { db -> Bool in
                    guard var asset = try Asset.fetchOne(db, key: candidate.assetId) else { return false }
                    asset.remoteNodeID = node.id
                    asset.remoteNodePath = node.path
                    try asset.update(db)
                    return true
                }) ?? false
                if didUpdate { backfilled += 1 }
            }
        }
        return backfilled
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Internet Archive source kinds — `RemoteLibraryProviderFactory`
    /// doesn't construct a provider for these via its normal `Source`-based
    /// path (see `backfillRemoteNodeReferences`'s doc); their remote assets
    /// need the direct `remoteURL`-as-node-reference shortcut instead.
    private static func isArchiveOrgKind(_ kind: SourceKind) -> Bool {
        switch kind {
        case .iaItem, .iaList, .iaCollection, .iaFavorites: return true
        default: return false
        }
    }

    /// Breadth-first crawl of a provider's whole tree starting at the root
    /// path (`""`, matching `SourceDetailView`'s browse convention),
    /// recursing into container nodes (`.directory`/`.collection`) and
    /// collecting every leaf (`.audio`/`.item`) node. Bounded on both depth
    /// and total visited nodes so a pathological/huge remote tree can't run
    /// away — a partial crawl still lets any track under the visited
    /// portion backfill; the rest is retried on the next run.
    private static func crawlRemoteNodes(
        provider: any RemoteLibraryProvider,
        maxDepth: Int = 12,
        maxVisited: Int = 20_000
    ) async -> [RemoteNode] {
        var result: [RemoteNode] = []
        var queue: [(path: String, depth: Int)] = [("", 0)]
        var visitedPaths = Set<String>()
        while !queue.isEmpty {
            let (path, depth) = queue.removeFirst()
            guard visitedPaths.insert(path).inserted else { continue }
            guard let nodes = try? await provider.browse(path: path) else { continue }
            for node in nodes {
                switch node.kind {
                case .directory, .collection:
                    if depth < maxDepth { queue.append((node.path, depth + 1)) }
                default:
                    result.append(node)
                }
            }
            if result.count + visitedPaths.count > maxVisited { break }
        }
        return result
    }

    /// The lowest-id remote asset that CAN be sparsely sampled — has the
    /// persisted node reference (`remoteNodeID`/`remoteNodePath`) the
    /// prerequisite work added, without which `RemoteSparseAssetResolver`
    /// can never re-authenticate it (commit `0a80ff8`). An asset persisted
    /// before that field existed, or otherwise missing it, does not get a
    /// job at all — it would only ever land in `.unsupported` on first
    /// attempt, so there's no point creating one.
    static func remoteSparseEligibleAsset(from assets: [Asset]) -> Asset? {
        assets
            .filter {
                $0.id != nil && $0.kind == .remote && $0.unsupportedReason == nil
                    && !$0.needsReimport && $0.remoteNodePath != nil
            }
            .min { ($0.id ?? .max) < ($1.id ?? .max) }
    }

    /// Deterministic preferred analyzable asset: the valid local original
    /// (resolvable without a network fetch) with the lowest asset id.
    /// `nil` when every asset is remote/cloud-only (or flagged
    /// `needsReimport`/unsupported) — such a track is left for indexing
    /// only once it actually has downloaded, on-device audio (see
    /// `AssetSelection`'s doc); this method previously also ranked a bare
    /// remote/downloadable original as a fallback "tier 2" pick, which is
    /// exactly what caused tracks to sit in `waitingForAsset` forever,
    /// since `AnalysisAssetResolver` can never resolve one locally on its
    /// own.
    static func preferredAsset(from assets: [Asset]) -> Asset? {
        assets
            .filter { $0.id != nil && $0.unsupportedReason == nil && isLocallyResolvable($0) }
            .min { ($0.id ?? .max) < ($1.id ?? .max) }
    }

    private static func isLocallyResolvable(_ asset: Asset) -> Bool {
        guard !asset.needsReimport else { return false }
        switch asset.kind {
        case .localRef, .managedCopy, .builtIn:
            return asset.bookmark != nil
                || asset.relPath != nil
                || (asset.remoteURL.flatMap(URL.init(string:))?.isFileURL ?? false)
        case .remote:
            return false
        }
    }
}
