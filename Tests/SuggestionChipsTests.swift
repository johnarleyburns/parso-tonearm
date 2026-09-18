import GRDB
import XCTest

@testable import TonearmCore

/// Regression coverage for `SuggestionChips`/`LibraryDescriptorSummary`
/// (`Sources/Domain/SuggestionChips.swift`), extracted from the deleted
/// `Sources/DJ/Features/VibeSearch/VibeSearchModel.swift` — see
/// docs/plans/mood-based-listening-plan.md §2/§5 step 2. The logic itself
/// is unchanged from the original (now-deleted) `SearchModelTests.swift`
/// coverage, just testing the standalone utility directly instead of
/// through the deleted `VibeSearchModel`.
final class SuggestionChipsTests: XCTestCase {
    func testChipsReflectTheLibraryDistribution() async throws {
        let library = try LibraryStore(inMemory: true)
        for i in 0..<4 {
            try await seedLibraryTrack(in: library, title: "Track \(i)",
                                       bpm: 124 + Double(i % 2), camelot: "9A",
                                       energy: 8, durationSec: 300)
        }
        let summary = await SuggestionChips.summary(library: library)
        let chips = SuggestionChips.seed(from: summary)
        XCTAssertEqual(chips, ["steady around 125 BPM", "in 9A", "high energy"],
                       "chips are seeded from the library's median tempo, dominant key and energy")
    }

    func testEmptyLibraryYieldsNoChips() async throws {
        let library = try LibraryStore(inMemory: true)
        let summary = await SuggestionChips.summary(library: library)
        XCTAssertTrue(SuggestionChips.seed(from: summary).isEmpty)
    }

    func testDurationExtremesProduceLengthChips() {
        let short = LibraryDescriptorSummary(durationSec: [120, 150])
        XCTAssertEqual(SuggestionChips.seed(from: short), ["shorter tracks"])

        let long = LibraryDescriptorSummary(durationSec: [360, 400])
        XCTAssertEqual(SuggestionChips.seed(from: long), ["long-form tracks"])
    }

    func testLimitCapsTheReturnedChipCount() {
        let summary = LibraryDescriptorSummary(
            bpm: [124], energy: [8], durationSec: [120], camelotCounts: ["9A": 1])
        XCTAssertEqual(SuggestionChips.seed(from: summary, limit: 2).count, 2)
    }

    // MARK: - Fixture

    private func seedLibraryTrack(in library: LibraryStore, title: String,
                                  bpm: Double? = nil, camelot: String? = nil,
                                  energy: Double? = nil,
                                  durationSec: Double? = nil) async throws {
        let source = try await library.insertSource(Source(
            id: nil, kind: .local, iaIdentifier: nil, originalURL: nil, title: "Fixture",
            addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
            licenseText: nil, memberCapHit: false))
        let track = try await library.insertTrack(Track(
            id: nil, albumId: nil, sourceId: source.id!, title: title, trackNo: nil,
            discNo: nil, durationSec: durationSec, codec: "WAV", sampleRate: 44_100,
            bitDepthOrBitrate: nil, sortKey: title))
        let asset = try await library.insertAsset(Asset(
            id: nil, trackId: track.id!, kind: .localRef, bookmark: nil,
            relPath: "\(title).wav", remoteURL: nil, altRemoteURL: nil,
            sizeBytes: nil, unsupportedReason: nil))
        let writer = await library.dbQueue
        try await writer.write { db in
            // analysisVersion is not filtered by SuggestionChips.summary's
            // query (a plain LEFT JOIN on trackId) — any value is fine here.
            var row = DiscoveryTrackAnalysis(
                trackId: track.id!, assetId: asset.id!, assetRevision: 1,
                analysisVersion: 1,
                bpm: bpm, key: camelot, energy: energy, phraseSummary: nil,
                analysisScopeSeconds: nil, completedAt: Date())
            try row.upsert(db)
        }
    }
}
