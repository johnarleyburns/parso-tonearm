import Foundation

/// Which lifecycle stage a catalog row reached. No code advances a row past `.unindexed` anymore
/// (the eligibility/edge-planning lifecycle that once did — `markBlendEligible`,
/// `recordBlendEdgePlan` — was removed as dead code; Jamendo tracks get their bpm/key from the
/// generic `discovery_track_analysis` pipeline instead). Kept, with its stored raw values, only
/// because it's still the type of `BlendCatalogTrack.state`, read back for existing/legacy rows.
public enum BlendCatalogState: String, Codable, Sendable, Equatable, CaseIterable {
    /// Known to the catalog, facts missing: never selected.
    case unindexed
    /// Every fact a blend needs is present (tempo, beat grid, duration, loudness).
    case blendEligible
    /// At least one adjacent edge has a concrete, executable plan.
    case edgePlanned
}

/// Selection facts beyond the beat grid: genre, optional subgenre and a Camelot key such as `8A`.
public struct BlendTraits: Codable, Sendable, Equatable {
    public var genre: String
    public var subgenre: String?
    public var camelotKey: String

    public init(genre: String, subgenre: String? = nil, camelotKey: String) {
        self.genre = genre; self.subgenre = subgenre; self.camelotKey = camelotKey
    }

    /// `(number 1…12, isMajor)` for a well-formed Camelot code (`8A` minor, `8B` major); nil otherwise.
    public static func parseCamelot(_ key: String) -> (number: Int, major: Bool)? {
        let text = key.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = text.last, letter == "A" || letter == "B",
              let number = Int(text.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter == "B")
    }

    static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public var isValid: Bool { Self.normalized(genre) != nil && Self.parseCamelot(camelotKey) != nil }

    /// Documented rule: the same code, a neighbour on the wheel (±1, wrapping 12↔1) in the same mode,
    /// or the relative major/minor (same number, other letter). Anything unparseable is incompatible.
    public static func camelotCompatible(_ a: String, _ b: String) -> Bool {
        guard let x = parseCamelot(a), let y = parseCamelot(b) else { return false }
        if x.number == y.number { return true }
        guard x.major == y.major else { return false }
        let step = abs(x.number - y.number)
        return step == 1 || step == 11
    }

    /// Same genre; when both name a subgenre it must match. Missing or invalid traits never pair.
    public func isCompatible(with other: BlendTraits) -> Bool {
        guard isValid, other.isValid, Self.normalized(genre) == Self.normalized(other.genre) else { return false }
        if let a = Self.normalized(subgenre), let b = Self.normalized(other.subgenre), a != b { return false }
        return Self.camelotCompatible(camelotKey, other.camelotKey)
    }

    /// Both sides name the same subgenre (preferred over a broad-genre-only match).
    public func sharesSubgenre(with other: BlendTraits) -> Bool {
        guard let a = Self.normalized(subgenre), let b = Self.normalized(other.subgenre) else { return false }
        return a == b
    }
}
