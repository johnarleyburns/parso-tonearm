import Foundation

public enum RemoteLibraryAction: Equatable {
    case openAddFlow
    case connect(SourceKind)
    case browse(SourceKind)
    case resolve(SourceKind)
}
public enum RemoteLibraryAccessPolicy {
    public static let productSourceKinds: [SourceKind] = RemoteConnectorCatalog.productSourceKinds

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

public enum RemoteLibraryEntryPointDecision: Equatable {
    case openSheet
    case showPaywall
}

public enum RemoteLibraryGate {
    public static func entryPointDecision(isPro: Bool) -> RemoteLibraryEntryPointDecision {
        switch RemoteLibraryAccessPolicy.decision(for: .openAddFlow, isPro: isPro) {
        case .allow:
            return .openSheet
        case .requiresPro:
            return .showPaywall
        }
    }

    public static func require(_ action: RemoteLibraryAction, isPro: Bool) throws {
        switch RemoteLibraryAccessPolicy.decision(for: action, isPro: isPro) {
        case .allow:
            return
        case .requiresPro(let feature):
            throw ProFeatureAccessError.requiresPro(feature)
        }
    }
}
