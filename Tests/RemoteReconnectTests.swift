import Testing
@testable import TonearmCore

@Suite struct RemoteReconnectTests {
    @Test func testReconnectReplacesCredentialsAtExistingAccountForEveryAuthenticatedProvider() async throws {
        let kinds: [SourceKind] = [.subsonic, .webDAV, .jellyfin, .emby, .plex, .smb,
                                   .dropbox, .googleDrive, .oneDrive, .pCloud, .box, .yandexDisk]
        let store = CredentialStore(service: "reconnect.tests.\(UUID().uuidString)")
        for kind in kinds {
            let source = makeSource(kind)
            let account = try #require(RemoteLibraryProviderFactory.credentialAccounts(for: 42, kind: kind).first)
            defer { try? store.delete(account: account) }
            try store.save(Data("old".utf8), account: account)
            try await RemoteLibraryProviderFactory.reconnect(source: source, credential: Data("new".utf8),
                provider: ReconnectProvider(sourceKind: kind), credentialStore: store)
            #expect(try store.read(account: account) == Data("new".utf8), "\(kind)")
        }
    }

    @Test func testFailedValidationPreservesExistingCredential() async throws {
        let store = CredentialStore(service: "reconnect.tests.\(UUID().uuidString)")
        let source = makeSource(.googleDrive)
        let account = CloudDriveServerPolicy.credentialAccount(sourceID: 42, provider: .googleDrive)
        defer { try? store.delete(account: account) }
        try store.save(Data("old".utf8), account: account)
        do {
            try await RemoteLibraryProviderFactory.reconnect(source: source, credential: Data("bad".utf8),
                provider: ReconnectProvider(sourceKind: .googleDrive, fails: true), credentialStore: store)
            Issue.record("Expected failed validation")
        } catch {
            #expect(try store.read(account: account) == Data("old".utf8))
        }
    }

    @Test func testReconnectRejectsProviderMismatchWithoutChangingCredentials() async throws {
        let store = CredentialStore(service: "reconnect.tests.\(UUID().uuidString)")
        let account = CloudDriveServerPolicy.credentialAccount(sourceID: 42, provider: .googleDrive)
        defer { try? store.delete(account: account) }
        try store.save(Data("old".utf8), account: account)
        do {
            try await RemoteLibraryProviderFactory.reconnect(source: makeSource(.googleDrive), credential: Data("new".utf8),
                provider: ReconnectProvider(sourceKind: .dropbox), credentialStore: store)
            Issue.record("Expected provider mismatch to fail")
        } catch {
            #expect(try store.read(account: account) == Data("old".utf8))
        }
    }

    private func makeSource(_ kind: SourceKind) -> Source {
        Source(id: 42, kind: kind, iaIdentifier: nil, originalURL: nil, title: "My Library",
               addedAt: Date(), lastResolvedAt: nil, followUpdates: false, licenseText: nil, memberCapHit: false)
    }

    @Test func testRecoveryOffersRealSignInInsteadOfRemoveAndReadd() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/Features/Sources/SourceDetailView+ManagementSection.swift"), encoding: .utf8)
        let detail = try String(contentsOf: root.appendingPathComponent("Sources/Features/Sources/SourceDetailView.swift"), encoding: .utf8)
        let sheet = try String(contentsOf: root.appendingPathComponent("Sources/Features/Ingest/AddServerSheet.swift"), encoding: .utf8)
        #expect(!settings.contains("remove and re-add"))
        #expect(settings.contains("reconnectingSource: source"))
        #expect(detail.contains("source.reconnect"))
        #expect(sheet.contains("reconnectRemoteSource"))
    }
}

private struct ReconnectProvider: RemoteLibraryProvider {
    var sourceKind: SourceKind
    var fails = false
    func browse(path: String) async throws -> [RemoteNode] { [] }
    func resolve(node: RemoteNode) async throws -> ResolvedAsset { throw URLError(.unsupportedURL) }
    func refresh() async throws {
        if fails { throw URLError(.userAuthenticationRequired) }
    }
}
