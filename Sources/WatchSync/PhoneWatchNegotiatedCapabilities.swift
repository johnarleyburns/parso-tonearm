import Foundation
import TonearmWatchProtocol

/// Background relaunch must not forget the protocol already negotiated with this
/// paired watch. A different watch has a different WCSession watch-directory ID.
public actor PhoneWatchNegotiatedCapabilities {
    private let defaults: UserDefaults
    private let watchIdentifier: @Sendable () -> String?
    private var capabilities: Set<WatchCapability> = []
    private var negotiatedWatchID: String?

    public init(suiteName: String? = nil, watchIdentifier: @escaping @Sendable () -> String? = { nil }) {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.watchIdentifier = watchIdentifier
    }

    public func set(_ capabilities: [WatchCapability]) {
        self.capabilities = Set(capabilities)
        negotiatedWatchID = watchIdentifier()
        if let id = negotiatedWatchID {
            defaults.set(capabilities.map(\.rawValue), forKey: "watch.negotiatedCapabilities." + id)
        }
    }

    public func supports(_ capability: WatchCapability) -> Bool {
        let id = watchIdentifier()
        if id == negotiatedWatchID, capabilities.contains(capability) { return true }
        guard let id else { return false }
        return defaults.stringArray(forKey: "watch.negotiatedCapabilities." + id)?.contains(capability.rawValue) ?? false
    }
}
