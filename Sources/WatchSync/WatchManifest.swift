import Foundation

public struct WatchLocalManifestEntry: Sendable {
    public var trackKey: String
    public var bytes: Int64
    public var pinned: Bool
    public var reportedAt: Date

    public init(trackKey: String, bytes: Int64, pinned: Bool, reportedAt: Date = Date()) {
        self.trackKey = trackKey
        self.bytes = bytes
        self.pinned = pinned
        self.reportedAt = reportedAt
    }
}

public enum WatchManifest {
    public static func totalBytes(_ entries: [WatchLocalManifestEntry]) -> Int64 {
        entries.reduce(0) { $0 + $1.bytes }
    }

    public static func pinnedBytes(_ entries: [WatchLocalManifestEntry]) -> Int64 {
        entries.filter(\.pinned).reduce(0) { $0 + $1.bytes }
    }

    public static func trackCount(_ entries: [WatchLocalManifestEntry]) -> Int {
        entries.count
    }
}
