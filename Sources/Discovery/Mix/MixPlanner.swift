import Accelerate
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

        if request.compatibility == nil,
           let target = request.targetDuration, target.isFinite, target > 0,
           pool.reduce(0, { $0 + max(0, $1.duration) }) > target {
            pool = fitToLength(pool, target: target, request: request, excluded: &excluded)
        }

        guard !pool.isEmpty else {
            return MixPlan(steps: [], excluded: excluded,
                           summary: MixSummary(), request: request)
        }

        // Camelot parsing normalizes strings and walks Unicode scalars. The
        // greedy solve evaluates hundreds of thousands of edges for a large
        // library, so parse each accepted key once and reuse the value.
        let camelotKeys = Dictionary(uniqueKeysWithValues: pool.compactMap { candidate in
            candidate.camelot.flatMap(CamelotKey.init(code:)).map { (candidate.trackID, $0) }
        })

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
        let lockedIDs = Set(lockedByPosition.values)
        var ordered: [MixCandidate] = []
        var orderedIndices: [Int] = []
        var used = [Bool](repeating: false, count: pool.count)
        ordered.reserveCapacity(pool.count)
        let indexByID = Dictionary(pool.enumerated().map { ($1.trackID, $0) }, uniquingKeysWith: { first, _ in first })
        let fast = MixPlannerFastPool(pool: pool, camelotKeys: camelotKeys)
        let tieBreaks = pool.map { seededTieBreak($0.trackID, seed: request.seed) }

        if let compatibility = request.compatibility {
            ordered = chain(pool: pool, request: request, compatibility: compatibility, fast: fast,
                            indexByID: indexByID, lockedByPosition: lockedByPosition,
                            tieBreaks: tieBreaks, target: target)
        } else {
            for position in pool.indices {
                if let lockedID = lockedByPosition[position], let lockedIndex = indexByID[lockedID] {
                    ordered.append(pool[lockedIndex])
                    orderedIndices.append(lockedIndex)
                    used[lockedIndex] = true
                    continue
                }

                let positionTarget = target(position, Double(pool.count))
                let previous = orderedIndices.last
                // One matrix-vector product scores the previous track's sound against every
                // candidate (a 4,000-track library was a minute of per-pair cosines).
                let distances = previous.map { fast.cosineDistances(from: $0) }
                var selected: Int?
                var selectedCost = Double.infinity
                for index in pool.indices {
                    guard !used[index], !lockedIDs.contains(pool[index].trackID) else { continue }

                    let cost: Double
                    if let previous {
                        cost = fast.edgeTotal(from: previous, to: index, target: positionTarget,
                                              shape: request.shape, distance: distances?[index])
                            + tieBreaks[index]
                    } else {
                        cost = startCost(pool[index], shape: request.shape, target: positionTarget,
                                         seed: request.seed)
                    }

                    // Evaluate each candidate once. The previous `min` comparator
                    // recalculated both edge scores on every comparison, which
                    // made a 500-track plan sensitive to host load.
                    if cost < selectedCost
                        || (cost == selectedCost && pool[index].trackID < selected.map { pool[$0].trackID } ?? .max) {
                        selected = index
                        selectedCost = cost
                    }
                }
                guard let selected else { break }
                ordered.append(pool[selected])
                orderedIndices.append(selected)
                used[selected] = true
            }

            // A bounded swap improvement preserves fixed positions and is cheap
            // enough for the 500-track CI performance bound.
            ordered = improve(ordered, lockedByPosition: lockedByPosition, request: request,
                               target: target, camelotKeys: camelotKeys,
                               maxIterations: min(2, ordered.count))
        }

        var steps: [MixStep] = []
        steps.reserveCapacity(ordered.count)
        // A mix has one musical clock. Use the fastest analyzed track as that
        // clock and key-tempo every other track up to it; never make the
        // listener choose a curve or silently switch between half/double time.
        let referenceBPM = ordered.compactMap(\.bpm).max() ?? 0
        var scores: [EdgeScore] = []
        for (position, candidate) in ordered.enumerated() {
            let previous = position > 0 ? ordered[position - 1] : nil
            // Every explanation edge from `previous` reuses one matrix-vector product of sound
            // distances instead of a per-pair cosine.
            let distances = previous.flatMap { indexByID[$0.trackID] }.map {
                StepDistances(byIndex: fast.cosineDistances(from: $0), indexByID: indexByID)
            }
            let score = previous.map { previousCandidate in
                let raw = edge(from: previousCandidate, to: candidate,
                               target: target(position, Double(ordered.count)),
                               shape: request.shape, isFirst: false,
                               camelotKeys: camelotKeys, distances: distances)
                return markUnavoidableIfForced(raw, from: previousCandidate,
                                               remaining: ordered.dropFirst(position + 1),
                                               target: target(position, Double(ordered.count)),
                                               shape: request.shape, distances: distances,
                                               camelotKeys: camelotKeys)
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
                                                    shape: request.shape,
                                                    camelotKeys: camelotKeys,
                                                    distances: distances,
                                                    compatibility: request.compatibility) } ?? []
            let relation: MixTempoRelation = position == 0 ? .same : .keyTempo
            let effective = referenceBPM > 0 ? referenceBPM : candidate.bpm!
            steps.append(MixStep(trackID: candidate.trackID, position: position,
                                 effectiveBPM: effective, sourceBPM: candidate.bpm,
                                 tempoRelation: relation,
                                reasons: reasons.sorted { String(describing: $0) < String(describing: $1) },
                                 edgeIn: score, runnersUp: runners))
        }

        let weakest = scores.enumerated().sorted { $0.element.total > $1.element.total }
            .prefix(3).map(\.offset)
        let harmonicEdges = scores.filter { harmonic($0.key) }.count
        let tempoJumps = scores.filter { $0.flags.contains(.tempoJump) }.count
        let againstShape = scores.filter { $0.flags.contains(.againstShape) }.count
        let totalDuration = ordered.reduce(0) { $0 + max(0, $1.duration) }
        let range = referenceBPM > 0 ? referenceBPM...referenceBPM : 0...0

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

    /// Build a Mix under mixing rules: a seeded random first track (or the locked one), then each
    /// next track chosen — by the usual shape/energy/sound cost — only among tracks within the BPM
    /// tolerance and a compatible key of the previous one, until the session length is reached or
    /// nothing compatible is left. Locked positions are honoured.
    private func chain(pool: [MixCandidate], request: MixRequest, compatibility: MixCompatibility,
                       fast: MixPlannerFastPool, indexByID: [Int64: Int],
                       lockedByPosition: [Int: Int64], tieBreaks: [Double],
                       target: (Int, Double) -> Double) -> [MixCandidate] {
        guard !pool.isEmpty else { return [] }
        let goal = request.targetDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let averageLength = max(60, pool.reduce(0) { $0 + max(0, $1.duration) } / Double(pool.count))
        let expectedCount = goal.map { max(1, ($0 / averageLength).rounded()) } ?? Double(pool.count)
        let codes = pool.map { $0.camelot ?? "" }
        var used = [Bool](repeating: false, count: pool.count)
        var orderedIndices: [Int] = []
        var total: TimeInterval = 0

        // A random first track — among those that fit the session (a 27-minute piece can't open a
        // 15-minute mix), unless nothing does.
        let fitting = pool.indices.filter { goal == nil || pool[$0].duration <= goal! }
        let firstPool = fitting.isEmpty ? Array(pool.indices) : fitting
        let first = request.lockedFirst.flatMap { indexByID[$0] }
            ?? lockedByPosition[0].flatMap { indexByID[$0] }
            ?? firstPool.min { tieBreaks[$0] == tieBreaks[$1] ? pool[$0].trackID < pool[$1].trackID : tieBreaks[$0] < tieBreaks[$1] }!
        orderedIndices.append(first)
        used[first] = true
        total += max(0, pool[first].duration)

        while true {
            if let goal, total >= goal * 0.97 { break }
            let position = orderedIndices.count
            if let lockedID = lockedByPosition[position], let locked = indexByID[lockedID], !used[locked] {
                orderedIndices.append(locked)
                used[locked] = true
                total += max(0, pool[locked].duration)
                continue
            }
            let previous = orderedIndices[orderedIndices.count - 1]
            let positionTarget = target(position, max(expectedCount, Double(position + 1)))
            let distances = fast.cosineDistances(from: previous)
            var selected: Int?
            var selectedCost = Double.infinity
            for index in pool.indices where !used[index] {
                guard compatibility.bpmCompatible(fast.bpm[previous], fast.bpm[index]),
                      MixCompatibility.keysCompatible(codes[previous], codes[index]) else { continue }
                if let goal, total + max(0, pool[index].duration) > goal * 1.1 { continue }
                let cost = fast.edgeTotal(from: previous, to: index, target: positionTarget,
                                          shape: request.shape, distance: distances[index]) + tieBreaks[index]
                if cost < selectedCost
                    || (cost == selectedCost && pool[index].trackID < selected.map { pool[$0].trackID } ?? .max) {
                    selected = index
                    selectedCost = cost
                }
            }
            guard let selected else { break }
            orderedIndices.append(selected)
            used[selected] = true
            total += max(0, pool[selected].duration)
        }
        return orderedIndices.map { pool[$0] }
    }

    /// Picks the tracks for a 15/30/60-minute mix from a larger pool. Locked tracks stay; the rest
    /// are taken in a seed-shuffled order — full-length tracks before short clips — while they still
    /// fit. (Trimming the longest tracks first used to leave a 15-minute mix of 24-second snippets,
    /// identical on every Regenerate.) The shape then orders whatever was picked.
    private func fitToLength(_ pool: [MixCandidate], target: TimeInterval, request: MixRequest,
                             excluded: inout [MixExclusion]) -> [MixCandidate] {
        var locked = Set(request.locks.keys)
        if let first = request.lockedFirst { locked.insert(first) }
        var keep = Set<Int64>()
        var used: TimeInterval = 0
        for candidate in pool where locked.contains(candidate.trackID) {
            keep.insert(candidate.trackID)
            used += max(0, candidate.duration)
        }
        let order = pool.filter { !locked.contains($0.trackID) }.sorted { lhs, rhs in
            let lhsShort = lhs.duration < Self.shortClipSeconds, rhsShort = rhs.duration < Self.shortClipSeconds
            if lhsShort != rhsShort { return !lhsShort }
            let l = seededTieBreak(lhs.trackID, seed: request.seed), r = seededTieBreak(rhs.trackID, seed: request.seed)
            return l == r ? lhs.trackID < rhs.trackID : l < r
        }
        for candidate in order {
            let length = max(0, candidate.duration)
            // Short clips only rescue a session the full-length tracks couldn't get near.
            if length < Self.shortClipSeconds, used >= target * 0.8 { break }
            guard used + length <= target else { continue }
            keep.insert(candidate.trackID)
            used += length
            if used >= target * 0.97 { break }
        }
        // Every track is longer than the session: keep the shortest one rather than nothing.
        if keep.isEmpty, let shortest = pool.min(by: { $0.duration < $1.duration }) {
            keep.insert(shortest.trackID)
        }
        for candidate in pool where !keep.contains(candidate.trackID) {
            excluded.append(MixExclusion(trackID: candidate.trackID, reason: .overTargetLength))
        }
        return pool.filter { keep.contains($0.trackID) }
    }

    /// Tracks shorter than this are picked only when longer ones can't fill the session.
    static let shortClipSeconds: TimeInterval = 90

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
        let sameDistance = abs(to / from - 1)
        let doubleDistance = abs(to * 2 / from - 1)
        let halfDistance = abs(to / 2 / from - 1)
        if sameDistance <= doubleDistance && sameDistance <= halfDistance {
            return (to, .same)
        }
        if doubleDistance <= halfDistance {
            return (to * 2, .doubleTime)
        }
        return (to / 2, .halfTime)
    }

    private func keyRelation(_ lhs: String?, _ rhs: String?) -> KeyRelation {
        keyRelation(lhs.flatMap(CamelotKey.init(code:)), rhs.flatMap(CamelotKey.init(code:)))
    }

    private func keyRelation(_ lhs: CamelotKey?, _ rhs: CamelotKey?) -> KeyRelation {
        guard let lhs, let rhs else { return .unknown }
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
                      shape: MixShape, isFirst: Bool,
                      camelotKeys: [Int64: CamelotKey] = [:],
                      distances: StepDistances? = nil) -> EdgeScore {
        let relation = keyRelation(camelotKeys[from.trackID], camelotKeys[to.trackID])
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
        let similarity = distances.map { $0.distance(to: to.trackID) }
            ?? cosineDistance(from.embedding, to.embedding)
        var flags: [EdgeFlag] = []
        if againstShape { flags.append(.againstShape) }
        if delta > 0.08 { flags.append(.tempoJump) }
        if relation == .clash(steps: 0) || (!harmonic(relation) && relation != .unknown) {
            flags.append(.keyClash)
        }
        if let lhs = from.artist, let rhs = to.artist,
           lhs == rhs || lhs.caseInsensitiveCompare(rhs) == .orderedSame {
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

    /// The greedy solve only needs a scalar score. Keeping that hot path free
    /// of EdgeScore/flag allocations makes the 500-track planner comfortably
    /// interactive while the full edge remains available for explanations.
    private func edgeTotal(from: MixCandidate, to: MixCandidate, target: Double,
                           shape: MixShape,
                           camelotKeys: [Int64: CamelotKey]) -> Double {
        let sameArtist = if let lhs = from.artist, let rhs = to.artist {
            lhs == rhs || lhs.caseInsensitiveCompare(rhs) == .orderedSame
        } else { false }
        return Self.edgeCost(fromBPM: from.bpm!, toBPM: to.bpm!,
                             fromKey: camelotKeys[from.trackID], toKey: camelotKeys[to.trackID],
                             fromEnergy: from.energy, toEnergy: to.energy, sameArtist: sameArtist,
                             similarityDistance: cosineDistance(from.embedding, to.embedding),
                             target: target, shape: shape)
    }

    /// The greedy solve's scalar edge score, shared by the pairwise path and the accelerated pool
    /// so both rank candidates identically.
    static func edgeCost(fromBPM: Double, toBPM: Double, fromKey: CamelotKey?, toKey: CamelotKey?,
                         fromEnergy: Double?, toEnergy: Double?, sameArtist: Bool,
                         similarityDistance: Double?, target: Double, shape: MixShape) -> Double {
        let planner = MixPlanner()
        let relation = planner.keyRelation(fromKey, toKey)
        let effective = planner.effectiveBPM(from: fromBPM, to: toBPM)
        let delta = abs(effective.bpm / fromBPM - 1)
        let direction = effective.bpm - fromBPM
        let expectedDirection: Double
        switch shape {
        case .risingBPM: expectedDirection = 1
        case .windDown: expectedDirection = -1
        case .steady: expectedDirection = 0
        case .warmUpPeakCoolDown: expectedDirection = target >= fromBPM ? 1 : -1
        }
        let againstShape = expectedDirection != 0 && direction * expectedDirection < -0.0001
        let energyCost: Double
        if let a = fromEnergy, let b = toEnergy {
            let desired: Double = switch shape {
            case .risingBPM, .warmUpPeakCoolDown: 0.1
            case .steady: 0
            case .windDown: -0.1
            }
            energyCost = abs((b - a) - desired) * weights.energy
        } else {
            energyCost = 0
        }
        let similarityCost = similarityDistance.map { $0 * weights.similarity } ?? 0
        let shapeDeviation = abs(effective.bpm - target) / max(1, target)
        return planner.keyCost(relation)
            + delta * weights.tempoPerPercent
                * (againstShape ? weights.againstShapeMultiplier : 1)
            + energyCost + similarityCost
            + (sameArtist ? weights.sameArtist : 0)
            + shapeDeviation * weights.shapeDeviation
    }

    private func markUnavoidableIfForced(_ score: EdgeScore, from: MixCandidate,
                                         remaining: ArraySlice<MixCandidate>, target: Double,
                                         shape: MixShape, distances: StepDistances? = nil,
                                         camelotKeys: [Int64: CamelotKey]) -> EdgeScore {
        // The explanation is intentionally bounded for large libraries. The
        // solve is already deterministic and the user-facing runners-up scan
        // is bounded separately; rescanning every remaining candidate for
        // every edge would make a 500-track mix miss its device budget.
        let considered = remaining.count > 128 ? remaining.prefix(64) : remaining
        guard score.flags.contains(.tempoJump),
              !considered.contains(where: {
                  !edge(from: from, to: $0, target: target, shape: shape, isFirst: false,
                       camelotKeys: camelotKeys, distances: distances).flags.contains(.tempoJump)
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
                           shape: MixShape,
                           camelotKeys: [Int64: CamelotKey],
                           distances: StepDistances? = nil,
                           compatibility: MixCompatibility? = nil) -> [RunnerUp] {
        // Under mixing rules a runner-up (and so a Swap) must obey them too.
        let admissible = compatibility.map { rules in
            pool.filter { candidate in
                rules.bpmCompatible(previous.bpm ?? 0, candidate.bpm ?? 0)
                    && MixCompatibility.keysCompatible(previous.camelot ?? "", candidate.camelot ?? "")
            }
        } ?? pool
        // Explanations stay complete for normal-size mixes. For a very large
        // library pool, bound the explanatory scan separately from the solve
        // so the 500-track planner remains interactive.
        let considered = admissible.count > 100 ? Array(admissible.prefix(64)) : admissible
        return considered.filter { $0.trackID != selected.trackID }
            .map { candidate in
                let score = edge(from: previous, to: candidate, target: target,
                                 shape: shape, isFirst: false,
                                 camelotKeys: camelotKeys, distances: distances)
                return RunnerUp(trackID: candidate.trackID, total: score.total,
                                lostBecause: score.flags, keyRelation: score.key,
                                bpmDeltaPct: score.bpmDeltaPct)
            }
            .sorted { lhs, rhs in lhs.total == rhs.total ? lhs.trackID < rhs.trackID : lhs.total < rhs.total }
            .prefix(2).map { $0 }
    }

    private func improve(_ ordered: [MixCandidate], lockedByPosition: [Int: Int64],
                         request: MixRequest, target: (Int, Double) -> Double,
                         camelotKeys: [Int64: CamelotKey],
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
                    let old = pathCost(result, request: request, target: target,
                                       camelotKeys: camelotKeys)
                    result.swapAt(lhs, rhs)
                    let new = pathCost(result, request: request, target: target,
                                       camelotKeys: camelotKeys)
                    if new + 0.000001 < old { changed = true } else { result.swapAt(lhs, rhs) }
                }
            }
            if !changed { break }
        }
        return result
    }

    private func pathCost(_ path: [MixCandidate], request: MixRequest,
                          target: (Int, Double) -> Double,
                          camelotKeys: [Int64: CamelotKey]) -> Double {
        guard path.count > 1 else { return 0 }
        return path.dropFirst().enumerated().reduce(0) { partial, pair in
            partial + edge(from: path[pair.offset], to: pair.element,
                           target: target(pair.offset + 1, Double(path.count)),
                           shape: request.shape, isFirst: false,
                           camelotKeys: camelotKeys).total
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

/// The greedy solve's inputs laid out for speed: per-track arrays instead of dictionary and string
/// work in the n² inner loop, and unit-length embeddings in one row-major matrix so each step's
/// sound distances are a single BLAS matrix-vector product. `edgeTotal` scores exactly what
/// `MixPlanner.edgeTotal` scores.
struct MixPlannerFastPool {
    let bpm: [Double]
    let energy: [Double?]
    let artistID: [Int?]
    let keys: [CamelotKey?]
    let artists: [String?]
    private let dimensions: Int
    private let unitEmbeddings: [Float]
    private let hasEmbedding: [Bool]

    init(pool: [MixCandidate], camelotKeys: [Int64: CamelotKey]) {
        bpm = pool.map { $0.bpm ?? 120 }
        energy = pool.map(\.energy)
        keys = pool.map { camelotKeys[$0.trackID] }
        artists = pool.map(\.artist)
        var artistIDs: [String: Int] = [:]
        artistID = pool.map { candidate in
            guard let name = candidate.artist else { return nil }
            let folded = name.folding(options: [.caseInsensitive], locale: nil)
            if let id = artistIDs[folded] { return id }
            let id = artistIDs.count
            artistIDs[folded] = id
            return id
        }
        // Embeddings of the most common width take part; others (a mismatched model) score as
        // "no similarity", exactly as the pairwise cosine treated a width mismatch.
        let widths = pool.compactMap { $0.embedding?.count }.filter { $0 > 0 }
        let width = Dictionary(widths.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key ?? 0
        dimensions = width
        var matrix = [Float](repeating: 0, count: pool.count * max(width, 1))
        var present = [Bool](repeating: false, count: pool.count)
        if width > 0 {
            for (row, candidate) in pool.enumerated() {
                guard let vector = candidate.embedding, vector.count == width else { continue }
                present[row] = true
                var norm: Float = 0
                vDSP_svesq(vector, 1, &norm, vDSP_Length(width))
                norm = norm.squareRoot()
                guard norm > 0 else { continue }  // zero vector: distance 1, as before
                var scale = 1 / norm
                matrix.withUnsafeMutableBufferPointer { buffer in
                    vDSP_vsmul(vector, 1, &scale, buffer.baseAddress! + row * width, 1, vDSP_Length(width))
                }
            }
        }
        unitEmbeddings = matrix
        hasEmbedding = present
    }

    /// Cosine distance from track `index` to every track (nil where either has no embedding).
    func cosineDistances(from index: Int) -> [Double?] {
        let count = hasEmbedding.count
        guard dimensions > 0, hasEmbedding[index] else { return [Double?](repeating: nil, count: count) }
        var similarities = [Float](repeating: 0, count: count)
        unitEmbeddings.withUnsafeBufferPointer { matrix in
            // (count × dimensions) · (dimensions × 1); vDSP_mmul replaces the deprecated cblas_sgemv.
            vDSP_mmul(matrix.baseAddress!, 1, matrix.baseAddress! + index * dimensions, 1,
                      &similarities, 1, vDSP_Length(count), 1, vDSP_Length(dimensions))
        }
        return (0..<count).map { hasEmbedding[$0] ? 1 - Double(similarities[$0]) : nil }
    }

    func edgeTotal(from: Int, to: Int, target: Double, shape: MixShape, distance: Double?) -> Double {
        MixPlanner.edgeCost(fromBPM: bpm[from], toBPM: bpm[to], fromKey: keys[from], toKey: keys[to],
                            fromEnergy: energy[from], toEnergy: energy[to],
                            sameArtist: artistID[from] != nil && artistID[from] == artistID[to],
                            similarityDistance: distance, target: target, shape: shape)
    }
}

/// Sound distances from one track to every track in the pool, looked up by track id.
struct StepDistances {
    let byIndex: [Double?]
    let indexByID: [Int64: Int]
    func distance(to trackID: Int64) -> Double? {
        indexByID[trackID].flatMap { byIndex[$0] }
    }
}
