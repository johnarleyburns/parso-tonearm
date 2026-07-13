import Foundation

enum RemotePathPolicy {
    static let defaultPageCap = CollectionResolver.memberCap

    static let audioExtensions: Set<String> = [
        "aac", "aif", "aiff", "alac", "caf", "flac", "m4a", "m4b",
        "mp3", "oga", "ogg", "opus", "wav"
    ]

    struct NormalizedPath: Equatable {
        var rawValue: String
        var segments: [String]
    }

    enum Rejection: Error, Equatable {
        case absolutePath
        case traversal
        case encodedSeparator
        case emptySegment
        case invalidEncoding
        case nonAudioExtension
        case pageCapExceeded(limit: Int)
    }

    struct Page<T> {
        var items: [T]
        var capHit: Bool
    }

    static func normalize(_ rawPath: String) throws -> NormalizedPath {
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

    static func acceptsAudioFile(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext)
    }

    static func requireAudioFile(path: String) throws {
        guard acceptsAudioFile(path: path) else {
            throw Rejection.nonAudioExtension
        }
    }

    static func audioNodes(from nodes: [RemoteNode]) -> [RemoteNode] {
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

    static func cappedPage<T>(_ items: [T], limit: Int = defaultPageCap) -> Page<T> {
        Page(items: Array(items.prefix(limit)), capHit: items.count > limit)
    }

    static func enforcePageCap<T>(_ items: [T], limit: Int = defaultPageCap) throws -> [T] {
        guard items.count <= limit else {
            throw Rejection.pageCapExceeded(limit: limit)
        }
        return items
    }
}
