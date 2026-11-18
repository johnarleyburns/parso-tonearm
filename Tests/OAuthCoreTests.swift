import Testing

@testable import TonearmCore

@Suite struct OAuthCoreTests {
    @Test func testPKCEKnownVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(
            OAuthPKCE.challenge(for: verifier) ==
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    @Test func testAuthorizationURLIncludesStatePKCEAndScopes() throws {
        let config = try OAuthProviderConfig.cloudDrive(
            provider: .dropbox,
            clientID: "dropbox-client",
            redirectURI: URL(string: "tonearm://oauth/dropbox")!
        )
        let pkce = OAuthPKCE(verifier: "verifier-1234567890123456789012345678901234567890")
        let url = try config.authorizationURL(state: "state-1", pkce: pkce)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.scheme == "https")
        #expect(components.host == "www.dropbox.com")
        #expect(query["client_id"] == "dropbox-client")
        #expect(query["redirect_uri"] == "tonearm://oauth/dropbox")
        #expect(query["response_type"] == "code")
        #expect(query["state"] == "state-1")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["scope"] == "files.metadata.read files.content.read")
        #expect(query["token_access_type"] == "offline")
    }

    @Test func testAuthorizationSessionValidatesStateAndExtractsCode() throws {
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
        #expect(code == "abc")
        do {
            _ = try session.authorizationCode(from: URL(string: "tonearm://oauth/googleDrive?code=abc&state=wrong")!)
            Issue.record("expected authorizationCode(from:) with a mismatched state to throw")
        } catch {
            #expect(error as? OAuthError == .stateMismatch)
        }
    }

    @Test func testTokenResponseBuildsStoredTokenWithExpiryAndEnvironment() throws {
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

        #expect(token.accessToken == "access-1")
        #expect(token.refreshToken == "refresh-1")
        #expect(token.expiresAt == now.addingTimeInterval(3_600))
        #expect(token.accountLabel == "acct-1")
        #expect(token.apiEnvironment.baseURL.absoluteString == "https://local.example/api")
    }

    @Test func testTokenStoreRoundTripsOAuthToken() throws {
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
        #expect(try store.read(provider: .dropbox, sourceID: 42) == token)
        try credentialStore.delete(account: CloudDriveServerPolicy.credentialAccount(sourceID: 42, provider: .dropbox))
    }

    @Test func testCloudProviderScopesAreReadOnlyForDropboxGoogleDriveAndOneDrive() throws {
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
            #expect(config.scopes == expectedScopes, "\(provider.rawValue) scopes should be read-only")
            #expect(!config.scopes.contains(where: { $0.lowercased().contains("write") || $0.lowercased().contains("modify") || $0.lowercased().contains("delete") || $0.lowercased().contains("manage") }), "\(provider.rawValue) should not request write scopes")
        }
    }

    @Test func testPCloudDoesNotRequestScopes() throws {
        let config = try OAuthProviderConfig.cloudDrive(
            provider: .pCloud,
            clientID: "pcloud-client",
            redirectURI: URL(string: "tonearm://oauth/pCloud")!
        )
        #expect(config.scopes == [])
    }

    @Test func testBoxConfigCarriesItsClientSecretLikePCloud() throws {
        // Box's own token-endpoint reference documents no code_verifier/code_challenge field —
        // no PKCE support — so unlike Dropbox/Google Drive/OneDrive it must be a confidential
        // client carrying a real secret, the same shape as pCloud above.
        let config = try OAuthProviderConfig.cloudDrive(
            provider: .box,
            clientID: "box-client",
            clientSecret: "box-secret",
            redirectURI: URL(string: "tonearm://oauth/box")!
        )
        #expect(config.scopes == [])
        #expect(config.clientSecret == "box-secret")
        #expect(config.authorizationEndpoint == URL(string: "https://account.box.com/api/oauth2/authorize")!)
        #expect(config.tokenEndpoint == URL(string: "https://api.box.com/oauth2/token")!)
    }

    @Test func testYandexDiskConfigRequestsReadOnlyScopeAndSupportsPKCEWithoutASecret() throws {
        // Confirmed against Yandex ID's own OAuth docs: the authorization request accepts
        // code_challenge/code_challenge_method and "you don't need to pass the secret key" once
        // code_verifier is sent — a real PKCE public client, unlike Box/pCloud above.
        let config = try OAuthProviderConfig.cloudDrive(
            provider: .yandexDisk,
            clientID: "yandex-client",
            redirectURI: URL(string: "tonearm://oauth/yandexDisk")!
        )
        #expect(config.scopes == ["cloud_api:disk.read"])
        #expect(config.clientSecret == nil)
        #expect(config.authorizationEndpoint == URL(string: "https://oauth.yandex.com/authorize")!)
        #expect(config.tokenEndpoint == URL(string: "https://oauth.yandex.com/token")!)

        let pkce = OAuthPKCE(verifier: OAuthPKCE.randomVerifier())
        let authURL = try config.authorizationURL(state: "state-1", pkce: pkce)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] != nil)
    }
}
