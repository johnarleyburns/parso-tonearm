import XCTest
@testable import TonearmCore
@testable import TonearmDiscovery

/// Build a Mix's mixing rules: ±8% BPM between neighbours, and keys that are the same, ±1 on the
/// Camelot wheel with the same letter, or the same number with the other letter.
final class MixCompatibilityTests: XCTestCase {
    func testKeyRule() {
        for ok in ["8A", "7A", "9A", "8B"] { XCTAssertTrue(MixCompatibility.keysCompatible("8A", ok), ok) }
        for no in ["10A", "6A", "7B", "9B", "3A", "x", ""] { XCTAssertFalse(MixCompatibility.keysCompatible("8A", no), no) }
        XCTAssertTrue(MixCompatibility.keysCompatible("12A", "1A"), "the wheel wraps")
        XCTAssertTrue(MixCompatibility.keysCompatible("1b", " 12B "))
    }

    func testBPMRule() {
        let rules = MixCompatibility.standard
        XCTAssertTrue(rules.bpmCompatible(100, 108))
        XCTAssertTrue(rules.bpmCompatible(100, 92))
        XCTAssertFalse(rules.bpmCompatible(100, 108.5))
        XCTAssertFalse(rules.bpmCompatible(100, 91))
        XCTAssertFalse(rules.bpmCompatible(0, 100))
    }

    func testChainObeysTheRulesAndReachesTheLengthFromTheBundledLibrary() {
        let candidates = BuiltInMoodIndexProvider.tracks.enumerated().compactMap { index, track -> MixCandidate? in
            guard track.hasMusicalAnalysis else { return nil }
            return MixCandidate(trackID: Int64(index), bpm: track.bpm, camelot: track.key, energy: track.energy,
                                artist: track.artist, duration: track.durationSec)
        }
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.trackID, $0) })
        var firsts = Set<Int64>()
        for seed in UInt64(1)...6 {
            for minutes in [15.0, 30, 60] {
                let plan = MixPlanner.plan(MixRequest(candidates: candidates, shape: .steady, targetDuration: minutes * 60,
                                                      seed: seed, compatibility: .standard))
                let tracks = plan.steps.compactMap { byID[$0.trackID] }
                XCTAssertFalse(tracks.isEmpty)
                for (a, b) in zip(tracks, tracks.dropFirst()) {
                    XCTAssertTrue(MixCompatibility.standard.bpmCompatible(a.bpm!, b.bpm!), "\(a.bpm!) → \(b.bpm!)")
                    XCTAssertTrue(MixCompatibility.keysCompatible(a.camelot!, b.camelot!), "\(a.camelot!) → \(b.camelot!)")
                }
                let length = tracks.reduce(0) { $0 + $1.duration } / 60
                XCTAssertGreaterThanOrEqual(length, minutes * 0.9, "seed \(seed): \(minutes) min mix is \(length) min")
                XCTAssertLessThanOrEqual(length, minutes * 1.1)
                for step in plan.steps.dropFirst() {
                    for runner in step.runnersUp {
                        let previous = byID[plan.steps[step.position - 1].trackID]!
                        let candidate = byID[runner.trackID]!
                        XCTAssertTrue(MixCompatibility.standard.bpmCompatible(previous.bpm!, candidate.bpm!)
                                      && MixCompatibility.keysCompatible(previous.camelot!, candidate.camelot!),
                                      "a Swap suggestion must obey the rules too")
                    }
                }
                if minutes == 30 { firsts.insert(plan.steps[0].trackID) }
            }
        }
        XCTAssertGreaterThan(firsts.count, 3, "the first track is random per seed")
    }

    func testLockedFirstTrackStartsTheChain() {
        let candidates = (0..<40).map { MixCandidate(trackID: Int64($0), bpm: 120 + Double($0 % 5), camelot: "\($0 % 3 + 7)A", duration: 200) }
        let plan = MixPlanner.plan(MixRequest(candidates: candidates, targetDuration: 1_200, lockedFirst: 17,
                                              compatibility: .standard))
        XCTAssertEqual(plan.steps.first?.trackID, 17)
    }
}
