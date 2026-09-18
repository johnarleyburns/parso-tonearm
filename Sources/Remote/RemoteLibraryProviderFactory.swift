import Foundation

public enum RemoteLibraryProviderFactory {
    public static func supports(_ kind: SourceKind) -> Bool {
        RemoteLibraryAccessPolicy.isRemoteLibrary(kind)
    }

    public static func provider(for source: Source,
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
        case .jamendoGenre:
            return JamendoGenreProvider(clientID: JamendoAppConfig.clientID,
                                        sourcePath: source.iaIdentifier)
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            // Real bug found auditing the remote-indexing backfill fix:
            // `RemoteLibraryAccessPolicy.isRemoteLibrary` (what `supports`
            // above reports) already counts these kinds as remote
            // libraries, but this factory fell through to the `default`
            // throw for every one of them — silently breaking both
            // `RemoteSparseAssetResolver`'s analysis-time re-
            // authentication AND any live browse of an IA source through
            // the generic remote-provider path, for what is very likely
            // this app's single largest remote-library source type.
            return IARemoteLibraryProvider(preferFLAC: false)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    public static func credentialAccounts(for sourceID: Int64, kind: SourceKind) -> [String] {
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
