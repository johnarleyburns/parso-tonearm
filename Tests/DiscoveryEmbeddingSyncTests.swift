import Testing
@testable import TonearmCore

/// docs/plans/macos-app-cloud-sync-plan.md §4.3/§6 — the three accept/
/// reject/requeue outcomes, pure (no CloudKit needed).
@Suite struct DiscoveryEmbeddingSyncTests {

    @Test func testAcceptsWhenVersionMatchesAndNotYetIndexedLocally() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 1, incomingPreprocessingVersion: 1, incomingSamplingVersion: 1,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: false)
        #expect(decision == .accept)
    }

    @Test func testRejectsAndKeepsLocalWhenAlreadyIndexedEvenIfVersionMatches() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 1, incomingPreprocessingVersion: 1, incomingSamplingVersion: 1,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: true)
        #expect(decision == .rejectKeepLocal)
    }

    @Test func testRejectsAndRequeuesOnModelVersionMismatch() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 2, incomingPreprocessingVersion: 1, incomingSamplingVersion: 1,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: false)
        #expect(decision == .rejectRequeue)
    }

    @Test func testRejectsAndRequeuesOnPreprocessingVersionMismatch() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 1, incomingPreprocessingVersion: 2, incomingSamplingVersion: 1,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: false)
        #expect(decision == .rejectRequeue)
    }

    @Test func testRejectsAndRequeuesOnSamplingVersionMismatch() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 1, incomingPreprocessingVersion: 1, incomingSamplingVersion: 2,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: false)
        #expect(decision == .rejectRequeue)
    }

    /// Version mismatch is checked before the already-indexed check —
    /// requeue must win even if this device happens to already have a
    /// (now-considered-incompatible) local row, since the owner's rule is
    /// "never trust an incompatible vector," not "never touch a track with
    /// any local row."
    @Test func testVersionMismatchTakesPriorityOverAlreadyIndexed() {
        let decision = DiscoveryEmbeddingSyncDecision.decide(
            incomingModelVersion: 2, incomingPreprocessingVersion: 1, incomingSamplingVersion: 1,
            activeModelVersion: 1, activePreprocessingVersion: 1, activeSamplingVersion: 1,
            localEmbeddingExists: true)
        #expect(decision == .rejectRequeue)
    }
}
