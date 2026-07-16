import Foundation

public struct JellyfinServerPolicy {
    public static func normalizeBaseURL(_ raw: String) throws -> URL {
        try JellyfinAPI.normalizeBaseURL(raw)
    }

    public static func canSubmit(url: String, username: String, password: String) -> Bool {
        (try? normalizeBaseURL(url)) != nil
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
    }

    public static func displayName(baseURL: URL) -> String {
        baseURL.host ?? baseURL.absoluteString
    }

    public static func credentialAccount(sourceID: Int64) -> String {
        "jellyfin:\(sourceID)"
    }
}

public struct JellyfinProvider: RemoteLibraryProvider {
    public var baseURL: URL
    public var userID: String
    public var accessToken: String
    public var session: URLSession = .shared
    public var client: JellyfinAPI.Client = JellyfinAPI.defaultClient

    public var sourceKind: SourceKind { .jellyfin }

    public func browse(path rawPath: String) async throws -> [RemoteNode] {
        let path = try RemotePathPolicy.normalize(rawPath)
        switch path.segments.count {
        case 0:
            let page = try await itemPage(for: .albumArtists(userID: userID))
            return page.items.filter { $0.type == .artist }.map { item in
                RemoteNode(
                    id: "artist:\(item.id)",
                    title: item.name,
                    path: "artist/\(pathComponent(item.id))",
                    kind: .directory
                )
            }

        case 2 where path.segments[0] == "artist":
            let page = try await itemPage(for: .albums(userID: userID, artistID: path.segments[1]))
            return page.items.filter { $0.type == .album }.map { item in
                RemoteNode(
                    id: "album:\(item.id)",
                    title: item.name,
                    path: "album/\(pathComponent(item.id))",
                    kind: .collection,
                    durationSec: item.durationSec
                )
            }

        case 2 where path.segments[0] == "album":
            let page = try await itemPage(for: .albumSongs(userID: userID, albumID: path.segments[1]))
            return page.items.filter { $0.type == .audio }.map { item in
                RemoteNode(
                    id: "track:\(item.id)",
                    title: item.name,
                    path: "track/\(pathComponent(item.id))",
                    kind: .audio,
                    sizeBytes: item.sizeBytes,
                    durationSec: item.durationSec
                )
            }

        default:
            throw URLError(.badURL)
        }
    }

    public func resolve(node: RemoteNode) async throws -> ResolvedAsset {
        guard node.kind == .audio,
              let itemID = node.path.split(separator: "/").dropFirst().first.map(String.init) else {
            throw URLError(.badURL)
        }
        let request = try JellyfinAPI.request(
            baseURL: baseURL,
            endpoint: .stream(itemID: itemID.removingPercentEncoding ?? itemID),
            token: accessToken,
            client: client
        )
        return ResolvedAsset(
            url: try requestURL(request),
            headers: authHeaders(),
            supportsByteRanges: true,
            sizeBytes: node.sizeBytes
        )
    }

    public func refresh() async throws {
        _ = try await itemPage(for: .albumArtists(userID: userID))
    }

    public static func from(source: Source,
                     credentialStore: CredentialStore = CredentialStore()) throws -> JellyfinProvider {
        guard source.kind == .jellyfin,
              let sourceID = source.id,
              let rawURL = source.originalURL,
              let userID = source.iaIdentifier,
              let tokenData = try credentialStore.read(
                account: JellyfinServerPolicy.credentialAccount(sourceID: sourceID)
              ),
              let token = String(data: tokenData, encoding: .utf8) else {
            throw URLError(.userAuthenticationRequired)
        }
        return JellyfinProvider(
            baseURL: try JellyfinAPI.normalizeBaseURL(rawURL),
            userID: userID,
            accessToken: token
        )
    }

    private func itemPage(for endpoint: JellyfinAPI.Endpoint) async throws -> JellyfinItemPage {
        let request = try JellyfinAPI.request(
            baseURL: baseURL,
            endpoint: endpoint,
            token: accessToken,
            client: client
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JellyfinAPI.decodeItems(data)
    }

    private func authHeaders() -> [String: String] {
        [
            "X-Emby-Authorization": JellyfinAPI.authorizationHeader(client: client, token: accessToken),
            "X-Emby-Token": accessToken,
        ]
    }

    private func requestURL(_ request: URLRequest) throws -> URL {
        guard let url = request.url else { throw URLError(.badURL) }
        return url
    }

    private func pathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/\\"))
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
