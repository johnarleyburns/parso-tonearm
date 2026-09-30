import Foundation

public enum MixShape: String, Codable, Sendable, Equatable, CaseIterable {
    case risingBPM
    case steady
    case warmUpPeakCoolDown
    case windDown
}

public enum MixTempoRelation: String, Codable, Sendable, Equatable {
    case same
    case halfTime
    case doubleTime
}

public struct MixCandidate: Codable, Sendable, Equatable, Identifiable {
    public let trackID: Int64
    public var bpm: Double?
    public var camelot: String?
    public var energy: Double?
    public var artist: String?
    public var albumID: Int64?
    public var duration: Double
    public var embedding: [Float]?

    public var id: Int64 { trackID }

    public init(trackID: Int64, bpm: Double? = nil, camelot: String? = nil,
                energy: Double? = nil, artist: String? = nil, albumID: Int64? = nil,
                duration: Double = 0, embedding: [Float]? = nil) {
        self.trackID = trackID
        self.bpm = bpm
        self.camelot = camelot
        self.energy = energy
        self.artist = artist
        self.albumID = albumID
        self.duration = duration
        self.embedding = embedding
    }
}

public struct MixRequest: Codable, Sendable, Equatable {
    public var candidates: [MixCandidate]
    public var shape: MixShape
    public var targetDuration: TimeInterval?
    public var lockedFirst: Int64?
    public var locks: [Int64: Int]
    public var seed: UInt64

    public init(candidates: [MixCandidate], shape: MixShape = .risingBPM,
                targetDuration: TimeInterval? = nil, lockedFirst: Int64? = nil,
                locks: [Int64: Int] = [:], seed: UInt64 = 0) {
        self.candidates = candidates
        self.shape = shape
        self.targetDuration = targetDuration
        self.lockedFirst = lockedFirst
        self.locks = locks
        self.seed = seed
    }
}

public struct MixMissingAnalysis: OptionSet, Codable, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bpm = Self(rawValue: 1)
    public static let key = Self(rawValue: 2)
    public static let energy = Self(rawValue: 4)
    public static let bpmAndKey: Self = [.bpm, .key]
}

public enum UnavoidableReason: Codable, Sendable, Equatable {
    case onlyRemainingOption
    case limitedTempoPool
    case missingGrid
    case explanation(String)
}

public enum KeyRelation: Codable, Sendable, Equatable {
    case same
    case adjacentUp
    case adjacentDown
    case relative
    case energyBoost
    case clash(steps: Int)
    case unknown
}

public enum EdgeFlag: Codable, Sendable, Equatable {
    case againstShape
    case tempoJump
    case keyClash
    case sameArtistBackToBack
    case unavoidable(UnavoidableReason)
}

public enum PlacementReason: Codable, Sendable, Equatable {
    case lowestBPMStart
    case followsShape
    case bestKeyNeighbor
    case closestTempo
    case energyFitsCurve
    case lockedByUser
    case onlyRemainingOption
    case soundsSimilar
}

public struct EdgeScore: Codable, Sendable, Equatable {
    public var key: KeyRelation
    public var bpmDeltaPct: Double
    public var energyDelta: Double?
    public var similarity: Double?
    public var shapeDeviation: Double
    public var total: Double
    public var flags: [EdgeFlag]

    public init(key: KeyRelation, bpmDeltaPct: Double, energyDelta: Double? = nil,
                similarity: Double? = nil, shapeDeviation: Double, total: Double,
                flags: [EdgeFlag] = []) {
        self.key = key
        self.bpmDeltaPct = bpmDeltaPct
        self.energyDelta = energyDelta
        self.similarity = similarity
        self.shapeDeviation = shapeDeviation
        self.total = total
        self.flags = flags
    }
}

public struct RunnerUp: Codable, Sendable, Equatable {
    public var trackID: Int64
    public var total: Double
    public var lostBecause: [EdgeFlag]
    public var keyRelation: KeyRelation
    public var bpmDeltaPct: Double

    public init(trackID: Int64, total: Double, lostBecause: [EdgeFlag],
                keyRelation: KeyRelation, bpmDeltaPct: Double) {
        self.trackID = trackID
        self.total = total
        self.lostBecause = lostBecause
        self.keyRelation = keyRelation
        self.bpmDeltaPct = bpmDeltaPct
    }
}

public enum MixExclusionReason: Codable, Sendable, Equatable {
    case notAnalyzed(missing: MixMissingAnalysis)
    case overTargetLength
    case duplicate
    case unplayable
}

public struct MixExclusion: Codable, Sendable, Equatable {
    public var trackID: Int64
    public var reason: MixExclusionReason

    public init(trackID: Int64, reason: MixExclusionReason) {
        self.trackID = trackID
        self.reason = reason
    }
}

public struct MixSummary: Codable, Sendable, Equatable {
    public var bpmRange: ClosedRange<Double>
    public var harmonicEdges: Int
    public var totalEdges: Int
    public var tempoJumps: Int
    public var againstShape: Int
    public var duration: TimeInterval
    public var weakestEdges: [Int]

