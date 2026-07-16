import Foundation

public struct OAuthCredential: Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String?
    public var issuedAt: Date
    public var expiresAt: Date?

    public init(accessToken: String,
         refreshToken: String? = nil,
         issuedAt: Date,
         expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

public struct OAuthTokenState: Equatable, Codable {
    public var credential: OAuthCredential?
    public var refreshInFlight: Bool
    public var revoked: Bool

    public init(credential: OAuthCredential? = nil,
         refreshInFlight: Bool = false,
         revoked: Bool = false) {
        self.credential = credential
        self.refreshInFlight = refreshInFlight
        self.revoked = revoked
    }
}

public enum OAuthTokenStatus: Equatable {
    case missing
    case revoked
    case valid(accessToken: String)
    case expiring(accessToken: String)
    case refreshRequired
    case refreshing
    case offline(refreshRequired: Bool)
}

public enum OAuthRefreshAction: Equatable {
    case none
    case startRefresh(refreshToken: String)
    case waitForInFlight
    case deferUntilOnline
    case requireReauthorization
}

public enum OAuthTokenEvent: Equatable {
    case received(OAuthCredential)
    case refreshStarted
    case refreshSucceeded(OAuthCredential)
    case refreshFailed(OAuthRefreshFailure)
    case unauthorizedResponse
    case signedOut
}

public enum OAuthRefreshFailure: Equatable {
    case offline
    case transient
    case revoked
}

public enum OAuthTokenStateMachine {
    public static let defaultClockSkew: TimeInterval = 60
    public static let defaultRefreshWindow: TimeInterval = 300

    public static func status(_ state: OAuthTokenState,
                       now: Date,
                       networkAvailable: Bool = true,
                       clockSkew: TimeInterval = defaultClockSkew,
                       refreshWindow: TimeInterval = defaultRefreshWindow) -> OAuthTokenStatus {
        guard !state.revoked else { return .revoked }
        guard let credential = state.credential else { return .missing }

        let refreshRequired = requiresRefresh(
            credential,
            now: now,
            clockSkew: clockSkew
        )
        if !networkAvailable {
            return .offline(refreshRequired: refreshRequired)
        }
        if state.refreshInFlight, refreshRequired || isExpiring(credential, now: now, clockSkew: clockSkew, refreshWindow: refreshWindow) {
            return .refreshing
        }
        if refreshRequired {
            return .refreshRequired
        }
        if isExpiring(credential, now: now, clockSkew: clockSkew, refreshWindow: refreshWindow) {
            return .expiring(accessToken: credential.accessToken)
        }
        return .valid(accessToken: credential.accessToken)
    }

    public static func refreshAction(for state: OAuthTokenState,
                              now: Date,
                              networkAvailable: Bool = true,
                              clockSkew: TimeInterval = defaultClockSkew,
                              refreshWindow: TimeInterval = defaultRefreshWindow) -> OAuthRefreshAction {
        switch status(
            state,
            now: now,
            networkAvailable: networkAvailable,
            clockSkew: clockSkew,
            refreshWindow: refreshWindow
        ) {
        case .missing, .revoked:
            return .requireReauthorization
        case .refreshing:
            return .waitForInFlight
        case .offline(let refreshRequired):
            return refreshRequired ? .deferUntilOnline : .none
        case .refreshRequired, .expiring:
            guard let refreshToken = state.credential?.refreshToken, !refreshToken.isEmpty else {
                return .requireReauthorization
            }
            return .startRefresh(refreshToken: refreshToken)
        case .valid:
            return .none
        }
    }

    public static func reduce(_ state: OAuthTokenState, event: OAuthTokenEvent) -> OAuthTokenState {
        var next = state
        switch event {
        case .received(let credential), .refreshSucceeded(let credential):
            next.credential = credential
            next.refreshInFlight = false
            next.revoked = false
        case .refreshStarted:
            next.refreshInFlight = true
        case .refreshFailed(.offline), .refreshFailed(.transient):
            next.refreshInFlight = false
        case .refreshFailed(.revoked), .unauthorizedResponse:
            next.refreshInFlight = false
            next.revoked = true
        case .signedOut:
            next = OAuthTokenState()
        }
        return next
    }

    private static func requiresRefresh(_ credential: OAuthCredential,
                                        now: Date,
                                        clockSkew: TimeInterval) -> Bool {
        guard let expiresAt = credential.expiresAt else { return false }
        return now.addingTimeInterval(clockSkew) >= expiresAt
    }

    private static func isExpiring(_ credential: OAuthCredential,
                                   now: Date,
                                   clockSkew: TimeInterval,
                                   refreshWindow: TimeInterval) -> Bool {
        guard let expiresAt = credential.expiresAt else { return false }
        return now.addingTimeInterval(clockSkew + refreshWindow) >= expiresAt
    }
}
