import Foundation
import GRDB

/// One local asset awaiting a content fingerprint backfill.
public struct LocalFingerprintCandidate: Sendable {
    public let assetId: Int64
    public let bookmark: Data?
    public let relPath: String?
    public let remoteURL: String?

    public init(assetId: Int64, bookmark: Data?, relPath: String?, remoteURL: String?) {
        self.assetId = assetId
        self.bookmark = bookmark
        self.relPath = relPath
        self.remoteURL = remoteURL
    }
}

/// Consolidates byte-identical local files that arrived through different
/// routes (added individually, then again inside a folder). Groups by the
/// stored sample fingerprint when available, otherwise by exact byte size plus
/// a 0.75 s duration tolerance — the same cheap key `IngestService` already
/// uses. User data is merged onto the survivor before losers are deleted.
enum LocalTrackConsolidator {
    struct Report: Equatable, Sendable {
        var groupsMerged = 0
        var tracksRemoved = 0
    }

    static func run(db: Database) throws -> Report {
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.trackId AS trackId, a.sizeBytes AS sizeBytes,
                   a.contentSampleHash AS hash, t.durationSec AS durationSec
            FROM asset a JOIN track t ON t.id = a.trackId
            WHERE a.kind = 'localRef' AND a.sizeBytes IS NOT NULL AND a.sizeBytes > 0
            ORDER BY a.trackId
            """)

        var byHash: [String: [Int64]] = [:]
        var bySizeWithoutHash: [Int64: [(id: Int64, duration: Double?)]] = [:]
        for row in rows {
            let trackID: Int64 = row["trackId"]
            let size: Int64 = row["sizeBytes"]
            if let hash: String = row["hash"], !hash.isEmpty {
                byHash["\(size)|\(hash)", default: []].append(trackID)
            } else {
                bySizeWithoutHash[size, default: []].append((trackID, row["durationSec"]))
            }
        }

        var groups: [[Int64]] = byHash.values.filter { $0.count > 1 }
        for (_, entries) in bySizeWithoutHash where entries.count > 1 {
            // Exact same byte count + duration within 0.75 s. Unknown durations
            // are never guessed; they simply stay unmerged.
            var remaining = entries.sorted { ($0.duration ?? 0) < ($1.duration ?? 0) }
            while let first = remaining.first {
                guard let anchor = first.duration else {
                    remaining.removeFirst()
                    continue
                }
                var cluster = [first.id]
                var rest: [(id: Int64, duration: Double?)] = []
                for entry in remaining.dropFirst() {
                    if let duration = entry.duration, abs(duration - anchor) <= 0.75 {
                        cluster.append(entry.id)
                    } else {
                        rest.append(entry)
                    }
                }
                if cluster.count > 1 { groups.append(cluster) }
                remaining = rest
            }
        }
        guard !groups.isEmpty else { return Report() }

        var report = Report()
        for rawGroup in groups {
            // A track can legitimately have more than one local asset row; never
            // let a duplicate id survive the loser filter and delete itself.
            let group = Array(Set(rawGroup)).sorted()
            guard group.count > 1 else { continue }
            let survivor = try TrackMerger.chooseSurvivor(db: db, tracks: group)
            let losers = group.filter { $0 != survivor }
            guard !losers.isEmpty else { continue }
            try TrackMerger.mergeGroup(db: db, survivor: survivor, losers: losers)
            try LibraryStore.refreshSearchIndex(trackID: survivor, db: db)
            report.groupsMerged += 1
            report.tracksRemoved += losers.count
        }
        return report
    }
}
