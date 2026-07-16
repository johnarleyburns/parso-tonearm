import Foundation

public struct ListResolver {
    public struct Strategy {
        let name: String
        let run: (String, String) async throws -> [IAMember]
    }

    public var strategies: [Strategy] = [
        Strategy(name: "users-list", run: ListResolver.usersListAPI),
        Strategy(name: "json-members", run: ListResolver.jsonMembers),
        Strategy(name: "html-scrape", run: ListResolver.htmlMembers)
    ]

    public func resolve(screenname: String, listId: String) async throws -> [IAMember] {
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

    // Strategy 1: /services/users/@screenname/lists/listId (confirmed working).
    private static func usersListAPI(_ screenname: String, _ listId: String) async throws -> [IAMember] {
        let path = "https://archive.org/services/users/@\(screenname)/lists/\(listId)"
        guard let url = URL(string: path) else { return [] }
        let data = try await IAClient.shared.data(from: url)

        struct ListResponse: Decodable {
            struct Value: Decodable {
                struct Member: Decodable {
                    let identifier: String
                }
                let members: [Member]?
            }
            let value: Value?
        }

        guard let decoded = try? JSONDecoder().decode(ListResponse.self, from: data),
              let members = decoded.value?.members, !members.isEmpty else {
            return try parseMembers(from: data)
        }

        return members.map { IAMember(identifier: $0.identifier, title: nil, mediatype: nil) }
    }

    // Strategy 2: legacy JSON API (may 404, kept as fallback).
    private static func jsonMembers(_ screenname: String, _ listId: String) async throws -> [IAMember] {
        let path = "https://archive.org/services/lists/@\(screenname)/lists/\(listId)/members.json"
        guard let url = URL(string: path) else { return [] }
        let data = try await IAClient.shared.data(from: url)
        return parseMembers(from: data)
    }

    /// Parses the several JSON shapes archive.org uses for list members.
    /// Deterministic and pure so it can be unit-tested without the network.
    public static func parseMembers(from data: Data) -> [IAMember] {
        struct MembersResponse: Decodable {
            struct Member: Decodable { let identifier: String?; let title: String? }
            let members: [Member]?
            let ids: [String]?
        }
        if let decoded = try? JSONDecoder().decode(MembersResponse.self, from: data) {
            if let members = decoded.members, !members.isEmpty {
                let mapped = members.compactMap { m in
                    m.identifier.map { IAMember(identifier: $0, title: m.title, mediatype: nil) }
                }
                if !mapped.isEmpty { return mapped }
            }
            if let ids = decoded.ids, !ids.isEmpty {
                return ids.map { IAMember(identifier: $0, title: nil, mediatype: nil) }
            }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let membersDict = obj["members"] as? [String: Any] {
                let members = membersDict.keys.sorted().map { key -> IAMember in
                    let title = (membersDict[key] as? [String: Any])?["title"] as? String
                    return IAMember(identifier: key, title: title, mediatype: nil)
                }
                if !members.isEmpty { return members }
            }
            if let value = obj["value"] as? [String: Any],
               let membersList = value["members"] as? [[String: Any]] {
                let members = membersList.compactMap { m -> IAMember? in
                    guard let id = m["identifier"] as? String else { return nil }
                    return IAMember(identifier: id, title: nil, mediatype: nil)
                }
                if !members.isEmpty { return members }
            }
        }
        return []
    }

    // Strategy 3: bounded HTML parse for /details/{id} links.
    private static func htmlMembers(_ screenname: String, _ listId: String) async throws -> [IAMember] {
        let path = "https://archive.org/details/@\(screenname)/lists/\(listId)"
        guard let url = URL(string: path) else { return [] }
        let data = try await IAClient.shared.data(from: url)
        let html = String(decoding: data, as: UTF8.self)
        return extractDetailIdentifiers(from: html)
    }

    /// Deterministic extraction of unique /details/{identifier} member links.
    public static func extractDetailIdentifiers(from html: String, limit: Int = 500) -> [IAMember] {
        var seen = Set<String>()
        var members: [IAMember] = []
        let pattern = #"/details/([A-Za-z0-9][A-Za-z0-9._-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match, let r = Range(match.range(at: 1), in: html) else { return }
            let id = String(html[r])
            if id.hasPrefix("@") || id.hasPrefix("fav-") || id == "lists" { return }
            if seen.insert(id).inserted {
                members.append(IAMember(identifier: id, title: nil, mediatype: nil))
                if members.count >= limit { stop.pointee = true }
            }
        }
        return members
    }
}
