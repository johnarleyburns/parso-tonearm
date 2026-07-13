import Foundation

enum SharePayloadResolver {
    enum Payload: Equatable {
        case url(URL)
        case text(String)
        case attributedText(String)
    }

    static func archiveURL(from payloads: [Payload]) -> String? {
        for payload in payloads {
            for candidate in candidates(from: payload) {
                if case .success = URLGrammar.parse(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func candidates(from payload: Payload) -> [String] {
        switch payload {
        case .url(let url):
            return [url.absoluteString]
        case .text(let value), .attributedText(let value):
            return candidates(in: value)
        }
    }

    private static func candidates(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [String] = [trimmed]
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            detector.enumerateMatches(in: trimmed, options: [], range: range) { match, _, _ in
                guard let matchRange = match?.range,
                      let swiftRange = Range(matchRange, in: trimmed) else {
                    return
                }
                results.append(String(trimmed[swiftRange]))
            }
        }

        let tokenCharacters = CharacterSet.whitespacesAndNewlines
        results.append(contentsOf: trimmed.components(separatedBy: tokenCharacters))
        return unique(results.compactMap(clean))
    }

    private static func clean(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}\"'.,;"))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for value in values where seen.insert(value).inserted {
            ordered.append(value)
        }
        return ordered
    }
}

enum TonearmDeepLink: Equatable {
    case addSource(String)

    static let scheme = "tonearm"
    private static let addSourceHost = "add-source"

    static func url(for action: TonearmDeepLink) -> URL? {
        switch action {
        case .addSource(let rawURL):
            guard !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            var components = URLComponents()
            components.scheme = scheme
            components.host = addSourceHost
            components.queryItems = [URLQueryItem(name: "url", value: rawURL)]
            return components.url
        }
    }

    static func parse(_ url: URL) -> TonearmDeepLink? {
        guard url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == addSourceHost,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              case .success = URLGrammar.parse(rawURL) else {
            return nil
        }
        return .addSource(rawURL)
    }
}
