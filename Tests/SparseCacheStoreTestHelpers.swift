import Foundation
import ParsoAudioStreaming

extension SparseCacheStore {
    /// Test convenience: single-tier store isolated under one throwaway
    /// directory. Mirrors the old `CacheStore(rootDirectory:)`.
    init(rootDirectory: URL) {
        self.init(evictableRoot: rootDirectory, durableRoot: nil)
    }
}
