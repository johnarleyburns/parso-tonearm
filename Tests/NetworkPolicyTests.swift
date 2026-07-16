import XCTest
@testable import TonearmCore

final class NetworkPolicyTests: XCTestCase {
    func testTruthTable() {
        let wifi = false
        let cellular = true
        let rows: [(NetworkPolicy.AssetKind, Bool, Bool, Bool, PlaybackDecision)] = [
            (.local, false, wifi, false, .play),
            (.local, false, wifi, true, .play),
            (.local, false, cellular, false, .play),
            (.local, false, cellular, true, .play),
            (.remote, true, wifi, false, .playFromCache),
            (.remote, true, wifi, true, .playFromCache),
            (.remote, true, cellular, false, .playFromCache),
            (.remote, true, cellular, true, .playFromCache),
            (.remote, false, wifi, false, .play),
            (.remote, false, wifi, true, .play),
            (.remote, false, cellular, false, .skipWiFiOnly),
            (.remote, false, cellular, true, .play)
        ]

        for (kind, cached, expensive, toggle, expected) in rows {
            XCTAssertEqual(NetworkPolicy.decide(
                assetKind: kind,
                isCached: cached,
                pathIsExpensive: expensive,
                streamOnCellular: toggle
            ), expected)
        }
    }

    func testCachedTracksAlwaysPlayRegardlessOfCellularToggle() {
        XCTAssertEqual(NetworkPolicy.decide(
            assetKind: .remote,
            isCached: true,
            pathIsExpensive: true,
            streamOnCellular: false
        ), .playFromCache)
    }

    func testQueueAdvanceSkipsWifiOnlyRows() {
        let decisions: [PlaybackDecision] = [.skipWiFiOnly, .skipWiFiOnly, .play, .skipWiFiOnly]
        let next = NetworkPolicy.nextPlayableIndex(
            after: 0,
            count: decisions.count,
            repeatAll: false,
            decisionAt: { decisions[$0] }
        )
        XCTAssertEqual(next, 2)
    }

    func testQueueAdvanceWrapsWhenRepeatAll() {
        let decisions: [PlaybackDecision] = [.play, .skipWiFiOnly, .skipWiFiOnly]
        let next = NetworkPolicy.nextPlayableIndex(
            after: 2,
            count: decisions.count,
            repeatAll: true,
            decisionAt: { decisions[$0] }
        )
        XCTAssertEqual(next, 0)
    }

    func testQueueAdvanceReturnsNilWhenAllRemainingRowsAreWifiOnly() {
        let decisions: [PlaybackDecision] = [.skipWiFiOnly, .skipWiFiOnly, .skipWiFiOnly]
        let next = NetworkPolicy.nextPlayableIndex(
            after: 0,
            count: decisions.count,
            repeatAll: true,
            decisionAt: { decisions[$0] }
        )
        XCTAssertNil(next)
    }
}
