import Foundation
import Testing
@testable import TonearmCore

/// Re-adding the same cloud account/endpoint must reuse the existing Source.
/// `RemoteTrackIdentity` is namespaced by source id, so a second Source row
/// re-ingests every file under a new identity (the duplicate Google Drive
/// tracks users saw in Jump Back In / Favorites).
@Suite struct RemoteSourceIdentityTests {
    private func source(kind: SourceKind = .googleDrive,
                        account: String? = nil,
                        url: String? = nil,
                        title: String = "Drive") -> Source {
        Source(id: 7, kind: kind, iaIdentifier: account, originalURL: url, title: title,
               addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
               licenseText: nil, memberCapHit: false)
    }

    @Test func testSameOAuthAccountMatchesCaseInsensitively() {
        let existing = source(account: "User@Example.com")
        #expect(RemoteSourceIdentity.existingSource(
            in: [existing], kind: .googleDrive,
            iaIdentifier: " user@example.com ", originalURL: nil)?.id == 7)
    }

    @Test func testDifferentOAuthAccountDoesNotMatch() {
        let existing = source(account: "user@example.com")
        #expect(RemoteSourceIdentity.existingSource(
            in: [existing], kind: .googleDrive,
            iaIdentifier: "other@example.com", originalURL: nil) == nil)
    }

    @Test func testSameKindWithDifferentProviderDoesNotMatch() {
        let existing = source(kind: .dropbox, account: "user@example.com")
        #expect(RemoteSourceIdentity.existingSource(
            in: [existing], kind: .googleDrive,
            iaIdentifier: "user@example.com", originalURL: nil) == nil)
    }

    @Test func testServerEndpointIgnoresTrailingSlashAndCase() {
        let existing = source(kind: .webDAV, url: "https://Music.Example.com/dav/")
        #expect(RemoteSourceIdentity.existingSource(
            in: [existing], kind: .webDAV,
            iaIdentifier: nil, originalURL: "https://music.example.com/dav")?.id == 7)
    }

    @Test func testSameEndpointWithDifferentUsernameDoesNotMatch() {
        let existing = source(kind: .webDAV, account: "alice", url: "https://music.example.com/dav")
        #expect(RemoteSourceIdentity.existingSource(
            in: [existing], kind: .webDAV,
            iaIdentifier: "bob", originalURL: "https://music.example.com/dav") == nil)
    }

    @Test func testSameAccountOnADifferentEndpointDoesNotMatch() {
        let existing = source(kind: .jellyfin, account: "user-1", url: "https://one.example.com")
        #expect(RemoteSourceIdentity.existingSource(
            in: [existing], kind: .jellyfin,
            iaIdentifier: "user-1", originalURL: "https://two.example.com") == nil)
    }

    @Test func testRawTokenWithNoAccountOrEndpointIsNeverGuessed() {
        let existing = source(account: nil, url: nil)
        #expect(RemoteSourceIdentity.existingSource(
            in: [existing], kind: .googleDrive,
            iaIdentifier: nil, originalURL: nil) == nil)
    }
}
