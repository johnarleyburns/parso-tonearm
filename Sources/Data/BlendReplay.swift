import Foundation

/// Builds a `BlendDocument` from a live queue and resolves one back into a
/// playable queue at replay time. Nothing is substituted or reordered: an
/// occurrence that cannot be resolved stays in the list, marked with why.
public enum BlendReplay {
    public enum Status: Sendable, Equatable {
        case playable
        case missingLocalFile
        case unavailableRemote
        case notInLibrary
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public var occurrence: BlendDocument.Occurrence
        public var row: TrackRow?
        public var status: Status
        public var id: UUID { occurrence.id }
    }

    public static func identity(of row: TrackRow) -> BlendDocument.SourceIdentity {
        let keys = TrackIdentity.keys(track: row.track, asset: row.asset, source: row.source,
                                      artist: row.artist?.name, album: row.album?.title)
        return .init(syncID: row.track.syncID, identityKeys: keys.map(\.cloudValue),
                     title: row.track.title, artist: row.artist?.name ?? row.album?.artist,
                     isRemote: row.asset?.kind == .remote)
    }

    /// Captures the queue as it is. `plan` supplies requested per-edge styles
    /// for generated blends, matched positionally by the queue's track IDs.
    public static func document(from queue: [TrackRow], plan: MixPlan? = nil,
                                title: String, origin: BlendDocument.Origin,
                                id: UUID = UUID(), now: Date = Date()) -> BlendDocument {
        var styles: [String?] = []
        if queue.count > 1 {
            for i in 0..<(queue.count - 1) {
                let plan = plan?.transitionPlans.first {
                    $0.fromTrackID == queue[i].id && $0.toTrackID == queue[i + 1].id
                }
                styles.append(plan?.style.rawValue)
            }
        }
        return BlendDocument(id: id, title: title,
                             artworkReference: queue.first?.track.syncID, origin: origin, now: now,
                             occurrences: queue.map { .init(source: identity(of: $0)) },
                             requestedStyles: styles)
    }

    /// Resolves every occurrence in document order. `lookup` finds a library
    /// row by `syncID`, then by identity keys.
    public static func resolve(_ document: BlendDocument,
                               lookup: (BlendDocument.SourceIdentity) -> TrackRow?) -> [Entry] {
        document.occurrences.map { occ in
            guard let row = lookup(occ.source) else {
                return Entry(occurrence: occ, row: nil,
                             status: occ.source.isRemote ? .unavailableRemote : .notInLibrary)
            }
            if let asset = row.asset {
                let local = asset.kind == .localRef || asset.kind == .managedCopy
                if asset.needsReimport || (local && asset.bookmark == nil && asset.relPath == nil) {
                    return Entry(occurrence: occ, row: row, status: .missingLocalFile)
                }
                if asset.kind == .remote && asset.needsReimport {
                    return Entry(occurrence: occ, row: row, status: .unavailableRemote)
                }
            }
            return Entry(occurrence: occ, row: row, status: .playable)
        }
    }

    /// The replay request for a saved Starter Blend, built only from what the document persisted:
    /// its pack identity, ordered release track ids and each edge's concrete plan. Nil for any
    /// other document, or one whose pack/plans are incomplete (it then replays as a plain queue).
    public static func starterRequest(for document: BlendDocument) -> StarterPlayRequest? {
        guard document.origin == .starter, let pack = document.pack else { return nil }
        let prefix = "\(pack.releaseTag):"
        let ids = document.occurrences.compactMap { occurrence -> String? in
            guard let sync = occurrence.source.syncID, sync.hasPrefix(prefix) else { return nil }
            return String(sync.dropFirst(prefix.count))
        }
        let plans = document.edges.compactMap(\.plan)
        guard ids.count == document.occurrences.count, ids.count > 1, plans.count == ids.count - 1,
              zip(plans, zip(ids, ids.dropFirst())).allSatisfy({
                  $0.outgoingTrackID == $1.0 && $0.incomingTrackID == $1.1 }) else { return nil }
        let blendID = StarterBlendCatalog.blends.first { $0.document.id == document.id }?.id ?? document.title
        guard let rows = try? StarterBlendPlayback.rows(blendID: blendID, title: document.title, trackIDs: ids, pack: pack),
              rows.count == ids.count else { return nil }
        return StarterPlayRequest(blendID: blendID, pack: pack, occurrenceIDs: document.occurrences.map(\.id), rows: rows,
                                  trackIDs: ids, edgePlans: plans)
    }

    /// The queue to hand to the player: playable rows only, in saved order.
    /// Skipped occurrences are the caller's to surface (`entries`), never
    /// replaced by another track.
    public static func playableQueue(_ entries: [Entry]) -> [TrackRow] {
        entries.compactMap { $0.status == .playable ? $0.row : nil }
    }

    public static func lookup(in rows: [TrackRow]) -> (BlendDocument.SourceIdentity) -> TrackRow? {
        var bySync: [String: TrackRow] = [:]
        var byKey: [String: TrackRow] = [:]
        for row in rows {
            if let s = row.track.syncID { bySync[s] = row }
            for k in identity(of: row).identityKeys where byKey[k] == nil { byKey[k] = row }
        }
        return { id in
            if let s = id.syncID, let row = bySync[s] { return row }
            for k in id.identityKeys { if let row = byKey[k] { return row } }
            return nil
        }
    }
}
