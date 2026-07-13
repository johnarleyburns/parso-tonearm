import Foundation

struct OAuthCredential: Equatable, Codable {
    var accessToken: String
    var refreshToken: String?
    var issuedAt: Date
    var expiresAt: Date?

    init(accessToken: String,
         refreshToken: String? = nil,
         issuedAt: Date,
         expiresAt: Date? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}

struct OAuthTokenState: Equatable, Codable {
    var credential: OAuthCredential?
    var refreshInFlight: Bool
    var revoked: Bool

    init(credential: OAuthCredential? = nil,
         refreshInFlight: Bool = false,
         revoked: Bool = false) {
        self.credential = credential
        self.refreshInFlight = refreshInFlight
        self.revoked = revoked
    }
}

enum OAuthTokenStatus: Equatable {
    case missing
    case revoked
    case valid(accessToken: String)
    case expiring(accessToken: String)
    case refreshRequired
    case refreshing
    case offline(refreshRequired: Bool)
}

enum OAuthRefreshAction: Equatable {
    case none
    case startRefresh(refreshToken: String)
    case waitForInFlight
    case deferUntilOnline
    case requireReauthorization
}

enum OAuthTokenEvent: Equatable {
    case received(OAuthCredential)
    case refreshStarted
    case refreshSucceeded(OAuthCredential)
    case refreshFailed(OAuthRefreshFailure)
    case unauthorizedResponse
    case signedOut
}

enum OAuthRefreshFailure: Equatable {
    case offline
    case transient
    case revoked
}

enum OAuthTokenStateMachine {
    static let defaultClockSkew: TimeInterval = 60
    static let defaultRefreshWindow: TimeInterval = 300

    static func status(_ state: OAuthTokenState,
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

    static func refreshAction(for state: OAuthTokenState,
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

    static func reduce(_ state: OAuthTokenState, event: OAuthTokenEvent) -> OAuthTokenState {
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
