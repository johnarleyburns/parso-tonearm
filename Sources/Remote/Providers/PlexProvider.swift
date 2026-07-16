import Foundation

public struct PlexServerPolicy {
    public static func normalizeBaseURL(_ raw: String) throws -> URL {
        try PlexAPI.normalizeBaseURL(raw)
    }

    public static func canSubmit(url: String, token: String) -> Bool {
        (try? normalizeBaseURL(url)) != nil
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func displayName(baseURL: URL) -> String {
        baseURL.host ?? baseURL.absoluteString
    }

    public static func credentialAccount(sourceID: Int64) -> String {
        "plex:\(sourceID)"
    }
}

public struct PlexProvider: RemoteLibraryProvider {
    public var baseURL: URL
    public var token: String
    public var session: URLSession = .shared
    public var client: PlexAPI.Client = PlexAPI.defaultClient

    public var sourceKind: SourceKind { .plex }

    public func browse(path rawPath: String) async throws -> [RemoteNode] {
        let path = try RemotePathPolicy.normalize(rawPath)
        switch path.segments.count {
        case 0:
            let sections = try await plexItems(for: .sections)
            return sections.filter(\.isMusicSection).map { item in
                RemoteNode(
                    id: "section:\(item.key ?? "")",
                    title: item.title,
                    path: "section/\(pathComponent(item.key ?? ""))",
                    kind: .directory
                )
            }

        case 2 where path.segments[0] == "section":
            let sectionKey = path.segments[1]
            let artists = try await plexItems(for: .artists(sectionKey: sectionKey))
            return artists.filter { $0.kind == .artist }.compactMap { item in
                guard let ratingKey = item.ratingKey else { return nil }
                return RemoteNode(
                    id: "artist:\(ratingKey)",
                    title: item.title,
                    path: "artist/\(pathComponent(ratingKey))",
                    kind: .directory
                )
            }

        case 2 where path.segments[0] == "artist":
            let albums = try await plexItems(for: .children(ratingKey: path.segments[1]))
            return albums.filter { $0.kind == .album }.compactMap { item in
                guard let ratingKey = item.ratingKey else { return nil }
                return RemoteNode(
                    id: "album:\(ratingKey)",
                    title: item.title,
                    path: "album/\(pathComponent(ratingKey))",
                    kind: .collection,
                    durationSec: item.durationSec
                )
            }

        case 2 where path.segments[0] == "album":
            let tracks = try await plexItems(for: .children(ratingKey: path.segments[1]))
            return tracks.filter { $0.kind == .track }.compactMap { item in
                guard let ratingKey = item.ratingKey else { return nil }
                return RemoteNode(
                    id: "track:\(ratingKey)",
                    title: item.title,
                    path: "track/\(pathComponent(ratingKey))",
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
              let ratingKey = node.path.split(separator: "/").dropFirst().first.map(String.init) else {
            throw URLError(.badURL)
        }
        let data = try await data(for: .metadata(ratingKey: ratingKey.removingPercentEncoding ?? ratingKey))
        let track = try PlexAPI.decodeTrackMetadata(data)
        guard let partKey = track.partKey else { throw URLError(.badURL) }
        return ResolvedAsset(
            url: url(forPlexKey: partKey),
            headers: authHeaders(),
            supportsByteRanges: true,
            sizeBytes: track.sizeBytes ?? node.sizeBytes
        )
    }

    public func refresh() async throws {
        _ = try await plexItems(for: .sections)
    }

    public static func from(source: Source,
                     credentialStore: CredentialStore = CredentialStore()) throws -> PlexProvider {
        guard source.kind == .plex,
              let sourceID = source.id,
              let rawURL = source.originalURL,
              let tokenData = try credentialStore.read(
                account: PlexServerPolicy.credentialAccount(sourceID: sourceID)
              ),
              let token = String(data: tokenData, encoding: .utf8) else {
            throw URLError(.userAuthenticationRequired)
        }
        return PlexProvider(
            baseURL: try PlexAPI.normalizeBaseURL(rawURL),
            token: token
        )
    }

    private func plexItems(for endpoint: PlexAPI.Endpoint) async throws -> [PlexItem] {
        let data = try await data(for: endpoint)
        switch endpoint {
        case .sections:
            return try PlexAPI.decodeSections(data)
        case .artists, .children, .metadata:
            return try PlexAPI.decodeItems(data)
        }
    }

    private func data(for endpoint: PlexAPI.Endpoint) async throws -> Data {
        let request = try PlexAPI.request(baseURL: baseURL, endpoint: endpoint, token: token, client: client)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func authHeaders() -> [String: String] {
        ["X-Plex-Token": token]
    }

    private func url(forPlexKey key: String) -> URL {
        if let absolute = URL(string: key), absolute.scheme != nil {
            return absolute
        }
        return baseURL.appendingPathComponent(key.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func pathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/\\"))
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
