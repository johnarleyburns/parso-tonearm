import XCTest
@testable import Tonearm

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

    func testArtworkFilenameDerivedFromArtworkID() throws {
        let now = Date(timeIntervalSince1970: 1_500)

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(
                track: .init(
                    id: 99,
                    title: "T",
                    artist: "A",
                    albumTitle: nil,
                    duration: 10,
                    artworkID: "my-cover-art"
                ),
                isPlaying: true,
                elapsed: 1,
                duration: 10
            ),
            recentlyPlayed: [],
            now: now
        )
        let track = try XCTUnwrap(snapshot.nowPlaying?.track)

        XCTAssertEqual(track.artworkFilename, "my-cover-art.jpg")
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
