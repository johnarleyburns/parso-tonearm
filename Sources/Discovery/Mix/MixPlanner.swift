import Foundation
import ParsoAudioAnalysis
import TonearmCore

public struct MixPlannerWeights: Codable, Sendable, Equatable {
    public var sameKey: Double = 0
    public var compatibleKey: Double = 1
    public var energyBoostKey: Double = 2.5
    public var clashingKey: Double = 6
    public var tempoPerPercent: Double = 10
    public var againstShapeMultiplier: Double = 3
    public var energy: Double = 1
    public var similarity: Double = 2
    public var sameArtist: Double = 3
    public var shapeDeviation: Double = 10

    public init() {}
}

/// Deterministic, explainable ordering for a pool of analysed tracks.
public struct MixPlanner: Sendable {
    public static let weights = MixPlannerWeights()

    public init() {}

    public static func plan(_ request: MixRequest) -> MixPlan {
        MixPlanner().plan(request)
    }

    public func plan(_ request: MixRequest) -> MixPlan {
        var excluded: [MixExclusion] = []
        var seen = Set<Int64>()
        var pool: [MixCandidate] = []

        for candidate in request.candidates {
            guard seen.insert(candidate.trackID).inserted else {
                excluded.append(MixExclusion(trackID: candidate.trackID, reason: .duplicate))
                continue
            }
            var missing: MixMissingAnalysis = []
            if !valid(candidate.bpm) { missing.insert(.bpm) }
            if CamelotKey(code: candidate.camelot ?? "") == nil { missing.insert(.key) }
            guard missing.isEmpty else {
                excluded.append(MixExclusion(trackID: candidate.trackID,
                                             reason: .notAnalyzed(missing: missing)))
                continue
            }
            pool.append(candidate)
        }

        if let target = request.targetDuration, target.isFinite, target > 0 {
            var duration = pool.reduce(0) { $0 + max(0, $1.duration) }
            while duration > target, pool.count > 1 {
                guard let index = pool.indices.max(by: { removalCost(pool[$0]) < removalCost(pool[$1]) }) else { break }
                let removed = pool.remove(at: index)
                duration -= max(0, removed.duration)
                excluded.append(MixExclusion(trackID: removed.trackID, reason: .overTargetLength))
            }
        }

        guard !pool.isEmpty else {
            return MixPlan(steps: [], excluded: excluded,
                           summary: MixSummary(), request: request)
        }

        let bpmValues = pool.compactMap(\.bpm).sorted()
        let p5 = quantile(bpmValues, 0.05)
        let median = quantile(bpmValues, 0.50)
        let p95 = quantile(bpmValues, 0.95)
        let target: (Int, Double) -> Double = { position, total in
            let fraction = total <= 1 ? 0 : Double(position) / Double(total - 1)
            switch request.shape {
            case .risingBPM:
                return p5 + (p95 - p5) * fraction
            case .steady:
                return median
            case .warmUpPeakCoolDown:
                if fraction <= 0.7 {
                    return p5 + (p95 - p5) * (fraction / 0.7)
                }
                return p95 + (median - p95) * ((fraction - 0.7) / 0.3)
            case .windDown:
                return p95 + (p5 - p95) * fraction
            }
        }

        let lockedByPosition = lockPositions(request: request, pool: pool)
        var ordered: [MixCandidate] = []
        var used = Set<Int64>()
        ordered.reserveCapacity(pool.count)

        for position in pool.indices {
            if let lockedID = lockedByPosition[position],
               let locked = pool.first(where: { $0.trackID == lockedID }) {
                ordered.append(locked)
                used.insert(locked.trackID)
                continue
            }

            let candidates = pool.filter { candidate in
                !used.contains(candidate.trackID)
                    && !lockedByPosition.values.contains(candidate.trackID)
            }
            guard !candidates.isEmpty else { break }

            if ordered.isEmpty {
                let selected = candidates.min { lhs, rhs in
                    startCost(lhs, shape: request.shape, target: target(position, Double(pool.count)), seed: request.seed)
                        < startCost(rhs, shape: request.shape, target: target(position, Double(pool.count)), seed: request.seed)
                }!
                ordered.append(selected)
                used.insert(selected.trackID)
                continue
            }

            let previous = ordered[ordered.count - 1]
            let selected = candidates.min { lhs, rhs in
                edge(from: previous, to: lhs, target: target(position, Double(pool.count)),
                     shape: request.shape, isFirst: false).total
                    + seededTieBreak(lhs.trackID, seed: request.seed)
                    < edge(from: previous, to: rhs, target: target(position, Double(pool.count)),
                          shape: request.shape, isFirst: false).total
                    + seededTieBreak(rhs.trackID, seed: request.seed)
            }!
            ordered.append(selected)
            used.insert(selected.trackID)
        }

        // A bounded swap improvement preserves fixed positions and is cheap
        // enough for the 500-track CI performance bound.
        ordered = improve(ordered, lockedByPosition: lockedByPosition, request: request,
                           target: target, maxIterations: min(2, ordered.count))

        var steps: [MixStep] = []
        steps.reserveCapacity(ordered.count)
        var scores: [EdgeScore] = []
        for (position, candidate) in ordered.enumerated() {
            let previous = position > 0 ? ordered[position - 1] : nil
            let score = previous.map { previousCandidate in
                let raw = edge(from: previousCandidate, to: candidate,
                               target: target(position, Double(ordered.count)),
                               shape: request.shape, isFirst: false)
                return markUnavoidableIfForced(raw, from: previousCandidate,
                                               remaining: ordered.dropFirst(position + 1),
                                               target: target(position, Double(ordered.count)),
                                               shape: request.shape)
            }
            if let score { scores.append(score) }

            var reasons: [PlacementReason] = []
            if position == 0 {
                if request.lockedFirst == candidate.trackID || lockedByPosition[0] == candidate.trackID {
                    reasons.append(.lockedByUser)
                } else if request.shape == .risingBPM {
                    reasons.append(.lowestBPMStart)
                }
            } else if let score {
                if score.key == KeyRelation.same || score.key == KeyRelation.adjacentUp
                    || score.key == KeyRelation.adjacentDown || score.key == KeyRelation.relative {
                    reasons.append(.bestKeyNeighbor)
                }
                if score.bpmDeltaPct <= 0.03 { reasons.append(.closestTempo) }
                if !score.flags.contains(EdgeFlag.againstShape) { reasons.append(.followsShape) }
                if candidate.energy != nil { reasons.append(.energyFitsCurve) }
            }
            if request.locks[candidate.trackID] != nil || request.lockedFirst == candidate.trackID {
                reasons.append(.lockedByUser)
            }

            let runners = previous.map { runnerUps(from: $0, selected: candidate,
                                                    pool: pool, position: position,
                                                    target: target(position, Double(ordered.count)),
                                                    shape: request.shape) } ?? []
            let relation = previous.map { effectiveBPM(from: $0.bpm!, to: candidate.bpm!).relation } ?? .same
            let effective = previous.map { effectiveBPM(from: $0.bpm!, to: candidate.bpm!).bpm } ?? candidate.bpm!
            steps.append(MixStep(trackID: candidate.trackID, position: position,
                                 effectiveBPM: effective, tempoRelation: relation,
                                reasons: reasons.sorted { String(describing: $0) < String(describing: $1) },
                                 edgeIn: score, runnersUp: runners))
        }

        let weakest = scores.enumerated().sorted { $0.element.total > $1.element.total }
            .prefix(3).map(\.offset)
        let harmonicEdges = scores.filter { harmonic($0.key) }.count
        let tempoJumps = scores.filter { $0.flags.contains(.tempoJump) }.count
        let againstShape = scores.filter { $0.flags.contains(.againstShape) }.count
        let totalDuration = ordered.reduce(0) { $0 + max(0, $1.duration) }
        let range = ordered.compactMap(\.bpm).min().map { minBPM in
            (minBPM...(ordered.compactMap(\.bpm).max() ?? minBPM))
        } ?? 0...0

        return MixPlan(
            steps: steps,
            excluded: excluded,
            summary: MixSummary(bpmRange: range, harmonicEdges: harmonicEdges,
                                totalEdges: scores.count, tempoJumps: tempoJumps,
                                againstShape: againstShape, duration: totalDuration,
                                weakestEdges: Array(weakest)),
            request: request)
    }

