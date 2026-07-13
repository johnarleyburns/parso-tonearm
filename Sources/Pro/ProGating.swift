import Foundation

/// Pure, testable gating rules for the settings surfaces that Phase 3 gates.
/// Keeping the policy out of the SwiftUI views lets `CachePresetGateTests` /
/// `PrefetchDepthTests` assert behavior without instantiating views.
enum ProGating {

    // MARK: - Cache presets (T3.4)

    /// The largest cache limit a *free* user may select. Presets above this are
    /// Pro-gated; free default stays 500 MB.
    static let freeMaxCacheBytes: Int64 = 500 * 1024 * 1024

    static func isCachePresetLocked(_ bytes: Int64, isPro: Bool) -> Bool {
        if isPro { return false }
        return bytes > freeMaxCacheBytes
    }

    /// Clamps a cache limit to what the current entitlement allows. Used on
    /// downgrade so the *setting* reverts; on-disk content still evicts lazily
    /// via `CacheStore.evictToFit` rather than being bulk-deleted.
    static func allowedCacheLimit(_ bytes: Int64, isPro: Bool) -> Int64 {
        if isPro { return bytes }
        return min(bytes, freeMaxCacheBytes)
    }

    // MARK: - Prefetch depth (T3.5)

    /// Free tier is capped at depth 1 — the value that powers near-gapless and
    /// Opus-when-ready (D7). Pro unlocks deeper values.
    static let freeMaxPrefetchDepth = 1

    static func clampedPrefetchDepth(_ requested: Int, isPro: Bool) -> Int {
        if isPro { return max(0, requested) }
        return min(max(0, requested), freeMaxPrefetchDepth)
    }

    static func isPrefetchDepthLocked(_ depth: Int, isPro: Bool) -> Bool {
        !isPro && depth > freeMaxPrefetchDepth
    }
}
