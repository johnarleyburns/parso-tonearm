#if !os(watchOS)
import Foundation

/// Filesystem locations owned by the discovery subsystem (plan §8).
///
/// The vector binary cache lives under a NEW core discovery Caches directory —
/// never the old DJ `vectors.i8` path (plan §8: "put vector cache files under
/// a new core discovery Caches directory. Do not trust an old DJ vectors.i8
/// file"). It is disposable derived state: a missing or truncated file is
/// rebuilt from the authoritative `discovery_embedding` rows.
public enum DiscoveryCaches {
    /// `<Caches>/Tonearm/Discovery/`, created on demand. Falls back to a
    /// temporary directory only if the Caches URL cannot be resolved (never
    /// expected on iOS/macOS) so callers always get a usable, writable path.
    public static func directory() -> URL {
        let fm = FileManager.default
        let base: URL
        if let caches = try? fm.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        {
            base = caches
        } else {
            base = fm.temporaryDirectory
        }
        let dir = base
            .appendingPathComponent("Tonearm", isDirectory: true)
            .appendingPathComponent("Discovery", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The quantized whole-catalog vector matrix snapshot file.
    public static func vectorCacheURL() -> URL {
        directory().appendingPathComponent("vectors.v1.bin")
    }
}
#endif
