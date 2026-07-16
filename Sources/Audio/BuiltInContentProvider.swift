import Foundation

public struct AmbientTrack {
    public let channelId: String
    public let title: String
    public let artist: String
    public let freesoundId: String
}

public enum BuiltInContentProvider {
    public static let ambientPlaylistId: Int64 = -1
    public static let ambientPlaylistTitle = "Ambient"
    public static let ambientSourceId: Int64 = -1

    public static let tracks: [AmbientTrack] = [
        AmbientTrack(channelId: "ambient-rain",
                     title: "Rainy Day",
                     artist: "speakwithanimals",
                     freesoundId: "525046"),
        AmbientTrack(channelId: "ambient-ocean",
                     title: "Ocean Waves",
                     artist: "Nox_Sound",
                     freesoundId: "829629"),
        AmbientTrack(channelId: "ambient-flowing-water",
                     title: "Flowing Water",
                     artist: "eardeer",
                     freesoundId: "443869"),
    ]

    public static var allTrackRows: [TrackRow] {
        tracks.map { row(for: $0) }
    }

    public static func row(for ambient: AmbientTrack) -> TrackRow {
        let track = Track(id: nil, albumId: nil, sourceId: ambientSourceId,
                          title: ambient.title, trackNo: nil, discNo: nil,
                          durationSec: 0, codec: "WAV", sampleRate: 44100,
                          bitDepthOrBitrate: "16-bit",
                          sortKey: ambient.title.lowercased())
        let album = Album(id: nil, sourceId: ambientSourceId,
                          title: "Ambient Sounds", artist: ambient.artist,
                          year: nil, artworkId: ambient.channelId)
        let source = Source(id: ambientSourceId, kind: .iaItem,
                            iaIdentifier: nil,
                            originalURL: nil, title: "Built-in Ambient",
                            addedAt: Date(), lastResolvedAt: nil,
                            followUpdates: false, licenseText: "CC0 Public Domain",
                            memberCapHit: false)
        let asset = Asset(id: nil, trackId: 0, kind: .builtIn,
                          bookmark: nil, relPath: bundledAudioName(for: ambient.channelId),
                          remoteURL: nil, altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
        return TrackRow(track: track, album: album, source: source, asset: asset)
    }

    public static func bundledAudioName(for channelId: String) -> String? {
        for ext in ["wav", "caf", "aiff", "m4a", "aac", "mp3"] {
            let name = "\(channelId).\(ext)"
            if resourceURL(for: channelId, withExtension: ext) != nil {
                return name
            }
        }
        return nil
    }

    public static func bundledAudioURL(forChannelId id: String) -> URL? {
        for ext in ["wav", "caf", "aiff", "m4a", "aac", "mp3"] {
            if let url = resourceURL(for: id, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    public static func bundledVideoURL(forChannelId id: String) -> URL? {
        for ext in ["mp4", "mov", "m4v"] {
            if let url = resourceURL(for: id, withExtension: ext) {
                return url
            }
        }
        return nil
    }

    private static func resourceURL(for name: String, withExtension ext: String) -> URL? {
        for bundle in resourceBundles {
            if let url = bundle.url(forResource: name, withExtension: ext) {
                return url
            }
            for subdirectory in ["Audio", "Video"] {
                if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory) {
                    return url
                }
            }
        }
        return nil
    }

    private static var resourceBundles: [Bundle] {
        #if SWIFT_PACKAGE
        return [Bundle.module, .main]
        #else
        return [.main]
        #endif
    }
}
