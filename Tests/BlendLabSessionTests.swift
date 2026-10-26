import XCTest
@testable import TonearmCore

@MainActor
final class BlendLabSessionTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("blends.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func row(_ id: Int64) -> TrackRow {
        TrackRow(track: Track(id: id, albumId: nil, sourceId: 1, title: "T\(id)", trackNo: nil, discNo: nil,
                              durationSec: 100, codec: nil, sampleRate: nil, bitDepthOrBitrate: nil,
                              sortKey: "t\(id)", syncID: "S\(id)"),
                 album: nil, source: nil,
                 asset: Asset(id: id, trackId: id, kind: .managedCopy, bookmark: nil, relPath: "a\(id).mp3",
                              remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil,
                              needsReimport: false))
    }

    private struct Played { var rows: [TrackRow] = [] }

    private func session(library: [TrackRow], generate: @escaping BlendLabSession.Generate,
                         played: PlayLog) -> BlendLabSession {
        BlendLabSession(generate: generate, library: { library },
                        repository: BlendRepository(url: url), play: { played.queues.append($0) })
    }

    @MainActor final class PlayLog { var queues: [[TrackRow]] = [] }

    func testGenerateEditPlaySaveReopenReplay() async throws {
        let lib = (1...4).map(row)
        let log = PlayLog()
        let s = session(library: lib, generate: { _ in
            BlendLabGeneration(rows: [lib[0], lib[1], lib[0]], isBasicMix: false)
        }, played: log)
        await s.startAndWait(BlendLabRequest())
        XCTAssertEqual(s.phase, .ready)
        let doc = try XCTUnwrap(s.document)
        // Duplicate occurrences keep distinct identity.
        XCTAssertEqual(Set(doc.occurrences.map(\.id)).count, 3)

        s.move(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(s.orderedRows.map(\.row.track.id), [1, 1, 2])
        s.setNoBlend(afterOccurrence: s.orderedRows[0].occurrenceID, true)
        XCTAssertEqual(s.document?.edges[0].requestedStyle, "gapless")
        s.replace(occurrenceID: s.orderedRows[2].occurrenceID, with: lib[3])
        s.remove(occurrenceID: s.orderedRows[1].occurrenceID)
        XCTAssertEqual(s.orderedRows.map(\.row.track.id), [1, 4])

        s.playPreview()
        XCTAssertEqual(log.queues.last?.map(\.track.id), [1, 4])

        await s.save(title: "Mine")
        let saved = await BlendRepository(url: url).load().blends
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].origin, .blendLab)
        XCTAssertEqual(saved[0].title, "Mine")
        let replay = BlendReplay.playableQueue(BlendReplay.resolve(saved[0], lookup: BlendReplay.lookup(in: lib)))
        XCTAssertEqual(replay.map(\.track.id), [1, 4])
    }

    func testModelUnavailableFallsBackToHonestBasicMix() async {
        let lib = (1...3).map(row)
        let s = session(library: lib, generate: { _ in throw CocoaError(.featureUnsupported) }, played: PlayLog())
        await s.startAndWait(BlendLabRequest(seedTrackIDs: [3], targetTrackCount: 2))
        XCTAssertEqual(s.phase, .ready)
        XCTAssertTrue(s.isBasicMix)
        XCTAssertEqual(s.orderedRows.map(\.row.track.id), [3, 1])
        XCTAssertNotNil(s.message)
    }

    func testNoEligibleSourcesFails() async {
        let s = session(library: [], generate: { _ in throw CocoaError(.featureUnsupported) }, played: PlayLog())
        await s.startAndWait(BlendLabRequest())
        guard case .failed = s.phase else { return XCTFail("expected failure") }
        XCTAssertNil(s.document)
    }

    func testSingleSourceSaysNothingToBlend() async {
        let lib = [row(1)]
        let s = session(library: lib, generate: { _ in BlendLabGeneration(rows: lib, isBasicMix: true) },
                        played: PlayLog())
        await s.startAndWait(BlendLabRequest())
        XCTAssertEqual(s.document?.edges.count, 0)
        XCTAssertTrue(s.message?.contains("one track") ?? false)
    }

    func testCancelAndLateCompletionNeverOverwriteNewerState() async throws {
        let lib = (1...3).map(row)
        let gate = AsyncStream<Void>.makeStream()
        let calls = CallCounter()
        let s = session(library: lib, generate: { _ in
            let n = await calls.next()
            if n == 1 { for await _ in gate.stream { break } }  // first call is slow
            return BlendLabGeneration(rows: n == 1 ? [lib[0], lib[1]] : [lib[2], lib[1]], isBasicMix: false)
        }, played: PlayLog())
        s.start(BlendLabRequest())          // slow, stale
        s.start(BlendLabRequest())          // rapid regenerate wins
        try await Task.sleep(nanoseconds: 100_000_000)
        gate.continuation.yield()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(s.orderedRows.map(\.row.track.id), [3, 2])

        // Cancelling while generating leaves the existing document.
        s.regenerate(); s.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(s.phase, .ready)
        XCTAssertEqual(s.orderedRows.map(\.row.track.id), [3, 2])
    }

    func testEditDuringGenerationWinsOverLateResult() async throws {
        let lib = (1...3).map(row)
        let gate = AsyncStream<Void>.makeStream()
        let calls = CallCounter()
        let s = session(library: lib, generate: { _ in
            if await calls.next() == 2 { for await _ in gate.stream { break } }
            return BlendLabGeneration(rows: [lib[0], lib[1], lib[2]], isBasicMix: false)
        }, played: PlayLog())
        await s.startAndWait(BlendLabRequest())
        s.regenerate()
        s.remove(occurrenceID: s.orderedRows[0].occurrenceID)   // edit while regenerating
        gate.continuation.yield()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(s.orderedRows.map(\.row.track.id), [2, 3])
    }
}

private actor CallCounter {
    private var n = 0
    func next() -> Int { n += 1; return n }
}

final class BlendLabScopeTests: XCTestCase {
    func testTrackCountRangeIsTwoToSmallerOfAvailableAndTen() {
        XCTAssertEqual(BlendLabScope.clampedCount(40, available: 50), 10)
        XCTAssertEqual(BlendLabScope.clampedCount(40, available: 5), 5)
        XCTAssertEqual(BlendLabScope.clampedCount(0, available: 5), 2)
        XCTAssertEqual(BlendLabScope.clampedCount(7, available: 1), 2)
    }

    func testBasicMixHonoursAllowedTrackIDs() {
        func row(_ id: Int64) -> TrackRow {
            TrackRow(track: Track(id: id, albumId: nil, sourceId: 1, title: "T\(id)", trackNo: nil, discNo: nil,
                                  durationSec: 100, codec: nil, sampleRate: nil, bitDepthOrBitrate: nil,
                                  sortKey: "t\(id)", syncID: "S\(id)"), album: nil, source: nil, asset: nil)
        }
        let out = BlendLabFallback.basicMix(BlendLabRequest(targetTrackCount: 5, allowedTrackIDs: [2, 3]),
                                            library: (1...4).map(row))
        XCTAssertEqual(Set(out.rows.map(\.id)), [2, 3])
    }
}
