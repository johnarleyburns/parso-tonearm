import Foundation
import ParsoAudioStreaming

/// Pure decision logic for a remote track's phone-download state, given the
/// already-read cache metadata and whether the cached blob exists on disk.
/// No disk access here so it is unit-testable and safe to call anywhere.
public enum PhoneDownloadStateResolver {
    /// Fallback progress when the total size is unknown (or zero).
    static let unknownTotalFraction = 0.05

    public static func resolve(meta: SparseCacheStore.Meta?, blobExists: Bool) -> PhoneDownloadState {
        guard let meta else { return .notDownloaded }
        if (meta.isDurable || meta.complete) && blobExists {
            return .downloaded
        }
        if meta.cachedBytes > 0 {
            let fraction = meta.totalBytes.map {
                $0 > 0 ? Double(meta.cachedBytes) / Double($0) : unknownTotalFraction
            } ?? unknownTotalFraction
            return .downloading(fraction)
        }
        return .notDownloaded
    }
}
