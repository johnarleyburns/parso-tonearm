import Foundation

/// FR-3.2 / FR-3.3 cache accounting: limit, LRU eviction, GC of stale partials.
/// The cache is passive (Invariant #5): nothing here initiates caching of a track
/// the player/prefetcher didn't request. It only stores/evicts what flows through.
actor CacheStore {
    static let shared = CacheStore()

    struct Meta: Codable {
        var totalBytes: Int64?
        var cachedBytes: Int64
        var complete: Bool
        var lastAccessedAt: Date
        var createdAt: Date
        var rangeMap: ByteRangeMap
    }

    private let dir: URL
    private let metaDir: URL
    private var metas: [String: Meta] = [:]   // key = cacheKey
    private var limitBytes: Int64

    static let limitKey = "cache.limit.bytes"
    static let defaultLimit: Int64 = 500 * 1024 * 1024

    init() {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        dir = base.appendingPathComponent("Tonearm/StreamCache", isDirectory: true)
        metaDir = base.appendingPathComponent("Tonearm/StreamCacheMeta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let stored = UserDefaults.standard.object(forKey: Self.limitKey) as? Int64
        limitBytes = stored ?? Self.defaultLimit
        metas = Self.loadMetas(from: metaDir)
    }

    // MARK: - Public accounting

    func currentLimit() -> Int64 { limitBytes }

    func setLimit(_ bytes: Int64) async {
        limitBytes = bytes
        UserDefaults.standard.set(bytes, forKey: Self.limitKey)
        await evictToFit(protecting: nil)
    }

    func totalCachedBytes() -> Int64 {
        metas.values.reduce(0) { $0 + $1.cachedBytes }
    }

    func cachedTrackCount() -> Int {
        metas.values.filter { $0.complete }.count
    }

    func state(for key: String) -> CacheGlyphState {
        guard let m = metas[key] else { return .none }
        if m.complete { return .cached }
        guard let total = m.totalBytes, total > 0 else { return .filling(0.05) }
        return .filling(Double(m.cachedBytes) / Double(total))
    }

    func fileURL(for key: String) -> URL {
        dir.appendingPathComponent(key)
    }

    func rangeMap(for key: String) -> ByteRangeMap {
        metas[key]?.rangeMap ?? ByteRangeMap()
    }

    func totalBytes(for key: String) -> Int64? {
        metas[key]?.totalBytes
    }

    // MARK: - Mutation (driven by the resource loader only)

    func setContentLength(_ length: Int64, for key: String) {
        var m = metas[key] ?? Meta(totalBytes: nil, cachedBytes: 0, complete: false,
                                    lastAccessedAt: Date(), createdAt: Date(), rangeMap: ByteRangeMap())
        m.totalBytes = length
        metas[key] = m
        persistMeta(key)
    }

    func recordWrite(range: Range<Int64>, for key: String) async {
        var m = metas[key] ?? Meta(totalBytes: nil, cachedBytes: 0, complete: false,
                                   lastAccessedAt: Date(), createdAt: Date(), rangeMap: ByteRangeMap())
        m.rangeMap.insert(range)
        m.cachedBytes = m.rangeMap.totalBytes()
        if let total = m.totalBytes, m.rangeMap.covers(total: total) {
            m.complete = true
        }
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
        await evictToFit(protecting: key)
    }

    func touch(_ key: String) {
        guard var m = metas[key] else { return }
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
    }

    func clearAll() {
        for key in metas.keys {
            try? FileManager.default.removeItem(at: fileURL(for: key))
            try? FileManager.default.removeItem(at: metaURL(key))
        }
        metas.removeAll()
    }

    /// FR-3.3: GC partial segments older than 7 days.
    func garbageCollectStalePartials() {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for (key, m) in metas where !m.complete && m.lastAccessedAt < cutoff {
            remove(key)
        }
    }

    // MARK: - Eviction

    private func evictToFit(protecting protectedKey: String?) async {
        guard limitBytes > 0 else { return }
        var total = totalCachedBytes()
        guard total > limitBytes else { return }
        let candidates = metas
            .filter { $0.key != protectedKey }
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        for (key, m) in candidates {
            if total <= limitBytes { break }
            remove(key)
            total -= m.cachedBytes
        }
    }

    private func remove(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
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
