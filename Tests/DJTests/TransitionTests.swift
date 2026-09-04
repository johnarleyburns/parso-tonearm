import XCTest

@testable import TonearmDJ

/// M5 commit 5.5 — **AT-TRANS-1..5**, each of the five §35B beginner
/// transitions, **layout half only** (plan decision 24, §47.3): a model-level
/// assertion that every control a transition needs is present and reachable
/// on both the tablet (§41.9b) and compact (§42.7c) surfaces.
///
/// **Phase 6d golden-audio re-baseline.** The *audio* half of this suite —
/// scripted EQ-kill / filter-sweep / echo-tail / sharp-crossfader / limiter-
/// ceiling assertions rendered against the offline harness — drove the GPLv3
/// `PerformanceEngine.render()`, deleted in this phase
/// (`parso-audio-engine/docs/phase6-parity.md`, "6d backlog", "6c — carried
/// into 6d" item 2). Per the Phase 6 author decision ("PAE's mixer curves are
/// the reference"), that coverage is **not** re-derived here against PAE: PAE
/// ships the `pd_eq3` RBJ isolator, `pd_filter`, look-ahead `pd_limiter` and
/// its own crossfade-curve math (the adapter's knob→dB EQ curve is fresh, not
/// `ThreeBandEQ.knobToGain` — see `PAEWorkspaceEngine.eqKnobToDB`), and the
/// equivalent goldens already exist and pass against that real DSP in
/// `parso-audio-engine`'s `ParsoDJEngineTests` (Phase 6b, e.g.
/// `isolatorEQKillsByBand`, `limiterCeilingChangeIsHonored`) and this repo's
/// `PAEWorkspaceEngineTests`. Re-deriving Goertzel-band EQ/filter assertions
/// here against the adapter would either duplicate that coverage or, worse,
/// silently re-encode Tonearm's now-deleted curve as the "golden" — which is
/// exactly backwards per the author decision. The layout half below is
/// engine-agnostic (it asserts UI control placement, not DSP) and is
/// unaffected by the cutover.
@MainActor
final class TransitionTests: XCTestCase {

    // MARK: - AT-TRANS-1..5 layout half (§41.9b, §42.7c)

    func testAllFiveTransitionsReachableOnTheTabletSurface() {
        // FR-TRANS-1/2: every control a §35B transition needs is on the §41.9b
        // tablet surface's always-visible club layout — no menu, no mode switch.
        for row in WorkspaceModel.transitionRoleSets {
            XCTAssertTrue(row.roles.isSubset(of: WorkspaceModel.tabletAlwaysVisibleRoles),
                          "\(row.transition)'s controls must be on the tablet's default surface "
                          + "(needs \(row.roles))")
        }
    }

    func testAllFiveTransitionsReachableOnTheCompactSurface() {
        // FR-TRANS-1 on the phone (§42.7c): every transition's controls are
        // reachable — always-visible or in the spring-loaded bank drawer.
        for row in WorkspaceModel.transitionRoleSets {
            XCTAssertTrue(row.roles.isSubset(of: WorkspaceModel.compactReachableRoles),
                          "\(row.transition)'s controls must be reachable on the compact surface "
                          + "(needs \(row.roles))")
        }
    }

    func testEchoOutRequiresNoDrawerOnTheCompactSurface() {
        // §42.7c: Echo Out is a two-control transition — echo on, fader down —
        // so both controls must be reachable without a drawer. The ECHO button
        // and the channel fader are both in the always-visible band.
        let echoOut = WorkspaceModel.transitionRoleSets.first { $0.transition == "Echo Out" }!
        XCTAssertTrue(echoOut.roles.isSubset(of: WorkspaceModel.compactAlwaysVisibleRoles),
                      "Echo Out's controls must both be always-visible on the compact surface "
                      + "(never behind a drawer)")
        XCTAssertTrue(echoOut.roles.contains(.echo))
        XCTAssertTrue(echoOut.roles.contains(.channelFader))
    }

    func testBassSwapUsesTheSpringLoadedEQDrawerOnCompact() {
        // §42.7c: the drawer's spring-loading is what makes Bass Swap
        // performable on a phone — press, kill the low, release, drawer gone.
        let bassSwap = WorkspaceModel.transitionRoleSets.first { $0.transition == "Bass Swap" }!
        XCTAssertTrue(bassSwap.roles.contains(.lowEQ))
        XCTAssertTrue(WorkspaceModel.compactDrawerRoles.contains(.lowEQ),
                      "the compact LOW EQ lives in the momentary bank drawer")
        XCTAssertTrue(bassSwap.roles.isSubset(of: WorkspaceModel.compactReachableRoles))
    }

    func testFaderCutAndEchoControlsMeetTheMinimumTarget() {
        // NFR-A11Y-6: no target shrunk to fit. The transferable-core controls
        // every transition reaches are ≥ 44 pt on both surfaces — the club
        // geometry asserts the transport/strip sizes; here the echo surface and
        // the crossfader band pin the minimum.
        XCTAssertGreaterThanOrEqual(WorkspaceModel.crossfaderBarHeight, 44,
                                    "the compact always-visible band is ≥ 44 pt")
        XCTAssertGreaterThanOrEqual(WorkspaceModel.DrawerGeometry.tapThreshold, 0.1)
    }
}
