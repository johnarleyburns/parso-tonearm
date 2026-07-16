import Foundation

public struct CloudDriveServerPolicy {
    public static func credentialAccount(sourceID: Int64, provider: CloudDriveAPI.Provider) -> String {
        "\(provider.rawValue):\(sourceID)"
    }

    public static func displayName(provider: CloudDriveAPI.Provider) -> String {
        switch provider {
        case .dropbox: return "Dropbox"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .pCloud: return "pCloud"
        }
    }
}

public struct CloudDriveProvider: RemoteLibraryProvider {
    public var provider: CloudDriveAPI.Provider
    public var accessToken: String
    public var session: URLSession = .shared

    public var sourceKind: SourceKind { provider.sourceKind }

    public func browse(path rawPath: String) async throws -> [RemoteNode] {
        let path = try RemotePathPolicy.normalize(rawPath)
        let containerID: String?
        switch path.segments.count {
        case 0:
            containerID = nil
        case 2 where path.segments[0] == "folder":
            containerID = path.segments[1]
        default:
            throw URLError(.badURL)
        }

        let request = try CloudDriveAPI.request(
            provider: provider,
            endpoint: .list(containerID: containerID),
            accessToken: accessToken
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let page = RemotePathPolicy.cappedPage(try CloudDriveAPI.decodeListing(provider: provider, data: data))
        return page.items.compactMap(remoteNode)
    }

    public func resolve(node: RemoteNode) async throws -> ResolvedAsset {
        guard node.kind == .audio,
              let fileID = node.path.split(separator: "/").dropFirst().first.map(String.init) else {
            throw URLError(.badURL)
        }
        let decodedID = fileID.removingPercentEncoding ?? fileID
        let request = try CloudDriveAPI.request(
            provider: provider,
            endpoint: .resolveFile(id: decodedID, path: nil),
            accessToken: accessToken
        )

        switch provider {
        case .googleDrive, .oneDrive:
            guard let url = request.url else { throw URLError(.badURL) }
            return ResolvedAsset(
                url: url,
                headers: authHeaders(),
                supportsByteRanges: true,
                sizeBytes: node.sizeBytes
            )
        case .dropbox, .pCloud:
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return try CloudDriveAPI.decodeResolvedAsset(
                provider: provider,
                data: data,
                fallbackSize: node.sizeBytes
            )
        }
    }

    public func refresh() async throws {
        _ = try await browse(path: "")
    }

    public static func from(source: Source,
                     credentialStore: CredentialStore = CredentialStore()) throws -> CloudDriveProvider {
        guard let sourceID = source.id,
              let provider = CloudDriveAPI.Provider(sourceKind: source.kind),
              let tokenData = try credentialStore.read(
                account: CloudDriveServerPolicy.credentialAccount(sourceID: sourceID, provider: provider)
              ),
              let token = String(data: tokenData, encoding: .utf8) else {
            throw URLError(.userAuthenticationRequired)
        }
        return CloudDriveProvider(provider: provider, accessToken: token)
    }

    private func remoteNode(from item: CloudDriveItem) -> RemoteNode? {
        switch item.kind {
        case .folder:
            return RemoteNode(
                id: "folder:\(item.id)",
                title: item.name,
                path: "folder/\(pathComponent(item.id))",
                kind: .directory
            )
        case .file:
            guard item.isAudio else { return nil }
            return RemoteNode(
                id: "file:\(item.id)",
                title: item.name,
                path: "file/\(pathComponent(item.id))",
                kind: .audio,
                sizeBytes: item.sizeBytes
            )
        }
    }

    private func authHeaders() -> [String: String] {
        ["Authorization": "Bearer \(accessToken)"]
    }

    private func pathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/\\"))
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
