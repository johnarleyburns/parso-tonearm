#if !os(watchOS)
import Foundation
import ParsoAudioAnalysis

/// A unified-catalog retrieval request (plan §9). Codable so a saved search /
/// auto-playlist brief round-trips through storage unchanged, and so search,
/// similar-track, saved searches and auto-playlist candidate retrieval all
/// speak the SAME contract (plan §9: "Search, similar-track search, saved
/// searches and auto-playlist candidate retrieval share the same scope/filter
/// semantics and repository").
///
/// This is the raw, user-supplied form. `ValidatedQuery.validate(_:)` turns it
/// into the normalized, checked value the engine actually runs; oversize or
/// malformed input yields an actionable `[QueryValidationIssue]` rather than a
/// silently-clamped query (plan §9).
public struct DiscoverySearchQuery: Codable, Equatable, Sendable {
    /// Free text. Empty text with no filters is an ordinary scoped library
    /// browse, not an error (plan §9).
    public var text: String
    /// "More like" soft vector nudges — NOT semantic guarantees (plan §9).
    public var positiveRefinements: [String]
    /// "Less like" soft vector nudges.
    public var negativeRefinements: [String]
    /// Explicit selected scope. `nil` means the whole library; an empty array
    /// means an explicitly empty scope (returns `emptyScope`, never silently
    /// widens — plan §9).
    public var sourceIDs: [Int64]?
    /// Scope to one playlist's tracks.
    public var playlistID: Int64?
    public var bpmMin: Double?
    public var bpmMax: Double?
    /// Camelot code, e.g. "8A". A hard harmonic gate (plan §9).
    public var compatibleKey: String?
    public var limit: Int

    public init(
        text: String = "",
        positiveRefinements: [String] = [],
        negativeRefinements: [String] = [],
        sourceIDs: [Int64]? = nil,
        playlistID: Int64? = nil,
        bpmMin: Double? = nil,
        bpmMax: Double? = nil,
        compatibleKey: String? = nil,
        limit: Int = ValidatedQuery.defaultLimit
    ) {
        self.text = text
        self.positiveRefinements = positiveRefinements
        self.negativeRefinements = negativeRefinements
        self.sourceIDs = sourceIDs
        self.playlistID = playlistID
        self.bpmMin = bpmMin
        self.bpmMax = bpmMax
        self.compatibleKey = compatibleKey
        self.limit = limit
    }
}

/// One reason a `DiscoverySearchQuery` was rejected — actionable, not a
/// generic "invalid query" (plan §9).
public enum QueryValidationIssue: Equatable, Sendable, CustomStringConvertible {
    case textTooLong(limit: Int, actual: Int)
    case tooManyRefinements(limit: Int, actual: Int)
    case refinementTermTooLong(limit: Int, actual: Int, term: String)
    case bpmNotFinite
    case bpmReversed(min: Double, max: Double)
    case bpmNegative(Double)
    case invalidKeyCode(String)
    case limitOutOfRange(min: Int, max: Int, actual: Int)

    public var description: String {
        switch self {
        case .textTooLong(let limit, let actual):
            return "Search text is \(actual) characters; the maximum is \(limit)."
        case .tooManyRefinements(let limit, let actual):
            return "\(actual) refinement terms supplied; at most \(limit) are allowed."
        case .refinementTermTooLong(let limit, let actual, let term):
            return "Refinement \"\(term)\" is \(actual) characters; the maximum is \(limit)."
        case .bpmNotFinite:
            return "The BPM range contains a value that is not a finite number."
        case .bpmReversed(let min, let max):
            return "The BPM range is reversed (\(min)–\(max)); the low value must not exceed the high value."
        case .bpmNegative(let value):
            return "BPM \(value) is negative."
        case .invalidKeyCode(let code):
            return "\"\(code)\" is not a valid Camelot key code (expected e.g. 8A, 12B)."
        case .limitOutOfRange(let min, let max, let actual):
            return "A result limit of \(actual) is out of range (\(min)…\(max))."
        }
    }
}

/// The normalized, validated form of a `DiscoverySearchQuery` — whitespace
/// collapsed, empties dropped, BPM range as a `ClosedRange`, key parsed to a
/// `CamelotKey`. The engine only ever runs this type.
public struct ValidatedQuery: Equatable, Sendable {
    public static let maxTextCharacters = 500
    public static let maxRefinementTerms = 8
    public static let maxRefinementTermCharacters = 100
    public static let minLimit = 1
    public static let maxLimit = 200
    public static let defaultLimit = 50

