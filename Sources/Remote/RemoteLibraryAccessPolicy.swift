import Foundation

public enum RemoteLibraryAction: Equatable {
    case openAddFlow
    case connect(SourceKind)
    case browse(SourceKind)
    case resolve(SourceKind)
}
public enum RemoteLibraryAccessPolicy {
    public static let productSourceKinds: [SourceKind] = [
        .subsonic,
        .webDAV,
        .smb,
        .jellyfin,
        .plex,
        .dropbox,
        .googleDrive,
        .oneDrive,
        .pCloud,
    ]

    public static func isRemoteLibrary(_ kind: SourceKind) -> Bool {
        productSourceKinds.contains(kind)
    }

    public static func decision(for action: RemoteLibraryAction, isPro: Bool) -> ProGateDecision {
        switch action {
        case .openAddFlow:
            return isPro ? .allow : .requiresPro(.remoteLibraries)
        case .connect(let kind), .browse(let kind), .resolve(let kind):
            guard isRemoteLibrary(kind) else { return .allow }
            return isPro ? .allow : .requiresPro(.remoteLibraries)
        }
    }
}
