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
        let account = normalizedAccount(iaIdentifier)
        let url = normalizedURL(originalURL)

        // A server endpoint is the primary key when present; the account label
        // is a second discriminator (two WebDAV/Jellyfin servers can share a
        // username/user id). OAuth cloud drives have no endpoint, so their
        // account label is the key.
        if let url {
            return sources.first {
                $0.kind == kind && normalizedURL($0.originalURL) == url
                    && (account == nil || normalizedAccount($0.iaIdentifier) == account)
            }
        }
        if let account {
            return sources.first {
                $0.kind == kind && normalizedAccount($0.iaIdentifier) == account
            }
        }
        return nil
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
