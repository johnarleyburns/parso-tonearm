import XCTest
@testable import TonearmCore

final class QueueSectionProjectionTests: XCTestCase {
    private func entry(_ i: Int, _ origin: PlaybackQueueEntry.Origin) -> PlaybackQueueEntry {
        let t = Track(id: Int64(i), albumId: 1, sourceId: 1, title: "T\(i)", trackNo: i, discNo: nil,
                      durationSec: 120, codec: "MP3", sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "\(i)")
        let a = Album(id: 1, sourceId: 1, title: "Album", artist: "Artist")
        let s = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil, title: "S",
                       addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                       licenseText: nil, memberCapHit: false)
        return PlaybackQueueEntry(row: TrackRow(track: t, album: a, source: s, asset: nil), origin: origin)
    }

    private func project(_ origins: [PlaybackQueueEntry.Origin], current: Int = 0) -> QueueSectionProjection {
        QueueSectionProjection(entries: origins.enumerated().map { entry($0.offset, $0.element) },
                               currentIndex: current)
    }

    func testEmptyQueueHasNoSections() {
        let p = project([])
        XCTAssertTrue(p.sections.isEmpty)
        XCTAssertNil(p.currentOffset)
    }

    func testContextOnly() {
        let p = project([.context, .context, .context])
        XCTAssertEqual(p.sections, [.init(kind: .context, offsets: [1, 2])])
    }

    func testManualBeforeContext() {
        let p = project([.context, .listenerNext, .listenerQueued, .context])
        XCTAssertEqual(p.sections.map(\.kind), [.manual, .context])
        XCTAssertEqual(p.sections[0].offsets, [1, 2])
        XCTAssertEqual(p.sections[1].offsets, [3])
    }

    func testKeepPlayingTailAfterContext() {
        let p = project([.context, .context, .keepPlaying(.mixMatched)])
        XCTAssertEqual(p.sections.map(\.kind), [.context, .keepPlaying])
    }

    func testReorderedKeepPlayingStaysKeepPlaying() {
        let p = project([.context, .keepPlaying(.soundSimilar), .context])
        XCTAssertEqual(p.sections.map(\.kind), [.context, .keepPlaying])
        XCTAssertEqual(p.sections[1].offsets, [1])
        XCTAssertEqual(p.sections[0].offsets, [2])
    }

    func testCurrentExcludedEvenIfManual() {
        let p = project([.listenerNext, .context], current: 0)
        XCTAssertEqual(p.currentOffset, 0)
        XCTAssertEqual(p.sections, [.init(kind: .context, offsets: [1])])
        XCTAssertFalse(p.hasManual)
    }

    func testDuplicateTracksGroupedByOccurrence() {
        let dup = entry(1, .listenerQueued)
        let dup2 = PlaybackQueueEntry(row: dup.row, origin: .context)
        let p = QueueSectionProjection(entries: [entry(0, .context), dup, dup2], currentIndex: 0)
        XCTAssertEqual(p.sections.map(\.kind), [.manual, .context])
        XCTAssertEqual(p.sections[0].offsets, [1])
        XCTAssertEqual(p.sections[1].offsets, [2])
    }

    func testViewSourceDeclaresSectionIdentifiers() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/NowPlaying/UpNextView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        for id in ["np.queue.clearManual", "np.keepPlaying.clearAutoAdded",
                   "Added by you", "Playing from", "Keep Playing", ".textCase(.uppercase)"] {
            XCTAssertTrue(src.contains(id), id)
        }
        XCTAssertTrue(src.contains("accessibilityIdentifier"))
        XCTAssertTrue(src.contains("kind.accessibilityIdentifier"))
        XCTAssertTrue(src.contains("projection.hasManual"))
        XCTAssertTrue(src.contains("projection.hasKeepPlaying"))
    }
}
