import Foundation

/// Why Keep Playing chose a track. Closed on purpose: UI labels switch over it exhaustively.
public enum KeepPlayingRecommendationReason: String, Codable, Equatable, Sendable {
    case mixMatched
    case soundSimilar
    case modelUnavailableShuffle
    case noMatchShuffle
}

/// Immutable snapshot of why one queue occurrence was auto-added. The BPM/key shown for a mix
/// match are captured when the entry is created so a later re-index cannot rewrite the
/// explanation. Only values the provider actually supplied are stored — no invented scores.
public struct KeepPlayingProvenance: Codable, Equatable, Sendable {
    public let reason: KeepPlayingRecommendationReason
    public let bpm: Double?
    public let camelotKey: String?

    /// Failable: a `.mixMatched` provenance requires a finite positive BPM and a Camelot key.
    public init?(reason: KeepPlayingRecommendationReason, bpm: Double? = nil, camelotKey: String? = nil) {
        if reason == .mixMatched {
            guard let bpm, bpm.isFinite, bpm > 0,
                  let camelotKey, !camelotKey.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            self.bpm = bpm
            self.camelotKey = camelotKey
        } else {
            self.bpm = nil
            self.camelotKey = nil
        }
        self.reason = reason
    }

    /// At most one decimal place: 124.4 -> "124.4", 124 -> "124".
    static func formatBPM(_ bpm: Double) -> String {
        let rounded = (bpm * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    public var subtitle: String {
        switch reason {
        case .mixMatched:
            return "Mix match · \(Self.formatBPM(bpm ?? 0)) BPM · \(camelotKey ?? "")"
        case .soundSimilar: return "Sound similar · no BPM/key match available"
        case .modelUnavailableShuffle: return "Shuffled · sound model is not ready"
        case .noMatchShuffle: return "Shuffled · no compatible recommendation was available"
        }
    }

    public var accessibilitySuffix: String { "Recommended by Keep Playing: \(subtitle)" }

    /// Exact detail lines for the "Why this track?" sheet; only fields that exist.
    public var detailLines: [String] {
        switch reason {
        case .mixMatched:
            return ["Recommendation: \(subtitle)",
                    "BPM: \(Self.formatBPM(bpm ?? 0))",
                    "Camelot key: \(camelotKey ?? "")"]
        case .soundSimilar:
            return ["Recommendation: \(subtitle)", "No DJ-compatible candidate was available"]
        case .modelUnavailableShuffle:
            return ["Recommendation: \(subtitle)", "Reason: the sound model is not ready"]
        case .noMatchShuffle:
            return ["Recommendation: \(subtitle)", "Reason: no compatible recommendation was available"]
        }
    }

    public static let whyActionName = "Why this track?"
}
