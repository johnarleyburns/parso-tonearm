import Foundation

/// The transfer phase of a single track toward the watch, as the iPhone track-row glyph
/// needs to render it. The Phase-6 pipeline (`PhoneWatchDownloadManager` / `WatchGlyph`)
/// is the only remaining consumer — `AppState.watchTransferState(forID:)` maps the
/// download job's state string onto these four cases. Phase 10 deleted the rest of the
/// pre-cutover transfer queue; this enum stays with the glyph API it now belongs to.
public enum WatchTransferState: String, Equatable, Codable, Sendable {
    case queued
    case sending
    case sent
    case failed
}

public enum WatchGlyphState: Equatable {
    case notOnWatch
    case transferring(progress: Double?)
    case onWatch
    case failed
}

public enum WatchGlyph {
    /// Derive glyph state from manifest + transfer states.
    /// Priority: transferring > failed > onWatch > notOnWatch.
    public static func state(
        trackKey: String,
        manifest: Set<String>,
        transferState: WatchTransferState?,
        errorText: String?,
        sendingProgress: Double? = nil
    ) -> WatchGlyphState {
        // Transferring takes priority
        if let ts = transferState {
            switch ts {
            case .queued:
                return .transferring(progress: nil)
            case .sending:
                return .transferring(progress: sendingProgress)
            case .sent:
                return .onWatch
            case .failed:
                return .failed
            }
        }
        // Check manifest (source of truth from watch)
        if manifest.contains(trackKey) {
            return .onWatch
        }
        if let error = errorText, !error.isEmpty {
            return .failed
        }
        return .notOnWatch
    }

    /// Derive aggregate state for a collection of track keys.
    /// Returns (state, fraction on watch).
    public static func aggregateState(
        trackKeys: [String],
        manifest: Set<String>,
        transferStates: [String: WatchTransferState],
        errorTexts: [String: String]
    ) -> (WatchGlyphState, Double) {
        guard !trackKeys.isEmpty else { return (.notOnWatch, 0.0) }

        let onWatchCount = trackKeys.filter { manifest.contains($0) }.count
        let fraction = Double(onWatchCount) / Double(trackKeys.count)

        let hasTransferring = trackKeys.contains { key in
            if let ts = transferStates[key], ts == .queued || ts == .sending { return true }
            return false
        }
        let hasFailed = trackKeys.contains { key in
            if let ts = transferStates[key], ts == .failed { return true }
            if let err = errorTexts[key], !err.isEmpty { return true }
            return false
        }

        if hasTransferring { return (.transferring(progress: fraction), fraction) }
        if hasFailed { return (.failed, fraction) }
        if onWatchCount == trackKeys.count { return (.onWatch, 1.0) }
        return (.notOnWatch, fraction)
    }
}
