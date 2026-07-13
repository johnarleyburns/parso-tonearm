import Foundation

struct ArtistNamePolicy {
    struct Attribution: Equatable {
        var albumArtist: String?
        var trackArtists: [String]
        var isCompilation: Bool
    }

    static let canonicalVariousArtists = "Various Artists"

    private static let articles: Set<String> = [
        "a", "an", "the",
        "el", "la", "los", "las",
        "le", "les",
        "il", "lo", "gli", "i",
        "der", "die", "das", "den",
    ]

    static func normalize(_ raw: String?) -> String? {
        guard var value = raw else { return nil }
        value = value.replacingOccurrences(of: "\u{00a0}", with: " ")
        value =
            value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        guard !value.isEmpty else { return nil }
        return isVariousArtists(value) ? canonicalVariousArtists : value
    }

    static func sortName(for raw: String) -> String {
        guard let normalized = normalize(raw) else { return "" }
        let folded = normalized.folding(
            options: [.diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let lowered = folded.lowercased()

        if lowered.hasPrefix("l'"), folded.count > 2 {
            return String(folded.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var parts = folded.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if let first = parts.first?.lowercased(), articles.contains(first), parts.count > 1 {
            parts.removeFirst()
        }
        return parts.joined(separator: " ")
    }

    static func splitArtists(_ raw: String?) -> [String] {
        guard let normalized = normalize(raw) else { return [] }
        if isVariousArtists(normalized) { return [canonicalVariousArtists] }

        let splitPattern = #"(?i)\s+(?:feat\.?|featuring|ft\.?|with)\s+|\s*(?:&|;|\+)\s*|\s+/\s+"#
        let regex = try? NSRegularExpression(pattern: splitPattern)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let separated =
            regex?.stringByReplacingMatches(in: normalized, range: range, withTemplate: "\u{001f}")
            ?? normalized

        var seen: Set<String> = []
        var result: [String] = []
        for piece in separated.split(separator: "\u{001f}") {
            guard let name = normalize(String(piece)) else { continue }
            let key = identityKey(for: name)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(name)
        }
        return result
    }

    static func artistNames(from raw: String?) -> [String] {
        splitArtists(raw)
    }

    static func attribution(
        albumArtist rawAlbumArtist: String?, trackArtist rawTrackArtist: String?
    )
        -> Attribution
    {
        let albumArtist = normalize(rawAlbumArtist)
        let trackArtists = splitArtists(rawTrackArtist)
        let compilation =
            isVariousArtists(albumArtist)
            || (albumArtist == nil && isVariousArtists(rawTrackArtist))

        if let albumArtist {
            return Attribution(
                albumArtist: albumArtist,
                trackArtists: trackArtists,
                isCompilation: compilation)
        }
        return Attribution(
            albumArtist: trackArtists.first,
            trackArtists: trackArtists,
            isCompilation: compilation)
    }

    static func isVariousArtists(_ raw: String?) -> Bool {
        guard
            let value = raw?
                .folding(
                    options: [.diacriticInsensitive, .caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }

        let compact =
            value
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        return compact == "va"
            || compact == "various"
            || compact == "variousartist"
            || compact == "variousartists"
    }

    static func identityKey(for raw: String) -> String {
        (normalize(raw) ?? raw)
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
    }
}
