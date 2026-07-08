import Foundation

enum IAResolvedURL: Equatable {
    case item(identifier: String, filename: String?)
    case list(screenname: String, listId: String, slug: String?)
    case favorites(screenname: String)
    case collection(identifier: String)
}

enum IAURLError: Error, Equatable, LocalizedError {
    case wayback
    case notArchiveHost
    case unrecognized
    case empty

    var errorDescription: String? {
        switch self {
        case .wayback: return "This is a Wayback Machine URL"
        case .notArchiveHost: return "Not an archive.org link"
        case .unrecognized: return "This link isn’t an item, list, favorites page, or collection"
        case .empty: return "Paste an archive.org link"
        }
    }
}

/// FR-2.1 URL grammar parser. Pure, deterministic, exhaustively tested.
enum URLGrammar {
    static let allowedHosts: Set<String> = ["archive.org", "www.archive.org"]

    static func parse(_ raw: String) -> Result<IAResolvedURL, IAURLError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        var string = trimmed
        if !string.lowercased().hasPrefix("http") {
            string = "https://" + string
        }

        guard let comps = URLComponents(string: string), let host = comps.host?.lowercased() else {
            return .failure(.unrecognized)
        }

        if host.contains("web.archive.org") { return .failure(.wayback) }
        guard allowedHosts.contains(host) || host.hasSuffix(".archive.org") else {
            return .failure(.notArchiveHost)
        }

        var segments = comps.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty else { return .failure(.unrecognized) }

        let first = segments.removeFirst()

        // archive.org/embed/{id}... → normalize to Item
        if first == "embed" {
            guard let id = segments.first, !id.isEmpty else { return .failure(.unrecognized) }
            return .success(.item(identifier: id, filename: nil))
        }

        guard first == "details" else { return .failure(.unrecognized) }
        guard let head = segments.first, !head.isEmpty else { return .failure(.unrecognized) }

        // Favorites: details/fav-{screenname}
        if head.hasPrefix("fav-") {
            let screenname = String(head.dropFirst(4))
            guard !screenname.isEmpty else { return .failure(.unrecognized) }
            return .success(.favorites(screenname: screenname))
        }

        // Public list: details/@{screenname}/lists/{listId}/{slug?}
        if head.hasPrefix("@") {
            let screenname = String(head.dropFirst())
            guard !screenname.isEmpty else { return .failure(.unrecognized) }
            guard segments.count >= 3, segments[1] == "lists" else { return .failure(.unrecognized) }
            let listId = segments[2]
            guard !listId.isEmpty else { return .failure(.unrecognized) }
            let slug = segments.count >= 4 && !segments[3].isEmpty ? segments[3] : nil
            return .success(.list(screenname: screenname, listId: listId, slug: slug))
        }

        // Item: details/{identifier}  or  details/{identifier}/{filename}
        let identifier = head
        if segments.count >= 2 {
            let filename = segments[1...].joined(separator: "/")
            return .success(.item(identifier: identifier, filename: filename))
        }
        return .success(.item(identifier: identifier, filename: nil))
    }
}
