import Foundation

/// FR-2.3 list resolution via a strategy chain. Lists are the least-stable IA
/// surface, so we try a JSON endpoint first, then fall back to a bounded,
/// deterministic HTML parse (no JS execution).
struct ListResolver {
    struct Strategy {
        let name: String
        let run: (String, String) async throws -> [IAMember]
    }

    var strategies: [Strategy] = [
        Strategy(name: "json-members", run: ListResolver.jsonMembers),
        Strategy(name: "html-scrape", run: ListResolver.htmlMembers)
    ]

    func resolve(screenname: String, listId: String) async throws -> [IAMember] {
        var lastError: Error = IANetworkError.badResponse
        for strategy in strategies {
            do {
                let members = try await strategy.run(screenname, listId)
                if !members.isEmpty { return members }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    // Strategy 1: the JSON members endpoint used by the web app.
    private static func jsonMembers(_ screenname: String, _ listId: String) async throws -> [IAMember] {
        struct MembersResponse: Decodable {
            struct Member: Decodable { let identifier: String?; let title: String? }
            let members: [Member]?
            let ids: [String]?
        }
        let path = "https://archive.org/services/lists/@\(screenname)/lists/\(listId)/members.json"
        guard let url = URL(string: path) else { return [] }
        let data = try await IAClient.shared.data(from: url)
        let decoded = try JSONDecoder().decode(MembersResponse.self, from: data)
        if let members = decoded.members {
            return members.compactMap { m in
                m.identifier.map { IAMember(identifier: $0, title: m.title, mediatype: nil) }
            }
        }
        if let ids = decoded.ids {
            return ids.map { IAMember(identifier: $0, title: nil, mediatype: nil) }
        }
        return []
    }

    // Strategy 2: bounded HTML parse for /details/{id} links.
    private static func htmlMembers(_ screenname: String, _ listId: String) async throws -> [IAMember] {
        let path = "https://archive.org/details/@\(screenname)/lists/\(listId)"
        guard let url = URL(string: path) else { return [] }
        let data = try await IAClient.shared.data(from: url)
        let html = String(decoding: data, as: UTF8.self)
        return extractDetailIdentifiers(from: html)
    }

    /// Deterministic extraction of unique /details/{identifier} member links.
    static func extractDetailIdentifiers(from html: String, limit: Int = 500) -> [IAMember] {
        var seen = Set<String>()
        var members: [IAMember] = []
        let pattern = #"/details/([A-Za-z0-9][A-Za-z0-9._-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match, let r = Range(match.range(at: 1), in: html) else { return }
            let id = String(html[r])
            // Exclude sub-paths (@user, fav-, lists) that are not plain items.
            if id.hasPrefix("@") || id.hasPrefix("fav-") || id == "lists" { return }
            if seen.insert(id).inserted {
                members.append(IAMember(identifier: id, title: nil, mediatype: nil))
                if members.count >= limit { stop.pointee = true }
            }
        }
        return members
    }
}
