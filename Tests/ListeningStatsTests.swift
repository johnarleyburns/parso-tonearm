import Foundation
import Testing

@testable import TonearmCore

@Suite struct ListeningStatsTests {
    @Test func testEmptyHistory() {
        let summary = ListeningStats.summarize(events: [], tracks: [], now: Date(timeIntervalSince1970: 0))

        #expect(summary.totalPlayCount == 0)
        #expect(summary.totalListeningTime == 0)
        #expect(summary.currentStreakDays == 0)
        #expect(summary.longestStreakDays == 0)
        #expect(summary.topArtists.isEmpty)
        #expect(summary.dailyRollups.isEmpty)
    }

    @Test func testSingleEventBuildsTotalsAndTopLists() {
        let row = track(id: 1, title: "Song", artist: "Artist", album: "Album", duration: 180)
        let date = Date(timeIntervalSince1970: 10_000)
        let summary = ListeningStats.summarize(
            events: [event(trackId: 1, at: date)],
            tracks: [row],
            now: date)

        #expect(summary.totalPlayCount == 1)
        #expect(summary.totalListeningTime == 180)
        #expect(summary.topTracks.map { $0.row.track.title } == ["Song"])
        #expect(summary.topArtists.map(\.name) == ["Artist"])
        #expect(summary.topAlbums.map(\.name) == ["Album"])
    }

    @Test func testDeterministicTieBreaking() {
        let beta = track(id: 2, title: "Beta", artist: "Same", album: "Album", duration: 100)
        let alpha = track(id: 1, title: "Alpha", artist: "Same", album: "Album", duration: 100)
        let summary = ListeningStats.summarize(
            events: [
                event(trackId: 2, at: Date(timeIntervalSince1970: 1)),
                event(trackId: 1, at: Date(timeIntervalSince1970: 2)),
            ],
            tracks: [beta, alpha],
            now: Date(timeIntervalSince1970: 2))

        #expect(summary.topTracks.map { $0.row.track.title } == ["Alpha", "Beta"])
    }

    @Test func testDSTBoundaryKeepsConsecutiveDayStreaks() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let dates = [
            date(calendar, year: 2026, month: 3, day: 7, hour: 23),
            date(calendar, year: 2026, month: 3, day: 8, hour: 3),
            date(calendar, year: 2026, month: 3, day: 9, hour: 1),
        ]
        let row = track(id: 1, duration: 60)

        let summary = ListeningStats.summarize(
            events: dates.map { event(trackId: 1, at: $0) },
            tracks: [row],
            calendar: calendar,
            now: dates[2])

        #expect(summary.currentStreakDays == 3)
        #expect(summary.longestStreakDays == 3)
        #expect(summary.dailyRollups.map(\.playCount) == [1, 1, 1])
    }

    @Test func testYearBoundarySeparatesYearlyRollupsAndReview() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let row = track(id: 1, title: "Year Song", artist: "Artist", duration: 120)
        let dec31 = date(calendar, year: 2025, month: 12, day: 31, hour: 23)
        let jan1 = date(calendar, year: 2026, month: 1, day: 1, hour: 1)

        let summary = ListeningStats.summarize(
            events: [event(trackId: 1, at: dec31), event(trackId: 1, at: jan1)],
            tracks: [row],
            calendar: calendar,
            now: jan1)

        #expect(summary.yearlyRollups.map(\.playCount) == [1, 1])
        #expect(summary.yearInReview.year == 2026)
        #expect(summary.yearInReview.playCount == 1)
        #expect(summary.yearInReview.shareText.contains("Year Song"))
    }

    @Test func testDeletedTracksStillCountInHistoryButNotTopListsOrDuration() {
        let row = track(id: 1, title: "Existing", artist: "Artist", duration: 90)
        let day = Date(timeIntervalSince1970: 20_000)
        let summary = ListeningStats.summarize(
            events: [
                event(trackId: 1, at: day),
                event(trackId: 999, at: day.addingTimeInterval(60)),
            ],
            tracks: [row],
            now: day)

        #expect(summary.totalPlayCount == 2)
        #expect(summary.totalListeningTime == 90)
        #expect(summary.topTracks.map { $0.row.id } == [1])
        #expect(summary.dailyRollups.map(\.playCount) == [2])
        #expect(summary.dailyRollups.map(\.listeningTime) == [90])
    }

    private func track(
        id: Int64,
        title: String = "Track",
        artist: String = "Artist",
        album: String = "Album",
        duration: TimeInterval
    ) -> TrackRow {
        TrackRow(
            track: Track(id: id, albumId: id, sourceId: 1, title: title,
                         trackNo: nil, discNo: nil, durationSec: duration,
                         codec: nil, sampleRate: nil, bitDepthOrBitrate: nil,
                         sortKey: title, genre: nil, composer: nil, artistId: nil),
            album: Album(id: id, sourceId: 1, title: album, artist: artist,
                         artistId: nil, albumArtist: artist, genre: nil,
                         year: nil, artworkId: nil),
            source: nil,
            asset: nil)
    }

    private func event(trackId: Int64, at date: Date) -> PlayEvent {
        PlayEvent(id: nil, trackId: trackId, playedAt: date, syncID: nil)
    }

    private func date(
        _ calendar: Calendar,
        year: Int,
        month: Int,
        day: Int,
        hour: Int
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour))!
    }
}
