import UIKit
import XCTest
@testable import TonearmCore

final class WidgetSnapshotTests: XCTestCase {
    func testNothingPlayingBuildsEmptySnapshot() {
        let now = Date(timeIntervalSince1970: 1_000)

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(track: nil, isPlaying: false, elapsed: 0, duration: 0),
            recentlyPlayed: [],
            now: now
        )
        let entry = WidgetSnapshotTimeline.entry(for: snapshot, now: now)

        XCTAssertNil(snapshot.nowPlaying)
        XCTAssertTrue(snapshot.recentlyPlayed.isEmpty)
        XCTAssertEqual(snapshot.generatedAt, now)
        XCTAssertEqual(entry.state, .empty)
    }

    func testArtworkMissingIsExplicitInTrackSnapshot() throws {
        let now = Date(timeIntervalSince1970: 1_100)

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: .init(
                    id: 42,
                    title: "Local Track",
                    artist: "Artist",
                    albumTitle: "Album",
                    duration: 120,
                    artworkID: "   "
                ),
                isPlaying: true,
                elapsed: 30,
                duration: 120
            ),
            recentlyPlayed: [],
            now: now
        )
        let track = try XCTUnwrap(snapshot.nowPlaying?.track)

        XCTAssertNil(track.artworkID)
        XCTAssertEqual(track.artworkStatus, .missing)
        XCTAssertFalse(track.hasArtwork)
    }

    func testVeryLongTitlesAreTrimmedForWidgetDisplay() throws {
        let now = Date(timeIntervalSince1970: 1_200)
        let longTitle = String(repeating: "A", count: 160)
        let longArtist = String(repeating: "B", count: 140)

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: .init(
                    id: 7,
                    title: longTitle,
                    artist: longArtist,
                    albumTitle: nil,
                    duration: 90,
                    artworkID: "cover"
                ),
                isPlaying: false,
                elapsed: 12,
                duration: 90
            ),
            recentlyPlayed: [],
            now: now
        )
        let track = try XCTUnwrap(snapshot.nowPlaying?.track)

        XCTAssertLessThanOrEqual(track.title.count, WidgetSnapshotBuilder.maxDisplayCharacters)
        XCTAssertTrue(track.title.hasSuffix("..."))
        XCTAssertLessThanOrEqual(track.artist.count, WidgetSnapshotBuilder.maxDisplayCharacters)
        XCTAssertTrue(track.artist.hasSuffix("..."))
        XCTAssertEqual(track.artworkStatus, .available)
    }

    func testStaleTimelineEntriesAreClassified() {
        let generatedAt = Date(timeIntervalSince1970: 2_000)
        let now = generatedAt.addingTimeInterval(WidgetSnapshotTimeline.staleAfter + 1)
        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: .init(
                    id: 1,
                    title: "A Track",
                    artist: "An Artist",
                    albumTitle: nil,
                    duration: 200,
                    artworkID: nil
                ),
                isPlaying: true,
                elapsed: 50,
                duration: 200
            ),
            recentlyPlayed: [],
            now: generatedAt
        )

        let entry = WidgetSnapshotTimeline.entry(for: snapshot, now: now)

        XCTAssertTrue(snapshot.isStale(at: now, staleAfter: WidgetSnapshotTimeline.staleAfter))
        XCTAssertEqual(entry.state, .stale)
        XCTAssertGreaterThanOrEqual(
            entry.nextRefreshDate.timeIntervalSince(now),
            WidgetSnapshotTimeline.minimumRefreshInterval
        )
    }

    func testRecentlyPlayedDedupesAndLimitsRows() {
        let now = Date(timeIntervalSince1970: 1_300)
        let inputs = [
            track(1, "One"),
            track(2, "Two"),
            track(1, "One Duplicate"),
            track(3, "Three"),
            track(4, "Four"),
            track(5, "Five"),
            track(6, "Six")
        ]

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(track: nil, isPlaying: false, elapsed: 0, duration: 0),
            recentlyPlayed: inputs,
            now: now
        )

        XCTAssertEqual(snapshot.recentlyPlayed.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(snapshot.recentlyPlayed.count, WidgetSnapshotBuilder.recentLimit)
    }

    func testProgressIsClampedToPlayableBounds() throws {
        let now = Date(timeIntervalSince1970: 1_400)

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: track(1, "Clamped"),
                isPlaying: true,
                elapsed: 500,
                duration: 100
            ),
            recentlyPlayed: [],
            now: now
        )
        let nowPlaying = try XCTUnwrap(snapshot.nowPlaying)

        XCTAssertEqual(nowPlaying.elapsed, 100)
        XCTAssertEqual(nowPlaying.duration, 100)
        XCTAssertEqual(nowPlaying.progress, 1)
    }

    func testStartEndDatesDeriveFromElapsedAndDuration() throws {
        let now = Date(timeIntervalSince1970: 1_000)

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: track(1, "Timed"),
                isPlaying: true,
                elapsed: 30,
                duration: 120
            ),
            recentlyPlayed: [],
            now: now
        )
        let nowPlaying = try XCTUnwrap(snapshot.nowPlaying)

        XCTAssertEqual(nowPlaying.startDate.timeIntervalSince1970, 1_000 - 30, accuracy: 0.001)
        XCTAssertEqual(nowPlaying.endDate.timeIntervalSince1970, 1_000 + 90, accuracy: 0.001)
    }

    func testZeroDurationProducesEqualStartAndEndDates() throws {
        let now = Date(timeIntervalSince1970: 1_000)

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: .init(
                    id: 1,
                    title: "ZeroDur",
                    artist: "A",
                    albumTitle: nil,
                    duration: nil,
                    artworkID: nil
                ),
                isPlaying: false,
                elapsed: 0,
                duration: 0
            ),
            recentlyPlayed: [],
            now: now
        )
        let nowPlaying = try XCTUnwrap(snapshot.nowPlaying)

        XCTAssertEqual(nowPlaying.elapsed, 0)
        XCTAssertEqual(nowPlaying.duration, 0)
        XCTAssertEqual(nowPlaying.startDate, nowPlaying.endDate)
    }

    func testArtworkFilenameIsNilWhenNoFileExistsOnDisk() throws {
        let now = Date(timeIntervalSince1970: 1_500)

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: .init(
                    id: 99,
                    title: "T",
                    artist: "A",
                    albumTitle: nil,
                    duration: 10,
                    artworkID: "never-written-cover-\(UUID().uuidString)"
                ),
                isPlaying: true,
                elapsed: 1,
                duration: 10
            ),
            recentlyPlayed: [],
            now: now
        )
        let track = try XCTUnwrap(snapshot.nowPlaying?.track)

        XCTAssertNil(track.artworkFilename)
        XCTAssertEqual(track.artworkStatus, .available)
    }

    func testArtworkFilenameIsSetOnceFileExistsOnDisk() throws {
        let artworkID = "written-cover-\(UUID().uuidString)"
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format)
            .image { context in
                UIColor.green.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        let saved = WidgetArtworkStore.save(image: image, for: artworkID)
        try XCTSkipIf(saved == nil, "App Group container unavailable in this test environment")
        defer { WidgetArtworkStore.prune(keeping: []) }

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: .init(
                    id: 100,
                    title: "T",
                    artist: "A",
                    albumTitle: nil,
                    duration: 10,
                    artworkID: artworkID
                ),
                isPlaying: true,
                elapsed: 1,
                duration: 10
            ),
            recentlyPlayed: [],
            now: Date(timeIntervalSince1970: 1_600)
        )
        let track = try XCTUnwrap(snapshot.nowPlaying?.track)

        XCTAssertEqual(track.artworkFilename, saved)
    }

    func testPausedTrackProducesStartableContentState() throws {
        let now = Date(timeIntervalSince1970: 1_700)

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: track(11, "Paused Track"),
                isPlaying: false,
                elapsed: 40,
                duration: 100
            ),
            recentlyPlayed: [],
            now: now
        )
        let state = try XCTUnwrap(TonearmNowPlayingAttributes.ContentState(snapshot: snapshot))

        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.title, "Paused Track")
        XCTAssertEqual(state.progress, 0.4, accuracy: 0.001)
        XCTAssertEqual(state.elapsed, 40)
        XCTAssertEqual(state.duration, 100)
    }

    func testStalledSnapshotFreezesAtTruePosition() throws {
        let now = Date(timeIntervalSince1970: 1_800)

        // A stalled/buffering player reports isPlaying=false (isAdvancing) so the
        // widget renders the static ProgressView branch at the frozen position.
        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: track(12, "Stalled"),
                isPlaying: false,
                elapsed: 25,
                duration: 100
            ),
            recentlyPlayed: [],
            now: now
        )
        let nowPlaying = try XCTUnwrap(snapshot.nowPlaying)
        let state = try XCTUnwrap(TonearmNowPlayingAttributes.ContentState(snapshot: snapshot))

        XCTAssertFalse(nowPlaying.isPlaying)
        XCTAssertEqual(nowPlaying.progress, 0.25, accuracy: 0.001)
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.progress, 0.25, accuracy: 0.001)
    }

    func testEmptySnapshotProducesNoContentState() {
        let snapshot = WidgetSnapshot.empty(now: Date(timeIntervalSince1970: 1_900))

        XCTAssertNil(TonearmNowPlayingAttributes.ContentState(snapshot: snapshot))
    }

    func testPlaybackStateStoreRoundTripsQueueIndexAndTime() throws {
        let suiteName = "guru.parso.tonearm.tests.playback-state"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertNil(PlaybackStateStore.load(defaults: defaults))

        let saved = PlaybackStateSnapshot(
            trackIDs: [10, 20, 30],
            currentIndex: 1,
            elapsed: 42.5,
            isPlaying: true,
            savedAt: Date(timeIntervalSince1970: 2_000)
        )
        PlaybackStateStore.save(saved, defaults: defaults)

        let loaded = try XCTUnwrap(PlaybackStateStore.load(defaults: defaults))
        XCTAssertEqual(loaded, saved)
        XCTAssertEqual(loaded.trackIDs, [10, 20, 30])
        XCTAssertEqual(loaded.currentIndex, 1)
        XCTAssertEqual(loaded.elapsed, 42.5, accuracy: 0.001)
        XCTAssertTrue(loaded.isPlaying)

        PlaybackStateStore.clear(defaults: defaults)
        XCTAssertNil(PlaybackStateStore.load(defaults: defaults))
    }

    private func track(_ id: Int64, _ title: String) -> WidgetSnapshotBuilder.TrackInput {
        WidgetSnapshotBuilder.TrackInput(
            id: id,
            title: title,
            artist: "Artist \(id)",
            albumTitle: nil,
            duration: 100,
            artworkID: nil
        )
    }
}
