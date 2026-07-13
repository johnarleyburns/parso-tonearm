import Foundation

enum ListeningStats {
    struct Summary: Equatable {
        var totalPlayCount: Int
        var totalListeningTime: TimeInterval
        var currentStreakDays: Int
        var longestStreakDays: Int
        var topTracks: [TrackRank]
        var topArtists: [NameRank]
        var topAlbums: [NameRank]
        var dailyRollups: [PeriodRollup]
        var monthlyRollups: [PeriodRollup]
        var yearlyRollups: [PeriodRollup]
        var yearInReview: YearInReview

        static let empty = Summary(
            totalPlayCount: 0,
            totalListeningTime: 0,
            currentStreakDays: 0,
            longestStreakDays: 0,
            topTracks: [],
            topArtists: [],
            topAlbums: [],
            dailyRollups: [],
            monthlyRollups: [],
            yearlyRollups: [],
            yearInReview: YearInReview(year: 0, playCount: 0, listeningTime: 0,
                                       topArtist: nil, topTrack: nil, shareText: ""))
    }

    struct TrackRank: Equatable, Identifiable {
        var row: TrackRow
        var playCount: Int
        var listeningTime: TimeInterval
        var id: Int64 { row.id }
    }

    struct NameRank: Equatable, Identifiable {
        var name: String
        var playCount: Int
        var listeningTime: TimeInterval
        var id: String { name }
    }

    struct PeriodRollup: Equatable, Identifiable {
        var start: Date
        var playCount: Int
        var listeningTime: TimeInterval
        var id: Date { start }
    }

    struct YearInReview: Equatable {
        var year: Int
        var playCount: Int
        var listeningTime: TimeInterval
        var topArtist: String?
        var topTrack: String?
        var shareText: String
    }

    static func summarize(
        events: [PlayEvent],
        tracks: [TrackRow],
        calendar: Calendar = .current,
        now: Date = Date(),
        rankLimit: Int = 5
    ) -> Summary {
        let rowsByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        var trackBuckets: [Int64: TrackBucket] = [:]
        var artistBuckets: [String: NameBucket] = [:]
        var albumBuckets: [String: NameBucket] = [:]
        var totalListeningTime: TimeInterval = 0

        for event in events {
            guard let row = rowsByID[event.trackId] else { continue }
            let duration = max(0, row.track.durationSec ?? 0)
            totalListeningTime += duration

            trackBuckets[event.trackId, default: TrackBucket(row: row)]
                .addPlay(duration: duration)
            artistBuckets[artistName(for: row), default: NameBucket(name: artistName(for: row))]
                .addPlay(duration: duration)
            albumBuckets[albumName(for: row), default: NameBucket(name: albumName(for: row))]
                .addPlay(duration: duration)
        }

        let topTracks = rankedTracks(Array(trackBuckets.values), limit: rankLimit)
        let topArtists = rankedNames(Array(artistBuckets.values), limit: rankLimit)
        let topAlbums = rankedNames(Array(albumBuckets.values), limit: rankLimit)
        let dailyRollups = rollups(events: events, rowsByID: rowsByID, period: .day, calendar: calendar)
        let monthlyRollups = rollups(events: events, rowsByID: rowsByID, period: .month, calendar: calendar)
        let yearlyRollups = rollups(events: events, rowsByID: rowsByID, period: .year, calendar: calendar)
        let streaks = streaks(from: events.map(\.playedAt), calendar: calendar, now: now)
        let yearInReview = review(
            year: calendar.component(.year, from: now),
            events: events,
            rowsByID: rowsByID,
            calendar: calendar,
            rankLimit: rankLimit)

        return Summary(
            totalPlayCount: events.count,
            totalListeningTime: totalListeningTime,
            currentStreakDays: streaks.current,
            longestStreakDays: streaks.longest,
            topTracks: topTracks,
            topArtists: topArtists,
            topAlbums: topAlbums,
            dailyRollups: dailyRollups,
            monthlyRollups: monthlyRollups,
            yearlyRollups: yearlyRollups,
            yearInReview: yearInReview)
    }

    private enum Period {
        case day
        case month
        case year
    }

    private struct TrackBucket {
        var row: TrackRow
        var playCount = 0
        var listeningTime: TimeInterval = 0

        mutating func addPlay(duration: TimeInterval) {
            playCount += 1
            listeningTime += duration
        }
    }

    private struct NameBucket {
        var name: String
        var playCount = 0
        var listeningTime: TimeInterval = 0

        mutating func addPlay(duration: TimeInterval) {
            playCount += 1
            listeningTime += duration
        }
    }

    private static func rankedTracks(_ buckets: [TrackBucket], limit: Int) -> [TrackRank] {
        buckets.sorted { left, right in
            if left.playCount != right.playCount { return left.playCount > right.playCount }
            if left.listeningTime != right.listeningTime { return left.listeningTime > right.listeningTime }
            let leftKey = trackSortKey(left.row)
            let rightKey = trackSortKey(right.row)
            if leftKey != rightKey { return leftKey < rightKey }
            return left.row.id < right.row.id
        }
        .prefix(max(0, limit))
        .map { TrackRank(row: $0.row, playCount: $0.playCount, listeningTime: $0.listeningTime) }
    }

