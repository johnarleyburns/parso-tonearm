import XCTest
@testable import TonearmCore
@testable import TonearmDiscovery

final class MixPlannerTests: XCTestCase {
    private func candidate(_ id: Int64, bpm: Double, key: String, artist: String = "A") -> MixCandidate {
        MixCandidate(trackID: id, bpm: bpm, camelot: key, artist: artist, duration: 180)
    }

    func testPlannerIsDeterministicAndRespectsLock() {
        let request = MixRequest(candidates: [
            candidate(1, bpm: 100, key: "8A"), candidate(2, bpm: 104, key: "9A"),
            candidate(3, bpm: 120, key: "10A"), candidate(4, bpm: 126, key: "11A")
        ], lockedFirst: 3, seed: 17)
        let first = MixPlanner.plan(request)
        XCTAssertEqual(first, MixPlanner.plan(request))
        XCTAssertEqual(first.steps.first?.trackID, 3)
    }

    func testExclusionsAndHalfTimeAreStructured() {
        let request = MixRequest(candidates: [
            candidate(1, bpm: 60, key: "8A"), candidate(2, bpm: 120, key: "9A"),
            MixCandidate(trackID: 3, bpm: nil, camelot: "8A"),
            MixCandidate(trackID: 4, bpm: 120, camelot: nil)
        ])
        let plan = MixPlanner.plan(request)
        XCTAssertEqual(plan.excluded.count, 2)
        XCTAssertTrue(plan.steps.contains { $0.tempoRelation == .doubleTime || $0.tempoRelation == .halfTime })
    }

    func testRunnersUpAreValidAndForcedJumpIsExplained() {
        let plan = MixPlanner.plan(MixRequest(candidates: [
            candidate(1, bpm: 100, key: "8A"), candidate(2, bpm: 101, key: "8A"),
            candidate(3, bpm: 160, key: "3B")
        ], seed: 1))
        let ids = Set(plan.request.candidates.map(\.trackID))
        XCTAssertTrue(plan.steps.dropFirst().allSatisfy { step in step.runnersUp.allSatisfy { ids.contains($0.trackID) } })
        XCTAssertTrue(plan.steps.contains { $0.edgeIn?.flags.contains { if case .unavoidable = $0 { return true }; return false } == true })
    }

    func testFiveHundredTracksFinishWithinOneSecond() {
        let candidates = (0..<500).map { index in
            candidate(Int64(index), bpm: 90 + Double(index % 70), key: "\((index % 12) + 1)A")
        }
        let start = Date()
        _ = MixPlanner.plan(MixRequest(candidates: candidates, seed: 9))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
