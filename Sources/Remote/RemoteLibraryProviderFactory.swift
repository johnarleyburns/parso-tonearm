import Foundation

enum RemoteLibraryProviderFactory {
    static func supports(_ kind: SourceKind) -> Bool {
        RemoteLibraryAccessPolicy.isRemoteLibrary(kind)
    }

    static func provider(for source: Source,
                         credentialStore: CredentialStore = CredentialStore()) throws -> any RemoteLibraryProvider {
        switch source.kind {
        case .subsonic:
            return try SubsonicProvider.from(source: source, credentialStore: credentialStore)
        case .webDAV:
            return try WebDAVProvider.from(source: source, credentialStore: credentialStore)
        case .smb:
            return try SMBProvider.from(source: source, credentialStore: credentialStore)
        case .jellyfin:
            return try JellyfinProvider.from(source: source, credentialStore: credentialStore)
        case .plex:
            return try PlexProvider.from(source: source, credentialStore: credentialStore)
        case .dropbox, .googleDrive, .oneDrive, .pCloud:
            return try CloudDriveProvider.from(source: source, credentialStore: credentialStore)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    static func credentialAccounts(for sourceID: Int64, kind: SourceKind) -> [String] {
        switch kind {
        case .subsonic:
            return [SubsonicServerPolicy.credentialAccount(sourceID: sourceID)]
        case .webDAV:
            return [WebDAVServerPolicy.credentialAccount(sourceID: sourceID)]
        case .smb:
            return [SMBFolderPolicy.credentialAccount(sourceID: sourceID)]
        case .jellyfin:
            return [JellyfinServerPolicy.credentialAccount(sourceID: sourceID)]
        case .plex:
            return [PlexServerPolicy.credentialAccount(sourceID: sourceID)]
        case .dropbox, .googleDrive, .oneDrive, .pCloud:
            guard let provider = CloudDriveAPI.Provider(sourceKind: kind) else { return [] }
            return [CloudDriveServerPolicy.credentialAccount(sourceID: sourceID, provider: provider)]
        default:
            return []
        }
    }
}
