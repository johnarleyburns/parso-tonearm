import Foundation
import TonearmWatchProtocol

/// §7.5 "Continue on Watch". When phone playback becomes unreachable and its current track has a
/// ready local asset, the watch offers an **explicit** continuation — never an automatic handoff,
/// never a claim of gapless playback. This is the pure projection of the phone's last snapshot onto
/// a local queue the watch can actually play.
public struct WatchContinueOnWatchPlan: Equatable, Sendable {
    /// Downloaded members of the phone's queue window, in the phone's order.
    public let trackIDs: [WatchTrackID]
    /// Index into `trackIDs` of the track the phone was on.
    public let startIndex: Int
    /// The elapsed position to resume at — the last authoritative anchor, projected to `now` and
    /// clamped to the track's duration (§7.5).
    public let elapsedAnchor: Double

    public init(trackIDs: [WatchTrackID], startIndex: Int, elapsedAnchor: Double) {
        self.trackIDs = trackIDs
        self.startIndex = startIndex
        self.elapsedAnchor = elapsedAnchor
    }

    /// Build the plan, or `nil` when the offer must not be made — the phone isn't playing a known
    /// track, or that track isn't downloaded on this watch.
    public static func make(from snapshot: WatchPhonePlaybackSnapshot,
                            locallyAvailable: Set<WatchTrackID>,
                            now: Date = Date()) -> WatchContinueOnWatchPlan? {
        guard let current = snapshot.currentItem,
              locallyAvailable.contains(current.trackID) else { return nil }

        let windowSurvivors = snapshot.queueWindow.filter { locallyAvailable.contains($0.trackID) }
        // An empty window still lets us continue the one track we know about.
        let survivors = windowSurvivors.isEmpty ? [current] : windowSurvivors

        guard let startIndex = survivors.firstIndex(where: { $0.trackID == current.trackID }) else {
            return nil
        }

        let projected = snapshot.elapsedSeconds(at: now)
        let anchor: Double
        if let duration = current.durationSeconds, duration > 0 {
            anchor = min(max(0, projected), duration)
        } else {
            anchor = max(0, projected)
        }

        return WatchContinueOnWatchPlan(trackIDs: survivors.map(\.trackID),
                                        startIndex: startIndex, elapsedAnchor: anchor)
    }
}
