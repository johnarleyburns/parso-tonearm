#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation

public struct TonearmNowPlayingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var title: String
        public var artist: String
        public var albumTitle: String?
        public var isPlaying: Bool
        public var elapsed: Double
        public var duration: Double
        public var progress: Double
        public var updatedAt: Date
        public var startDate: Date
        public var endDate: Date
        public var artworkFilename: String?

        public init?(snapshot: WidgetSnapshot) {
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

    public var trackID: Int64?

    public init(trackID: Int64?) {
        self.trackID = trackID
    }
}
#endif
