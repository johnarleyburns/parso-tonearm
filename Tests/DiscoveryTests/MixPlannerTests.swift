import Testing
@testable import TonearmCore
@testable import TonearmDiscovery

@Suite struct MixPlannerTests {
    private func candidate(_ id: Int64, bpm: Double, key: String, artist: String = "A") -> MixCandidate {
        MixCandidate(trackID: id, bpm: bpm, camelot: key, artist: artist, duration: 180)
    }

    @Test func testPlannerIsDeterministicAndRespectsLock() {
        let request = MixRequest(candidates: [
            candidate(1, bpm: 100, key: "8A"), candidate(2, bpm: 104, key: "9A"),
            candidate(3, bpm: 120, key: "10A"), candidate(4, bpm: 126, key: "11A")
        ], lockedFirst: 3, seed: 17)
        let first = MixPlanner.plan(request)
        #expect(first == MixPlanner.plan(request))
        #expect(first.steps.first?.trackID == 3)
    }

    @Test func testExclusionsAndHalfTimeAreStructured() {
        let request = MixRequest(candidates: [
            candidate(1, bpm: 60, key: "8A"), candidate(2, bpm: 120, key: "9A"),
            MixCandidate(trackID: 3, bpm: nil, camelot: "8A"),
            MixCandidate(trackID: 4, bpm: 120, camelot: nil)
        ])
        let plan = MixPlanner.plan(request)
        #expect(plan.excluded.count == 2)
        #expect(plan.steps.dropFirst().allSatisfy { $0.tempoRelation == .keyTempo })
        #expect(Set(plan.steps.map { Int($0.effectiveBPM) }) == Set([120]))
    }

    @Test func testAllTracksUseHighestBPMAsTheKeyTempoReference() {
        let plan = MixPlanner.plan(MixRequest(candidates: [
            candidate(1, bpm: 112, key: "8A"), candidate(2, bpm: 124, key: "9A"),
            candidate(3, bpm: 118, key: "10A")
        ], shape: .risingBPM))
        #expect(plan.steps.allSatisfy { $0.effectiveBPM == 124 })
        #expect(plan.summary.bpmRange == 124...124)
    }

    @Test func testRunnersUpAreValidAndForcedJumpIsExplained() {
        let plan = MixPlanner.plan(MixRequest(candidates: [
            candidate(1, bpm: 100, key: "8A"), candidate(2, bpm: 101, key: "8A"),
            candidate(3, bpm: 160, key: "3B")
        ], seed: 1))
        let ids = Set(plan.request.candidates.map(\.trackID))
        #expect(plan.steps.dropFirst().allSatisfy { step in step.runnersUp.allSatisfy { ids.contains($0.trackID) } })
        #expect(plan.steps.contains { $0.edgeIn?.flags.contains { if case .unavoidable = $0 { return true }; return false } == true })
    }

    @Test func testFiveHundredTracksFinishWithinTwoSeconds() {
        let candidates = (0..<500).map { index in
            candidate(Int64(index), bpm: 90 + Double(index % 70), key: "\((index % 12) + 1)A")
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let plan = MixPlanner.plan(MixRequest(candidates: candidates, seed: 9))
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000

        #expect(plan.steps.count == candidates.count)
        // Keep this as a broad regression guard rather than a machine-specific
        // microbenchmark. Hosted macOS runners have varied enough to exceed a
        // one-second wall-clock limit even when the planner is unchanged.
        #expect(elapsed < 2.0)
    }
}
