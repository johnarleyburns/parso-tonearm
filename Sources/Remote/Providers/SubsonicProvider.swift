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

    public init(baseURL: URL,
                username: String,
                password: String,
                session: URLSession = .shared,
                format: SubsonicAPI.Format = .json) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session
        self.format = format
    }

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
                let artwork = album.coverArt.map(subsonicArtwork(id:))
                let metadata = artwork.map { RemoteTrackMetadata(artwork: $0) }
                return RemoteNode(
                    id: "album:\(album.id)",
                    title: album.name,
                    path: "album/\(pathComponent(album.id))",
                    kind: .collection,
                    metadata: metadata
                )
            }

        case 2 where segments[0] == "album":
            let albumID = segments[1]
            let data = try await data(for: .getAlbum(id: albumID))
            let album = try SubsonicAPI.decodeAlbum(data, format: format)
            return album.songs.enumerated().map { index, song in
                let metadata = metadata(for: song, album: album, fallbackTrackNumber: index + 1)
                return RemoteNode(
                    id: "song:\(song.id)",
                    title: song.title,
                    path: "song/\(pathComponent(song.id))",
                    kind: .audio,
                    sizeBytes: song.size,
                    durationSec: song.duration,
                    metadata: metadata
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
        return ResolvedAsset(
            url: url,
            headers: [:],
            supportsByteRanges: true,
            sizeBytes: node.sizeBytes,
            metadata: node.metadata
        )
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

    private func metadata(for song: SubsonicSong,
                          album: SubsonicAlbum,
                          fallbackTrackNumber: Int) -> RemoteTrackMetadata {
        let coverArt = song.coverArt ?? album.coverArt
        return RemoteTrackMetadata(
            title: song.title,
            artist: song.artist ?? album.artist,
            album: song.album ?? album.name,
            albumArtist: album.artist,
            trackNumber: song.track ?? fallbackTrackNumber,
            discNumber: song.discNumber,
            durationSec: song.duration,
            codec: codec(suffix: song.suffix, contentType: song.contentType),
            sampleRate: song.samplingRate,
            bitRateKbps: song.bitRate,
            genre: album.genre,
            artwork: coverArt.map(subsonicArtwork(id:))
        )
    }

    private func subsonicArtwork(id coverArtID: String) -> RemoteArtwork {
        let url = try? SubsonicAPI.url(
            baseURL: baseURL,
            endpoint: .coverArt(id: coverArtID),
            auth: auth(),
            format: format
        )
        return RemoteArtwork(
            id: stableArtworkID(provider: "subsonic", remoteID: coverArtID),
            url: url,
            headers: [:]
        )
    }

    private func codec(suffix: String?, contentType: String?) -> String? {
        if let suffix, !suffix.isEmpty { return suffix.uppercased() }
        guard let contentType else { return nil }
        if contentType.localizedCaseInsensitiveContains("flac") { return "FLAC" }
        if contentType.localizedCaseInsensitiveContains("mpeg") { return "MP3" }
        if contentType.localizedCaseInsensitiveContains("aac") { return "AAC" }
        if contentType.localizedCaseInsensitiveContains("wav") { return "WAV" }
        return contentType.split(separator: "/").last.map { String($0).uppercased() }
    }

    private func stableArtworkID(provider: String, remoteID: String) -> String {
        let host = baseURL.host ?? baseURL.absoluteString
        return "\(provider):\(host):\(remoteID)"
    }

    private static func randomSalt() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).description
    }

    private func pathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/\\"))
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    public func gatherStats() async throws -> RemoteLibraryStats {
        let artists = try await browseArtists()
        var albumCount = 0
        var trackCount = 0
        var totalSize: Int64 = 0

        for artist in artists {
            let artistData = try await data(for: .getArtist(id: artist.id))
            let detail = try SubsonicAPI.decodeArtist(artistData, format: format)
            albumCount += detail.albums.count

            for albumSummary in detail.albums {
                let albumData = try await data(for: .getAlbum(id: albumSummary.id))
                let album = try SubsonicAPI.decodeAlbum(albumData, format: format)
                trackCount += album.songs.count
                for song in album.songs {
                    if let size = song.size { totalSize += size }
                }
            }
        }

        return RemoteLibraryStats(
            artistCount: artists.count,
            albumCount: albumCount,
            trackCount: trackCount,
            totalBytes: totalSize > 0 ? totalSize : nil
        )
    }
}
