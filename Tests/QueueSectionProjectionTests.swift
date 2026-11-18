import Testing
@testable import TonearmCore

@Suite struct QueueSectionProjectionTests {
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

    @Test func testEmptyQueueHasNoSections() {
        let p = project([])
        #expect(p.sections.isEmpty)
        #expect(p.currentOffset == nil)
    }

    @Test func testContextOnly() {
        let p = project([.context, .context, .context])
        #expect(p.sections == [.init(kind: .context, offsets: [1, 2])])
    }

    @Test func testManualBeforeContext() {
        let p = project([.context, .listenerNext, .listenerQueued, .context])
        #expect(p.sections.map(\.kind) == [.manual, .context])
        #expect(p.sections[0].offsets == [1, 2])
        #expect(p.sections[1].offsets == [3])
    }

    @Test func testKeepPlayingTailAfterContext() {
        let p = project([.context, .context, .keepPlaying(.mixMatched)])
        #expect(p.sections.map(\.kind) == [.context, .keepPlaying])
    }

    @Test func testReorderedKeepPlayingStaysKeepPlaying() {
        let p = project([.context, .keepPlaying(.soundSimilar), .context])
        #expect(p.sections.map(\.kind) == [.context, .keepPlaying])
        #expect(p.sections[1].offsets == [1])
        #expect(p.sections[0].offsets == [2])
    }

    @Test func testCurrentExcludedEvenIfManual() {
        let p = project([.listenerNext, .context], current: 0)
        #expect(p.currentOffset == 0)
        #expect(p.sections == [.init(kind: .context, offsets: [1])])
        #expect(!p.hasManual)
    }

    @Test func testDuplicateTracksGroupedByOccurrence() {
        let dup = entry(1, .listenerQueued)
        let dup2 = PlaybackQueueEntry(row: dup.row, origin: .context)
        let p = QueueSectionProjection(entries: [entry(0, .context), dup, dup2], currentIndex: 0)
        #expect(p.sections.map(\.kind) == [.manual, .context])
        #expect(p.sections[0].offsets == [1])
        #expect(p.sections[1].offsets == [2])
    }

    @Test func testViewSourceDeclaresSectionIdentifiers() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/NowPlaying/UpNextView.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        for id in ["np.queue.clearManual", "np.keepPlaying.clearAutoAdded",
                   "Added by you", "Playing from", "Keep Playing", ".textCase(.uppercase)"] {
            #expect(src.contains(id), "\(id)")
        }
        #expect(src.contains("accessibilityIdentifier"))
        #expect(src.contains("kind.accessibilityIdentifier"))
        #expect(src.contains("projection.hasManual"))
        #expect(src.contains("projection.hasKeepPlaying"))
    }
}
