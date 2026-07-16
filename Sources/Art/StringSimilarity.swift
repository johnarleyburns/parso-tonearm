import Foundation

/// Pure string-similarity helpers used by the artwork search confidence gate.
/// Case- and diacritic-insensitive throughout so "Bodzín" matches "Bodzin".
public enum StringSimilarity {

    /// Normalizes a string for comparison: lowercased, diacritic-folded,
    /// punctuation reduced to spaces, whitespace collapsed.
    public static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                               locale: Locale(identifier: "en_US"))
        let mapped = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(mapped)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// Distinct normalized tokens of a string.
    public static func tokens(_ s: String) -> Set<String> {
        Set(normalize(s).split(separator: " ").map(String.init))
    }

    /// Levenshtein edit distance between two already-normalized strings.
    public static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var curr = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            curr[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[y.count]
    }

    /// Similarity ratio in [0,1] based on normalized Levenshtein distance.
    /// 1.0 = identical (after normalization), 0.0 = maximally different.
    public static func ratio(_ a: String, _ b: String) -> Double {
        let na = normalize(a), nb = normalize(b)
        if na.isEmpty && nb.isEmpty { return 1 }
        let maxLen = max(na.count, nb.count)
        guard maxLen > 0 else { return 1 }
        let dist = levenshtein(na, nb)
        return 1.0 - (Double(dist) / Double(maxLen))
    }

    /// True when every non-trivial token of `needle` appears (as a close match)
    /// within `haystack`'s tokens. Used to confirm an inferred artist appears in
    /// a candidate's artistName. Tokens of length < 2 are ignored.
    public static func tokensContained(needle: String, in haystack: String,
                                perTokenThreshold: Double = 0.85) -> Bool {
        let needleTokens = tokens(needle).filter { $0.count >= 2 }
        guard !needleTokens.isEmpty else { return false }
        let hayTokens = tokens(haystack)
        guard !hayTokens.isEmpty else { return false }
        for nt in needleTokens {
            let matched = hayTokens.contains(nt)
                || hayTokens.contains(where: { ratio($0, nt) >= perTokenThreshold })
            if !matched { return false }
        }
        return true
    }

    /// Overlap fraction of `needle` tokens found within `haystack` tokens.
    public static func tokenOverlap(needle: String, haystack: String) -> Double {
        let needleTokens = tokens(needle).filter { $0.count >= 2 }
        guard !needleTokens.isEmpty else { return 0 }
        let hayTokens = tokens(haystack)
        let hits = needleTokens.filter { nt in
            hayTokens.contains(nt) || hayTokens.contains(where: { ratio($0, nt) >= 0.85 })
        }
        return Double(hits.count) / Double(needleTokens.count)
    }
}
