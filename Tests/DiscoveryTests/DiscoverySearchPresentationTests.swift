#if !os(watchOS)
import ParsoAudioNeural
import Testing

@testable import TonearmCore
@testable import TonearmDiscovery

/// Exhaustive, SwiftUI-free coverage of the pure
/// `DiscoverySearchResponse` → `DiscoverySearchScreenState` mapping and the
/// score-detail component list (plan §10.1 / §9: "Map every distinct response
/// state to distinct UI").
@Suite struct DiscoverySearchPresentationTests {

    private func response(
        mode: DiscoverySearchMode,
        state: DiscoverySearchResponse.State,
        results: [DiscoverySearchResult] = [],
        coverage: SearchRepository.Coverage? = nil
    ) -> DiscoverySearchResponse {
        DiscoverySearchResponse(
            mode: mode, state: state, results: results, coverage: coverage,
            indexGeneration: nil, latencyMillis: 1)
    }

    private func coverage(_ state: SearchRepository.Coverage.State) -> SearchRepository.Coverage {
        SearchRepository.Coverage(
            state: state, totalInScope: 10, indexed: 3, awaitingIndex: 7, waitingForAssets: 0,
            failedOrUnsupported: 0, matchingHardFilters: nil)
    }

    private func result(id: Int64 = 1) -> DiscoverySearchResult {
        let track = Track(
            id: id, albumId: nil, sourceId: 1, title: "t", trackNo: nil, discNo: nil,
            durationSec: 100, codec: "wav", sampleRate: 44_100, bitDepthOrBitrate: nil, sortKey: "t")
        return DiscoverySearchResult(
            track: TrackRow(track: track, album: nil, source: nil, asset: nil),
            similarity: 0.42,
            finalScore: 0.6,
            breakdown: RankBreakdown(
                semantic: 0.42, bpm: 0.5, key: 0.9, energy: 0.5, phrase: 0.5, fused: 0.6))
    }

    // MARK: - Every response state maps to a distinct screen state

    @Test func testReadySemanticIsSemanticResults() {
        let s = DiscoverySearchPresentation.make(
            from: response(mode: .semantic, state: .ready, results: [result()]))
        #expect(s == .results(kind: .semantic, count: 1, stillIndexing: false))
        #expect(s.hasResults)
    }

    @Test func testReadyFilterOnlyIsFilterOnlyResults() {
        let s = DiscoverySearchPresentation.make(
            from: response(mode: .filterOnly, state: .ready, results: [result(), result(id: 2)]))
        #expect(s == .results(kind: .filterOnly, count: 2, stillIndexing: false))
    }

    @Test func testReadyMetadataBrowseIsBrowseResults() {
        let s = DiscoverySearchPresentation.make(
            from: response(mode: .metadataBrowse, state: .ready, results: [result()]))
        #expect(s == .results(kind: .metadataBrowse, count: 1, stillIndexing: false))
        #expect(!DiscoverySearchResultKind.metadataBrowse.showsSemanticScore)
        #expect(DiscoverySearchResultKind.semantic.showsSemanticScore)
    }

    @Test func testReadyWithIndexingInProgressCoverageFlagsStillIndexing() {
        let s = DiscoverySearchPresentation.make(
            from: response(
                mode: .semantic, state: .ready, results: [result()],
                coverage: coverage(.indexingInProgress)))
        #expect(s == .results(kind: .semantic, count: 1, stillIndexing: true))
    }

