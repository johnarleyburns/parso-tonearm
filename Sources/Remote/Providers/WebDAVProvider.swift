import Foundation

public struct WebDAVServerPolicy {
    public static func normalizeBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw URLError(.badURL) }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            throw URLError(.badURL)
        }
        return url
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
        "webdav:\(sourceID)"
    }

    public static func authorizationHeader(username: String, password: String) -> String {
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }
}

public struct WebDAVCredential: Codable, Equatable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

public struct WebDAVProvider: RemoteLibraryProvider {
    public var baseURL: URL
    public var username: String
    public var password: String
    public var session: URLSession = .shared

    public var sourceKind: SourceKind { .webDAV }

    public init(baseURL: URL,
                username: String,
                password: String,
                session: URLSession = .shared) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
        self.session = session
    }

    public func browse(path rawPath: String) async throws -> [RemoteNode] {
        _ = try RemotePathPolicy.normalize(rawPath)
        let url = url(for: rawPath)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue(WebDAVServerPolicy.authorizationHeader(username: username, password: password),
                         forHTTPHeaderField: "Authorization")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <d:propfind xmlns:d="DAV:">
          <d:prop>
            <d:displayname/>
            <d:resourcetype/>
            <d:getcontentlength/>
            <d:getcontenttype/>
            <d:getlastmodified/>
          </d:prop>
        </d:propfind>
        """.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let listing = try WebDAVParser.parse(data, basePath: url.path)
        return listing.playableEntries.map { entry in
            RemoteNode(
                id: entry.href,
                title: entry.name,
                path: entry.relativePath,
                kind: entry.kind == .directory ? .directory : .audio,
                sizeBytes: entry.contentLength
            )
        }
    }

    public func resolve(node: RemoteNode) async throws -> ResolvedAsset {
        guard node.kind == .audio else { throw URLError(.badURL) }
        return ResolvedAsset(
            url: url(for: node.path),
            headers: ["Authorization": WebDAVServerPolicy.authorizationHeader(username: username, password: password)],
            supportsByteRanges: true,
            sizeBytes: node.sizeBytes
        )
    }

    public func refresh() async throws {
        _ = try await browse(path: "")
    }

    public static func from(source: Source,
                     credentialStore: CredentialStore = CredentialStore()) throws -> WebDAVProvider {
        guard source.kind == .webDAV,
              let sourceID = source.id,
              let rawURL = source.originalURL,
              let data = try credentialStore.read(
                account: WebDAVServerPolicy.credentialAccount(sourceID: sourceID)
              ) else {
            throw URLError(.userAuthenticationRequired)
        }
        let credential = try JSONDecoder().decode(WebDAVCredential.self, from: data)
        return WebDAVProvider(
            baseURL: try WebDAVServerPolicy.normalizeBaseURL(rawURL),
            username: credential.username,
            password: credential.password
        )
    }

    private func url(for path: String) -> URL {
        guard !path.isEmpty else { return baseURL }
        return baseURL.appendingPathComponent(path)
    }
}
