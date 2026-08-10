import Foundation

/// Classifies source kinds for the remote-library feature. Commit 0.4 removed
/// the purchase gate entirely (FR-LIB-7): every remote-library provider is free
/// for everyone, so nothing here decides purchase — it only answers "is this a
/// remote library?" for provider dispatch and UI copy.
public enum RemoteLibraryAccessPolicy {
    public static let productSourceKinds: [SourceKind] = RemoteConnectorCatalog.productSourceKinds

    public static func isRemoteLibrary(_ kind: SourceKind) -> Bool {
        if isArchiveKind(kind) { return true }
        return productSourceKinds.contains(kind)
    }

    private static func isArchiveKind(_ kind: SourceKind) -> Bool {
        switch kind {
        case .iaItem, .iaList, .iaCollection, .iaFavorites: return true
        default: return false
        }
    }
}
