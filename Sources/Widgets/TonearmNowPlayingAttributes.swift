import ActivityKit
import Foundation

struct TonearmNowPlayingAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var albumTitle: String?
        var isPlaying: Bool
        var elapsed: Double
        var duration: Double
        var progress: Double
        var updatedAt: Date
        var startDate: Date
        var endDate: Date
        var artworkFilename: String?

        init?(snapshot: WidgetSnapshot) {
            guard let nowPlaying = snapshot.nowPlaying else { return nil }
            title = nowPlaying.track.title
            artist = nowPlaying.track.artist
            albumTitle = nowPlaying.track.albumTitle
            isPlaying = nowPlaying.isPlaying
            elapsed = nowPlaying.elapsed
            duration = nowPlaying.duration
            progress = nowPlaying.progress
            updatedAt = nowPlaying.updatedAt
            startDate = nowPlaying.startDate
            endDate = nowPlaying.endDate
            artworkFilename = nowPlaying.track.artworkFilename
        }
    }

    var trackID: Int64?
}
