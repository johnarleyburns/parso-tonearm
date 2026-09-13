import Foundation

/// Pure "Keep Playing" selection logic, factored out of `AudioPlayer` so it's
/// testable without a live player/queue/`LibraryStore` — the same reason
/// `QueueEditor` exists as a static namespace over plain queue state rather
/// than living as private logic inside `AudioPlayer` itself.
public enum KeepPlayingPicker {
    /// Whether the manually-built queue is close enough to running out that
    /// Keep Playing should attempt an extension right now. Mirrors exactly
    /// what `AudioPlayer.maybeExtendKeepPlayingQueue()` gates on.
    public static func shouldAttemptExtension(
        enabled: Bool,
        isAmbient: Bool,
        repeatMode: RepeatMode,
        queueCount: Int,
        index: Int,
        lastAttemptedIndex: Int?,
        extensionInFlight: Bool
    ) -> Bool {
        guard enabled, !isAmbient else { return false }
        // `.all` loops the existing queue forever and `.one` never advances
        // past the current track — neither can ever "run out".
        guard repeatMode == .off else { return false }
        guard index >= 0, index < queueCount else { return false }
        // The current track is the last or second-to-last in the queue — the
        // second-to-last case gives the lookup a full track's worth of time
        // to finish before playback actually needs the result.
        guard queueCount - index <= 2 else { return false }
        guard lastAttemptedIndex != index else { return false }
        guard !extensionInFlight else { return false }
        return true
    }

    /// Filters a similarity provider's raw candidate ids down to the ones
    /// Keep Playing may actually use: never something already excluded
    /// (this session's play history, or a track already sitting in the live
    /// queue), and never a duplicate within the candidate list itself — a
    /// defense against a misbehaving provider, not just documentation of the
    /// protocol's contract. Order is preserved (best match first).
    public static func dedupedCandidates(_ ids: [Int64], excluding: Set<Int64>) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { id in
            guard !excluding.contains(id), seen.insert(id).inserted else { return false }
            return true
        }
    }
}
