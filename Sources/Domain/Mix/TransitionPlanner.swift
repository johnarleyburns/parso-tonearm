import Foundation

public struct TransitionPlanningContext: Codable, Sendable, Equatable {
    public var fromTrackID: Int64
    public var toTrackID: Int64
    public var fromDuration: Double
    public var toDuration: Double
    public var sameAlbumInOrder: Bool
    public var userChosePlainFade: Bool
    public var prepState: GridPrepState
    public var incomingBuffered: Bool

    public init(fromTrackID: Int64, toTrackID: Int64, fromDuration: Double = 0,
                toDuration: Double = 0, sameAlbumInOrder: Bool = false,
                userChosePlainFade: Bool = false, prepState: GridPrepState = .ready,
                incomingBuffered: Bool = true) {
        self.fromTrackID = fromTrackID
        self.toTrackID = toTrackID
        self.fromDuration = fromDuration
        self.toDuration = toDuration
        self.sameAlbumInOrder = sameAlbumInOrder
        self.userChosePlainFade = userChosePlainFade
        self.prepState = prepState
        self.incomingBuffered = incomingBuffered
    }
}

/// Pure, analysis-backed transition selection. Both the player and preview
/// call this type so the explanation is the same decision the listener hears.
public enum TransitionPlanner {
    /// A plain crossfade's length. It used to be 0 — the chip said "Plain crossfade" and the
    /// player, seeing a zero-length fade, cut straight from one track to the next.
    public static let plainCrossfadeSeconds: Double = 8

    public static func plan(from outgoing: DJTrackPrepPayload?, to incoming: DJTrackPrepPayload?,
                            context: TransitionPlanningContext) -> TransitionPlan {
        if context.sameAlbumInOrder {
            return TransitionPlan(fromTrackID: context.fromTrackID, toTrackID: context.toTrackID,
                                  style: .gapless, overlapSeconds: 0, confidence: 1,
                                  reasons: [.sameAlbumGapless])
        }
        if context.userChosePlainFade {
            return TransitionPlan(fromTrackID: context.fromTrackID, toTrackID: context.toTrackID,
                                  style: .plainCrossfade, overlapSeconds: plainCrossfadeSeconds, confidence: 1,
                                  reasons: [.userChosePlainFade])
        }
        guard let outgoing, let incoming else {
            return TransitionPlan(fromTrackID: context.fromTrackID, toTrackID: context.toTrackID,
                                  style: .plainCrossfade, overlapSeconds: plainCrossfadeSeconds, confidence: 0,
                                  reasons: [.gridNotReady(context.prepState)])
        }
        guard context.incomingBuffered else {
            return TransitionPlan(fromTrackID: context.fromTrackID, toTrackID: context.toTrackID,
                                  style: .plainCrossfade, overlapSeconds: plainCrossfadeSeconds, confidence: 0,
                                  reasons: [.notBuffered], downgradedFrom: .beatmatchedBlend)
        }

        let relation = keyRelation(outgoing.key.camelot, incoming.key.camelot)
        let bpmDelta = abs(incoming.bpm / max(outgoing.bpm, 1) - 1) * 100
        let confidence = min(outgoing.tempoConfidence, incoming.tempoConfidence)
        let constantTempo = outgoing.isConstantTempo && incoming.isConstantTempo
        if confidence >= 0.6 && constantTempo && bpmDelta <= 8 {
            let fromDuration = context.fromDuration > 0 ? context.fromDuration : outgoing.duration
            let intro = introStart(incoming)
            let outro = outroStart(outgoing, duration: fromDuration)
            let beatLength = 60 / max(outgoing.bpm, 1)
            let compatible = harmonic(relation)
            let overlapBeats = compatible ? 96 : 4
            let overlapSeconds = Double(overlapBeats) * beatLength
            var reasons: [TransitionReason] = [
                .tempoMatched(pct: bpmDelta), .keyCompatible(relation),
                .tempoReturnsOverBeats(96)
            ]
            if let section = outgoing.sections.last(where: { $0.kind.lowercased().contains("outro") }) {
                reasons.append(.outgoingOutroPhrase(bar: section.bar, beats: overlapBeats))
            }
            if let section = incoming.sections.first(where: { $0.kind.lowercased().contains("intro") }) {
                reasons.append(.incomingIntroPhrase(beats: max(1, section.bar)))
            }
            if let skipped = leadingSilence(incoming), skipped > 0.5 {
                reasons.append(.skippedLeadingSilence(seconds: skipped))
            }
            if !compatible { reasons.append(.keyClashShortOverlap) }
            if let loudness = loudnessDifference(outgoing, incoming) {
                reasons.append(.loudnessMatched(dB: loudness))
            }
            return TransitionPlan(fromTrackID: context.fromTrackID, toTrackID: context.toTrackID,
                                  style: .beatmatchedBlend, exitTime: outro, entryTime: intro,
                                  overlapBeats: overlapBeats, overlapSeconds: overlapSeconds,
                                  blendRate: outgoing.bpm / max(incoming.bpm, 1),
                                  rateRampBeats: 96, gainMatchDB: loudnessDifference(outgoing, incoming),
                                  keyRelation: relation, bpmDeltaPct: bpmDelta,
                                  confidence: confidence, reasons: reasons)
        }

        var reasons: [TransitionReason] = []
        if !constantTempo { reasons.append(.variableTempo) }
        if confidence < 0.6 { reasons.append(.lowTempoConfidence(confidence)) }
        if bpmDelta > 8 { reasons.append(.tempoTooFar(pct: bpmDelta)) }
        if reasons.isEmpty { reasons.append(.tempoTooFar(pct: bpmDelta)) }
        reasons.append(.keyCompatible(relation))
        let duration = context.fromDuration > 0 ? context.fromDuration : outgoing.duration
        let exit = phraseBoundary(outgoing, duration: duration)
        let overlap = min(8 * 60 / max(outgoing.bpm, 1), 8)
        return TransitionPlan(fromTrackID: context.fromTrackID, toTrackID: context.toTrackID,
                              style: .phraseFade, exitTime: exit, entryTime: introStart(incoming),
                              overlapBeats: min(8, outgoing.downbeatPositions.count),
                              overlapSeconds: overlap, blendRate: 1, keyRelation: relation,
                              bpmDeltaPct: bpmDelta, confidence: confidence, reasons: reasons,
                              downgradedFrom: .beatmatchedBlend)
    }

