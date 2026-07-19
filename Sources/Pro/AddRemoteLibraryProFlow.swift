import Foundation

public enum ProPaywallEntryPoint: String, Equatable {
    case generic
    case addRemoteLibrary
}

public enum RemoteLibraryPostPurchasePresentation: Equatable {
    case none
    case showAddRemoteLibraryCompletion
}

public enum RemoteLibraryPostPurchaseAction: Equatable {
    case addLibraryNow
    case maybeLater
}

public struct RemoteLibraryPostPurchaseOutcome: Equatable {
    public var openLibrariesTab: Bool
    public var openAddServerSheet: Bool

    public init(openLibrariesTab: Bool, openAddServerSheet: Bool) {
        self.openLibrariesTab = openLibrariesTab
        self.openAddServerSheet = openAddServerSheet
    }
}

public enum AddRemoteLibraryProFlow {
    public static func presentationAfterProCompletion(
        entryPoint: ProPaywallEntryPoint,
        didBecomePro: Bool
    ) -> RemoteLibraryPostPurchasePresentation {
        guard didBecomePro, entryPoint == .addRemoteLibrary else { return .none }
        return .showAddRemoteLibraryCompletion
    }

    public static func outcome(for action: RemoteLibraryPostPurchaseAction) -> RemoteLibraryPostPurchaseOutcome {
        switch action {
        case .addLibraryNow:
            return RemoteLibraryPostPurchaseOutcome(openLibrariesTab: true, openAddServerSheet: true)
        case .maybeLater:
            return RemoteLibraryPostPurchaseOutcome(openLibrariesTab: false, openAddServerSheet: false)
        }
    }
}
