import CryptoKit
import Foundation

/// Stable, privacy-preserving content identities used by discovery and DJ
/// preparation sync. The source key is preferred, while the metadata key lets
/// a local copy match an Internet Archive or remote copy on another device.
public struct TrackIdentityKey: Equatable, Hashable, Codable, Sendable {
    public enum Strength: String, Codable, Sendable { case source, meta }
    public let strength: Strength
    public let value: String

    public init(strength: Strength, value: String) {
        self.strength = strength; self.value = value
    }

    public var cloudValue: String { "\(strength.rawValue):\(value)" }
}

public enum TrackIdentity {
    public static func keys(track: Track, asset: Asset?, source: Source?, artist: String? = nil, album: String? = nil) -> [TrackIdentityKey] {
        var result: [TrackIdentityKey] = []
        if let sourceString = sourceString(track: track, asset: asset, source: source) {
            result.append(.init(strength: .source, value: hash(sourceString)))
        }
        let artist = ArtistNamePolicy.normalize(artist ?? "") ?? ""
        let meta = ["meta", normalize(artist), normalize(track.title), normalize(album ?? ""),
                    String(Int((track.durationSec ?? 0).rounded()))].joined(separator: "|")
        result.append(.init(strength: .meta, value: hash(meta)))
        return result
    }

    public static func parse(_ values: [String]) -> [TrackIdentityKey] {
        values.compactMap { value in
            let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let strength = TrackIdentityKey.Strength(rawValue: parts[0]) else { return nil }
            return TrackIdentityKey(strength: strength, value: parts[1])
        }
    }

    private static func sourceString(track: Track, asset: Asset?, source: Source?) -> String? {
        guard let source else { return nil }
        if source.kind == .iaItem, let identifier = source.iaIdentifier,
           let remoteURL = asset?.remoteURL,
           let url = URL(string: remoteURL), !url.path.isEmpty {
            return "ia:\(identifier)/\(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)"
        }
        if let nodePath = asset?.remoteNodePath, !nodePath.isEmpty,
           let original = source.originalURL, let host = URL(string: original)?.host {
            return "remote:\(source.kind.rawValue):\(host)/\(nodePath)"
        }
        return nil
    }

    private static func normalize(_ raw: String) -> String {
        // NFKC first makes compatibility spellings (full-width characters,
        // ligatures, etc.) match the same track identity across devices.
        var value = raw.decomposedStringWithCompatibilityMapping
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if value.hasPrefix("the ") { value.removeFirst(4) }
        return value
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