    private func valid(_ bpm: Double?) -> Bool {
        guard let bpm else { return false }
        return bpm.isFinite && bpm > 0
    }

    private func removalCost(_ candidate: MixCandidate) -> Double {
        max(1, candidate.duration) * (candidate.energy.map { 1 + abs($0 - 0.5) } ?? 1)
    }

    private func quantile(_ values: [Double], _ fraction: Double) -> Double {
        guard let first = values.first else { return 120 }
        guard values.count > 1 else { return first }
        let index = fraction * Double(values.count - 1)
        let lower = Int(index.rounded(.down))
        let upper = Int(index.rounded(.up))
        if lower == upper { return values[lower] }
        return values[lower] + (values[upper] - values[lower]) * (index - Double(lower))
    }

    private func lockPositions(request: MixRequest, pool: [MixCandidate]) -> [Int: Int64] {
        var result: [Int: Int64] = request.locks.reduce(into: [:]) { value, pair in
            if pair.value >= 0 && pair.value < pool.count,
               pool.contains(where: { $0.trackID == pair.key }) {
                value[pair.value] = pair.key
            }
        }
        if let lockedFirst = request.lockedFirst, pool.contains(where: { $0.trackID == lockedFirst }) {
            result[0] = lockedFirst
        }
        return result
    }

