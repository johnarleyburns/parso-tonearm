import Foundation
import ParsoAudioPlayback

/// ReplayGain tag parsing + gain math is now shared: `parso-audio-engine`'s
/// `ReplayGainReader` / `NormalizationPlanner` (`ParsoAudioPlayback`) is the same
/// parser Tonearm authored, relicensed into PAE
/// (parso-audio-engine/docs/UNIFICATION_PLAN.md §3). This is a thin compatibility
/// shim over those types so existing call sites (`AudioPlayer`,
/// `MetadataNormalizer`) keep working; the `Track` convenience stays app-side.
public enum ReplayGain {
    public typealias Mode = NormalizationPlanner.Mode
    public typealias Tags = ReplayGainTags
    public typealias TagItem = ReplayGainTagItem

    public static func parse(items: [TagItem]) -> Tags {
        ReplayGainReader.parse(items: items)
    }

    public static func appliedGain(
        mode: Mode,
        tags: Tags,
        preampDB: Double = 0,
        preventClipping: Bool = true
    ) -> Double {
        NormalizationPlanner(mode: mode, preampDB: preampDB, preventClipping: preventClipping)
            .gain(from: tags)
    }

    public static func parseGainDB(_ raw: String?) -> Double? { ReplayGainReader.gainDB(from: raw) }
    public static func parsePeak(_ raw: String?) -> Double? { ReplayGainReader.peak(from: raw) }
}

public extension Track {
    var replayGainTags: ReplayGain.Tags {
        ReplayGain.Tags(trackGainDB: rgTrackGain,
                        albumGainDB: rgAlbumGain,
                        trackPeak: rgTrackPeak,
                        albumPeak: rgAlbumPeak)
    }
}
