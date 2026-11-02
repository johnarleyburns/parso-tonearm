import Foundation

/// A track's drop/bass-exit structure on its own beat grid, snapped to its dominant bar phase.
/// Ported from tools/blend-lab/structure.py + djmix.py's `Track`/`phase_of`/`snap` (2026-10-08).
/// Beat indices are into the track's own full beat grid (beat 0 = the track's first detected
/// beat); `beatCount` is that grid's length. Carries no audio — only the real detector's output
/// (`ParsoAudioAnalysis.DropDetector`, called by whoever builds this) and simple arithmetic.
public struct DropAwareTrackStructure: Sendable, Equatable {
    public let barPhase: Int
    public let phrasePhase: Int
    /// Bar-phase-snapped, deduplicated, sorted beat indices.
    public let drops: [Int]
    public let exits: [Int]
    public let beatCount: Int
    /// Kick-band level per beat interval (`DropDetector.bassLevelsDB`); only used to judge
    /// whether a track's bass is already present from its start (`incomingPoints`'s first
    /// priority tier skips a track's own drop in favor of the first phrase line for that case).
    public let bassLevelsDB: [Double]

    public init(barPhase: Int, phrasePhase: Int, drops: [Int], exits: [Int], beatCount: Int,
                bassLevelsDB: [Double]) {
        self.barPhase = barPhase
        self.phrasePhase = phrasePhase
        self.drops = drops
        self.exits = exits
        self.beatCount = beatCount
        self.bassLevelsDB = bassLevelsDB
    }

    /// Builds the structure from `DropDetector`'s raw drop/exit beat indices (unweighted voting
    /// for bar/phrase phase — the reference tool weights by dB-step size; we vote by count, a
    /// reasonable simplification since both just find "the phase most events share").
    public static func detect(rawDrops: [Int], rawExits: [Int], beatCount: Int,
                              bassLevelsDB: [Double]) -> DropAwareTrackStructure {
        let events = rawDrops + rawExits
        let bar = phase(of: events, mod: 4)
        let snappedForPhrase = events.map { snap($0, to: bar, mod: 4) }
        let phrase = phase(of: snappedForPhrase, mod: 32)
        let drops = Array(Set(rawDrops.map { snap($0, to: bar, mod: 4) })).sorted()
        let exits = Array(Set(rawExits.map { snap($0, to: bar, mod: 4) })).sorted()
        return DropAwareTrackStructure(barPhase: bar, phrasePhase: phrase, drops: drops, exits: exits,
                                       beatCount: beatCount, bassLevelsDB: bassLevelsDB)
    }

    /// The beat-index phase (mod `mod`) most events share.
    private static func phase(of events: [Int], mod: Int) -> Int {
        guard !events.isEmpty else { return 0 }
        var score = [Int](repeating: 0, count: mod)
        for i in events { score[((i % mod) + mod) % mod] += 1 }
        var best = 0
        for i in 1..<mod where score[i] > score[best] { best = i }
        return best
    }

    private static func snap(_ i: Int, to phase: Int, mod: Int) -> Int {
        i + (((phase - i + mod / 2) % mod + mod) % mod) - mod / 2
    }

    /// True when the first 16 beats after `silenceBeat` already carry bass within 6 dB of the
    /// track's overall level — i.e. nothing to wait for, so a phrase line is as good an entry as
    /// a drop.
    public func bassPresentFromStart(silenceBeat: Int) -> Bool {
        guard !bassLevelsDB.isEmpty else { return false }
        let lo = max(0, silenceBeat), hi = min(bassLevelsDB.count, silenceBeat + 16)
        guard hi > lo else { return false }
        let overall = bassLevelsDB.sorted()[bassLevelsDB.count / 2]
        let first = bassLevelsDB[lo..<hi].sorted()
        let firstMedian = first[first.count / 2]
        return firstMedian >= overall - 6
    }
}

/// Picks a real drop/bass-exit/phrase-line swap point between two tracks' structures, ported
/// from tools/blend-lab/djmix.py's `outgoing_points`/`incoming_points` (2026-10-08). Unlike the
/// reference tool, this does not verify groove (cross-correlated timing agreement) — it trusts
/// the bar-phase-snapped beat grid directly, the same simplification `CatalogEdgePlanner` already
/// makes for its constant-tempo bassSwap. A result's `style` says which real structure anchored
/// it: `.doubleDrop` (a real drop in the outgoing's second half), `.bassSwap` (a bass exit there),
/// or `.phraseCut` (only a phrase line was found — no overlap, a hard cut).
public enum DropAwareEdgePlanner {
    /// Overlap length in beats for a drop/exit-anchored edge (matches the reference tool's
    /// `OVERLAP`; `CatalogEdgePlanner`'s plain bassSwap uses a shorter 32-beat fallback).
    public static let overlapBeats = 64
    static let half = overlapBeats / 2

    public struct SwapPoint: Sendable, Equatable {
        public let outgoingBeat: Int
        public let incomingBeat: Int
        public let style: BlendEdgePlan.Style
    }

    /// The best swap point, or nil when neither track has any usable drop/exit/phrase-line point
    /// within bounds (the caller falls back to `CatalogEdgePlanner.plan`).
    public static func swapPoint(outgoing: DropAwareTrackStructure, incoming: DropAwareTrackStructure,
                                 incomingSilenceBeat: Int = 0) -> SwapPoint? {
        let incomingCandidates = incomingPoints(incoming, silenceBeat: incomingSilenceBeat)
        guard let incomingBeat = incomingCandidates.first else { return nil }
        guard let (outgoingBeat, style) = outgoingPoints(outgoing).first else { return nil }
        return SwapPoint(outgoingBeat: outgoingBeat, incomingBeat: incomingBeat, style: style)
    }