    private func startCost(_ candidate: MixCandidate, shape: MixShape, target: Double, seed: UInt64) -> Double {
        let bpm = candidate.bpm ?? 120
        let directionCost: Double
        switch shape {
        case .risingBPM: directionCost = bpm
        case .windDown: directionCost = -bpm
        default: directionCost = abs(bpm - target)
        }
        return directionCost + abs(bpm - target) * 0.01 + seededTieBreak(candidate.trackID, seed: seed)
    }

    private func effectiveBPM(from: Double, to: Double) -> (bpm: Double, relation: MixTempoRelation) {
        let options: [(Double, MixTempoRelation)] = [(to, .same), (to * 2, .doubleTime), (to / 2, .halfTime)]
        return options.min { abs($0.0 / from - 1) < abs($1.0 / from - 1) }!
    }

    private func keyRelation(_ lhs: String?, _ rhs: String?) -> KeyRelation {
        guard let lhs = lhs.flatMap(CamelotKey.init(code:)),
              let rhs = rhs.flatMap(CamelotKey.init(code:)) else { return .unknown }
        if lhs == rhs { return .same }
        if lhs.relative == rhs { return .relative }
        if lhs.letter == rhs.letter {
            let delta = (rhs.number - lhs.number + 12) % 12
            if delta == 1 { return .adjacentUp }
            if delta == 11 { return .adjacentDown }
            if delta == 6 { return .energyBoost }
            return .clash(steps: min(delta, 12 - delta))
        }
        return .clash(steps: min((rhs.number - lhs.number + 12) % 12,
                                 (lhs.number - rhs.number + 12) % 12))
    }

    private func keyCost(_ relation: KeyRelation) -> Double {
        switch relation {
        case .same: return Self.weights.sameKey
        case .adjacentUp, .adjacentDown, .relative: return Self.weights.compatibleKey
        case .energyBoost: return Self.weights.energyBoostKey
        case .clash, .unknown: return Self.weights.clashingKey
        }
    }

    private func harmonic(_ relation: KeyRelation) -> Bool {
        switch relation {
        case .same, .adjacentUp, .adjacentDown, .relative: return true
        default: return false
        }
    }

    private func edge(from: MixCandidate, to: MixCandidate, target: Double,
                      shape: MixShape, isFirst: Bool) -> EdgeScore {
        let relation = keyRelation(from.camelot, to.camelot)
        let effective = effectiveBPM(from: from.bpm!, to: to.bpm!)
        let delta = abs(effective.bpm / from.bpm! - 1)
        let direction = effective.bpm - from.bpm!
        let expectedDirection: Double = {
            switch shape {
            case .risingBPM: return 1
            case .windDown: return -1
            case .steady: return 0
            case .warmUpPeakCoolDown: return target >= from.bpm! ? 1 : -1
            }
        }()
        let againstShape = expectedDirection != 0 && direction * expectedDirection < -0.0001
        let energyDelta: Double? = if let a = from.energy, let b = to.energy { b - a } else { nil }
        let similarity = cosineDistance(from.embedding, to.embedding)
        var flags: [EdgeFlag] = []
        if againstShape { flags.append(.againstShape) }
        if delta > 0.08 { flags.append(.tempoJump) }
        if relation == .clash(steps: 0) || (!harmonic(relation) && relation != .unknown) {
            flags.append(.keyClash)
        }
        if let lhs = from.artist, let rhs = to.artist, lhs.caseInsensitiveCompare(rhs) == .orderedSame {
            flags.append(.sameArtistBackToBack)
        }
        let shapeDeviation = abs(effective.bpm - target) / max(1, target)
        let energyCost = energyDelta.map { abs($0 - expectedEnergyDelta(from: from, to: to, shape: shape)) * Self.weights.energy } ?? 0
        let similarityCost = similarity.map { $0 * Self.weights.similarity } ?? 0
        let total = keyCost(relation)
            + delta * 100 * Self.weights.tempoPerPercent / 100
                * (againstShape ? Self.weights.againstShapeMultiplier : 1)
            + energyCost + similarityCost
            + (flags.contains(.sameArtistBackToBack) ? Self.weights.sameArtist : 0)
            + shapeDeviation * Self.weights.shapeDeviation
        return EdgeScore(key: relation, bpmDeltaPct: delta * 100,
                         energyDelta: energyDelta, similarity: similarity,
                         shapeDeviation: shapeDeviation, total: total, flags: flags)
    }

