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

public struct CloudDriveAccess: Equatable {
    public var accessToken: String
    public var environment: CloudDriveAPI.Environment

    public init(accessToken: String, environment: CloudDriveAPI.Environment) {
        self.accessToken = accessToken
        self.environment = environment
    }
}

public protocol CloudDriveAccessProviding {
    func access() async throws -> CloudDriveAccess
}

public struct StaticCloudDriveAccessProvider: CloudDriveAccessProviding {
    public var accessToken: String
    public var environment: CloudDriveAPI.Environment

    public init(accessToken: String, environment: CloudDriveAPI.Environment) {
        self.accessToken = accessToken
        self.environment = environment
    }

    public func access() async throws -> CloudDriveAccess {
        CloudDriveAccess(accessToken: accessToken, environment: environment)
    }
}

public actor OAuthCloudDriveAccessProvider: CloudDriveAccessProviding {
    private var token: OAuthToken
    private let sourceID: Int64?
    private let tokenStore: OAuthTokenStore
    private let tokenClient: OAuthTokenClient

    public init(token: OAuthToken,
                sourceID: Int64? = nil,
                tokenStore: OAuthTokenStore = OAuthTokenStore(),
                tokenClient: OAuthTokenClient = OAuthTokenClient()) {
        self.token = token
        self.sourceID = sourceID
        self.tokenStore = tokenStore
        self.tokenClient = tokenClient
    }

    public func access() async throws -> CloudDriveAccess {
        if token.isExpired {
            token = try await tokenClient.refresh(token)
            if let sourceID {
                try tokenStore.save(token, sourceID: sourceID)
            }
        }
        return CloudDriveAccess(accessToken: token.accessToken, environment: token.apiEnvironment)
    }
}

public struct CloudDriveProvider: RemoteLibraryProvider {
    public var provider: CloudDriveAPI.Provider
    public var accessProvider: any CloudDriveAccessProviding
    public var session: URLSession = .shared

    public var sourceKind: SourceKind { provider.sourceKind }

    public init(provider: CloudDriveAPI.Provider,
                accessToken: String,
                session: URLSession = .shared,
                environment: CloudDriveAPI.Environment? = nil) {
        self.init(
            provider: provider,
            accessProvider: StaticCloudDriveAccessProvider(
                accessToken: accessToken,
                environment: environment ?? .production(provider: provider)
            ),
            session: session
        )
    }

    public init(provider: CloudDriveAPI.Provider,
                accessProvider: any CloudDriveAccessProviding,
                session: URLSession = .shared) {
        self.provider = provider
        self.accessProvider = accessProvider
        self.session = session
    }

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

        let access = try await accessProvider.access()
        let request = try CloudDriveAPI.request(
            provider: provider,
            endpoint: .list(containerID: containerID),
            accessToken: access.accessToken,
            environment: access.environment
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
        let access = try await accessProvider.access()
        let request = try CloudDriveAPI.request(
            provider: provider,
            endpoint: .resolveFile(id: decodedID, path: nil),
            accessToken: access.accessToken,
            environment: access.environment
        )

        switch provider {
        case .googleDrive, .oneDrive:
            guard let url = request.url else { throw URLError(.badURL) }
            return ResolvedAsset(
                url: url,
                headers: authHeaders(access.accessToken),
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
              ) else {
            throw URLError(.userAuthenticationRequired)
        }
        if let token = try? JSONDecoder().decode(OAuthToken.self, from: tokenData) {
            return CloudDriveProvider(
                provider: provider,
                accessProvider: OAuthCloudDriveAccessProvider(
                    token: token,
                    sourceID: sourceID,
                    tokenStore: OAuthTokenStore(credentialStore: credentialStore)
                )
            )
        }
        guard let legacyToken = String(data: tokenData, encoding: .utf8) else {
            throw URLError(.userAuthenticationRequired)
        }
        return CloudDriveProvider(provider: provider, accessToken: legacyToken)
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

    private func authHeaders(_ accessToken: String) -> [String: String] {
        ["Authorization": "Bearer \(accessToken)"]
    }

    private func pathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/\\"))
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }
}
