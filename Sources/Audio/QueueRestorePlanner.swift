import Foundation

/// The result of planning a queue restore from a persisted snapshot.
public struct RestorePlan {
    public var rows: [TrackRow]
    public var startIndex: Int
    public var seekTo: Double

    public init(rows: [TrackRow], startIndex: Int, seekTo: Double) {
        self.rows = rows
        self.startIndex = startIndex
        self.seekTo = seekTo
    }
}

/// Pure, testable planner that rebuilds a play queue from a `PlaybackStateSnapshot`.
/// Resolves tracks by rowid, falling back to syncID for reinstall scenarios where
/// rowids have changed after CloudKit resync (G6).
public enum QueueRestorePlanner {

    /// Plans a restore given resolution closures. `resolveByID` looks up a row
    /// by the legacy Int64 PK; `resolveBySyncID` looks up by the stable syncID.
    ///
    /// - If the saved current track cannot be resolved, `seekTo` is zeroed to
    ///   avoid applying the old position to the wrong track (Loss #5).
    /// - Returns `nil` when no tracks can be resolved at all.
    public static func plan(
        saved: PlaybackStateSnapshot,
        resolveByID: (Int64) async -> TrackRow?,
        resolveBySyncID: (String) async -> TrackRow?
    ) async -> RestorePlan? {
        var rows: [TrackRow] = []
        var startIndex = 0
        var currentResolved = false

        for (position, id) in saved.trackIDs.enumerated() {
            // Try rowid first, then syncID fallback (reinstall shape).
            let resolved: TrackRow?
            if let row = await resolveByID(id) {
                resolved = row
            } else if let syncID = saved.trackSyncIDs?[safe: position], let sid = syncID {
                resolved = await resolveBySyncID(sid)
            } else {
                resolved = nil
            }

            guard let row = resolved else { continue }

            if position == saved.currentIndex {
                startIndex = rows.count
                currentResolved = true
            }
            rows.append(row)
        }

        guard !rows.isEmpty else { return nil }

        let clampedIndex = min(startIndex, rows.count - 1)
        let seekTo: Double
        if currentResolved, saved.elapsed > 0 {
            // Clamp: if duration is known and elapsed > duration - 0.5,
            // keep end-of-track snapshots from auto-advancing.
            let dur = rows[clampedIndex].track.durationSec ?? 0
            let clamped = dur > 0 ? min(saved.elapsed, max(0, dur - 0.5)) : saved.elapsed
            seekTo = clamped.isFinite ? max(0, clamped) : 0
        } else {
            // Current track missing → zero elapsed (Loss #5).
            seekTo = 0
        }

        return RestorePlan(rows: rows, startIndex: clampedIndex, seekTo: seekTo)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
