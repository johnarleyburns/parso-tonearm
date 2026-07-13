import Foundation

enum IANetworkError: Error, LocalizedError {
    case disallowedHost(String)
    case http(Int)
    case notFound
    case videoItem
    case badResponse

    var errorDescription: String? {
        switch self {
        case .disallowedHost(let h): return "Refusing to contact non-archive.org host: \(h)"
        case .http(let code): return "archive.org returned HTTP \(code)"
        case .notFound: return "Item not found"
        case .videoItem: return "This item is video"
        case .badResponse: return "Unexpected response from archive.org"
        }
    }
}

/// Shared archive.org client. Enforces host allowlist (Invariant #3) and etiquette (FR-2.6).
actor IAClient {
    static let shared = IAClient()

    private let session: URLSession
    private let userAgent: String

    init() {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = [:]
        session = URLSession(configuration: config)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
        userAgent = "Tonearm/\(version) (parso.guru)"
    }

    static func isAllowedHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "archive.org" || h == "www.archive.org" || h.hasSuffix(".archive.org")
    }

    func data(from url: URL, attempt: Int = 0) async throws -> Data {
        guard let host = url.host, IAClient.isAllowedHost(host) else {
            throw IANetworkError.disallowedHost(url.host ?? "unknown")
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IANetworkError.badResponse }

        switch http.statusCode {
        case 200...299:
            return data
        case 404:
            throw IANetworkError.notFound
        case 429, 500...599:
            if attempt < 3 {
                let backoff = UInt64(pow(2.0, Double(attempt)) * 500_000_000)
                try await Task.sleep(nanoseconds: backoff)
                return try await self.data(from: url, attempt: attempt + 1)
            }
            throw IANetworkError.http(http.statusCode)
        default:
            throw IANetworkError.http(http.statusCode)
        }
    }
}
