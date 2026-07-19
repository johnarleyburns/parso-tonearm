import Foundation

public enum ProGateDecision: Equatable {
    case allow
    case requiresPro(ProFeature)
}

public enum ProFeatureAccessError: LocalizedError, Equatable {
    case requiresPro(ProFeature)

    public var errorDescription: String? {
        switch self {
        case .requiresPro:
            return "Platterhead Pro is required for this feature."
        }
    }
}

/// Thin entitlement read for Pro capabilities. Product decisions live in the
/// feature-specific pure policy types, not here.
public enum ProGating {
    public static func isEnabled(_ feature: ProFeature) -> Bool {
        ProFeature.isEnabled(feature)
    }

    public static func decision(for feature: ProFeature, isEnabled: Bool = ProEntitlement.isActive) -> ProGateDecision {
        isEnabled ? .allow : .requiresPro(feature)
    }

    public static func require(_ feature: ProFeature) throws {
        switch decision(for: feature) {
        case .allow:
            return
        case .requiresPro(let feature):
            throw ProFeatureAccessError.requiresPro(feature)
        }
    }
}
