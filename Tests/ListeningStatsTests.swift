import XCTest

@testable import Tonearm

final class ListeningStatsTests: XCTestCase {
    func testEmptyHistory() {
        let summary = ListeningStats.summarize(events: [], tracks: [], now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(summary.totalPlayCount, 0)
        XCTAssertEqual(summary.totalListeningTime, 0)
        XCTAssertEqual(summary.currentStreakDays, 0)
        XCTAssertEqual(summary.longestStreakDays, 0)
        XCTAssertTrue(summary.topArtists.isEmpty)
        XCTAssertTrue(summary.dailyRollups.isEmpty)
    }

    func testSingleEventBuildsTotalsAndTopLists() {
        let row = track(id: 1, title: "Song", artist: "Artist", album: "Album", duration: 180)
        let date = Date(timeIntervalSince1970: 10_000)
        let summary = ListeningStats.summarize(
            events: [event(trackId: 1, at: date)],
            tracks: [row],
            now: date)

        XCTAssertEqual(summary.totalPlayCount, 1)
        XCTAssertEqual(summary.totalListeningTime, 180)
        XCTAssertEqual(summary.topTracks.map { $0.row.track.title }, ["Song"])
        XCTAssertEqual(summary.topArtists.map(\.name), ["Artist"])
        XCTAssertEqual(summary.topAlbums.map(\.name), ["Album"])
    }

    func testDeterministicTieBreaking() {
        let beta = track(id: 2, title: "Beta", artist: "Same", album: "Album", duration: 100)
        let alpha = track(id: 1, title: "Alpha", artist: "Same", album: "Album", duration: 100)
        let summary = ListeningStats.summarize(
            events: [
                event(trackId: 2, at: Date(timeIntervalSince1970: 1)),
                event(trackId: 1, at: Date(timeIntervalSince1970: 2)),
            ],
            tracks: [beta, alpha],
            now: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(summary.topTracks.map { $0.row.track.title }, ["Alpha", "Beta"])
    }

    func testDSTBoundaryKeepsConsecutiveDayStreaks() {
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

        XCTAssertEqual(summary.currentStreakDays, 3)
        XCTAssertEqual(summary.longestStreakDays, 3)
        XCTAssertEqual(summary.dailyRollups.map(\.playCount), [1, 1, 1])
    }

    func testYearBoundarySeparatesYearlyRollupsAndReview() {
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

        XCTAssertEqual(summary.yearlyRollups.map(\.playCount), [1, 1])
        XCTAssertEqual(summary.yearInReview.year, 2026)
        XCTAssertEqual(summary.yearInReview.playCount, 1)
        XCTAssertTrue(summary.yearInReview.shareText.contains("Year Song"))
    }

    func testDeletedTracksStillCountInHistoryButNotTopListsOrDuration() {
        let row = track(id: 1, title: "Existing", artist: "Artist", duration: 90)
        let day = Date(timeIntervalSince1970: 20_000)
        let summary = ListeningStats.summarize(
            events: [
                event(trackId: 1, at: day),
                event(trackId: 999, at: day.addingTimeInterval(60)),
            ],
            tracks: [row],
            now: day)

        XCTAssertEqual(summary.totalPlayCount, 2)
        XCTAssertEqual(summary.totalListeningTime, 90)
        XCTAssertEqual(summary.topTracks.map { $0.row.id }, [1])
        XCTAssertEqual(summary.dailyRollups.map(\.playCount), [2])
        XCTAssertEqual(summary.dailyRollups.map(\.listeningTime), [90])
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
