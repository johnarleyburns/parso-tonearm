import CryptoKit
import Foundation
import Security

public enum OAuthError: LocalizedError, Equatable {
    case invalidClientConfiguration(String)
    case invalidRedirect
    case stateMismatch
    case missingAuthorizationCode
    case missingTokenField(String)
    case refreshRequired
    case unsupportedProvider

    public var errorDescription: String? {
        switch self {
        case .invalidClientConfiguration(let provider):
            return "OAuth is not configured for \(provider)."
        case .invalidRedirect:
            return "The sign-in redirect was invalid."
        case .stateMismatch:
            return "The sign-in response did not match this session."
        case .missingAuthorizationCode:
            return "The sign-in response did not include an authorization code."
        case .missingTokenField(let field):
            return "The token response was missing \(field)."
        case .refreshRequired:
            return "Reconnect this library to continue."
        case .unsupportedProvider:
            return "This provider does not support OAuth sign-in."
        }
    }
}

public struct OAuthPKCE: Equatable {
    public var verifier: String
    public var challenge: String
    public var method: String

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
        self.method = "S256"
    }

    public static func randomVerifier(byteCount: Int = 48) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

public struct OAuthProviderConfig: Equatable, Codable {
    public var provider: CloudDriveAPI.Provider
    public var clientID: String
    public var clientSecret: String?
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var redirectURI: URL
    public var scopes: [String]
    public var apiEnvironment: CloudDriveAPI.Environment
    public var additionalAuthorizationParameters: [String: String]

    public init(provider: CloudDriveAPI.Provider,
                clientID: String,
                clientSecret: String? = nil,
                authorizationEndpoint: URL,
                tokenEndpoint: URL,
                redirectURI: URL,
                scopes: [String],
                apiEnvironment: CloudDriveAPI.Environment,
                additionalAuthorizationParameters: [String: String] = [:]) {
        self.provider = provider
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.apiEnvironment = apiEnvironment
        self.additionalAuthorizationParameters = additionalAuthorizationParameters
    }

    public static func cloudDrive(provider: CloudDriveAPI.Provider,
                                  clientID: String,
                                  clientSecret: String? = nil,
                                  redirectURI: URL) throws -> OAuthProviderConfig {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            throw OAuthError.invalidClientConfiguration(provider.rawValue)
        }
        switch provider {
        case .dropbox:
            return OAuthProviderConfig(
                provider: provider,
                clientID: trimmedClientID,
                authorizationEndpoint: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
                tokenEndpoint: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                redirectURI: redirectURI,
                scopes: ["files.metadata.read", "files.content.read"],
                apiEnvironment: .production(provider: provider),
                additionalAuthorizationParameters: ["token_access_type": "offline"]
            )
        case .googleDrive:
            return OAuthProviderConfig(
                provider: provider,
                clientID: trimmedClientID,
                authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                redirectURI: redirectURI,
                scopes: ["https://www.googleapis.com/auth/drive.readonly"],
                apiEnvironment: .production(provider: provider),
                additionalAuthorizationParameters: ["access_type": "offline", "prompt": "consent"]
            )
        case .oneDrive:
            return OAuthProviderConfig(
                provider: provider,
                clientID: trimmedClientID,
                authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                redirectURI: redirectURI,
                scopes: ["offline_access", "Files.Read"],
                apiEnvironment: .production(provider: provider)
            )
        case .pCloud:
            return OAuthProviderConfig(
                provider: provider,
                clientID: trimmedClientID,
                clientSecret: clientSecret,
                authorizationEndpoint: URL(string: "https://my.pcloud.com/oauth2/authorize")!,
                tokenEndpoint: URL(string: "https://api.pcloud.com/oauth2_token")!,
                redirectURI: redirectURI,
                scopes: [],
                apiEnvironment: .production(provider: provider)
            )
        }
    }

    public func authorizationURL(state: String, pkce: OAuthPKCE) throws -> URL {
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidClientConfiguration(provider.rawValue)
        }
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
        ]
        if !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        items.append(contentsOf: additionalAuthorizationParameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = (components.queryItems ?? []) + items
        guard let url = components.url else {
            throw OAuthError.invalidClientConfiguration(provider.rawValue)
        }
        return url
    }

    public func tokenExchangeRequest(code: String, pkce: OAuthPKCE) throws -> URLRequest {
        try formRequest(parameters: [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": pkce.verifier,
        ])
    }

    public func refreshRequest(refreshToken: String) throws -> URLRequest {
        try formRequest(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
        ])
    }

    private func formRequest(parameters: [String: String?]) throws -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded(parameters.compactMapValues { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        })
        return request
    }
}

public struct OAuthAuthorizationSession: Equatable {
    public var config: OAuthProviderConfig
    public var state: String
    public var pkce: OAuthPKCE
    public var authorizationURL: URL

    public init(config: OAuthProviderConfig,
                state: String = UUID().uuidString,
                pkce: OAuthPKCE = OAuthPKCE(verifier: OAuthPKCE.randomVerifier())) throws {
        self.config = config
        self.state = state
        self.pkce = pkce
        self.authorizationURL = try config.authorizationURL(state: state, pkce: pkce)
    }

    public func authorizationCode(from callbackURL: URL) throws -> String {
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidRedirect
        }
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw OAuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OAuthError.missingAuthorizationCode
        }
        return code
    }
}

public struct OAuthToken: Equatable, Codable {
    public var provider: CloudDriveAPI.Provider
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String
    public var issuedAt: Date
    public var expiresAt: Date?
    public var accountLabel: String?
    public var clientID: String
    public var clientSecret: String?
    public var tokenEndpoint: URL
    public var apiEnvironment: CloudDriveAPI.Environment

