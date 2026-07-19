import Foundation

/// FR-3.2 / FR-3.3 cache accounting: limit, LRU eviction, GC of stale partials.
/// The cache is passive (Invariant #5): nothing here initiates caching of a track
/// the player/prefetcher didn't request. It only stores/evicts what flows through.
public actor CacheStore {
    public static let shared = CacheStore()

    public struct Meta: Codable {
        var totalBytes: Int64?
        var cachedBytes: Int64
        var complete: Bool
        var lastAccessedAt: Date
        var createdAt: Date
        var rangeMap: ByteRangeMap
        /// Byte size of the remuxed Opus CAF sibling, if one exists. Counted in
        /// `totalCachedBytes()` so eviction accounts for the real on-disk artifact.
        var cafBytes: Int64? = nil
        /// Pin state is persisted with cache metadata. `nil` decodes as unpinned
        /// for caches written before pinning existed.
        var pinned: Bool? = nil
    }

    private let dir: URL
    private let metaDir: URL
    private var metas: [String: Meta] = [:]   // key = cacheKey
    private var limitBytes: Int64
    /// When true (tests), the limit is not persisted to shared UserDefaults.
    private let isolated: Bool

    /// After F1 (Hasher → SHA256), old Hasher-based cache keys are unrecoverable
    /// across launches. A one-shot wipe clears orphaned files and metadata so they
    /// don't squat on the limit. Increment this when the key scheme changes.
    private static let cacheSchemaVersionKey = "cache.schema.version"
    private static let currentSchemaVersion = 1

    public static let limitKey = "cache.limit.bytes"
    public static let defaultLimit: Int64 = 500 * 1024 * 1024

    public init() {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("Tonearm/StreamCache", isDirectory: true)
        metaDir = base.appendingPathComponent("Tonearm/StreamCacheMeta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let stored = UserDefaults.standard.object(forKey: Self.limitKey) as? Int64
        limitBytes = stored ?? Self.defaultLimit
        isolated = false
        let existing = Self.loadMetas(from: metaDir)
        if UserDefaults.standard.integer(forKey: Self.cacheSchemaVersionKey) < Self.currentSchemaVersion {
            for key in existing.keys {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(key))
                try? FileManager.default.removeItem(at: metaDir.appendingPathComponent("\(key).json"))
            }
            UserDefaults.standard.set(Self.currentSchemaVersion, forKey: Self.cacheSchemaVersionKey)
            metas = [:]
        } else {
            metas = existing
        }
    }

    /// Isolated instance rooted at a private directory for tests; does not read
    /// or persist the shared cache limit.
    public init(rootDirectory: URL, limitBytes: Int64 = defaultLimit) {
        dir = rootDirectory.appendingPathComponent("StreamCache", isDirectory: true)
        metaDir = rootDirectory.appendingPathComponent("StreamCacheMeta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        self.limitBytes = limitBytes
        isolated = true
        metas = Self.loadMetas(from: metaDir)
    }

    // MARK: - Public accounting

    public func currentLimit() -> Int64 { limitBytes }

    public func setLimit(_ bytes: Int64) async {
        limitBytes = bytes
        if !isolated { UserDefaults.standard.set(bytes, forKey: Self.limitKey) }
        await evictToFit(protecting: nil)
    }

    public func totalCachedBytes() -> Int64 {
        metas.values.reduce(0) { $0 + $1.cachedBytes + ($1.cafBytes ?? 0) }
    }

    public func cachedTrackCount() -> Int {
        metas.values.filter { $0.complete }.count
    }

    public func pinnedTrackCount() -> Int {
        metas.values.filter { $0.pinned == true }.count
    }

    public func state(for key: String) -> CacheGlyphState {
        guard let m = metas[key] else { return .none }
        if m.complete { return .cached }
        guard let total = m.totalBytes, total > 0 else { return .filling(0.05) }
        return .filling(Double(m.cachedBytes) / Double(total))
    }

    public func fileURL(for key: String) -> URL {
        dir.appendingPathComponent(key)
    }

    /// Sibling CAF URL for a remuxed Opus key.
    public func cafURL(for key: String) -> URL {
        fileURL(for: key).deletingPathExtension().appendingPathExtension("caf")
    }

    /// True when a playable remuxed CAF exists on disk for this key.
    public func hasRemuxedCAF(for key: String) -> Bool {
        FileManager.default.fileExists(atPath: cafURL(for: key).path)
    }

    public func rangeMap(for key: String) -> ByteRangeMap {
        metas[key]?.rangeMap ?? ByteRangeMap()
    }

    public func totalBytes(for key: String) -> Int64? {
        metas[key]?.totalBytes
    }

    public func isPinned(_ key: String) -> Bool {
        metas[key]?.pinned == true
    }

    // MARK: - Mutation (driven by the resource loader only)

    public func setContentLength(_ length: Int64, for key: String) {
        var m = metas[key] ?? Meta(totalBytes: nil, cachedBytes: 0, complete: false,
                                    lastAccessedAt: Date(), createdAt: Date(), rangeMap: ByteRangeMap())
        m.totalBytes = length
        metas[key] = m
        persistMeta(key)
    }

    public func recordWrite(range: Range<Int64>, for key: String) async {
        var m = metas[key] ?? Meta(totalBytes: nil, cachedBytes: 0, complete: false,
                                   lastAccessedAt: Date(), createdAt: Date(), rangeMap: ByteRangeMap())
        let wasComplete = m.complete
        m.rangeMap.insert(range)
        m.cachedBytes = m.rangeMap.totalBytes()
        if let total = m.totalBytes, m.rangeMap.covers(total: total) {
            m.complete = true
        }
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
        // Trigger Opus→CAF remux the moment an `.opus` key completes (T2.3).
        if m.complete && !wasComplete && Self.isOpusKey(key) {
#if !os(watchOS)
            triggerOpusRemux(for: key)
#endif
        }
        await evictToFit(protecting: key)
    }

    /// Records the byte size of a remuxed CAF sibling so it counts toward the
    /// cache budget (T2.3). Called by the remux path after a successful write.
    public func recordCAFBytes(_ bytes: Int64, for key: String) async {
        guard var m = metas[key] else { return }
        m.cafBytes = bytes
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
        await evictToFit(protecting: key)
    }

    public static func isOpusKey(_ key: String) -> Bool {
        key.hasSuffix("-opus")
    }

    /// Kicks off a background remux of a completed `.opus` cache file to a sibling
    /// `.caf`, updating cache accounting on success. Fire-and-forget; failures are
    /// swallowed (the remuxer marks the key unavailable for playback fallback).
#if !os(watchOS)
    private func triggerOpusRemux(for key: String) {
        let opusURL = fileURL(for: key)
        Task.detached(priority: .utility) {
            guard let caf = try? await OpusRemuxer.shared.remux(opusFileURL: opusURL, cacheKey: key) else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: caf.path)[.size] as? Int64) ?? nil
            await CacheStore.shared.recordCAFBytes(size ?? 0, for: key)
        }
    }
