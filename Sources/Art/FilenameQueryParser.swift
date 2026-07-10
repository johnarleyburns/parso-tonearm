import Foundation

/// Parses a noisy track title / filename into structured query candidates for
/// artwork lookup. Handles the messy cases where only an artist name, or a
/// single keyword, is present (e.g. "Stephan Bodzin", "Solomun.flac",
/// "01 - Nicola Cruz - Boiler Room (Live)").
struct FilenameQueryParser {

    struct Query: Equatable {
        var artist: String?
        var title: String?
        /// Whole cleaned string, used for last-resort term searches.
        var cleanedTerm: String
    }

    /// Noise tokens (mix/edit/quality qualifiers) removed before splitting.
    private static let noiseTokens: Set<String> = [
        "original", "mix", "remix", "extended", "edit", "radio", "version",
        "live", "dj", "set", "bootleg", "remaster", "remastered", "instrumental",
        "flac", "mp3", "wav", "320", "kbps", "hd", "hq", "official", "audio",
        "video", "lyrics", "feat", "ft", "featuring"
    ]

    func parse(_ raw: String) -> Query {
        var s = raw

        // 1. Strip a file extension if present.
        let ext = (s as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 4, Int(ext) == nil {
            s = (s as NSString).deletingPathExtension
        }

        // 2. Separator normalization: underscores/dots -> spaces.
        s = s.replacingOccurrences(of: "_", with: " ")
             .replacingOccurrences(of: ".", with: " ")

        // 3. Remove bracketed segments: (...), [...], {...}.
        s = Self.removeBracketed(s)

        // 4. Strip leading track numbers ("01 - ", "3. ", "07 ").
        s = Self.stripLeadingTrackNumber(s)

        // 5. Collapse whitespace.
        s = s.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
             .trimmingCharacters(in: .whitespaces)

        // 6. Split on " - " into artist / title candidates.
        var artist: String?
        var title: String?
        if let range = s.range(of: " - ") {
            let left = String(s[s.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !left.isEmpty { artist = Self.stripNoise(left) }
            if !right.isEmpty { title = Self.stripNoise(right) }
        } else {
            // No dash: whole cleaned string is the artist term (bare "Solomun").
            let cleaned = Self.stripNoise(s)
            if !cleaned.isEmpty { artist = cleaned }
        }

        let cleanedTerm = Self.stripNoise(s)
        return Query(artist: artist?.nilIfEmpty,
                     title: title?.nilIfEmpty,
                     cleanedTerm: cleanedTerm)
    }

    // MARK: - Helpers

    private static func removeBracketed(_ s: String) -> String {
        var result = ""
        var depth = 0
        for ch in s {
            if ch == "(" || ch == "[" || ch == "{" {
                depth += 1
            } else if ch == ")" || ch == "]" || ch == "}" {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                result.append(ch)
            }
        }
        return result
    }

    private static func stripLeadingTrackNumber(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        var idx = trimmed.startIndex
        var digits = 0
        while idx < trimmed.endIndex, trimmed[idx].isNumber {
            idx = trimmed.index(after: idx)
            digits += 1
        }
        guard digits > 0, digits <= 3, idx < trimmed.endIndex else { return trimmed }
        // Require a separator after the digits so we don't eat "3005" style names.
        var sepIdx = idx
        var sawSep = false
        while sepIdx < trimmed.endIndex,
              trimmed[sepIdx] == " " || trimmed[sepIdx] == "-" || trimmed[sepIdx] == "." {
            sepIdx = trimmed.index(after: sepIdx)
            sawSep = true
        }
        guard sawSep, sepIdx < trimmed.endIndex else { return trimmed }
        return String(trimmed[sepIdx...]).trimmingCharacters(in: .whitespaces)
    }

    /// Removes noise/qualifier tokens and years, collapsing whitespace.
    private static func stripNoise(_ s: String) -> String {
        let kept = s.split(separator: " ").map(String.init).filter { token in
            let lower = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-–—"))
            if lower.isEmpty { return false }
            if noiseTokens.contains(lower) { return false }
            // Drop bare 4-digit years (1900-2099).
            if lower.count == 4, let n = Int(lower), (1900...2099).contains(n) { return false }
            return true
        }
        return kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