    private func markUnavoidableIfForced(_ score: EdgeScore, from: MixCandidate,
                                         remaining: ArraySlice<MixCandidate>, target: Double,
                                         shape: MixShape) -> EdgeScore {
        guard score.flags.contains(.tempoJump),
              !remaining.contains(where: {
                  !edge(from: from, to: $0, target: target, shape: shape, isFirst: false)
                      .flags.contains(.tempoJump)
              }) else { return score }
        var marked = score
        marked.flags.append(.unavoidable(.onlyRemainingOption))
        return marked
    }

    private func expectedEnergyDelta(from: MixCandidate, to: MixCandidate, shape: MixShape) -> Double {
        guard from.energy != nil, to.energy != nil else { return 0 }
        switch shape {
        case .risingBPM, .warmUpPeakCoolDown: return 0.1
        case .steady: return 0
        case .windDown: return -0.1
        }
    }

    private func runnerUps(from previous: MixCandidate, selected: MixCandidate,
                           pool: [MixCandidate], position: Int, target: Double,
                           shape: MixShape) -> [RunnerUp] {
        // Explanations stay complete for normal-size mixes. For a very large
        // library pool, bound the explanatory scan separately from the solve
        // so the 500-track planner remains interactive.
        let considered = pool.count > 100 ? Array(pool.prefix(64)) : pool
        return considered.filter { $0.trackID != selected.trackID }
            .map { candidate in
                let score = edge(from: previous, to: candidate, target: target,
                                 shape: shape, isFirst: false)
                return RunnerUp(trackID: candidate.trackID, total: score.total,
                                lostBecause: score.flags, keyRelation: score.key,
                                bpmDeltaPct: score.bpmDeltaPct)
            }
            .sorted { lhs, rhs in lhs.total == rhs.total ? lhs.trackID < rhs.trackID : lhs.total < rhs.total }
            .prefix(2).map { $0 }
    }

    private func improve(_ ordered: [MixCandidate], lockedByPosition: [Int: Int64],
                         request: MixRequest, target: (Int, Double) -> Double,
                         maxIterations: Int) -> [MixCandidate] {
        // The greedy pass is already deterministic for large libraries. Keep
        // the local-search polish for normal mixes, where it improves quality
        // without turning a 500-track request into an O(n³) operation.
        guard ordered.count > 3, ordered.count <= 100 else { return ordered }
        var result = ordered
        var iterations = 0
        while iterations < maxIterations {
            iterations += 1
            var changed = false
            var evaluated = 0
            for lhs in 1..<(result.count - 2) {
                for rhs in (lhs + 1)..<(result.count - 1) {
                    guard evaluated < 256 else { break }
                    evaluated += 1
                    guard lockedByPosition[lhs] == nil, lockedByPosition[rhs] == nil else { continue }
                    let old = pathCost(result, request: request, target: target)
                    result.swapAt(lhs, rhs)
                    let new = pathCost(result, request: request, target: target)
                    if new + 0.000001 < old { changed = true } else { result.swapAt(lhs, rhs) }
                }
            }
            if !changed { break }
        }
        return result
    }

    private func pathCost(_ path: [MixCandidate], request: MixRequest,
                          target: (Int, Double) -> Double) -> Double {
        guard path.count > 1 else { return 0 }
        return path.dropFirst().enumerated().reduce(0) { partial, pair in
            partial + edge(from: path[pair.offset], to: pair.element,
                           target: target(pair.offset + 1, Double(path.count)),
                           shape: request.shape, isFirst: false).total
        }
    }

    private func cosineDistance(_ lhs: [Float]?, _ rhs: [Float]?) -> Double? {
        guard let lhs, let rhs, lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var dot = 0.0
        var left = 0.0
        var right = 0.0
        for (a, b) in zip(lhs, rhs) {
            dot += Double(a * b)
            left += Double(a * a)
            right += Double(b * b)
        }
        let denominator = sqrt(left) * sqrt(right)
        return denominator > 0 ? 1 - dot / denominator : 1
    }

    private func seededTieBreak(_ trackID: Int64, seed: UInt64) -> Double {
        var value = UInt64(bitPattern: trackID) ^ seed &* 0x9E37_79B9_7F4A_7C15
        value ^= value >> 30
        value &*= 0xBF58476D1CE4E5B9
        value ^= value >> 27
        value &*= 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value % 10_000) / 10_000_000
    }
}