    private static func introStart(_ payload: DJTrackPrepPayload) -> Double {
        guard let silence = leadingSilence(payload) else { return payload.beatPositions.first ?? 0 }
        return payload.beatPositions.first(where: { $0 >= silence }) ?? silence
    }

    private static func leadingSilence(_ payload: DJTrackPrepPayload) -> Double? {
        guard !payload.waveform.isEmpty else { return nil }
        let threshold: Float = pow(10, -50 / 20)
        guard let index = payload.waveform.firstIndex(where: { $0.rms >= threshold }) else { return nil }
        return payload.duration * Double(index) / Double(payload.waveform.count)
    }

    private static func outroStart(_ payload: DJTrackPrepPayload, duration: Double) -> Double {
        // Section metadata is useful for explanation, but must not move the
        // handoff later and shorten the requested three-phrase overlap.
        let blendStart = max(0, duration - 96 * 60 / max(payload.bpm, 1))
        return payload.downbeatPositions.last(where: { $0 <= blendStart }) ?? blendStart
    }

    private static func phraseBoundary(_ payload: DJTrackPrepPayload, duration: Double) -> Double {
        if let section = payload.sections.last(where: {
            $0.kind.lowercased().contains("outro") || $0.kind.lowercased().contains("phrase")
        }) { return section.start }
        return max(0, duration - min(8, 8 * 60 / max(payload.bpm, 1)))
    }

    private static func snappedOverlap(outro: Double, intro: Double,
                                       fromDuration: Double, toDuration: Double,
                                       beatLength: Double) -> Int {
        let outgoingWindow = max(beatLength, fromDuration - outro)
        let incomingWindow = max(beatLength, toDuration - intro)
        let available = max(1, min(32, Int((min(outgoingWindow, incomingWindow) / max(beatLength, 0.001)).rounded(.down))))
        return [8, 16, 32].last(where: { $0 <= available }) ?? 8
    }

    private static func loudnessDifference(_ lhs: DJTrackPrepPayload, _ rhs: DJTrackPrepPayload) -> Double? {
        guard let left = lhs.loudness.first, let right = rhs.loudness.first,
              left.isFinite, right.isFinite else { return nil }
        return left - right
    }

    private static func keyRelation(_ lhs: String, _ rhs: String) -> KeyRelation {
        guard let left = Camelot(code: lhs), let right = Camelot(code: rhs) else { return .unknown }
        if left == right { return .same }
        if left.letter == right.letter {
            let delta = (right.number - left.number + 12) % 12
            if delta == 1 { return .adjacentUp }
            if delta == 11 { return .adjacentDown }
            if delta == 6 { return .energyBoost }
        }
        if left.number == right.number && left.letter != right.letter { return .relative }
        return .clash(steps: min((right.number - left.number + 12) % 12,
                                 (left.number - right.number + 12) % 12))
    }

    private static func harmonic(_ relation: KeyRelation) -> Bool {
        switch relation {
        case .same, .adjacentUp, .adjacentDown, .relative: true
        default: false
        }
    }

    private struct Camelot: Equatable {
        let number: Int
        let letter: Character

        init?(code: String) {
            let value = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let letter = value.last, ["A", "B"].contains(letter),
                  let number = Int(value.dropLast()), (1...12).contains(number) else { return nil }
            self.number = number
            self.letter = letter
        }
    }
}
