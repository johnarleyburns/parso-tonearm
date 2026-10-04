import Foundation

public enum CrossfadeCurve: String, CaseIterable, Codable, Equatable {
    case equalPower
    case linear

    public struct Gains: Equatable {
        var outgoing: Double
        var incoming: Double
        var active: Bool
    }

    public struct AlbumContinuity: Equatable {
        var albumID: Int64?
        var sourceID: Int64?
        var albumTitle: String?
        var albumArtist: String?
        var discNumber: Int?
        var trackNumber: Int?

        init(albumID: Int64? = nil,
             sourceID: Int64? = nil,
             albumTitle: String? = nil,
             albumArtist: String? = nil,
             discNumber: Int? = nil,
             trackNumber: Int? = nil) {
            self.albumID = albumID
            self.sourceID = sourceID
            self.albumTitle = albumTitle
            self.albumArtist = albumArtist
            self.discNumber = discNumber
            self.trackNumber = trackNumber
        }
    }

    public static func gains(position: TimeInterval,
                      duration: TimeInterval,
                      fadeSeconds: TimeInterval,
                      curve: CrossfadeCurve) -> Gains {
        guard duration.isFinite, duration > 0,
              fadeSeconds.isFinite, fadeSeconds > 0 else {
            return Gains(outgoing: 1, incoming: 0, active: false)
        }

        let fadeWindow = min(duration, fadeSeconds)
        let fadeStart = max(0, duration - fadeWindow)
        return gains(position: position, fadeStart: fadeStart, fadeSeconds: fadeWindow, curve: curve)
    }

    /// Three-phrase DJ handoff: incoming ramps to unity over phrase one,
    /// both remain at unity for phrase two, then outgoing fades over phrase
    /// three. `fadeSeconds` is the complete 96-beat overlap.
    public static func threePhraseGains(position: TimeInterval,
                                        fadeStart: TimeInterval,
                                        fadeSeconds: TimeInterval) -> Gains {
        guard fadeStart.isFinite, fadeSeconds.isFinite, fadeSeconds > 0 else {
            return Gains(outgoing: 1, incoming: 0, active: false)
        }
        guard position >= fadeStart else { return Gains(outgoing: 1, incoming: 0, active: false) }
        let progress = min(max((position - fadeStart) / fadeSeconds, 0), 1)
        if progress < 1.0 / 3.0 {
            return Gains(outgoing: 1, incoming: progress * 3, active: true)
        }
        if progress < 2.0 / 3.0 {
            return Gains(outgoing: 1, incoming: 1, active: true)
        }
        return Gains(outgoing: (1 - progress) * 3, incoming: 1, active: true)
    }

    /// Calculates a fade at an analyzed phrase boundary rather than always
    /// pinning it to the file's final seconds.
    public static func gains(position: TimeInterval,
                             fadeStart: TimeInterval,
                             fadeSeconds: TimeInterval,
                             curve: CrossfadeCurve) -> Gains {
        guard fadeStart.isFinite, fadeSeconds.isFinite, fadeSeconds > 0 else {
            return Gains(outgoing: 1, incoming: 0, active: false)
        }
        let fadeWindow = fadeSeconds
        guard position >= fadeStart else {
            return Gains(outgoing: 1, incoming: 0, active: false)
        }

        let clampedPosition = min(max(position, fadeStart), fadeStart + fadeWindow)
        let progress = fadeWindow > 0 ? (clampedPosition - fadeStart) / fadeWindow : 1
        if progress <= 0 {
            return Gains(outgoing: 1, incoming: 0, active: true)
        }
        if progress >= 1 {
            return Gains(outgoing: 0, incoming: 1, active: true)
        }

        switch curve {
        case .linear:
            return Gains(outgoing: 1 - progress, incoming: progress, active: true)
        case .equalPower:
            let angle = progress * .pi / 2
            return Gains(outgoing: cos(angle), incoming: sin(angle), active: true)
        }
    }

    public static func suppressesForGaplessAlbum(current: AlbumContinuity,
                                          next: AlbumContinuity) -> Bool {
        guard sameAlbum(current, next) else { return false }

        guard let currentTrack = current.trackNumber,
              let nextTrack = next.trackNumber else {
            // Without track numbers only a real album (it names its artist) counts. A
            // collection bucket such as a Mood Starter genre album has no album artist, and
            // treating it as gapless would hard-cut every transition between its tracks.
            return normalized(current.albumArtist) != nil
        }

        if normalizedDisc(current.discNumber) == normalizedDisc(next.discNumber) {
            return nextTrack == currentTrack + 1
        }

        if let currentDisc = current.discNumber,
           let nextDisc = next.discNumber,
           nextDisc == currentDisc + 1 {
            return nextTrack == 1
        }

        return false
    }

    private static func sameAlbum(_ left: AlbumContinuity, _ right: AlbumContinuity) -> Bool {
        if let leftID = left.albumID, let rightID = right.albumID {
            return leftID == rightID
        }

        guard let leftTitle = normalized(left.albumTitle),
              let rightTitle = normalized(right.albumTitle),
              leftTitle == rightTitle else {
            return false
        }

        let leftArtist = normalized(left.albumArtist)
        let rightArtist = normalized(right.albumArtist)
        if leftArtist != nil || rightArtist != nil {
            return leftArtist == rightArtist
        }

        if let leftSource = left.sourceID, let rightSource = right.sourceID {
            return leftSource == rightSource
        }

        return true
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive],
                               locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func normalizedDisc(_ value: Int?) -> Int {
        value ?? 0
    }
}

public extension CrossfadeCurve.AlbumContinuity {
    init(row: TrackRow) {
        self.init(albumID: row.album?.id ?? row.track.albumId,
                  sourceID: row.track.sourceId,
                  albumTitle: row.album?.title,
                  albumArtist: row.album?.albumArtist ?? row.album?.artist,
                  discNumber: row.track.discNo,
                  trackNumber: row.track.trackNo)
    }
}
