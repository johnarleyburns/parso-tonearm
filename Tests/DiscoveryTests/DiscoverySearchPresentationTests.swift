#if !os(watchOS)
import ParsoAudioNeural
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// Exhaustive, SwiftUI-free coverage of the pure
/// `DiscoverySearchResponse` → `DiscoverySearchScreenState` mapping and the
/// score-detail component list (plan §10.1 / §9: "Map every distinct response
/// state to distinct UI").
final class DiscoverySearchPresentationTests: XCTestCase {

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

    func testReadySemanticIsSemanticResults() {
        let s = DiscoverySearchPresentation.make(
            from: response(mode: .semantic, state: .ready, results: [result()]))
        XCTAssertEqual(s, .results(kind: .semantic, count: 1, stillIndexing: false))
        XCTAssertTrue(s.hasResults)
    }

    func testReadyFilterOnlyIsFilterOnlyResults() {
        let s = DiscoverySearchPresentation.make(
            from: response(mode: .filterOnly, state: .ready, results: [result(), result(id: 2)]))
        XCTAssertEqual(s, .results(kind: .filterOnly, count: 2, stillIndexing: false))
    }

    func testReadyMetadataBrowseIsBrowseResults() {
        let s = DiscoverySearchPresentation.make(
            from: response(mode: .metadataBrowse, state: .ready, results: [result()]))
        XCTAssertEqual(s, .results(kind: .metadataBrowse, count: 1, stillIndexing: false))
        XCTAssertFalse(DiscoverySearchResultKind.metadataBrowse.showsSemanticScore)
        XCTAssertTrue(DiscoverySearchResultKind.semantic.showsSemanticScore)
    }

    func testReadyWithIndexingInProgressCoverageFlagsStillIndexing() {
        let s = DiscoverySearchPresentation.make(
            from: response(
                mode: .semantic, state: .ready, results: [result()],
                coverage: coverage(.indexingInProgress)))
        XCTAssertEqual(s, .results(kind: .semantic, count: 1, stillIndexing: true))
    }

    func testNoMatchesCarriesKind() {
        XCTAssertEqual(
            DiscoverySearchPresentation.make(from: response(mode: .filterOnly, state: .noMatches)),
            .noMatches(kind: .filterOnly))
    }

    func testValidationErrorCarriesIssues() {
        let issues: [QueryValidationIssue] = [.bpmReversed(min: 140, max: 120), .invalidKeyCode("ZZ")]
        XCTAssertEqual(
            DiscoverySearchPresentation.make(
                from: response(mode: .semantic, state: .validationFailed(issues))),
            .validationError(issues))
    }

    func testEmptyLibraryEmptyScopeSourceUnavailableAreDistinct() {
        XCTAssertEqual(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .emptyLibrary)),
            .emptyLibrary)
        XCTAssertEqual(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .emptyScope)),
            .emptyScope)
        XCTAssertEqual(
            DiscoverySearchPresentation.make(
                from: response(mode: .semantic, state: .sourceUnavailable)),
            .sourceUnavailable)
    }

    func testZeroIndexedIsItsOwnState() {
        XCTAssertEqual(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .zeroIndexed)),
            .zeroIndexed)
    }

    func testModelMissingAndDownloadFailedAreDistinct() {
        XCTAssertEqual(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .modelMissing)),
            .modelMissing)
        XCTAssertEqual(
            DiscoverySearchPresentation.make(
                from: response(mode: .semantic, state: .modelDownloadFailed)),
            .modelDownloadFailed)
    }

    func testUnindexedReferenceBecomesAnalyzeWithTheReferenceID() {
        let s = DiscoverySearchPresentation.make(
            from: response(mode: .similar(referenceTrackID: 77), state: .unindexedReference))
        XCTAssertEqual(s, .analyzeReference(trackID: 77))
    }

    func testMatchingReferenceUnavailableHasItsOwnState() {
        XCTAssertEqual(
            DiscoverySearchPresentation.make(
                from: response(mode: .semantic, state: .matchingReferenceUnavailable)),
            .matchingReferenceUnavailable)
    }

    func testSearchFailedIsRetryableFailureNotNoMatches() {
        XCTAssertEqual(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .searchFailed)),
            .searchFailed)
    }

    func testCancelledBecomesStaleSuppressed() {
        XCTAssertEqual(
            DiscoverySearchPresentation.make(from: response(mode: .semantic, state: .cancelled)),
            .staleSuppressed)
    }

    func testIndexingInProgressTerminalStateMapsToPartialResults() {
        let s = DiscoverySearchPresentation.make(
            from: response(mode: .semantic, state: .indexingInProgress))
        XCTAssertEqual(s, .results(kind: .semantic, count: 0, stillIndexing: true))
    }

    // MARK: - Score-detail components

    func testScoreComponentsListRawSimilarityAndAllFitComponents() {
        let comps = RankBreakdownDisplay.components(for: result())
        let labels = comps.map(\.label)
        XCTAssertEqual(labels, ["similarity", "tempo fit", "key fit", "energy fit", "phrase fit", "match score"])
        XCTAssertEqual(comps.first { $0.label == "similarity" }?.formattedValue, "0.42")
        XCTAssertEqual(comps.first { $0.label == "key fit" }?.formattedValue, "0.90")
        // Never a percent / "confident" phrasing.
        for c in comps {
            XCTAssertFalse(c.formattedValue.contains("%"))
        }
    }

    func testScoreComponentsEmptyForFilterOnlyRow() {
        let track = Track(
            id: 5, albumId: nil, sourceId: 1, title: "t", trackNo: nil, discNo: nil,
            durationSec: 1, codec: "wav", sampleRate: 44_100, bitDepthOrBitrate: nil, sortKey: "t")
        let row = DiscoverySearchResult(
            track: TrackRow(track: track, album: nil, source: nil, asset: nil),
            similarity: nil, finalScore: nil, breakdown: nil)
        XCTAssertTrue(RankBreakdownDisplay.components(for: row).isEmpty)
    }

    func testScoreComponentsToleratesNonFiniteValues() {
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
            XCTAssertTrue(c.value.isFinite)
        }
    }
}
#endif
