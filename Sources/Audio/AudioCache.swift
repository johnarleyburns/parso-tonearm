import Foundation
import ParsoAudioStreaming

/// Composition root for Tonearm's streaming cache. Storage, byte-range
/// accounting, LRU eviction (protecting the playing/prefetching keys and pinned
/// downloads) and the resource loader are `ParsoAudioStreaming.SparseCacheStore`
/// / `CachingResourceLoader`, shared with parso-voxglass (see
/// `parso-audio-engine/docs/UNIFICATION_PLAN.md` Phase 2).
///
/// This enum keeps only what is Tonearm-specific: the `tonearm-cache` scheme, the
/// historical `<sha256>-<ext>` key identity, the persisted cache-limit
/// preference, and path helpers for the `@MainActor` player / watch adapter that
/// must resolve on-disk paths synchronously.
///
/// Pinned tracks are marked *durable* (`setDurable(_:for:)`): eviction never
/// removes them and their bytes sit outside the streaming budget. Single-tier —
/// the durable and evictable roots are the same directory.
public enum AudioCache {

    public static let scheme = "tonearm-cache"

    /// Tonearm's historical key: `<sha256hex>-<ext>`, always with the trailing
    /// separator even when the URL has no extension.
    public static let keyStrategy: CacheKeyStrategy = .sha256WithExtension

    public static func key(for url: URL) -> String { keyStrategy.key(url) }

    static let root: URL = {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Tonearm/StreamCacheV2", isDirectory: true)
    }()

    public static let limitDefaultsKey = "cache.limit.bytes"

    private static var savedLimit: Int64 {
        (UserDefaults.standard.object(forKey: limitDefaultsKey) as? Int64) ?? SparseCacheStore.defaultLimit
    }

    public static let shared = SparseCacheStore(
        evictableRoot: root, durableRoot: root, limitBytes: savedLimit)

    /// Synchronous, actor-free view of the same layout.
    public static let layout = SparseCacheLayout(evictableRoot: root, durableRoot: root)

    /// Sets and persists the streaming-cache budget.
    public static func setLimit(_ bytes: Int64) async {
        UserDefaults.standard.set(bytes, forKey: limitDefaultsKey)
        await shared.setLimit(bytes)
    }

    // MARK: - Synchronous path helpers (player / watch adapter / DJ importer)

    public static func fileURL(for key: String) -> URL { layout.blobURL(for: key) }

    public static func metaURL(for key: String) -> URL { layout.metaURL(for: key) }

    public static func completeCacheExists(for remote: URL) -> Bool {
        layout.completeBlobExists(for: key(for: remote))
    }

    /// On-disk CAF sibling (a named derived artifact) for a remote Opus URL,
    /// whether or not it exists yet.
    public static func cafURL(forRemoteOpus url: URL) -> URL {
        layout.derivedURL(for: key(for: url), name: cafArtifactName)
    }

    public static let cafArtifactName = "opus.caf"

    #if !os(watchOS)
    public static func loaderConfig(headers: [String: String] = [:]) -> CachingResourceLoaderConfig {
        CachingResourceLoaderConfig(scheme: scheme, headers: headers, keyStrategy: keyStrategy)
    }
    #endif
}

public extension CacheGlyphState {
    /// The fill glyph for a cache entry, derived from its metadata. Was
    /// `CacheStore.state(for:)`.
    static func of(_ meta: SparseCacheStore.Meta?) -> CacheGlyphState {
        guard let meta else { return .none }
        if meta.complete { return .cached }
        guard let total = meta.totalBytes, total > 0 else { return .filling(0.05) }
        return .filling(Double(meta.cachedBytes) / Double(total))
    }
}
