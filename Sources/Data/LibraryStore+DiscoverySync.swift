import Foundation
import GRDB

/// Local reads of discovery analysis results — the query the DJ surface needs
/// to display BPM and key without knowing the discovery table layout.
extension LibraryStore {
    /// The DJ surface needs the locally-indexed musical values without making
    /// the UI know the discovery table layout. Unknown BPM/key values remain
    /// nil; callers display an honest "—" until analysis completes.
    public func discoveryTrackAnalysis(trackId: Int64) throws -> DiscoveryTrackAnalysis? {
        try dbQueue.read { db in
            try DiscoveryTrackAnalysis.fetchOne(db, key: trackId)
        }
    }
}
