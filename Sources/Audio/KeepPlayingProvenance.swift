import Foundation

/// Why Keep Playing chose a track. Closed on purpose: UI labels switch over it exhaustively.
public enum KeepPlayingRecommendationReason: String, Codable, Equatable, Sendable {
    /// Strict Build-a-Mix rules: ±8% BPM and a compatible Camelot key.
    case mixMatched
    /// No strict pair was available, so the nearest analysed track by BPM,
    /// key and energy was used. Still a musical pick, not a shuffle.
    case relaxedMixMatched
    /// Nothing in the analysed library was usable; plain shuffle.
    case noMatchShuffle

    var needsMusicalFacts: Bool {
        self == .mixMatched || self == .relaxedMixMatched
    }
}

/// Immutable snapshot of why one queue occurrence was auto-added. The BPM/key shown for a mix
/// match are captured when the entry is created so a later re-index cannot rewrite the
/// explanation. Only values the provider actually supplied are stored — no invented scores.
public struct KeepPlayingProvenance: Codable, Equatable, Sendable {
    public let reason: KeepPlayingRecommendationReason
    public let bpm: Double?
    public let camelotKey: String?

    /// Failable: a musical match requires a finite positive BPM and a Camelot key.
    public init?(reason: KeepPlayingRecommendationReason, bpm: Double? = nil, camelotKey: String? = nil) {
        if reason.needsMusicalFacts {
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
        case .relaxedMixMatched:
            return "Nearest match · \(Self.formatBPM(bpm ?? 0)) BPM · \(camelotKey ?? "")"
        case .noMatchShuffle:
            return "Shuffled · no BPM/key-compatible track was available"
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
        case .relaxedMixMatched:
            return ["Recommendation: \(subtitle)",
                    "BPM: \(Self.formatBPM(bpm ?? 0))",
                    "Camelot key: \(camelotKey ?? "")",
                    "No track satisfied the strict ±8% / compatible-key rule"]
        case .noMatchShuffle:
            return ["Recommendation: \(subtitle)", "Reason: the library has no usable BPM/key analysis"]
        }
    }

    public static let whyActionName = "Why this track?"
}
