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
    public let dimensions: Int
    public let scale: Double
    public let quantizedVectorBase64: String
}

public enum BuiltInMoodIndexProvider {
    public static var tracks: [BuiltInMoodTrack] {
        guard let url = resourceURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BuiltInMoodTrack].self, from: data)) ?? []
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
            if let url = bundle.url(forResource: "builtin-mood-index", withExtension: "json") {
                return url
            }
        }
        return nil
    }
}
