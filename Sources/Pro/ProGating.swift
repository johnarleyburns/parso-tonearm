import Foundation

enum ProGateDecision: Equatable {
    case allow
    case requiresPro(ProFeature)
}

enum ProFeatureAccessError: LocalizedError, Equatable {
    case requiresPro(ProFeature)

    var errorDescription: String? {
        switch self {
        case .requiresPro:
            return "Tonearm Pro is required for this feature."
        }
    }
}

/// Thin entitlement read for Pro capabilities. Product decisions live in the
/// feature-specific pure policy types, not here.
enum ProGating {
    static func isEnabled(_ feature: ProFeature) -> Bool {
        ProFeature.isEnabled(feature)
    }

    static func decision(for feature: ProFeature, isEnabled: Bool = ProEntitlement.isActive) -> ProGateDecision {
        isEnabled ? .allow : .requiresPro(feature)
    }

    static func require(_ feature: ProFeature) throws {
        switch decision(for: feature) {
        case .allow:
            return
        case .requiresPro(let feature):
            throw ProFeatureAccessError.requiresPro(feature)
        }
    }
}
