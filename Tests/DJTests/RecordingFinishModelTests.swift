import XCTest
@testable import TonearmDJ

/// Commit 5.12 — the recording-finish screen's model (§41.11, plan 5.12): the
/// review listen (FR-REC-6 — playable in place with a seekable waveform and
/// tappable markers), the §37.4 timeline, title/notes (FR-REC-1), attribution
/// (§18A.5), and the FR-REC-4 export (cue-sheet + honest format, FR-REC-7).
@MainActor
final class RecordingFinishModelTests: XCTestCase {

    private final class FakeMixRepository: MixServicing, @unchecked Sendable {
        var mixes: [DJMix] = []
        var eventsByMix: [Int64: [DJMixTrackEvent]] = [:]
        var assetURLs: [Int64: URL] = [:]
        var storage: Int64 = 0
        private(set) var saved: [(Int64, String, String?)] = []
        private(set) var deleted: [Int64] = []

        func completedMixes() async throws -> [DJMix] { mixes }
        func mixTrackEvents(mixID: Int64) async throws -> [DJMixTrackEvent] {
            eventsByMix[mixID] ?? []
        }
        func mixAssetURL(mixID: Int64) async throws -> URL? { assetURLs[mixID] }
        func updateMix(mixID: Int64, title: String, notes: String?) async throws {
            saved.append((mixID, title, notes))
        }
        func deleteMix(mixID: Int64) async throws { deleted.append(mixID) }
        func mixStorageBytes() async throws -> Int64 { storage }
    }

    private final class FakeMixPlayback: MixPlayback {
        private(set) var played = 0
        private(set) var paused = 0
        private(set) var seeks: [TimeInterval] = []
        var currentTime: TimeInterval = 0
        var duration: TimeInterval = 60
        var isPlaying = false
        private(set) var loadedURL: URL?

        func load(url: URL) throws { loadedURL = url }
        func play() { played += 1; isPlaying = true }
        func pause() { paused += 1; isPlaying = false }
        func seek(to time: TimeInterval) { seeks.append(time); currentTime = time }
    }

    private struct FakeWaveformLoader: MixWaveformLoading {
        var model: MixWaveformModel?
        func loadWaveform(url: URL) async throws -> MixWaveformModel {
            model ?? MixWaveformModel(peaks: [0.5], duration: 60, sampleRate: 48_000, channelCount: 2)
        }
    }

    private func makeMix(id: Int64 = 1, state: MixLocalState = .complete,
                         title: String = "Friday set", duration: Double = 360) -> DJMix {
        var mix = DJMix(syncID: "mix-\(id)", title: title, durationSec: duration, trackCount: 2,
                        format: RecordingEncoder.formatName, sizeBytes: 138_000_000,
                        recordedAt: Date(), localState: state.rawValue)
        mix.id = id
        return mix
    }

    private func makeEvent(trackID: Int64, title: String, artist: String,
                           offset: Double, position: Int) -> DJMixTrackEvent {
        DJMixTrackEvent(mixID: 1, trackID: trackID, title: title, artist: artist,
                        deck: "A", startOffsetSec: offset, bpmAtPlay: 124,
                        camelotAtPlay: "8A", position: position)
    }

    // MARK: - Load

