import XCTest
@testable import TonearmCore

final class RemoteReconnectTests: XCTestCase {
    func testReconnectReplacesCredentialsAtExistingAccountForEveryAuthenticatedProvider() async throws {
        let kinds: [SourceKind] = [.subsonic, .webDAV, .jellyfin, .emby, .plex, .smb,
                                   .dropbox, .googleDrive, .oneDrive, .pCloud, .box, .yandexDisk]
        let store = CredentialStore(service: "reconnect.tests.\(UUID().uuidString)")
        for kind in kinds {
            let source = makeSource(kind)
            let account = try XCTUnwrap(RemoteLibraryProviderFactory.credentialAccounts(for: 42, kind: kind).first)
            defer { try? store.delete(account: account) }
            try store.save(Data("old".utf8), account: account)
            try await RemoteLibraryProviderFactory.reconnect(source: source, credential: Data("new".utf8),
                provider: ReconnectProvider(sourceKind: kind), credentialStore: store)
            XCTAssertEqual(try store.read(account: account), Data("new".utf8), "\(kind)")
        }
    }

    func testFailedValidationPreservesExistingCredential() async throws {
        let store = CredentialStore(service: "reconnect.tests.\(UUID().uuidString)")
        let source = makeSource(.googleDrive)
        let account = CloudDriveServerPolicy.credentialAccount(sourceID: 42, provider: .googleDrive)
        defer { try? store.delete(account: account) }
        try store.save(Data("old".utf8), account: account)
        do {
            try await RemoteLibraryProviderFactory.reconnect(source: source, credential: Data("bad".utf8),
                provider: ReconnectProvider(sourceKind: .googleDrive, fails: true), credentialStore: store)
            XCTFail("Expected failed validation")
        } catch {
            XCTAssertEqual(try store.read(account: account), Data("old".utf8))
        }
    }

    func testReconnectRejectsProviderMismatchWithoutChangingCredentials() async throws {
        let store = CredentialStore(service: "reconnect.tests.\(UUID().uuidString)")
        let account = CloudDriveServerPolicy.credentialAccount(sourceID: 42, provider: .googleDrive)
        defer { try? store.delete(account: account) }
        try store.save(Data("old".utf8), account: account)
        do {
            try await RemoteLibraryProviderFactory.reconnect(source: makeSource(.googleDrive), credential: Data("new".utf8),
                provider: ReconnectProvider(sourceKind: .dropbox), credentialStore: store)
            XCTFail("Expected provider mismatch to fail")
        } catch {
            XCTAssertEqual(try store.read(account: account), Data("old".utf8))
        }
    }

    private func makeSource(_ kind: SourceKind) -> Source {
        Source(id: 42, kind: kind, iaIdentifier: nil, originalURL: nil, title: "My Library",
               addedAt: Date(), lastResolvedAt: nil, followUpdates: false, licenseText: nil, memberCapHit: false)
    }

    func testRecoveryOffersRealSignInInsteadOfRemoveAndReadd() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/Features/Sources/SourceDetailView+ManagementSection.swift"), encoding: .utf8)
        let detail = try String(contentsOf: root.appendingPathComponent("Sources/Features/Sources/SourceDetailView.swift"), encoding: .utf8)
        let sheet = try String(contentsOf: root.appendingPathComponent("Sources/Features/Ingest/AddServerSheet.swift"), encoding: .utf8)
        XCTAssertFalse(settings.contains("remove and re-add"))
        XCTAssertTrue(settings.contains("reconnectingSource: source"))
        XCTAssertTrue(detail.contains("source.reconnect"))
        XCTAssertTrue(sheet.contains("reconnectRemoteSource"))
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
