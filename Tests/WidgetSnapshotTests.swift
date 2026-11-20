import Foundation
import Testing
@testable import TonearmCore

@Suite struct WidgetSnapshotTests {
    @Test func testNothingPlayingBuildsEmptySnapshot() {
        let now = Date(timeIntervalSince1970: 1_000)

        let snapshot = WidgetSnapshotBuilder.build(
            playback: .init(track: nil, isPlaying: false, elapsed: 0, duration: 0),
            recentlyPlayed: [],
            now: now
        )
        let entry = WidgetSnapshotTimeline.entry(for: snapshot, now: now)

        #expect(snapshot.nowPlaying == nil)
        #expect(snapshot.recentlyPlayed.isEmpty)
        #expect(snapshot.generatedAt == now)
        #expect(entry.state == .empty)
    }

    @Test func testArtworkMissingIsExplicitInTrackSnapshot() throws {
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
        let track = try #require(snapshot.nowPlaying?.track)

        #expect(track.artworkID == nil)
        #expect(track.artworkStatus == .missing)
        #expect(!track.hasArtwork)
    }

    @Test func testVeryLongTitlesAreTrimmedForWidgetDisplay() throws {
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
        let track = try #require(snapshot.nowPlaying?.track)

        #expect(track.title.count <= WidgetSnapshotBuilder.maxDisplayCharacters)
        #expect(track.title.hasSuffix("..."))
        #expect(track.artist.count <= WidgetSnapshotBuilder.maxDisplayCharacters)
        #expect(track.artist.hasSuffix("..."))
        #expect(track.artworkStatus == .available)
    }

    @Test func testStaleTimelineEntriesAreClassified() {
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

        #expect(snapshot.isStale(at: now, staleAfter: WidgetSnapshotTimeline.staleAfter))
        #expect(entry.state == .stale)
        #expect(
            entry.nextRefreshDate.timeIntervalSince(now)
            >= WidgetSnapshotTimeline.minimumRefreshInterval
        )
    }

    @Test func testRecentlyPlayedDedupesAndLimitsRows() {
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

        #expect(snapshot.recentlyPlayed.map(\.id) == [1, 2, 3, 4, 5])
        #expect(snapshot.recentlyPlayed.count == WidgetSnapshotBuilder.recentLimit)
    }

    @Test func testProgressIsClampedToPlayableBounds() throws {
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
        let nowPlaying = try #require(snapshot.nowPlaying)

        #expect(nowPlaying.elapsed == 100)
        #expect(nowPlaying.duration == 100)
        #expect(nowPlaying.progress == 1)
    }

    @Test func testStartEndDatesDeriveFromElapsedAndDuration() throws {
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
        let nowPlaying = try #require(snapshot.nowPlaying)

        #expect(abs(nowPlaying.startDate.timeIntervalSince1970 - (1_000 - 30)) <= 0.001)
        #expect(abs(nowPlaying.endDate.timeIntervalSince1970 - (1_000 + 90)) <= 0.001)
    }

    @Test func testZeroDurationProducesEqualStartAndEndDates() throws {
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
        let nowPlaying = try #require(snapshot.nowPlaying)

        #expect(nowPlaying.elapsed == 0)
        #expect(nowPlaying.duration == 0)
        #expect(nowPlaying.startDate == nowPlaying.endDate)
    }

    @Test func testArtworkFilenameIsNilWhenNoFileExistsOnDisk() throws {
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
        let track = try #require(snapshot.nowPlaying?.track)

        #expect(track.artworkFilename == nil)
        #expect(track.artworkStatus == .available)
    }

    @Test func testPausedTrackPreservesWidgetProgress() throws {
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
        let nowPlaying = try #require(snapshot.nowPlaying)

        #expect(!nowPlaying.isPlaying)
        #expect(nowPlaying.track.title == "Paused Track")
        #expect(abs(nowPlaying.progress - 0.4) <= 0.001)
        #expect(nowPlaying.elapsed == 40)
        #expect(nowPlaying.duration == 100)
    }

    @Test func testStalledSnapshotFreezesAtTruePosition() throws {
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
        let nowPlaying = try #require(snapshot.nowPlaying)

        #expect(!nowPlaying.isPlaying)
        #expect(abs(nowPlaying.progress - 0.25) <= 0.001)
    }

    @Test func testEmptySnapshotHasNoNowPlayingTrack() {
        let snapshot = WidgetSnapshot.empty(now: Date(timeIntervalSince1970: 1_900))

        #expect(snapshot.nowPlaying == nil)
    }

    @Test func testPlaybackStateStoreRoundTripsQueueIndexAndTime() throws {
        let defaults = InMemoryDefaultsStore()

        #expect(PlaybackStateStore.load(defaults: defaults) == nil)

        let saved = PlaybackStateSnapshot(
            trackIDs: [10, 20, 30],
            currentIndex: 1,
            elapsed: 42.5,
            isPlaying: true,
            savedAt: Date(timeIntervalSince1970: 2_000)
        )
        PlaybackStateStore.save(saved, defaults: defaults)

        let loaded = try #require(PlaybackStateStore.load(defaults: defaults))
        #expect(loaded == saved)
        #expect(loaded.trackIDs == [10, 20, 30])
        #expect(loaded.currentIndex == 1)
        #expect(abs(loaded.elapsed - 42.5) <= 0.001)
        #expect(loaded.isPlaying)

        PlaybackStateStore.clear(defaults: defaults)
        #expect(PlaybackStateStore.load(defaults: defaults) == nil)
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