    @Test func testNoMatchesCarriesKind() {
        #expect(
            DiscoverySearchPresentation.make(from: response(mode: .filterOnly, state: .noMatches)) ==
            .noMatches(kind: .filterOnly))
    }

    @Test func testValidationErrorCarriesIssues() {
        let issues: [QueryValidationIssue] = [.bpmReversed(min: 140, max: 120), .invalidKeyCode("ZZ")]
        #expect(
            DiscoverySearchPresentation.make(
                from: response(mode: .semantic, state: .validationFailed(issues))) ==
            .validationError(issues))
    }

    @Test func testEmptyLibraryEmptyScopeSourceUnavailableAreDistinct() {
        #expect(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .emptyLibrary)) ==
            .emptyLibrary)
        #expect(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .emptyScope)) ==
            .emptyScope)
        #expect(
            DiscoverySearchPresentation.make(
                from: response(mode: .semantic, state: .sourceUnavailable)) ==
            .sourceUnavailable)
    }

    @Test func testZeroIndexedIsItsOwnState() {
        #expect(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .zeroIndexed)) ==
            .zeroIndexed)
    }

    @Test func testModelMissingAndDownloadFailedAreDistinct() {
        #expect(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .modelMissing)) ==
            .modelMissing)
        #expect(
            DiscoverySearchPresentation.make(
                from: response(mode: .semantic, state: .modelDownloadFailed)) ==
            .modelDownloadFailed)
    }

    @Test func testUnindexedReferenceBecomesAnalyzeWithTheReferenceID() {
        let s = DiscoverySearchPresentation.make(
            from: response(mode: .similar(referenceTrackID: 77), state: .unindexedReference))
        #expect(s == .analyzeReference(trackID: 77))
    }

    @Test func testMatchingReferenceUnavailableHasItsOwnState() {
        #expect(
            DiscoverySearchPresentation.make(
                from: response(mode: .semantic, state: .matchingReferenceUnavailable)) ==
            .matchingReferenceUnavailable)
    }

    @Test func testSearchFailedIsRetryableFailureNotNoMatches() {
        #expect(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .searchFailed)) ==
            .searchFailed)
    }

    @Test func testCancelledBecomesStaleSuppressed() {
        #expect(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .cancelled)) ==
            .staleSuppressed)
    }

    @Test func testIndexingInProgressTerminalStateMapsToPartialResults() {
        let s = DiscoverySearchPresentation.make(
            from: response(mode: .semantic, state: .indexingInProgress))
        #expect(s == .results(kind: .semantic, count: 0, stillIndexing: true))
    }

    // MARK: - Score-detail components

    @Test func testScoreComponentsListRawSimilarityAndAllFitComponents() {
        let comps = RankBreakdownDisplay.components(for: result())
        let labels = comps.map(\.label)
        #expect(labels == ["similarity", "tempo fit", "key fit", "energy fit", "phrase fit", "match score"])
        #expect(comps.first { $0.label == "similarity" }?.formattedValue == "0.42")
        #expect(comps.first { $0.label == "key fit" }?.formattedValue == "0.90")
        // Never a percent / "confident" phrasing.
        for c in comps {
            #expect(!c.formattedValue.contains("%"))
        }
    }

    @Test func testScoreComponentsEmptyForFilterOnlyRow() {
        let track = Track(
            id: 5, albumId: nil, sourceId: 1, title: "t", trackNo: nil, discNo: nil,
            durationSec: 1, codec: "wav", sampleRate: 44_100, bitDepthOrBitrate: nil, sortKey: "t")
        let row = DiscoverySearchResult(
            track: TrackRow(track: track, album: nil, source: nil, asset: nil),
            similarity: nil, finalScore: nil, breakdown: nil)
        #expect(RankBreakdownDisplay.components(for: row).isEmpty)
    }

    @Test func testScoreComponentsToleratesNonFiniteValues() {
        let track = Track(
            id: 6, albumId: nil, sourceId: 1, title: "t", trackNo: nil, discNo: nil,
            durationSec: 1, codec: "wav", sampleRate: 44_100, bitDepthOrBitrate: nil, sortKey: "t")
        let row = DiscoverySearchResult(
            track: TrackRow(track: track, album: nil, source: nil, asset: nil),
            similarity: .nan,
            finalScore: .infinity,
            breakdown: RankBreakdown(
                semantic: .nan, bpm: .nan, key: .nan, energy: .nan, phrase: .nan, fused: .infinity))
        for c in RankBreakdownDisplay.components(for: row) {
            #expect(c.value.isFinite)
        }
    }
}
#endif