    public init(provider: CloudDriveAPI.Provider,
                accessToken: String,
                refreshToken: String? = nil,
                tokenType: String = "Bearer",
                issuedAt: Date = Date(),
                expiresAt: Date? = nil,
                accountLabel: String? = nil,
                clientID: String,
                clientSecret: String? = nil,
                tokenEndpoint: URL,
                apiEnvironment: CloudDriveAPI.Environment) {
        self.provider = provider
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.accountLabel = accountLabel
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.tokenEndpoint = tokenEndpoint
        self.apiEnvironment = apiEnvironment
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().addingTimeInterval(OAuthTokenStateMachine.defaultClockSkew) >= expiresAt
    }
}

public struct OAuthTokenResponse: Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String
    public var expiresIn: TimeInterval?
    public var accountLabel: String?
    public var apiBaseURL: URL?

    public static func decode(_ data: Data) throws -> OAuthTokenResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.missingTokenField("access_token")
        }
        guard let accessToken = string(object["access_token"]), !accessToken.isEmpty else {
            throw OAuthError.missingTokenField("access_token")
        }
        let expiresIn = double(object["expires_in"])
        let apiBaseURL = [
            string(object["api_base_url"]),
            string(object["api_endpoint"]),
            string(object["hostname"]).map { "https://\($0)" },
            string(object["host"]).map { "https://\($0)" },
        ].compactMap { $0 }.first.flatMap(URL.init(string:))
        return OAuthTokenResponse(
            accessToken: accessToken,
            refreshToken: string(object["refresh_token"]),
            tokenType: string(object["token_type"]) ?? "Bearer",
            expiresIn: expiresIn,
            accountLabel: string(object["account_id"]) ?? string(object["uid"]) ?? string(object["user_id"]),
            apiBaseURL: apiBaseURL
        )
    }

    public func token(config: OAuthProviderConfig, now: Date = Date()) -> OAuthToken {
        OAuthToken(
            provider: config.provider,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            issuedAt: now,
            expiresAt: expiresIn.map { now.addingTimeInterval($0) },
            accountLabel: accountLabel,
            clientID: config.clientID,
            clientSecret: config.clientSecret,
            tokenEndpoint: config.tokenEndpoint,
            apiEnvironment: apiBaseURL.map(CloudDriveAPI.Environment.init(baseURL:)) ?? config.apiEnvironment
        )
    }

    private static func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

public struct OAuthTokenStore {
    public var credentialStore: CredentialStore

    public init(credentialStore: CredentialStore = CredentialStore()) {
        self.credentialStore = credentialStore
    }

    public func read(provider: CloudDriveAPI.Provider, sourceID: Int64) throws -> OAuthToken? {
        guard let data = try credentialStore.read(
            account: CloudDriveServerPolicy.credentialAccount(sourceID: sourceID, provider: provider)
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(OAuthToken.self, from: data)
    }

    public func save(_ token: OAuthToken, sourceID: Int64) throws {
        let data = try JSONEncoder().encode(token)
        try credentialStore.save(
            data,
            account: CloudDriveServerPolicy.credentialAccount(sourceID: sourceID, provider: token.provider)
        )
    }
}

public struct OAuthTokenClient {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func exchange(session authSession: OAuthAuthorizationSession, callbackURL: URL) async throws -> OAuthToken {
        let code = try authSession.authorizationCode(from: callbackURL)
        let request = try authSession.config.tokenExchangeRequest(code: code, pkce: authSession.pkce)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return try OAuthTokenResponse.decode(data).token(config: authSession.config)
    }

    public func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.refreshRequired
        }
        let config = OAuthProviderConfig(
            provider: token.provider,
            clientID: token.clientID,
            clientSecret: token.clientSecret,
            authorizationEndpoint: URL(string: "https://example.invalid/oauth/authorize")!,
            tokenEndpoint: token.tokenEndpoint,
            redirectURI: URL(string: "tonearm://oauth/\(token.provider.rawValue)")!,
            scopes: [],
            apiEnvironment: token.apiEnvironment
        )
        let request = try config.refreshRequest(refreshToken: refreshToken)
        let (data, response) = try await session.data(for: request)
        try validateRefresh(response)
        let refreshed = try OAuthTokenResponse.decode(data)
        return OAuthToken(
            provider: token.provider,
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? token.refreshToken,
            tokenType: refreshed.tokenType,
            issuedAt: Date(),
            expiresAt: refreshed.expiresIn.map { Date().addingTimeInterval($0) },
            accountLabel: refreshed.accountLabel ?? token.accountLabel,
            clientID: token.clientID,
            clientSecret: token.clientSecret,
            tokenEndpoint: token.tokenEndpoint,
            apiEnvironment: refreshed.apiBaseURL.map(CloudDriveAPI.Environment.init(baseURL:)) ?? token.apiEnvironment
        )
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }
    }

    private func validateRefresh(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if (200 ..< 300).contains(http.statusCode) { return }
        if (400 ..< 500).contains(http.statusCode) {
            throw OAuthError.refreshRequired
        }
        throw URLError(.badServerResponse)
    }
}

private func formEncoded(_ values: [String: String]) -> Data {
    values
        .sorted { $0.key < $1.key }
        .map { "\($0.key.urlFormEncoded)=\($0.value.urlFormEncoded)" }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
}

private extension String {
    var urlFormEncoded: String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
