import XCTest

@testable import Tonearm

final class OAuthTokenStateTests: XCTestCase {

    func testClockSkewMakesNearExpiredTokenRefreshRequired() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = OAuthTokenState(credential: OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            issuedAt: now.addingTimeInterval(-600),
            expiresAt: now.addingTimeInterval(30)
        ))

        XCTAssertEqual(
            OAuthTokenStateMachine.status(state, now: now, clockSkew: 60, refreshWindow: 300),
            .refreshRequired
        )
        XCTAssertEqual(
            OAuthTokenStateMachine.refreshAction(for: state, now: now, clockSkew: 60, refreshWindow: 300),
            .startRefresh(refreshToken: "refresh")
        )
    }

    func testExpiringTokenCanStillBeUsedWhileRefreshStarts() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = OAuthTokenState(credential: OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(240)
        ))

        XCTAssertEqual(
            OAuthTokenStateMachine.status(state, now: now, clockSkew: 0, refreshWindow: 300),
            .expiring(accessToken: "access")
        )
        XCTAssertEqual(
            OAuthTokenStateMachine.refreshAction(for: state, now: now, clockSkew: 0, refreshWindow: 300),
            .startRefresh(refreshToken: "refresh")
        )
    }

    func testRefreshRaceWaitsForInFlightRefresh() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = OAuthTokenState(
            credential: OAuthCredential(
                accessToken: "access",
                refreshToken: "refresh",
                issuedAt: now,
                expiresAt: now.addingTimeInterval(30)
            ),
            refreshInFlight: true
        )

        XCTAssertEqual(OAuthTokenStateMachine.status(state, now: now), .refreshing)
        XCTAssertEqual(OAuthTokenStateMachine.refreshAction(for: state, now: now), .waitForInFlight)
    }

    func testRevocationMidRequestRequiresReauthorization() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = OAuthTokenState(credential: OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(3_600)
        ))
        let revoked = OAuthTokenStateMachine.reduce(state, event: .unauthorizedResponse)

        XCTAssertEqual(OAuthTokenStateMachine.status(revoked, now: now), .revoked)
        XCTAssertEqual(OAuthTokenStateMachine.refreshAction(for: revoked, now: now), .requireReauthorization)
    }

    func testOfflineDefersOnlyWhenRefreshIsNeeded() {
        let now = Date(timeIntervalSince1970: 1_000)
        let valid = OAuthTokenState(credential: OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(3_600)
        ))
        let expired = OAuthTokenState(credential: OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            issuedAt: now.addingTimeInterval(-7_200),
            expiresAt: now.addingTimeInterval(-60)
        ))

        XCTAssertEqual(
            OAuthTokenStateMachine.status(valid, now: now, networkAvailable: false),
            .offline(refreshRequired: false)
        )
        XCTAssertEqual(
            OAuthTokenStateMachine.refreshAction(for: valid, now: now, networkAvailable: false),
            .none
        )
        XCTAssertEqual(
            OAuthTokenStateMachine.status(expired, now: now, networkAvailable: false),
            .offline(refreshRequired: true)
        )
        XCTAssertEqual(
            OAuthTokenStateMachine.refreshAction(for: expired, now: now, networkAvailable: false),
            .deferUntilOnline
        )
    }

    func testNonExpiringTokensStayValid() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = OAuthTokenState(credential: OAuthCredential(
            accessToken: "pcloud-access",
            issuedAt: now
        ))

        XCTAssertEqual(OAuthTokenStateMachine.status(state, now: now.addingTimeInterval(90_000)), .valid(accessToken: "pcloud-access"))
        XCTAssertEqual(OAuthTokenStateMachine.refreshAction(for: state, now: now.addingTimeInterval(90_000)), .none)
    }
}
