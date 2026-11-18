import Testing

@testable import TonearmCore

@Suite struct OAuthTokenClientTests {

    @Test func testTokenIsExpiredWhenBeyondExpiry() {
        let token = OAuthToken(
            provider: .dropbox,
            accessToken: "at",
            issuedAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2),
            accountLabel: nil,
            clientID: "c",
            tokenEndpoint: URL(string: "https://example.com/token")!,
            apiEnvironment: .production(provider: .dropbox)
        )
        #expect(token.isExpired)
    }

    @Test func testTokenIsNotExpiredWithFutureExpiry() {
        let future = Date().addingTimeInterval(3_600)
        let token = OAuthToken(
            provider: .googleDrive,
            accessToken: "at",
            issuedAt: Date(),
            expiresAt: future,
            accountLabel: nil,
            clientID: "c",
            tokenEndpoint: URL(string: "https://example.com/token")!,
            apiEnvironment: .production(provider: .googleDrive)
        )
        #expect(!token.isExpired)
    }

    @Test func testTokenIsNotExpiredWithoutExpiryPCloud() {
        let token = OAuthToken(
            provider: .pCloud,
            accessToken: "at",
            issuedAt: Date(timeIntervalSince1970: 1),
            expiresAt: nil,
            accountLabel: nil,
            clientID: "c",
            tokenEndpoint: URL(string: "https://api.pcloud.com/oauth2_token")!,
            apiEnvironment: .production(provider: .pCloud)
        )
        #expect(!token.isExpired)
    }

    @Test func testRefreshErrorDescriptionIsUserFacing() {
        #expect(OAuthError.refreshRequired.errorDescription == "Reconnect this library to continue.")
    }

    @Test func testOAuthTokenSerializationRoundTrips() throws {
        let token = OAuthToken(
            provider: .oneDrive,
            accessToken: "at",
            refreshToken: "rt",
            tokenType: "Bearer",
            issuedAt: Date(timeIntervalSince1970: 1_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_003_600),
            accountLabel: "acct-1",
            clientID: "cid",
            clientSecret: "csec",
            tokenEndpoint: URL(string: "https://login.example/token")!,
            apiEnvironment: .production(provider: .oneDrive)
        )
        let data = try JSONEncoder().encode(token)
        let restored = try JSONDecoder().decode(OAuthToken.self, from: data)
        #expect(restored == token)
    }

    @Test func testAccessProviderRefreshesExpiredTokenAndSavesToStore() async throws {
        let credentialStore = CredentialStore(service: "guru.parso.tonearm.oauth.tests.\(UUID().uuidString)")
        let store = OAuthTokenStore(credentialStore: credentialStore)
        let sourceID: Int64 = 99
        defer {
            try? credentialStore.delete(account: CloudDriveServerPolicy.credentialAccount(sourceID: sourceID, provider: .dropbox))
        }

        let expiredToken = OAuthToken(
            provider: .dropbox,
            accessToken: "expired",
            refreshToken: "dropbox-refresh",
            issuedAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2),
            accountLabel: "acct",
            clientID: "dropbox-client",
            tokenEndpoint: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            apiEnvironment: .production(provider: .dropbox)
        )
        try store.save(expiredToken, sourceID: sourceID)

        let refreshJSON = """
        {"access_token":"fresh-access","refresh_token":"fresh-refresh","token_type":"Bearer","expires_in":3600,"account_id":"acct"}
        """
        let client = OAuthTokenClient(session: mockSession(json: refreshJSON))
        let accessProvider = OAuthCloudDriveAccessProvider(
            token: expiredToken,
            sourceID: sourceID,
            tokenStore: store,
            tokenClient: client
        )
        let access = try await accessProvider.access()
        #expect(access.accessToken == "fresh-access")

        let saved = try #require(try store.read(provider: .dropbox, sourceID: sourceID))
        #expect(saved.accessToken == "fresh-access")
        #expect(saved.refreshToken == "fresh-refresh")
    }

    @Test func testAccessProviderUsesCachedTokenWhenNotExpired() async throws {
        let validToken = OAuthToken(
            provider: .googleDrive,
            accessToken: "valid-access",
            refreshToken: "googleDrive-refresh",
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(3_600),
            accountLabel: nil,
            clientID: "google-client",
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            apiEnvironment: .production(provider: .googleDrive)
        )
        let accessProvider = OAuthCloudDriveAccessProvider(token: validToken)
        let access = try await accessProvider.access()
        #expect(access.accessToken == "valid-access")
    }

    @Test func testAccessProviderThrowsReconnectRequiredWithoutRefreshToken() async {
        let expiredToken = OAuthToken(
            provider: .oneDrive,
            accessToken: "stale",
            refreshToken: nil,
            issuedAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2),
            accountLabel: nil,
            clientID: "oneDrive-client",
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            apiEnvironment: .production(provider: .oneDrive)
        )
        let accessProvider = OAuthCloudDriveAccessProvider(token: expiredToken)
        do {
            _ = try await accessProvider.access()
            Issue.record("Expected refreshRequired")
        } catch let error as OAuthError {
            #expect(error == .refreshRequired)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

extension OAuthTokenClientTests {
    private func mockSession(json: String) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefreshMockURLProtocol.self]
        RefreshMockURLProtocol.mockJSON = json
        return URLSession(configuration: config)
    }
}

private final class RefreshMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var mockJSON: String?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/token") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        guard let json = Self.mockJSON, let data = json.data(using: .utf8) else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
