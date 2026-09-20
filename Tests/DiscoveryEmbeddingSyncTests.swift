import XCTest
@testable import TonearmCore

/// docs/plans/macos-app-cloud-sync-plan.md §4.3/§6 — the three accept/
/// reject/requeue outcomes, pure (no CloudKit needed).
final class DiscoveryEmbeddingSyncTests: XCTestCase {

    func testAcceptsWhenVersionMatchesAndNotYetIndexedLocally() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 1, incomingPreprocessingVersion: 1, incomingSamplingVersion: 1,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: false)
        XCTAssertEqual(decision, .accept)
    }

    func testRejectsAndKeepsLocalWhenAlreadyIndexedEvenIfVersionMatches() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 1, incomingPreprocessingVersion: 1, incomingSamplingVersion: 1,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: true)
        XCTAssertEqual(decision, .rejectKeepLocal)
    }

    func testRejectsAndRequeuesOnModelVersionMismatch() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 2, incomingPreprocessingVersion: 1, incomingSamplingVersion: 1,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: false)
        XCTAssertEqual(decision, .rejectRequeue)
    }

    func testRejectsAndRequeuesOnPreprocessingVersionMismatch() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 1, incomingPreprocessingVersion: 2, incomingSamplingVersion: 1,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: false)
        XCTAssertEqual(decision, .rejectRequeue)
    }

    func testRejectsAndRequeuesOnSamplingVersionMismatch() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 1, incomingPreprocessingVersion: 1, incomingSamplingVersion: 2,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: false)
        XCTAssertEqual(decision, .rejectRequeue)
    }

    /// Version mismatch is checked before the already-indexed check —
    /// requeue must win even if this device happens to already have a
    /// (now-considered-incompatible) local row, since the owner's rule is
    /// "never trust an incompatible vector," not "never touch a track with
    /// any local row."
    func testVersionMismatchTakesPriorityOverAlreadyIndexed() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 2, incomingPreprocessingVersion: 1, incomingSamplingVersion: 1,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: true)
        XCTAssertEqual(decision, .rejectRequeue)
    }
}
