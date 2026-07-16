import Foundation

public struct SubsonicServerPolicy {
    public static func normalizeBaseURL(_ raw: String) throws -> URL {
        try SubsonicAPI.normalizeBaseURL(raw)
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
        "subsonic:\(sourceID)"
    }
}

public struct SubsonicProvider: RemoteLibraryProvider {
    public var baseURL: URL
    public var username: String
    public var password: String
    public var session: URLSession = .shared
    public var format: SubsonicAPI.Format = .json

    public var sourceKind: SourceKind { .subsonic }

    public func browse(path rawPath: String) async throws -> [RemoteNode] {
        let path = try RemotePathPolicy.normalize(rawPath)
        let segments = path.segments
        switch segments.count {
        case 0:
            let artists = try await browseArtists()
            return artists.map { artist in
                RemoteNode(
                    id: "artist:\(artist.id)",
                    title: artist.name,
                    path: "artist/\(pathComponent(artist.id))",
                    kind: .directory
                )
            }

        case 2 where segments[0] == "artist":
            let artistID = segments[1]
            let data = try await data(for: .getArtist(id: artistID))
            let artist = try SubsonicAPI.decodeArtist(data, format: format)
            return artist.albums.map { album in
                RemoteNode(
                    id: "album:\(album.id)",
                    title: album.name,
                    path: "album/\(pathComponent(album.id))",
                    kind: .collection
                )
            }

        case 2 where segments[0] == "album":
            let albumID = segments[1]
            let data = try await data(for: .getAlbum(id: albumID))
            let album = try SubsonicAPI.decodeAlbum(data, format: format)
            return album.songs.enumerated().map { index, song in
                RemoteNode(
                    id: "song:\(song.id)",
                    title: song.title,
                    path: "song/\(pathComponent(song.id))",
                    kind: .audio,
                    sizeBytes: song.size,
                    durationSec: song.duration
                )
            }

        default:
            throw URLError(.badURL)
        }
    }

    public func resolve(node: RemoteNode) async throws -> ResolvedAsset {
        guard node.kind == .audio,
              let songID = node.path.split(separator: "/").dropFirst().first.map(String.init) else {
            throw URLError(.badURL)
        }
        let url = try SubsonicAPI.url(
            baseURL: baseURL,
            endpoint: .stream(id: songID.removingPercentEncoding ?? songID),
            auth: auth(),
            format: format
        )
        return ResolvedAsset(url: url, headers: [:], supportsByteRanges: true, sizeBytes: node.sizeBytes)
    }

    public func refresh() async throws {
        let data = try await data(for: .ping)
        try SubsonicAPI.decodePing(data, format: format)
    }

    public static func from(source: Source,
                     credentialStore: CredentialStore = CredentialStore()) throws -> SubsonicProvider {
        guard source.kind == .subsonic,
              let sourceID = source.id,
              let rawURL = source.originalURL,
              let username = source.iaIdentifier,
              let passwordData = try credentialStore.read(
                account: SubsonicServerPolicy.credentialAccount(sourceID: sourceID)
              ),
              let password = String(data: passwordData, encoding: .utf8) else {
            throw URLError(.userAuthenticationRequired)
        }
        return SubsonicProvider(
            baseURL: try SubsonicAPI.normalizeBaseURL(rawURL),
            username: username,
            password: password
        )
    }

    private func data(for endpoint: SubsonicAPI.Endpoint) async throws -> Data {
        let url = try SubsonicAPI.url(baseURL: baseURL, endpoint: endpoint, auth: auth(), format: format)
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private func browseArtists() async throws -> [SubsonicArtist] {
        do {
            let data = try await data(for: .getArtists)
            return try SubsonicAPI.decodeArtists(data, format: format)
        } catch {
            let data = try await data(for: .getIndexes)
            return try SubsonicAPI.decodeArtists(data, format: format)
        }
    }

    private func auth() -> SubsonicAPI.Auth {
        SubsonicAPI.Auth(username: username, password: password, salt: Self.randomSalt())
    }

    private static func randomSalt() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).description
    }

    private func pathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/\\"))
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