#endif

    public func touch(_ key: String) {
        guard var m = metas[key] else { return }
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
    }

    public func setPinned(_ pinned: Bool, for key: String) async {
        guard var m = metas[key] else { return }
        m.pinned = pinned
        metas[key] = m
        persistMeta(key)
        await evictToFit(protecting: key)
    }

    public func clearAll() {
        for key in metas.keys {
            try? FileManager.default.removeItem(at: fileURL(for: key))
            try? FileManager.default.removeItem(at: cafURL(for: key))
            try? FileManager.default.removeItem(at: metaURL(key))
        }
        metas.removeAll()
    }

    /// FR-3.3: GC partial segments older than 7 days.
    public func garbageCollectStalePartials() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for (key, m) in metas where !m.complete && m.lastAccessedAt < cutoff {
            remove(key)
        }
    }

    // MARK: - Eviction

    /// Keys that eviction must never remove. Maintained by the player so the
    /// currently playing track and its active prefetch/warm loaders are never
    /// evicted mid-stream (F6). Call `setProtectedKeys` to atomically replace.
    private var protectedKeys: Set<String> = []

    public func setProtectedKeys(_ keys: Set<String>) {
        protectedKeys = keys
    }

    private func evictToFit(protecting extraKey: String? = nil) async {
        var protected = protectedKeys
        if let extraKey { protected.insert(extraKey) }
        guard limitBytes > 0 else { return }
        let plan = PinPolicy.evictionPlan(
            items: metas.map { key, meta in
                PinPolicy.Item(
                    key: key,
                    bytes: meta.cachedBytes + (meta.cafBytes ?? 0),
                    lastAccessedAt: meta.lastAccessedAt,
                    isPinned: meta.pinned == true
                )
            },
            cacheLimitBytes: limitBytes,
            proEnabled: true,
            protectedKeys: protected
        )
        for key in plan.evictKeys {
            remove(key)
        }
    }

    private func remove(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
        try? FileManager.default.removeItem(at: cafURL(for: key))
        try? FileManager.default.removeItem(at: metaURL(key))
        metas.removeValue(forKey: key)
    }

    // MARK: - Persistence

    private func metaURL(_ key: String) -> URL {
        metaDir.appendingPathComponent("\(key).json")
    }

    private func persistMeta(_ key: String) {
        guard let m = metas[key], let data = try? JSONEncoder().encode(m) else { return }
        try? data.write(to: metaURL(key))
    }

    private static func loadMetas(from metaDir: URL) -> [String: Meta] {
        var result: [String: Meta] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(at: metaDir,
                                                                       includingPropertiesForKeys: nil) else {
            return result
        }
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            if let data = try? Data(contentsOf: file),
               let m = try? JSONDecoder().decode(Meta.self, from: data) {
                result[key] = m
            }
        }
        return result
    }
}

public extension CacheStore {
    /// Non-actor-isolated cache directory (same computation as `init`), so the
    /// @MainActor player can derive on-disk paths synchronously without awaiting
    /// the actor. Read-only path math — never mutates cache state.
    nonisolated static var cacheDirectory: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Tonearm/StreamCache", isDirectory: true)
    }

    nonisolated static func fileURL(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key)
    }

    nonisolated static var cacheMetaDirectory: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Tonearm/StreamCacheMeta", isDirectory: true)
    }

    nonisolated static func completeCacheExists(for remote: URL) -> Bool {
        let key = CacheKeyGenerator.key(for: remote)
        let metaURL = cacheMetaDirectory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data),
              meta.complete else {
            return false
        }
        return FileManager.default.fileExists(atPath: fileURL(for: key).path)
    }

    /// On-disk CAF sibling for a remote Opus URL, whether or not it exists yet.
    nonisolated static func cafURL(forRemoteOpus url: URL) -> URL {
        let key = CacheKeyGenerator.key(for: url)
        return fileURL(for: key).deletingPathExtension().appendingPathExtension("caf")
    }
}
