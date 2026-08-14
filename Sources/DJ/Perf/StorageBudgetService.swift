import Foundation

/// §43.6 storage budget and cache eviction — the pure disk-budget policy.
///
/// Regenerable caches are evictable under pressure by an LRU policy; mixes are
/// user content and are **never** auto-evicted (the app asks, it never chooses).
/// This type is the policy only — a decision table over byte numbers, with no
/// file or database I/O — so the budget, the LRU ordering and the "show the
/// eviction before doing it" contract are all testable deterministically
/// (AT-STEM-\*, FR-ANL-9). The I/O side (`GigCrateRepository`, `StemCache`)
/// performs the eviction the preview names.
public enum StorageBudgetService {

    /// §43.6's default stem budget per device class: iPhone **4 GB**, iPad
    /// **12 GB**. This is the *gig-crate scoped* ceiling — separation happens
    /// for one prepared night out, never a whole library.
    public static func defaultStemBudget(deviceClass: MemoryCeiling.DeviceClass) -> Int64 {
        switch deviceClass {
        case .ipad:
            return 12_000_000_000
        case .iphone8GB, .iphone6GB, .other:
            return 4_000_000_000
        }
    }

    /// §43.6's default waveform-pyramid budget: iPhone **300 MB**, iPad **600 MB**.
    public static func defaultWaveformBudget(deviceClass: MemoryCeiling.DeviceClass) -> Int64 {
        switch deviceClass {
        case .ipad:
            return 600_000_000
        case .iphone8GB, .iphone6GB, .other:
            return 300_000_000
        }
    }

    /// §43.6's stems-per-track planning figure ("a 300-track crate at ~13
    /// MB/track is ~4 GB"). The crate's projected size uses this; the on-disk
    /// account is always the real `gig_crate_track.stemsBytes` sum.
    public static let estimatedStemsBytesPerTrack: Int64 = 13_000_000

    /// Mixes are the user's own recordings and cannot be re-derived: **never
    /// evictable**, regardless of pressure (§43.6). The service states the rule
    /// once so the UI and the lane share it.
    public static let mixesEvictable = false

    // MARK: - The decision

    /// One crate's stem usage, as the budget accounts it (§43.6, FR-ANL-9).
    public struct CrateUsage: Identifiable, Equatable, Sendable {
        public let crateID: Int64
        public let name: String
        /// The crate's on-disk stem bytes — what evicting it reclaims.
        public let stemsBytes: Int64
        /// The crate's `lastPerformedAt` — the LRU clock. `nil` (never
        /// performed) evicts first.
        public let lastPerformedAt: Date?

        public init(crateID: Int64, name: String, stemsBytes: Int64,
                    lastPerformedAt: Date?) {
            self.crateID = crateID
            self.name = name
            self.stemsBytes = stemsBytes
            self.lastPerformedAt = lastPerformedAt
        }

        public var id: Int64 { crateID }
    }

    /// The eviction decision for preparing a crate (§41.17's "Making room"
    /// panel, FR-ANL-9, AT-STEM-\*): what the budget accounts, whether the
    /// addition fits, and — when it does not — exactly which crates are
    /// evicted, in order, to make room.
    public struct StemPlan: Equatable, Sendable {
        /// The stem bytes accounted on disk before this addition.
        public let currentStemsBytes: Int64
        /// `currentStemsBytes + addingBytes` — the total the addition implies.
        public let projectedTotal: Int64
        /// The budget ceiling.
        public let budget: Int64
        /// The crates evicted to make room, **oldest-performed first** (LRU).
        /// Empty when the addition already fits. This is the preview the UI
        /// shows BEFORE any eviction happens (§43.6).
        public let evictions: [CrateUsage]

        public init(currentStemsBytes: Int64, projectedTotal: Int64,
                    budget: Int64, evictions: [CrateUsage]) {
            self.currentStemsBytes = currentStemsBytes
            self.projectedTotal = projectedTotal
            self.budget = budget
            self.evictions = evictions
        }

        /// Whether the crate fits within the budget after the evictions the
        /// plan names. `false` means even evicting every LRU candidate cannot
        /// make room — the prepare must be refused with an honest message.
        public var fits: Bool {
            let reclaimed = evictions.reduce(Int64(0)) { $0 + $1.stemsBytes }
            return projectedTotal - reclaimed <= budget
        }

        /// Whether room had to be made.
        public var needsEviction: Bool { !evictions.isEmpty }

        /// The free headroom before this addition (the "X free" readout).
        public var freeBytes: Int64 { max(0, budget - currentStemsBytes) }
    }

    /// The pure LRU planning function (§43.6, FR-ANL-9, AT-STEM-\*):
    ///
    /// - Adding `addingBytes` to the accounted `currentStemsBytes` fits within
    ///   `budget` → an empty eviction list, nothing evicted.
    /// - It does not fit → the eviction preview: the crates whose stems must be
    ///   dropped, in LRU order (oldest `lastPerformedAt` first; a crate never
    ///   performed is the oldest), skipping `protectedIDs` — the crate being
    ///   prepared, crates backing a currently loaded deck, and anything live
    ///   (§43.6 "never evict… a live session").
    ///
    /// Eviction is **shown, never done** by this function — the caller renders
    /// the `evictions` list first and only then performs it (decision 11).
    public static func plan(addingBytes: Int64,
                            budget: Int64,
                            currentStemsBytes: Int64,
                            usages: [CrateUsage],
                            protectedIDs: Set<Int64> = []) -> StemPlan {
        let projected = currentStemsBytes + addingBytes
        guard projected > budget else {
            return StemPlan(currentStemsBytes: currentStemsBytes,
                            projectedTotal: projected,
                            budget: budget,
                            evictions: [])
        }

        let candidates = usages
            .filter { !protectedIDs.contains($0.crateID) }
            .sorted { l, r in
                let lDate = l.lastPerformedAt ?? .distantPast
                let rDate = r.lastPerformedAt ?? .distantPast
                return lDate < rDate
            }

        var remaining = projected - budget
        var evictions: [CrateUsage] = []
        for usage in candidates where remaining > 0 {
            evictions.append(usage)
            remaining -= usage.stemsBytes
        }
        return StemPlan(currentStemsBytes: currentStemsBytes,
                        projectedTotal: projected,
                        budget: budget,
                        evictions: evictions)
    }

    // MARK: - Display helpers

    /// A compact byte label ("1.9 GB", "412 MB") shared by the budget panels.
    public static func bytesText(_ bytes: Int64) -> String {
        let absolute = Double(abs(bytes))
        let gb = absolute / 1_000_000_000
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = absolute / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return "\(bytes) B"
    }
}
