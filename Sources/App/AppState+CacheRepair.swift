import Foundation
import ParsoAudioStreaming

extension AppState {
    /// Result of a `repairPoisonedCloudDownloads()` run — published via
    /// `AppState.lastCacheRepairResult` so Settings can show it (CLAUDE.md: no silent background
    /// work, even for a quick manual scan).
    struct CacheRepairResult: Equatable {
        var checked: Int
        var repaired: Int
    }

    /// Manual, one-shot repair for an install that already has a poisoned durable cache entry
    /// from before `cacheCompletedDownload`'s HTTP-status check existed: an expired Dropbox/
    /// pCloud temp link or a revoked token whose error-page response body got written to disk
    /// and marked `complete`/durable anyway. Those entries fail every later play and are never
    /// re-fetched on their own — "already downloaded" only ever checked that *something* was
    /// cached, not that it was actually audio.
    ///
    /// Only sniffs entries that are both durable and complete (a normal in-progress stream is
    /// untouched); evicts (not just unpins) anything that fails the check, so the next play
    /// re-resolves and re-fetches fresh through the now-hardened path.
    @discardableResult
    func repairPoisonedCloudDownloads() async -> CacheRepairResult {
        let assets = (try? await store.allAssets()) ?? []
        var checked = 0
        var repaired = 0
        for asset in assets {
            guard asset.kind == .remote, let remoteStr = asset.remoteURL,
                  let remoteURL = URL(string: remoteStr) else { continue }
            let cacheKey = AudioCache.key(for: remoteURL)
            guard let meta = await AudioCache.shared.meta(for: cacheKey), meta.isDurable, meta.complete else { continue }
            checked += 1
            let fileURL = AudioCache.fileURL(for: cacheKey)
            guard let handle = FileHandle(forReadingAtPath: fileURL.path) else { continue }
            let prefix = handle.readData(ofLength: 64)
            handle.closeFile()
            guard !AudioFileSniffer.looksLikeAudio(prefix: prefix) else { continue }
            await AudioCache.shared.remove(keys: [cacheKey])
            repaired += 1
        }
        let result = CacheRepairResult(checked: checked, repaired: repaired)
        lastCacheRepairResult = result
        return result
    }
}
