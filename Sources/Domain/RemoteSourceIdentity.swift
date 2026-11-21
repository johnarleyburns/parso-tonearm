import Foundation

/// Decides whether a cloud/server provider being added is the same account or
/// endpoint as an existing source. Re-adding the same Google Drive account used
/// to insert a second `Source` row; because `RemoteTrackIdentity` is namespaced
/// by source id, every file then re-ingested under a new identity and appeared
/// twice in Jump Back In / Favorites.
public enum RemoteSourceIdentity {
    /// Returns the existing source that represents the same remote account or
    /// endpoint, or nil when this is genuinely a new one.
    ///
    /// - OAuth cloud drives carry the account label (email / username) in
    ///   `iaIdentifier`; that is the strongest cross-launch identity.
    /// - URL-based servers carry a canonical base URL in `originalURL`.
    /// - Providers with neither (a raw bearer token with no account label) are
    ///   left alone: guessing by display title would merge different accounts.
    public static func existingSource(in sources: [Source], kind: SourceKind,
                                      iaIdentifier: String?, originalURL: String?) -> Source? {
        guard let key = canonicalKey(kind: kind, iaIdentifier: iaIdentifier,
                                     originalURL: originalURL) else { return nil }
        return sources.first { canonicalKey(for: $0) == key }
    }

    /// The cross-launch identity used both when re-adding a source and by the
    /// v53 consolidation migration. `nil` means "do not guess" (local sources
    /// and providers added with neither an account label nor an endpoint).
    public static func canonicalKey(for source: Source) -> String? {
        canonicalKey(kind: source.kind, iaIdentifier: source.iaIdentifier,
                     originalURL: source.originalURL)
    }

    public static func canonicalKey(kind: SourceKind, iaIdentifier: String?,
                                    originalURL: String?) -> String? {
        let account = normalizedAccount(iaIdentifier)
        let url = normalizedURL(originalURL)
        switch kind {
        case .local:
            return nil
        case .webDAV, .jellyfin, .emby, .subsonic, .plex, .smb:
            // Endpoint is the primary key; username/user id is a second
            // discriminator so two servers sharing a username never merge.
            guard let url else { return nil }
            return "\(kind.rawValue)|url:\(url)|acct:\(account ?? "")"
        case .dropbox, .googleDrive, .oneDrive, .pCloud, .box, .yandexDisk:
            // OAuth drives have no endpoint; the account label is the key.
            if let account { return "\(kind.rawValue)|acct:\(account)" }
            if let url { return "\(kind.rawValue)|url:\(url)|acct:" }
            return nil
        case .iaItem, .iaList, .iaCollection, .iaFavorites, .jamendoGenre:
            // The archive identifier / genre path is the durable identity.
            guard let account else { return nil }
            return "\(kind.rawValue)|id:\(account)"
        }
    }

    static func normalizedAccount(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }

    static func normalizedURL(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        var normalized = trimmed
        while normalized.hasSuffix("/") { normalized.removeLast() }
        return normalized.lowercased()
    }
}