    func testBeginLoadsTimelineWaveformAndPlayer() async throws {
        let repository = FakeMixRepository()
        repository.eventsByMix[1] = [makeEvent(trackID: 5, title: "Neon Circuit",
                                               artist: "Kora Mechanism", offset: 0, position: 1)]
        let player = FakeMixPlayback()
        let url = URL(fileURLWithPath: "/tmp/mix.m4a")
        repository.assetURLs[1] = url

        let model = RecordingFinishModel(mix: makeMix(), repository: repository,
                                         player: player, waveformLoader: FakeWaveformLoader())
        await model.begin()

        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.timeline.count, 1)
        XCTAssertEqual(model.timeline.first?.title, "Neon Circuit")
        XCTAssertEqual(model.waveform?.binCount, 1, "the review-listen waveform is decoded")
        XCTAssertEqual(player.loadedURL, url, "the player is prepared for the mix")
        XCTAssertEqual(try XCTUnwrap(model.sampleRate), 48_000, accuracy: 1)
        XCTAssertEqual(model.formatLabel, "M4A · AAC 256 kbps",
                       "the format is named honestly — never MP3 (FR-REC-7)")
        XCTAssertEqual(model.markers, [0], "one tappable transition marker per timeline row")
    }

    func testBeginSurfacesTheHonestAbsenceWhenTheFileIsGone() async throws {
        let repository = FakeMixRepository()
        repository.assetURLs = [:] // no file
        let player = FakeMixPlayback()
        let model = RecordingFinishModel(mix: makeMix(), repository: repository,
                                         player: player, waveformLoader: FakeWaveformLoader())
        await model.begin()
        XCTAssertTrue(model.isLoaded)
        XCTAssertNotNil(model.loadError,
                        "a complete mix whose file is gone is an honest absence, not a dead player (§46.2)")
        XCTAssertNil(model.assetURLForExport)
    }

    func testCorruptMixNeverOffersPlayback() async throws {
        let repository = FakeMixRepository()
        let player = FakeMixPlayback()
        let model = RecordingFinishModel(mix: makeMix(state: .corrupt), repository: repository,
                                         player: player, waveformLoader: FakeWaveformLoader())
        await model.begin()
        XCTAssertTrue(model.isCorrupt)
        XCTAssertNil(model.assetURLForExport)

        model.play()
        XCTAssertEqual(player.played, 0, "a corrupt mix never arms the player (§46.2)")
        XCTAssertEqual(model.isPlaying, false)
    }

    // MARK: - Review-listen transport (FR-REC-6)

    func testPlayPauseAndSeekForwardToThePlayer() async throws {
        let repository = FakeMixRepository()
        repository.assetURLs[1] = URL(fileURLWithPath: "/tmp/mix.m4a")
        let player = FakeMixPlayback()
        let model = RecordingFinishModel(mix: makeMix(), repository: repository,
                                         player: player, waveformLoader: FakeWaveformLoader())
        await model.begin()

        model.play()
        XCTAssertEqual(player.played, 1)
        XCTAssertTrue(model.isPlaying)

        model.seek(to: 120)
        XCTAssertEqual(player.seeks, [120])

        model.jump(to: 300)
        XCTAssertEqual(player.seeks.last, 300, "jumping to a marker seeks…")
        XCTAssertEqual(player.played, 2, "…and plays — 'tap one to jump straight to it'")

        model.pause()
        XCTAssertEqual(player.paused, 1)
        XCTAssertFalse(model.isPlaying)
    }

    func testTickMirrorsThePlayerPositionAndState() async throws {
        let repository = FakeMixRepository()
        repository.assetURLs[1] = URL(fileURLWithPath: "/tmp/mix.m4a")
        let player = FakeMixPlayback()
        let model = RecordingFinishModel(mix: makeMix(), repository: repository,
                                         player: player, waveformLoader: FakeWaveformLoader())
        await model.begin()
        model.play()
        player.currentTime = 42
        model.tick()
        XCTAssertEqual(model.currentTime, 42, "the playhead follows the player at ~10 Hz")
        XCTAssertTrue(model.isPlaying)

        player.isPlaying = false
        model.tick()
        XCTAssertFalse(model.isPlaying, "a finished playhead is honest, not stuck playing")
    }

    // MARK: - Title / notes (FR-REC-1)

    func testSavePersistsTitleAndNotes() async throws {
        let repository = FakeMixRepository()
        let player = FakeMixPlayback()
        let model = RecordingFinishModel(mix: makeMix(), repository: repository,
                                         player: player, waveformLoader: FakeWaveformLoader())
        await model.begin()
        model.title = "The long one"
        model.notes = "Bass swap was clean"
        await model.save()
        XCTAssertEqual(repository.saved.count, 1)
        XCTAssertEqual(repository.saved.first?.1, "The long one")
        XCTAssertEqual(repository.saved.first?.2, "Bass swap was clean")
    }

    func testDeleteRemovesTheMix() async throws {
        let repository = FakeMixRepository()
        let player = FakeMixPlayback()
        let model = RecordingFinishModel(mix: makeMix(), repository: repository,
                                         player: player, waveformLoader: FakeWaveformLoader())
        await model.begin()
        model.play()
        await model.delete()
        XCTAssertEqual(repository.deleted, [1])
        XCTAssertEqual(player.paused, 1, "deleting stops the review listen")
    }

    // MARK: - Attribution (§18A.5) + cue sheet (FR-REC-4)

    func testAttributionListsArtistAndTitlePerTimelineTrack() async throws {
        let repository = FakeMixRepository()
        repository.eventsByMix[1] = [
            makeEvent(trackID: 5, title: "Neon Circuit", artist: "Kora Mechanism", offset: 0, position: 1),
            makeEvent(trackID: 9, title: "Warehouse Line", artist: "Nils Anberg", offset: 300, position: 2),
        ]
        let model = RecordingFinishModel(mix: makeMix(), repository: repository,
                                         player: FakeMixPlayback(), waveformLoader: FakeWaveformLoader())
        await model.begin()
        XCTAssertEqual(model.attributionLines,
                       ["Kora Mechanism — Neon Circuit", "Nils Anberg — Warehouse Line"])
        XCTAssertEqual(model.attributionNote, CueSheetBuilder.attributionLine)
    }

    func testCueSheetTextNamesTheFormatAndCarriesCredits() async throws {
        let repository = FakeMixRepository()
        repository.eventsByMix[1] = [
            makeEvent(trackID: 5, title: "Neon Circuit", artist: "Kora Mechanism", offset: 0, position: 1),
        ]
        let model = RecordingFinishModel(mix: makeMix(), repository: repository,
                                         player: FakeMixPlayback(), waveformLoader: FakeWaveformLoader())
        await model.begin()
        let cue = model.cueSheetText()
        XCTAssertTrue(cue.contains("M4A · AAC 256 kbps"), "FR-REC-7: names the real format")
        XCTAssertTrue(cue.contains("Kora Mechanism — Neon Circuit"))
        XCTAssertTrue(cue.contains(CueSheetBuilder.attributionLine), "the licence survives (§18A.5)")
    }

    func testShareItemsCarryTheMixAndOptionallyTheCueSheet() async throws {
        let repository = FakeMixRepository()
        repository.assetURLs[1] = URL(fileURLWithPath: "/tmp/mix.m4a")
        let model = RecordingFinishModel(mix: makeMix(), repository: repository,
                                         player: FakeMixPlayback(), waveformLoader: FakeWaveformLoader())
        await model.begin()

        model.includeCueSheet = true
        let both = model.shareItems
        XCTAssertEqual(both.count, 2, "the share carries the M4A and the cue-sheet by default")
        XCTAssertEqual(both.first, URL(fileURLWithPath: "/tmp/mix.m4a"),
                       "the share hands the recorded file itself — no re-encode (FR-REC-4)")
        XCTAssertTrue(both[1].lastPathComponent.hasSuffix("cue-sheet.txt"))

        model.includeCueSheet = false
        let audioOnly = model.shareItems
        XCTAssertEqual(audioOnly.count, 1, "the cue-sheet is optional (FR-REC-4)")
    }
}
