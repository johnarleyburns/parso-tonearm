import Foundation
import Testing

@testable import TonearmCore

@Suite struct OAuthTokenStateTests {

    @Test func testClockSkewMakesNearExpiredTokenRefreshRequired() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = OAuthTokenState(credential: OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            issuedAt: now.addingTimeInterval(-600),
            expiresAt: now.addingTimeInterval(30)
        ))

        #expect(
            OAuthTokenStateMachine.status(state, now: now, clockSkew: 60, refreshWindow: 300) ==
            .refreshRequired
        )
        #expect(
            OAuthTokenStateMachine.refreshAction(for: state, now: now, clockSkew: 60, refreshWindow: 300) ==
            .startRefresh(refreshToken: "refresh")
        )
    }

    @Test func testExpiringTokenCanStillBeUsedWhileRefreshStarts() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = OAuthTokenState(credential: OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(240)
        ))

        #expect(
            OAuthTokenStateMachine.status(state, now: now, clockSkew: 0, refreshWindow: 300) ==
            .expiring(accessToken: "access")
        )
        #expect(
            OAuthTokenStateMachine.refreshAction(for: state, now: now, clockSkew: 0, refreshWindow: 300) ==
            .startRefresh(refreshToken: "refresh")
        )
    }

    @Test func testRefreshRaceWaitsForInFlightRefresh() {
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

        #expect(OAuthTokenStateMachine.status(state, now: now) == .refreshing)
        #expect(OAuthTokenStateMachine.refreshAction(for: state, now: now) == .waitForInFlight)
    }

    @Test func testRevocationMidRequestRequiresReauthorization() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = OAuthTokenState(credential: OAuthCredential(
            accessToken: "access",
            refreshToken: "refresh",
            issuedAt: now,
            expiresAt: now.addingTimeInterval(3_600)
        ))
        let revoked = OAuthTokenStateMachine.reduce(state, event: .unauthorizedResponse)

        #expect(OAuthTokenStateMachine.status(revoked, now: now) == .revoked)
        #expect(OAuthTokenStateMachine.refreshAction(for: revoked, now: now) == .requireReauthorization)
    }

    @Test func testOfflineDefersOnlyWhenRefreshIsNeeded() {
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

        #expect(
            OAuthTokenStateMachine.status(valid, now: now, networkAvailable: false) ==
            .offline(refreshRequired: false)
        )
        #expect(
            OAuthTokenStateMachine.refreshAction(for: valid, now: now, networkAvailable: false) ==
            .none
        )
        #expect(
            OAuthTokenStateMachine.status(expired, now: now, networkAvailable: false) ==
            .offline(refreshRequired: true)
        )
        #expect(
            OAuthTokenStateMachine.refreshAction(for: expired, now: now, networkAvailable: false) ==
            .deferUntilOnline
        )
    }

    @Test func testNonExpiringTokensStayValid() {
        let now = Date(timeIntervalSince1970: 1_000)
        let state = OAuthTokenState(credential: OAuthCredential(
            accessToken: "pcloud-access",
            issuedAt: now
        ))

        #expect(OAuthTokenStateMachine.status(state, now: now.addingTimeInterval(90_000)) == .valid(accessToken: "pcloud-access"))
        #expect(OAuthTokenStateMachine.refreshAction(for: state, now: now.addingTimeInterval(90_000)) == .none)
    }
}