    public let text: String
    public let positiveRefinements: [String]
    public let negativeRefinements: [String]
    /// `nil` → whole library; `.some([])` → explicitly empty scope.
    public let sourceIDs: [Int64]?
    public let playlistID: Int64?
    public let bpmRange: ClosedRange<Double>?
    public let compatibleKey: CamelotKey?
    public let limit: Int

    /// True when the request carries a hard musical gate (BPM range or key).
    /// Hard gates exclude tracks whose required attribute is unknown (plan §9).
    public var hasHardMusicalFilter: Bool { bpmRange != nil || compatibleKey != nil }

    /// True when there is neither text nor a refinement term.
    public var hasText: Bool { !text.isEmpty || !positiveRefinements.isEmpty }

    /// Wraps `[QueryValidationIssue]` so it can travel as `Result.Failure`.
    public struct Failure: Error, Equatable, Sendable {
        public let issues: [QueryValidationIssue]
    }

    public static func validate(
        _ raw: DiscoverySearchQuery
    ) -> Result<ValidatedQuery, Failure> {
        var issues: [QueryValidationIssue] = []

        let normalizedText = normalizeWhitespace(raw.text)
        // Count against the raw (pre-normalization) text so a user pasting a
        // 10k-char blob gets told, not silently trimmed.
        if raw.text.count > maxTextCharacters {
            issues.append(.textTooLong(limit: maxTextCharacters, actual: raw.text.count))
        }

        func normalizeTerms(_ terms: [String]) -> [String] {
            terms.map(normalizeWhitespace).filter { !$0.isEmpty }
        }
        let pos = normalizeTerms(raw.positiveRefinements)
        let neg = normalizeTerms(raw.negativeRefinements)
        let totalTerms = pos.count + neg.count
        if totalTerms > maxRefinementTerms {
            issues.append(.tooManyRefinements(limit: maxRefinementTerms, actual: totalTerms))
        }
        for term in pos + neg where term.count > maxRefinementTermCharacters {
            issues.append(
                .refinementTermTooLong(
                    limit: maxRefinementTermCharacters, actual: term.count, term: term))
        }

        var bpmRange: ClosedRange<Double>?
        if raw.bpmMin != nil || raw.bpmMax != nil {
            let lo = raw.bpmMin ?? raw.bpmMax ?? 0
            let hi = raw.bpmMax ?? raw.bpmMin ?? 0
            if !lo.isFinite || !hi.isFinite {
                issues.append(.bpmNotFinite)
            } else if lo < 0 || hi < 0 {
                issues.append(.bpmNegative(min(lo, hi)))
            } else if lo > hi {
                issues.append(.bpmReversed(min: lo, max: hi))
            } else {
                bpmRange = lo...hi
            }
        }

        var key: CamelotKey?
        if let code = raw.compatibleKey, !code.trimmingCharacters(in: .whitespaces).isEmpty {
            if let parsed = CamelotKey(code: code) {
                key = parsed
            } else {
                issues.append(.invalidKeyCode(code))
            }
        }

        if raw.limit < minLimit || raw.limit > maxLimit {
            issues.append(.limitOutOfRange(min: minLimit, max: maxLimit, actual: raw.limit))
        }

        guard issues.isEmpty else { return .failure(Failure(issues: issues)) }

        return .success(
            ValidatedQuery(
                text: normalizedText,
                positiveRefinements: pos,
                negativeRefinements: neg,
                sourceIDs: raw.sourceIDs,
                playlistID: raw.playlistID,
                bpmRange: bpmRange,
                compatibleKey: key,
                limit: raw.limit))
    }

    init(
        text: String,
        positiveRefinements: [String],
        negativeRefinements: [String],
        sourceIDs: [Int64]?,
        playlistID: Int64?,
        bpmRange: ClosedRange<Double>?,
        compatibleKey: CamelotKey?,
        limit: Int
    ) {
        self.text = text
        self.positiveRefinements = positiveRefinements
        self.negativeRefinements = negativeRefinements
        self.sourceIDs = sourceIDs
        self.playlistID = playlistID
        self.bpmRange = bpmRange
        self.compatibleKey = compatibleKey
        self.limit = limit
    }

    private static func normalizeWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
#endif
