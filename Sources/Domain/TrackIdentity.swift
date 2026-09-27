import CryptoKit
import Foundation

public struct TrackIdentityKey: Equatable, Hashable, Codable, Sendable {
    public enum Strength: String, Codable, Sendable { case source, meta }
    public let strength: Strength
    public let value: String
    public init(strength: Strength, value: String) { self.strength = strength; self.value = value }
    public var cloudValue: String { "\(strength.rawValue):\(value)" }
}
public enum TrackIdentity {
    public static func keys(track: Track, asset: Asset?, source: Source?) -> [TrackIdentityKey] {
        var result: [TrackIdentityKey] = []
        if let sourceValue = sourceValue(asset: asset, source: source) {
            result.append(.init(strength: .source, value: digest(sourceValue)))
        }
        let artist = sourceArtist(track: track, source: source)
        let meta = [artist, track.title, sourceAlbum(track: track), roundedDuration(track.durationSec)]
            .map(normalize).joined(separator: "|")
        result.append(.init(strength: .meta, value: digest("meta:\(meta)")))
        return result
    }

    private static func sourceValue(asset: Asset?, source: Source?) -> String? {
        guard let asset, let source else { return nil }
        if source.kind == .iaItem, let identifier = source.iaIdentifier,
           let path = URL(string: asset.remoteURL ?? "")?.path, !path.isEmpty {
            return "ia:\(identifier)/\(URL(fileURLWithPath: path).lastPathComponent)"
        }
        if let node = asset.remoteNodePath, let original = source.originalURL,
           let host = URL(string: original)?.host {
            return "remote:\(source.kind.rawValue):\(host):\(node)"
        }
        return nil
    }

    private static func sourceArtist(track: Track, source: Source?) -> String {
        _ = source
        return track.artistId.map(String.init) ?? ""
    }

    private static func sourceAlbum(track: Track) -> String { track.albumId.map(String.init) ?? "" }
    private static func roundedDuration(_ value: Double?) -> String { String(Int((value ?? 0).rounded())) }
    private static func normalize(_ value: String) -> String {
        var text = value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if text.hasPrefix("the ") { text.removeFirst(4) }
        return text
    }
    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
