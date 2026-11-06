import XCTest

@testable import TonearmCore

final class OAuthCoreTests: XCTestCase {
    func testPKCEKnownVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            OAuthPKCE.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testAuthorizationURLIncludesStatePKCEAndScopes() throws {
        let config = try OAuthProviderConfig.cloudDrive(
            provider: .dropbox,
            clientID: "dropbox-client",
            redirectURI: URL(string: "tonearm://oauth/dropbox")!
        )
        let pkce = OAuthPKCE(verifier: "verifier-1234567890123456789012345678901234567890")
        let url = try config.authorizationURL(state: "state-1", pkce: pkce)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.dropbox.com")
        XCTAssertEqual(query["client_id"], "dropbox-client")
        XCTAssertEqual(query["redirect_uri"], "tonearm://oauth/dropbox")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["state"], "state-1")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["scope"], "files.metadata.read files.content.read")
        XCTAssertEqual(query["token_access_type"], "offline")
    }

    func testAuthorizationSessionValidatesStateAndExtractsCode() throws {
        let config = try OAuthProviderConfig.cloudDrive(
            provider: .googleDrive,
            clientID: "google-client",
            redirectURI: URL(string: "tonearm://oauth/googleDrive")!
        )
        let session = try OAuthAuthorizationSession(
            config: config,
            state: "state-1",
            pkce: OAuthPKCE(verifier: "verifier-1234567890123456789012345678901234567890")
        )

        let code = try session.authorizationCode(from: URL(string: "tonearm://oauth/googleDrive?code=abc&state=state-1")!)
        XCTAssertEqual(code, "abc")
        XCTAssertThrowsError(try session.authorizationCode(from: URL(string: "tonearm://oauth/googleDrive?code=abc&state=wrong")!)) { error in
            XCTAssertEqual(error as? OAuthError, .stateMismatch)
        }
    }

    func testTokenResponseBuildsStoredTokenWithExpiryAndEnvironment() throws {
        let config = OAuthProviderConfig(
            provider: .oneDrive,
            clientID: "client",
            authorizationEndpoint: URL(string: "https://login.example/authorize")!,
            tokenEndpoint: URL(string: "https://login.example/token")!,
            redirectURI: URL(string: "tonearm://oauth/oneDrive")!,
            scopes: ["Files.Read"],
            apiEnvironment: CloudDriveAPI.Environment(baseURL: URL(string: "https://graph.example")!)
        )
        let response = try OAuthTokenResponse.decode(Data("""
        {
          "access_token": "access-1",
          "refresh_token": "refresh-1",
          "token_type": "Bearer",
          "expires_in": 3600,
          "account_id": "acct-1",
          "api_base_url": "https://local.example/api"
        }
        """.utf8))
        let now = Date(timeIntervalSince1970: 1_000)
        let token = response.token(config: config, now: now)

        XCTAssertEqual(token.accessToken, "access-1")
        XCTAssertEqual(token.refreshToken, "refresh-1")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(token.accountLabel, "acct-1")
        XCTAssertEqual(token.apiEnvironment.baseURL.absoluteString, "https://local.example/api")
    }

    func testTokenStoreRoundTripsOAuthToken() throws {
        let credentialStore = CredentialStore(service: "guru.parso.tonearm.oauth.tests.\(UUID().uuidString)")
        let store = OAuthTokenStore(credentialStore: credentialStore)
        let token = OAuthToken(
            provider: .dropbox,
            accessToken: "access",
            refreshToken: "refresh",
            issuedAt: Date(timeIntervalSince1970: 1),
            expiresAt: Date(timeIntervalSince1970: 2),
            accountLabel: "acct",
            clientID: "client",
            tokenEndpoint: URL(string: "https://example.com/token")!,
            apiEnvironment: .production(provider: .dropbox)
        )

        try store.save(token, sourceID: 42)
        XCTAssertEqual(try store.read(provider: .dropbox, sourceID: 42), token)
        try credentialStore.delete(account: CloudDriveServerPolicy.credentialAccount(sourceID: 42, provider: .dropbox))
    }

    func testCloudProviderScopesAreReadOnlyForDropboxGoogleDriveAndOneDrive() throws {
        let providers: [(CloudDriveAPI.Provider, [String])] = [
            (.dropbox, ["files.metadata.read", "files.content.read"]),
            (.googleDrive, ["https://www.googleapis.com/auth/drive.readonly"]),
            (.oneDrive, ["offline_access", "Files.Read"]),
        ]
        for (provider, expectedScopes) in providers {
            let config = try OAuthProviderConfig.cloudDrive(
                provider: provider,
                clientID: "client-\(provider.rawValue)",
                redirectURI: URL(string: "tonearm://oauth/\(provider.rawValue)")!
            )
            XCTAssertEqual(config.scopes, expectedScopes, "\(provider.rawValue) scopes should be read-only")
            XCTAssertFalse(config.scopes.contains(where: { $0.lowercased().contains("write") || $0.lowercased().contains("modify") || $0.lowercased().contains("delete") || $0.lowercased().contains("manage") }), "\(provider.rawValue) should not request write scopes")
        }
    }

    func testPCloudDoesNotRequestScopes() throws {
        let config = try OAuthProviderConfig.cloudDrive(
            provider: .pCloud,
            clientID: "pcloud-client",
            redirectURI: URL(string: "tonearm://oauth/pCloud")!
        )
        XCTAssertEqual(config.scopes, [])
    }

    func testBoxConfigCarriesItsClientSecretLikePCloud() throws {
        // Box's own token-endpoint reference documents no code_verifier/code_challenge field —
        // no PKCE support — so unlike Dropbox/Google Drive/OneDrive it must be a confidential
        // client carrying a real secret, the same shape as pCloud above.
        let config = try OAuthProviderConfig.cloudDrive(
            provider: .box,
            clientID: "box-client",
            clientSecret: "box-secret",
            redirectURI: URL(string: "tonearm://oauth/box")!
        )
        XCTAssertEqual(config.scopes, [])
        XCTAssertEqual(config.clientSecret, "box-secret")
        XCTAssertEqual(config.authorizationEndpoint, URL(string: "https://account.box.com/api/oauth2/authorize")!)
        XCTAssertEqual(config.tokenEndpoint, URL(string: "https://api.box.com/oauth2/token")!)
    }

    func testYandexDiskConfigRequestsReadOnlyScopeAndSupportsPKCEWithoutASecret() throws {
        // Confirmed against Yandex ID's own OAuth docs: the authorization request accepts
        // code_challenge/code_challenge_method and "you don't need to pass the secret key" once
        // code_verifier is sent — a real PKCE public client, unlike Box/pCloud above.
        let config = try OAuthProviderConfig.cloudDrive(
            provider: .yandexDisk,
            clientID: "yandex-client",
            redirectURI: URL(string: "tonearm://oauth/yandexDisk")!
        )
        XCTAssertEqual(config.scopes, ["cloud_api:disk.read"])
        XCTAssertNil(config.clientSecret)
        XCTAssertEqual(config.authorizationEndpoint, URL(string: "https://oauth.yandex.com/authorize")!)
        XCTAssertEqual(config.tokenEndpoint, URL(string: "https://oauth.yandex.com/token")!)

        let pkce = OAuthPKCE(verifier: OAuthPKCE.randomVerifier())
        let authURL = try config.authorizationURL(state: "state-1", pkce: pkce)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertNotNil(query["code_challenge"])
    }
}
