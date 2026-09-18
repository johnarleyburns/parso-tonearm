import Foundation
import GRDB

/// Extracted from the DJ mixer-era `Sources/DJ/Features/VibeSearch/
/// VibeSearchModel.swift` (found orphaned/dead during the mood-based-
/// listening plan's audit — see docs/plans/mood-based-listening-plan.md
/// §2/§5 step 2) — the rest of that feature is gone with the DJ mixer, but
/// this piece is genuinely reusable: it answers the mood-listening plan's
/// own "Era/Vibe" pill category question (§3.2) with real, deterministic,
/// library-derived chip text instead of a hand-picked list.
///
/// A compact summary of the library's own descriptor distribution — what
/// suggestion chips are seeded from, never a hard-coded list.
public struct LibraryDescriptorSummary: Sendable, Equatable {
    public var bpm: [Double]
    public var energy: [Double]
    public var durationSec: [Double]
    public var camelotCounts: [String: Int]

    public init(bpm: [Double] = [],
                energy: [Double] = [],
                durationSec: [Double] = [],
                camelotCounts: [String: Int] = [:]) {
        self.bpm = bpm
        self.energy = energy
        self.durationSec = durationSec
        self.camelotCounts = camelotCounts
    }
}

/// Pure, deterministic chips derived from a library's own descriptors:
/// median tempo band, dominant Camelot, energy and duration. These read as
/// the user's own music rather than a copy-written list.
public enum SuggestionChips {

    public static func seed(from summary: LibraryDescriptorSummary,
                            limit: Int = 4) -> [String] {
        var chips: [String] = []

        if let median = median(summary.bpm) {
            let rounded = median.rounded()
            if rounded >= 118 && rounded <= 132 {
                chips.append("steady around \(Int(rounded)) BPM")
            } else if rounded < 118 {
                chips.append("slow and deep")
            } else {
                chips.append("fast and relentless")
            }
        }

        if let dominant = summary.camelotCounts.max(by: {
            ($0.value, $0.key) < ($1.value, $1.key)
        }) {
            chips.append("in \(dominant.key)")
        }

        if let meanEnergy = mean(summary.energy) {
            if meanEnergy >= 7 {
                chips.append("high energy")
            } else if meanEnergy <= 3.5 {
                chips.append("low-key")
            } else {
                chips.append("mid-energy")
            }
        }

        if let meanDuration = mean(summary.durationSec) {
            if meanDuration < 210 {
                chips.append("shorter tracks")
            } else if meanDuration > 330 {
                chips.append("long-form tracks")
            }
        }

        return Array(chips.prefix(limit))
    }

    /// Read the distribution straight from the core library: track duration
    /// from core `track`, bpm/energy/camelot from the core
    /// `discovery_track_analysis` side table — one cheap aggregate query, no
    /// object graph.
    public static func summary(library: LibraryStore) async -> LibraryDescriptorSummary {
        let rows = (try? await library.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT t.durationSec AS durationSec, a.bpm AS bpm,
                       a.energy AS energy, a.key AS camelot
                FROM track t LEFT JOIN discovery_track_analysis a ON a.trackId = t.id
                """)
        }) ?? []
        var bpm: [Double] = []
        bpm.reserveCapacity(rows.count)
        var energy: [Double] = []
        energy.reserveCapacity(rows.count)
        var duration: [Double] = []
        duration.reserveCapacity(rows.count)
        var counts: [String: Int] = [:]
        for row in rows {
            if let value: Double = row["bpm"] { bpm.append(value) }
            if let value: Double = row["energy"] { energy.append(value) }
            if let value: Double = row["durationSec"] { duration.append(value) }
            if let key: String = row["camelot"] { counts[key, default: 0] += 1 }
        }
        return LibraryDescriptorSummary(bpm: bpm, energy: energy,
                                        durationSec: duration, camelotCounts: counts)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
