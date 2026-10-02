import Foundation

/// One track of the bundled Jamendo/archive.org mood-starter index
/// (docs/plans/builtin-mood-starter-index-plan.md, expansion phase): real
/// CC-licensed tracks whose metadata AND precomputed CLAP embedding ship in
/// the app bundle, but whose audio streams from the original host
/// (Jamendo/archive.org) only when the user actually plays one — no bundled
/// audio, no background network fetch for search/indexing.
public struct BuiltInMoodTrack: Codable, Sendable {
    public let id: String
    public let title: String
    public let artist: String
    public let genre: String
    public let license: String
    public let licenseURL: String?
    public let durationSec: Double
    public let streamURL: String
    /// Real report: "none of the Jamendo artwork is loading" — Jamendo's own
    /// `album_image` field (a plain, public, non-authenticated CDN URL), when
    /// the source provides one. `nil` for the archive.org classical items,
    /// which don't carry a comparable per-track image.
    public let artworkURL: String?
    public let dimensions: Int
    public let scale: Double
    public let quantizedVectorBase64: String
    /// Tempo, Camelot key and energy from the same mid-track `FullAnalysis` window the on-device
    /// indexer uses (computed on the Mac by BuiltInAnalyzer). Build a Mix needs BPM + key to
    /// place a track, so without these a fresh install had nothing it could mix. Absent for the
    /// few tracks whose audio couldn't be analysed.
    public let bpm: Double?
    public let key: String?
    public let energy: Double?
    public let analysisScopeSeconds: Double?

    public var hasMusicalAnalysis: Bool { bpm != nil && key != nil }
}

public enum BuiltInMoodIndexProvider {
    public static var tracks: [BuiltInMoodTrack] {
        guard let url = resourceURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BuiltInMoodTrack].self, from: data)) ?? []
    }

    /// The Mood Starter transition-prep pack (BuiltInTransitionPrepPack): the Mac app ships the
    /// full-waveform pack, the iPhone the compact one.
    public static var transitionPrepPackURL: URL? {
        #if os(macOS)
        let names = ["builtin-transition-prep-full", "builtin-transition-prep"]
        #else
        let names = ["builtin-transition-prep"]
        #endif
        for bundle in bundles {
            for name in names {
                if let url = bundle.url(forResource: name, withExtension: "bin")
                    ?? bundle.url(forResource: name, withExtension: "bin", subdirectory: "Audio") {
                    return url
                }
            }
        }
        return nil
    }

    private static var bundles: [Bundle] {
        #if SWIFT_PACKAGE
        return [Bundle.module, .main]
        #else
        return [.main]
        #endif
    }

    private static var resourceURL: URL? {
        let bundles: [Bundle] = {
            #if SWIFT_PACKAGE
            return [Bundle.module, .main]
            #else
            return [.main]
            #endif
        }()
        for bundle in bundles {
            // The app bundle flattens resources; the SwiftPM module bundle keeps the copied
            // `Audio/` folder.
            if let url = bundle.url(forResource: "builtin-mood-index", withExtension: "json")
                ?? bundle.url(forResource: "builtin-mood-index", withExtension: "json", subdirectory: "Audio") {
                return url
            }
        }
        return nil
    }
}
