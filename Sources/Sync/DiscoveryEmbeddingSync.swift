import Foundation

/// Accept/reject rule for an incoming `discovery_embedding`/
/// `discovery_track_analysis` record — docs/plans/macos-app-cloud-sync-plan.md
/// §4.3, encoding the owner's explicit decisions (2026-09-19):
///
/// - A version mismatch is always rejected, and the *local* job is requeued
///   so this device re-indexes with its own currently-active pipeline —
///   never trusts a vector produced by a different model/preprocessing/
///   sampling version, and never silently drops the track either.
/// - This device's own completed indexing always wins: if it has already
///   indexed a track, an incoming embedding for that same track is
///   rejected outright, never overwriting completed local work.
/// - The one case a device benefits from another device's work: it hasn't
///   indexed the track itself yet, and the incoming embedding's version
///   matches this device's own active version.
///
/// Deliberately NOT `SyncMerge`'s last-writer-wins rule — kept in its own
/// file rather than folded into that one, since the two policies operate on
/// genuinely different axes (recency vs. version-compatibility-and-
/// already-done) and conflating them would make either one hard to read on
/// its own.
public enum DiscoveryEmbeddingSyncDecision: Equatable, Sendable {
    /// Write the incoming record locally.
    case accept
    /// Incompatible version: discard the incoming record, and reset this
    /// device's own `discovery_index_job` for the track back to `queued` so
    /// it re-indexes with its own active pipeline.
    case rejectRequeue
    /// This device already has a completed local embedding for the track:
    /// discard the incoming record, no requeue.
    case rejectKeepLocal

    public static func decide(
        incomingModelVersion: Int, incomingPreprocessingVersion: Int, incomingSamplingVersion: Int,
        activeModelVersion: Int, activePreprocessingVersion: Int, activeSamplingVersion: Int,
        localEmbeddingExists: Bool
    ) -> DiscoveryEmbeddingSyncDecision {
        let versionMatches = incomingModelVersion == activeModelVersion
            && incomingPreprocessingVersion == activePreprocessingVersion
            && incomingSamplingVersion == activeSamplingVersion
        guard versionMatches else { return .rejectRequeue }
        guard !localEmbeddingExists else { return .rejectKeepLocal }
        return .accept
    }
}
