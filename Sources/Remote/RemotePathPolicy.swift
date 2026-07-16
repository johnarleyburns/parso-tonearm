import Foundation

public enum RemotePathPolicy {
    public static let defaultPageCap = CollectionResolver.memberCap

    public static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "m4b",
        "mp3", "oga", "ogg", "opus", "wav"
    ]

    public struct NormalizedPath: Equatable {
        var rawValue: String
        var segments: [String]
    }

    public enum Rejection: Error, Equatable {
        case absolutePath
        case traversal
        case encodedSeparator
        case emptySegment
        case invalidEncoding
        case nonAudioExtension
        case pageCapExceeded(limit: Int)
    }

    public struct Page<T> {
        var items: [T]
        var capHit: Bool
    }

    public static func normalize(_ rawPath: String) throws -> NormalizedPath {
        if rawPath.isEmpty {
            return NormalizedPath(rawValue: "", segments: [])
        }
        if rawPath.hasPrefix("/") || rawPath.hasPrefix("\\") {
            throw Rejection.absolutePath
        }

        let lowercased = rawPath.lowercased()
        if lowercased.contains("%2f") || lowercased.contains("%5c") {
            throw Rejection.encodedSeparator
        }
        if rawPath.contains("\\") {
            throw Rejection.encodedSeparator
        }

        let rawSegments = rawPath.split(separator: "/", omittingEmptySubsequences: false)
        if rawSegments.contains(where: { $0.isEmpty }) {
            throw Rejection.emptySegment
        }

        let segments = try rawSegments.map { segment -> String in
            guard let decoded = String(segment).removingPercentEncoding else {
                throw Rejection.invalidEncoding
            }
            if decoded.contains("/") || decoded.contains("\\") {
                throw Rejection.encodedSeparator
            }
            if decoded.isEmpty {
                throw Rejection.emptySegment
            }
            if decoded == "." || decoded == ".." {
                throw Rejection.traversal
            }
            return decoded
        }

        return NormalizedPath(rawValue: segments.joined(separator: "/"), segments: segments)
    }

    public static func acceptsAudioFile(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext)
    }

    public static func requireAudioFile(path: String) throws {
        guard acceptsAudioFile(path: path) else {
            throw Rejection.nonAudioExtension
        }
    }

    public static func audioNodes(from nodes: [RemoteNode]) -> [RemoteNode] {
        nodes.filter { node in
            switch node.kind {
            case .directory, .collection:
                return true
            case .audio:
                return acceptsAudioFile(path: node.path)
            case .item:
                return false
            }
        }
    }

    public static func cappedPage<T>(_ items: [T], limit: Int = defaultPageCap) -> Page<T> {
        Page(items: Array(items.prefix(limit)), capHit: items.count > limit)
    }

    public static func enforcePageCap<T>(_ items: [T], limit: Int = defaultPageCap) throws -> [T] {
        guard items.count <= limit else {
            throw Rejection.pageCapExceeded(limit: limit)
        }
        return items
    }
}
