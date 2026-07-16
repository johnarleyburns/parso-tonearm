import Foundation

public struct IAMember: Equatable {
    public let identifier: String
    public let title: String?
    public let mediatype: String?
}

/// FR-2.4 collection & favorites resolution via the scrape API.
/// NOTE (Invariant #1): `scrape?q=` is confined to this file. This is member
/// enumeration of a user-supplied collection, never a search query UI.
public struct CollectionResolver {
    public static let memberCap = 500
    private static let audioMediatypes: Set<String> = ["audio", "etree"]

    public struct Page: Decodable {
        struct Doc: Decodable {
            let identifier: String
            let title: StringOrArray?
            let mediatype: String?
        }
        let items: [Doc]?
        let cursor: String?
        let total: Int?
    }

    /// Returns members (capped) and the true total count.
    public func resolve(collection identifier: String) async throws -> (members: [IAMember], total: Int, capHit: Bool) {
        try await resolve(query: "collection:\(identifier)")
    }

    public func resolveFavorites(screenname: String) async throws -> (members: [IAMember], total: Int, capHit: Bool) {
        // Favorites are a fav-* collection.
        try await resolve(query: "collection:fav-\(screenname)")
    }

    private func resolve(query: String) async throws -> (members: [IAMember], total: Int, capHit: Bool) {
        var members: [IAMember] = []
        var cursor: String?
        var total = 0

        repeat {
            var comps = URLComponents(string: "https://archive.org/services/search/v1/scrape")!
            var qi = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "identifier,title,mediatype"),
                URLQueryItem(name: "count", value: "100")
            ]
            if let cursor { qi.append(URLQueryItem(name: "cursor", value: cursor)) }
            comps.queryItems = qi

            let data = try await IAClient.shared.data(from: comps.url!)
            let page = try JSONDecoder().decode(Page.self, from: data)
            total = page.total ?? total

            for doc in page.items ?? [] {
                guard let mt = doc.mediatype, Self.audioMediatypes.contains(mt) else { continue }
                members.append(IAMember(identifier: doc.identifier, title: doc.title?.first, mediatype: mt))
                if members.count >= Self.memberCap { break }
            }
            cursor = page.cursor
        } while cursor != nil && members.count < Self.memberCap

        let capHit = total > members.count && members.count >= Self.memberCap
        return (members, total, capHit)
    }
}
