import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
import UIKit

extension AppState {
    func requestAddRemoteLibrary() {
        tab = .settings
        showAddRemoteLibrary = true
    }

    func addSubsonicServer(url rawURL: String, username rawUsername: String, password: String) async throws {
        let baseURL = try SubsonicServerPolicy.normalizeBaseURL(rawURL)
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = SubsonicProvider(baseURL: baseURL, username: username, password: password)
        try await provider.refresh()

        var source = Source(
            id: nil,
            kind: .subsonic,
            iaIdentifier: username,
            originalURL: baseURL.absoluteString,
            title: SubsonicServerPolicy.displayName(baseURL: baseURL),
            addedAt: Date(),
            lastResolvedAt: Date(),
            followUpdates: false,
            licenseText: nil,
            memberCapHit: false
        )
        source = try await store.insertSource(source)
        guard let sourceID = source.id else { return }
        do {
            try CredentialStore().save(Data(password.utf8),
                                       account: SubsonicServerPolicy.credentialAccount(sourceID: sourceID))
        } catch {
            try? await store.deleteSource(id: sourceID)
            throw error
        }
        await reload()
        tab = .settings
    }

    func addWebDAVServer(url rawURL: String, username rawUsername: String, password: String) async throws {
        let baseURL = try WebDAVServerPolicy.normalizeBaseURL(rawURL)
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = WebDAVProvider(baseURL: baseURL, username: username, password: password)
        try await provider.refresh()

        let credential = WebDAVCredential(username: username, password: password)
        try await insertRemoteSource(
            kind: .webDAV,
            title: WebDAVServerPolicy.displayName(baseURL: baseURL),
            originalURL: baseURL.absoluteString,
            iaIdentifier: username,
            credential: try JSONEncoder().encode(credential),
            credentialAccount: WebDAVServerPolicy.credentialAccount
        )
    }

    func addJellyfinServer(url rawURL: String, username rawUsername: String, password: String) async throws {
        let baseURL = try JellyfinServerPolicy.normalizeBaseURL(rawURL)
        let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = try JellyfinAPI.request(
            baseURL: baseURL,
            endpoint: .authenticate(username: username, password: password)
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.userAuthenticationRequired)
        }
        let auth = try JellyfinAPI.decodeAuthentication(data)
        let provider = JellyfinProvider(baseURL: baseURL, userID: auth.userID, accessToken: auth.accessToken)
        try await provider.refresh()

        try await insertRemoteSource(
            kind: .jellyfin,
            title: JellyfinServerPolicy.displayName(baseURL: baseURL),
            originalURL: baseURL.absoluteString,
            iaIdentifier: auth.userID,
            credential: Data(auth.accessToken.utf8),
            credentialAccount: JellyfinServerPolicy.credentialAccount
        )
    }

    func addPlexServer(url rawURL: String, token rawToken: String) async throws {
        let baseURL = try PlexServerPolicy.normalizeBaseURL(rawURL)
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = PlexProvider(baseURL: baseURL, token: token)
        try await provider.refresh()

        try await insertRemoteSource(
            kind: .plex,
            title: PlexServerPolicy.displayName(baseURL: baseURL),
            originalURL: baseURL.absoluteString,
            iaIdentifier: nil,
            credential: Data(token.utf8),
            credentialAccount: PlexServerPolicy.credentialAccount
        )
    }

    func addCloudDrive(provider cloudProvider: CloudDriveAPI.Provider, accessToken rawToken: String) async throws {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = CloudDriveProvider(provider: cloudProvider, accessToken: token)
        try await provider.refresh()

        try await insertRemoteSource(
            kind: cloudProvider.sourceKind,
            title: CloudDriveServerPolicy.displayName(provider: cloudProvider),
            originalURL: nil,
            iaIdentifier: nil,
            credential: Data(token.utf8),
            credentialAccount: { sourceID in
                CloudDriveServerPolicy.credentialAccount(sourceID: sourceID, provider: cloudProvider)
            }
        )
    }

    func addCloudDrive(provider cloudProvider: CloudDriveAPI.Provider, oauthToken token: OAuthToken) async throws {
        let provider = CloudDriveProvider(
            provider: cloudProvider,
            accessProvider: OAuthCloudDriveAccessProvider(token: token)
        )
        try await provider.refresh()

        try await insertRemoteSource(
            kind: cloudProvider.sourceKind,
            title: CloudDriveServerPolicy.displayName(provider: cloudProvider),
            originalURL: nil,
            iaIdentifier: token.accountLabel,
            credential: try JSONEncoder().encode(token),
            credentialAccount: { sourceID in
                CloudDriveServerPolicy.credentialAccount(sourceID: sourceID, provider: cloudProvider)
            }
        )
    }

    func addSMBFolder(_ folderURL: URL, bookmark folderBookmark: Data?) async throws {
        let bookmark = folderBookmark ?? BookmarkVault.makeBookmark(for: folderURL)
        guard let bookmark else { throw IngestError.failedToCreateBookmark }

        try await insertRemoteSource(
            kind: .smb,
            title: SMBFolderPolicy.displayName(rootURL: folderURL),
            originalURL: folderURL.absoluteString,
            iaIdentifier: nil,
            credential: bookmark,
            credentialAccount: SMBFolderPolicy.credentialAccount
        )
    }

    func addIASource(url rawURL: String, username: String?, password: String?) async throws {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = SourceService(preferFLAC: preferFLAC)
        let preview = try await service.preview(from: url)

        let followUpdates = preview.kind != .iaItem

        let source = try await service.add(preview: preview, followUpdates: followUpdates, store: store)

        if let _ = username, let password, let sourceID = source.id {
            let data = Data(password.utf8)
            let account = "ia-private:\(sourceID)"
            try CredentialStore().save(data, account: account)
        }

        await reload()
        tab = .settings
    }

}
