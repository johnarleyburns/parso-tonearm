import Foundation

struct WebDAVServerPolicy {
    static func normalizeBaseURL(_ raw: String) throws -> URL {
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

    static func authorizationHeader(username: String, password: String) -> String {
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        return "Basic \(token)"
    }
}

struct WebDAVProvider: RemoteLibraryProvider {
    var baseURL: URL
    var username: String
    var password: String
    var session: URLSession = .shared

    var sourceKind: SourceKind { .webDAV }

    func browse(path rawPath: String) async throws -> [RemoteNode] {
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

    func resolve(node: RemoteNode) async throws -> ResolvedAsset {
        guard node.kind == .audio else { throw URLError(.badURL) }
        return ResolvedAsset(
            url: url(for: node.path),
            headers: ["Authorization": WebDAVServerPolicy.authorizationHeader(username: username, password: password)],
            supportsByteRanges: true,
            sizeBytes: node.sizeBytes
        )
    }

    func refresh() async throws {
        _ = try await browse(path: "")
    }

    private func url(for path: String) -> URL {
        guard !path.isEmpty else { return baseURL }
        return baseURL.appendingPathComponent(path)
    }
}
