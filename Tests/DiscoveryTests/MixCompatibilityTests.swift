import Testing
@testable import TonearmCore
@testable import TonearmDiscovery

/// Build a Mix's mixing rules: ±8% BPM between neighbours, and keys that are the same, ±1 on the
/// Camelot wheel with the same letter, or the same number with the other letter.
@Suite struct MixCompatibilityTests {
    @Test func testKeyRule() {
        for ok in ["8A", "7A", "9A", "8B"] { #expect(MixCompatibility.keysCompatible("8A", ok), "\(ok)") }
        for no in ["10A", "6A", "7B", "9B", "3A", "x", ""] { #expect(!MixCompatibility.keysCompatible("8A", no), "\(no)") }
        #expect(MixCompatibility.keysCompatible("12A", "1A"), "the wheel wraps")
        #expect(MixCompatibility.keysCompatible("1b", " 12B "))
    }

    @Test func testBPMRule() {
        let rules = MixCompatibility.standard
        #expect(rules.bpmCompatible(100, 108))
        #expect(rules.bpmCompatible(100, 92))
        #expect(!rules.bpmCompatible(100, 108.5))
        #expect(!rules.bpmCompatible(100, 91))
        #expect(!rules.bpmCompatible(0, 100))
    }

    /// Same BPM and Camelot key for every candidate makes every pair trivially rule-compatible
    /// by construction (no risk of an incompatible pair breaking the chain regardless of how the
    /// planner walks the pool) — varying only duration/artist, exactly what's needed to exercise
    /// "reaches the target length" and "the first track is random per seed" without depending on
    /// real, bundled library data (the Jamendo starter pack this previously read from no longer
    /// exists; on-device indexing of the user's own library is the sole source now).
    @Test func testChainObeysTheRulesAndReachesTheLength() throws {
        let candidates = (0..<300).map { index in
            MixCandidate(trackID: Int64(index), bpm: 120, camelot: "8A", energy: nil,
                        artist: "Artist \(index % 40)", duration: 180 + Double(index % 60))
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.trackID, $0) })
        var firsts = Set<Int64>()
        for seed in UInt64(1)...6 {
            for minutes in [15.0, 30, 60] {
                let plan = MixPlanner.plan(MixRequest(candidates: candidates, shape: .steady, targetDuration: minutes * 60,
                                                      seed: seed, compatibility: .standard))
                let tracks = plan.steps.compactMap { byID[$0.trackID] }
                #expect(!tracks.isEmpty)
                for (a, b) in zip(tracks, tracks.dropFirst()) {
                    #expect(MixCompatibility.standard.bpmCompatible(a.bpm!, b.bpm!), "\(a.bpm!) → \(b.bpm!)")
                    #expect(MixCompatibility.keysCompatible(a.camelot!, b.camelot!), "\(a.camelot!) → \(b.camelot!)")
                }
                let length = tracks.reduce(0) { $0 + $1.duration } / 60
                #expect(length >= minutes * 0.9, "seed \(seed): \(minutes) min mix is \(length) min")
                #expect(length <= minutes * 1.1)
                for step in plan.steps.dropFirst() {
                    for runner in step.runnersUp {
                        let previous = byID[plan.steps[step.position - 1].trackID]!
                        let candidate = byID[runner.trackID]!
                        #expect(MixCompatibility.standard.bpmCompatible(previous.bpm!, candidate.bpm!)
                                      && MixCompatibility.keysCompatible(previous.camelot!, candidate.camelot!),
                                      "a Swap suggestion must obey the rules too")
                    }
                }
                if minutes == 30 { firsts.insert(plan.steps[0].trackID) }
            }
        }
        #expect(firsts.count > 3, "the first track is random per seed")
    }

    @Test func testLockedFirstTrackStartsTheChain() {
        let candidates = (0..<40).map { MixCandidate(trackID: Int64($0), bpm: 120 + Double($0 % 5), camelot: "\($0 % 3 + 7)A", duration: 200) }
        let plan = MixPlanner.plan(MixRequest(candidates: candidates, targetDuration: 1_200, lockedFirst: 17,
                                              compatibility: .standard))
        #expect(plan.steps.first?.trackID == 17)
    }
}