    private static func rankedNames(_ buckets: [NameBucket], limit: Int) -> [NameRank] {
        buckets.sorted { left, right in
            if left.playCount != right.playCount { return left.playCount > right.playCount }
            if left.listeningTime != right.listeningTime { return left.listeningTime > right.listeningTime }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        .prefix(max(0, limit))
        .map { NameRank(name: $0.name, playCount: $0.playCount, listeningTime: $0.listeningTime) }
    }

    private static func rollups(
        events: [PlayEvent],
        rowsByID: [Int64: TrackRow],
        period: Period,
        calendar: Calendar
    ) -> [PeriodRollup] {
        var buckets: [Date: PeriodRollup] = [:]
        for event in events {
            let start = periodStart(for: event.playedAt, period: period, calendar: calendar)
            let duration = rowsByID[event.trackId].map { max(0, $0.track.durationSec ?? 0) } ?? 0
            var rollup = buckets[start] ?? PeriodRollup(start: start, playCount: 0, listeningTime: 0)
            rollup.playCount += 1
            rollup.listeningTime += duration
            buckets[start] = rollup
        }
        return buckets.values.sorted { $0.start < $1.start }
    }

    private static func streaks(
        from dates: [Date],
        calendar: Calendar,
        now: Date
    ) -> (current: Int, longest: Int) {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        guard !days.isEmpty else { return (0, 0) }
        let sortedDays = days.sorted()

        var longest = 1
        var run = 1
        for index in sortedDays.indices.dropFirst() {
            let previous = sortedDays[sortedDays.index(before: index)]
            let current = sortedDays[index]
            if calendar.dateComponents([.day], from: previous, to: current).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
        }

        var current = 0
        var day = calendar.startOfDay(for: now)
        while days.contains(day) {
            current += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }

        return (current, longest)
    }

    private static func review(
        year: Int,
        events: [PlayEvent],
        rowsByID: [Int64: TrackRow],
        calendar: Calendar,
        rankLimit: Int
    ) -> YearInReview {
        let eventsThisYear = events.filter { calendar.component(.year, from: $0.playedAt) == year }
        let summary = summarizeForReview(
            events: eventsThisYear,
            rowsByID: rowsByID,
            rankLimit: rankLimit)
        let topArtist = summary.topArtists.first?.name
        let topTrack = summary.topTracks.first?.row.track.title
        let text = shareText(year: year, playCount: eventsThisYear.count,
                             listeningTime: summary.totalListeningTime,
                             topArtist: topArtist, topTrack: topTrack)
        return YearInReview(year: year, playCount: eventsThisYear.count,
                            listeningTime: summary.totalListeningTime,
                            topArtist: topArtist, topTrack: topTrack,
                            shareText: text)
    }

    private static func summarizeForReview(
        events: [PlayEvent],
        rowsByID: [Int64: TrackRow],
        rankLimit: Int
    ) -> (totalListeningTime: TimeInterval, topTracks: [TrackRank], topArtists: [NameRank]) {
        var trackBuckets: [Int64: TrackBucket] = [:]
        var artistBuckets: [String: NameBucket] = [:]
        var total: TimeInterval = 0

        for event in events {
            guard let row = rowsByID[event.trackId] else { continue }
            let duration = max(0, row.track.durationSec ?? 0)
            total += duration
            trackBuckets[event.trackId, default: TrackBucket(row: row)].addPlay(duration: duration)
            artistBuckets[artistName(for: row), default: NameBucket(name: artistName(for: row))]
                .addPlay(duration: duration)
        }

        return (
            total,
            rankedTracks(Array(trackBuckets.values), limit: rankLimit),
            rankedNames(Array(artistBuckets.values), limit: rankLimit))
    }

    private static func periodStart(for date: Date, period: Period, calendar: Calendar) -> Date {
        switch period {
        case .day:
            return calendar.startOfDay(for: date)
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
        case .year:
            return calendar.dateInterval(of: .year, for: date)?.start ?? calendar.startOfDay(for: date)
        }
    }

    private static func shareText(
        year: Int,
        playCount: Int,
        listeningTime: TimeInterval,
        topArtist: String?,
        topTrack: String?
    ) -> String {
        var lines = [
            "Tonearm \(year)",
            "\(playCount) plays",
            durationText(listeningTime),
        ]
        if let topArtist {
            lines.append("Top artist: \(topArtist)")
        }
        if let topTrack {
            lines.append("Top track: \(topTrack)")
        }
        return lines.joined(separator: "\n")
    }

    private static func artistName(for row: TrackRow) -> String {
        let value = row.album?.albumArtist ?? row.album?.artist
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown Artist" : trimmed
    }

    private static func albumName(for row: TrackRow) -> String {
        let title = row.album?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Unknown Album" : title
    }

    private static func trackSortKey(_ row: TrackRow) -> String {
        [artistName(for: row), row.track.title]
            .joined(separator: "\u{0}")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func durationText(_ duration: TimeInterval) -> String {
        let minutes = max(0, Int(duration.rounded()) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