    public init(bpmRange: ClosedRange<Double> = 0...0, harmonicEdges: Int = 0,
                totalEdges: Int = 0, tempoJumps: Int = 0, againstShape: Int = 0,
                duration: TimeInterval = 0, weakestEdges: [Int] = []) {
        self.bpmRange = bpmRange
        self.harmonicEdges = harmonicEdges
        self.totalEdges = totalEdges
        self.tempoJumps = tempoJumps
        self.againstShape = againstShape
        self.duration = duration
        self.weakestEdges = weakestEdges
    }
}

public struct MixStep: Codable, Sendable, Equatable, Identifiable {
    public var trackID: Int64
    public var position: Int
    public var effectiveBPM: Double
    public var tempoRelation: MixTempoRelation
    public var reasons: [PlacementReason]
    public var edgeIn: EdgeScore?
    public var runnersUp: [RunnerUp]

    public var id: Int64 { trackID }

    public init(trackID: Int64, position: Int, effectiveBPM: Double,
                tempoRelation: MixTempoRelation = .same,
                reasons: [PlacementReason] = [], edgeIn: EdgeScore? = nil,
                runnersUp: [RunnerUp] = []) {
        self.trackID = trackID
        self.position = position
        self.effectiveBPM = effectiveBPM
        self.tempoRelation = tempoRelation
        self.reasons = reasons
        self.edgeIn = edgeIn
        self.runnersUp = Array(runnersUp.prefix(2))
    }
}

public struct MixPlan: Codable, Sendable, Equatable {
    public var steps: [MixStep]
    public var excluded: [MixExclusion]
    public var summary: MixSummary
    public var request: MixRequest
    /// Fully resolved transition decisions used by both preview and playback.
    /// Empty is valid for old persisted plans; the player resolves missing
    /// edges from the stored analysis payload before the fade begins.
    public var transitionPlans: [TransitionPlan]

    public init(steps: [MixStep], excluded: [MixExclusion], summary: MixSummary,
                request: MixRequest, transitionPlans: [TransitionPlan] = []) {
        self.steps = steps
        self.excluded = excluded
        self.summary = summary
        self.request = request
        self.transitionPlans = transitionPlans
    }

    private enum CodingKeys: String, CodingKey {
        case steps, excluded, summary, request, transitionPlans
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        steps = try container.decode([MixStep].self, forKey: .steps)
        excluded = try container.decode([MixExclusion].self, forKey: .excluded)
        summary = try container.decode(MixSummary.self, forKey: .summary)
        request = try container.decode(MixRequest.self, forKey: .request)
        transitionPlans = try container.decodeIfPresent([TransitionPlan].self,
                                                        forKey: .transitionPlans) ?? []
    }
}

public enum TransitionStyle: String, Codable, Sendable, Equatable {
    case gapless
    case beatmatchedBlend
    case phraseFade
    case plainCrossfade
}

public enum GridPrepState: Codable, Sendable, Equatable {
    case notPrepared
    case ready
    case queued
    case downloading(Double)
    case analyzing(Double)
    case waitingForNetwork
    case waitingForWiFi
    case failed(String)
    case cancelled
}

public enum TransitionReason: Codable, Sendable, Equatable {
    case outgoingOutroPhrase(bar: Int, beats: Int)
    case incomingIntroPhrase(beats: Int)
    case lastPhraseBoundary(bar: Int)
    case skippedLeadingSilence(seconds: Double)
    case tempoMatched(pct: Double)
    case tempoReturnsOverBeats(Int)
    case keyCompatible(KeyRelation)
    case keyClashShortOverlap
    case tempoTooFar(pct: Double)
    case lowTempoConfidence(Double)
    case variableTempo
    case gridNotReady(GridPrepState)
    case notBuffered
    case sameAlbumGapless
    case loudnessMatched(dB: Double)
    case userChosePlainFade
}

public struct TransitionPlan: Codable, Sendable, Equatable {
    public var fromTrackID: Int64
    public var toTrackID: Int64
    public var style: TransitionStyle
    public var exitTime: Double
    public var entryTime: Double
    public var overlapBeats: Int?
    public var overlapSeconds: Double
    public var blendRate: Double
    public var rateRampBeats: Int?
    public var gainMatchDB: Double?
    public var keyRelation: KeyRelation
    public var bpmDeltaPct: Double?
    public var confidence: Double
    public var reasons: [TransitionReason]
    public var downgradedFrom: TransitionStyle?

    public init(fromTrackID: Int64, toTrackID: Int64, style: TransitionStyle,
                exitTime: Double = 0, entryTime: Double = 0, overlapBeats: Int? = nil,
                overlapSeconds: Double = 0, blendRate: Double = 1,
                rateRampBeats: Int? = nil, gainMatchDB: Double? = nil,
                keyRelation: KeyRelation = .unknown, bpmDeltaPct: Double? = nil,
                confidence: Double = 0, reasons: [TransitionReason] = [],
                downgradedFrom: TransitionStyle? = nil) {
        self.fromTrackID = fromTrackID
        self.toTrackID = toTrackID
        self.style = style
        self.exitTime = exitTime
        self.entryTime = entryTime
        self.overlapBeats = overlapBeats
        self.overlapSeconds = overlapSeconds
        self.blendRate = blendRate
        self.rateRampBeats = rateRampBeats
        self.gainMatchDB = gainMatchDB
        self.keyRelation = keyRelation
        self.bpmDeltaPct = bpmDeltaPct
        self.confidence = confidence
        self.reasons = reasons
        self.downgradedFrom = downgradedFrom
    }
}
