#if !os(watchOS)
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoMixEngine

/// The one place blends are planned. The mix decks plan the next blend while a
/// track plays; the transition preparation (Mix preview, Up Next) plans the
/// opening blends of a queue ahead of time. Both go through `BlendEdgePlanner`
/// and share this cache, so what the preview shows is what the decks play.
///
/// A plan depends on the tempo the outgoing track plays at (each incoming track
/// is stretched to the one before), so entries are keyed by it too.
@MainActor
public final class BlendPlanCache {
    public static let shared = BlendPlanCache()

    struct Key: Hashable {
        let from: Int64
        let to: Int64
        /// The outgoing deck's tempo, in millionths.
        let outgoingTempo: Int64

        init(from: Int64, to: Int64, outgoingTempo: Double) {
            self.from = from
            self.to = to
            self.outgoingTempo = Int64((outgoingTempo * 1_000_000).rounded())
        }
    }

    /// A planned edge: the plans (best first) and the incoming track's analysis
    /// as its deck will play it, the outgoing side of the next edge.
    public struct Entry: Sendable {
        public let plans: [BlendPlan]
        public let incomingPlayed: BlendTrackAnalysis
        public let outgoingTempo: Double
        public var tempo: Double { plans.first?.tempo ?? 1 }
    }

    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    /// Bounded: each entry is a few KB (two beat grids and per-beat levels).
    static let capacity = 256

    func entry(from: Int64, to: Int64, outgoingTempo: Double) -> Entry? {
        entries[Key(from: from, to: to, outgoingTempo: outgoingTempo)]
    }

    func store(_ entry: Entry, from: Int64, to: Int64) {
        let key = Key(from: from, to: to, outgoingTempo: entry.outgoingTempo)
        if entries[key] == nil { order.append(key) }
        entries[key] = entry
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
    }

    /// The most recently planned blend between two tracks, at whatever tempo,
    /// for display.
    public func latest(from: Int64, to: Int64) -> Entry? {
        for key in order.reversed() where key.from == from && key.to == to {
            return entries[key]
        }
        return nil
    }

    /// How the preview and Up Next describe a planned blend.
    public func transitionPlan(from: Int64, to: Int64) -> TransitionPlan? {
        guard let entry = latest(from: from, to: to), let plan = entry.plans.first else { return nil }
        return Self.transitionPlan(plan, from: from, to: to, outgoingTempo: entry.outgoingTempo)
    }

    nonisolated static func transitionPlan(_ plan: BlendPlan, from: Int64, to: Int64,
                                           outgoingTempo: Double) -> TransitionPlan {
        TransitionPlan(fromTrackID: from, toTrackID: to,
                       style: plan.style == .phraseCut ? .phraseFade : .beatmatchedBlend,
                       exitTime: plan.blendStart * outgoingTempo,
                       entryTime: max(0, (plan.blendStart - plan.incomingOffset) * plan.tempo),
                       overlapBeats: plan.overlapBeats,
                       overlapSeconds: Double(plan.overlapBeats) * plan.period,
                       blendRate: plan.tempo,
                       gainMatchDB: 20 * log10(max(plan.incomingGain, 1e-6)),
                       bpmDeltaPct: (plan.tempo - 1) * 100,
                       confidence: plan.placement == .none ? 0.5 : 1,
                       reasons: [.tempoMatched(pct: (plan.tempo - 1) * 100)])
    }
}

/// Plans one blend from decoded audio. Heavy (seconds to tens of seconds):
/// call off the main actor.
enum BlendEdgePlanner {
    /// The outgoing track as its deck plays it, at `tempo`: the source itself at
    /// its own tempo, otherwise the keylocked render the deck produces.
    static func played(_ track: MixTrackAudio, tempo: Double,
                       analysis playedAnalysis: BlendTrackAnalysis?) -> PlayedTrack? {
        guard abs(tempo - 1) > 1e-9 else { return PlayedTrack(source: track.audio, analysis: track.analysis) }
        guard let rendered = MixEngine.renderTempo(track.audio, tempo: tempo) else { return nil }
        let mono = BlendPlanner.mono(rendered)
        let analysis = playedAnalysis ?? BlendAnalyzer.analyze(
            mono, grid: BlendGrid(period: track.analysis.grid.period / tempo,
                                  phase: track.analysis.grid.phase / tempo,
                                  sharpness: track.analysis.grid.sharpness))
        return PlayedTrack(analysis: analysis, audio: mono)
    }

    static func plan(outgoing: PlayedTrack, incoming: MixTrackAudio) -> BlendPlanning? {
        BlendPlanner.planBlend(outgoing: outgoing, incoming: incoming.analysis, incomingAudio: incoming.audio)
    }
}
#endif
