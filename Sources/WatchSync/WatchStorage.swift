import Foundation

public enum WatchStorage {
    public static let watchAudioDirName = "WatchAudio"
    public static let orphansDirName = "WatchAudio/orphans"
    public static let cacheDirName = "StreamCache"

    public struct Accounting: Equatable {
        public var pinnedBytes: Int64
        public var cacheBytes: Int64
        public var freeBytes: Int64
        public var totalBytes: Int64

        public var usedBytes: Int64 { pinnedBytes + cacheBytes }
        public var usageFraction: Double {
            totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
        }
    }

    /// Compute storage accounting from manifest entries and system free space.
    public static func accounting(manifestEntries: [WatchLocalManifestEntry],
                                  freeBytes: Int64,
                                  totalBytes: Int64) -> Accounting {
        let pinned = manifestEntries.filter(\.pinned).reduce(Int64(0)) { $0 + $1.bytes }
        let cache = manifestEntries.filter { !$0.pinned }.reduce(Int64(0)) { $0 + $1.bytes }
        return Accounting(pinnedBytes: pinned, cacheBytes: cache, freeBytes: freeBytes, totalBytes: totalBytes)
    }

    /// Check if enough free space is available (reserve 100 MB).
    public static func hasFreeSpace(freeBytes: Int64, reserve: Int64 = 100 * 1024 * 1024) -> Bool {
        freeBytes >= reserve
    }

    /// Track keys to remove when clearing pinned content for a collection.
    public static func keysForCollection(
        _ trackKeys: [String],
        manifestEntries: [WatchLocalManifestEntry]
    ) -> [String] {
        let pinnedKeys = Set(manifestEntries.filter(\.pinned).map(\.trackKey))
        return trackKeys.filter { pinnedKeys.contains($0) }
    }

    /// Compute bytes to free for a set of keys.
    public static func bytesForKeys(_ keys: Set<String>,
                                     manifestEntries: [WatchLocalManifestEntry]) -> Int64 {
        manifestEntries.filter { keys.contains($0.trackKey) }.reduce(0) { $0 + $1.bytes }
    }
}