    /// A concrete `BlendEdgePlan` for `swapPoint`, using the same tempo/gain arithmetic as
    /// `CatalogEdgePlanner.plan` but anchored at the real swap point instead of the track's tail.
    public static func plan(blendID: String, edge: Int, outgoing: StarterTrackFacts,
                            outgoingStructure: DropAwareTrackStructure, incoming: StarterTrackFacts,
                            incomingStructure: DropAwareTrackStructure,
                            incomingSilenceBeat: Int = 0) -> BlendEdgePlan? {
        guard outgoing.isBlendReady, incoming.isBlendReady,
              let point = swapPoint(outgoing: outgoingStructure, incoming: incomingStructure,
                                    incomingSilenceBeat: incomingSilenceBeat)
        else { return nil }
        let tempo = outgoing.bpm / incoming.bpm
        guard abs(tempo - 1) <= CatalogEdgePlanner.maxTempoDifference else { return nil }
        let gain = min(max(pow(10, (outgoing.rmsDB - incoming.rmsDB) / 20),
                           CatalogEdgePlanner.gainRange.lowerBound), CatalogEdgePlanner.gainRange.upperBound)

        if point.style == .phraseCut {
            return BlendEdgePlan(
                blendID: blendID, edge: edge, outgoingTrackID: outgoing.id, incomingTrackID: incoming.id,
                style: .phraseCut, tempo: tempo, overlapBeats: 0, incomingGain: gain,
                outgoingStartSeconds: outgoing.beatTime(point.outgoingBeat),
                incomingStartSeconds: incoming.beatTime(max(0, point.incomingBeat - half)))
        }

        let start = outgoing.beatTime(point.outgoingBeat - half)
        let end = outgoing.beatTime(point.outgoingBeat + half)
        let incomingLeadIn = incoming.beatTime(max(0, point.incomingBeat - half))
        return BlendEdgePlan(
            blendID: blendID, edge: edge, outgoingTrackID: outgoing.id, incomingTrackID: incoming.id,
            style: point.style, tempo: tempo, overlapBeats: overlapBeats, incomingGain: gain,
            outgoingSwapBeat: point.outgoingBeat, incomingSwapBeat: half, blendStartSeconds: start,
            swapSeconds: outgoing.beatTime(point.outgoingBeat), blendEndSeconds: end,
            incomingOffsetSeconds: start - incomingLeadIn / tempo)
    }

    // MARK: - Point selection (tools/blend-lab/djmix.py)

    /// Swap points on the outgoing track, best first within each style, latest-in-track first:
    /// a real drop in its second half (`.doubleDrop`), else a bass exit there (`.bassSwap`), else
    /// a phrase line (`.phraseCut`).
    private static func outgoingPoints(_ a: DropAwareTrackStructure) -> [(beat: Int, style: BlendEdgePlan.Style)] {
        func inBounds(_ i: Int) -> Bool { i - half >= 0 && i + half < a.beatCount - 1 }
        let secondHalf = a.beatCount / 2
        var points: [(Int, BlendEdgePlan.Style)] = []
        points += a.drops.reversed().filter { $0 >= secondHalf && inBounds($0) }.map { ($0, .doubleDrop) }
        points += a.exits.reversed().filter { $0 >= secondHalf && inBounds($0) }.map { ($0, .bassSwap) }
        guard a.phrasePhase < a.beatCount else { return points }
        let phraseLines = Swift.stride(from: a.phrasePhase, to: a.beatCount, by: 32).reversed()
        points += phraseLines.filter { $0 >= secondHalf && inBounds($0) }.map { ($0, .phraseCut) }
        return points
    }

    /// Swap points on the incoming track, best first: its first drop with at least a 4-bar lead-
    /// in, else a phrase line 8 bars in when its bass is already present from the start, then its
    /// later drops in its first half, then phrase lines.
    private static func incomingPoints(_ b: DropAwareTrackStructure, silenceBeat: Int) -> [Int] {
        var ranked: [(beat: Int, priority: Int)] = []
        let earlyDrops = b.drops.filter { $0 - 16 >= silenceBeat }
        if let first = earlyDrops.first { ranked.append((first, 0)) }
        guard b.phrasePhase < b.beatCount / 2 else {
            return dedupedInBounds(ranked, beatCount: b.beatCount)
        }
        let phrases = Swift.stride(from: b.phrasePhase, to: b.beatCount / 2, by: 32)
            .filter { $0 - 16 >= silenceBeat }
        if b.bassPresentFromStart(silenceBeat: silenceBeat), !phrases.isEmpty {
            let chosen = phrases.first { $0 - half >= silenceBeat } ?? phrases.first!
            ranked.append((chosen, 1))
        }
        ranked += earlyDrops.dropFirst().filter { $0 < b.beatCount / 2 }.map { ($0, 2) }
        ranked += phrases.map { ($0, 3) }
        return dedupedInBounds(ranked, beatCount: b.beatCount)
    }

    private static func dedupedInBounds(_ ranked: [(beat: Int, priority: Int)], beatCount: Int) -> [Int] {
        var seen = Set<Int>(), out: [Int] = []
        for (beat, _) in ranked.sorted(by: { $0.priority < $1.priority }) {
            guard !seen.contains(beat), beat + half < beatCount else { continue }
            seen.insert(beat); out.append(beat)
        }
        return out
    }
}
