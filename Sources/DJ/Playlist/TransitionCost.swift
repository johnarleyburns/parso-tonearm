import Foundation
import Accelerate

/// One candidate track's musical attributes for the sequencer (§28A.2). Every
/// attribute except identity is optional: an unanalysed track still sequences,
/// with missing attributes contributing the neutral 0.5 per term (the
/// `RankCandidate` convention). `energy` is the [0,1] empirical-CDF percentile
/// rank over the candidate set (§28A.5, plan §2.2); `embedding` is the
/// dequantized f32 pooled CLAP vector used for timbral continuity.
public struct TrackFeatures: Sendable, Equatable {
    public var trackID: Int64
    public var durationSec: Double
    public var bpm: Double?
    public var camelot: CamelotKey?
    public var energy: Double?
    public var embedding: [Float]?
    public var artistIDs: [Int64]
    public var albumID: Int64?
    public var isExplicit: Bool
    public var isFullyCached: Bool

    public init(trackID: Int64,
                durationSec: Double,
                bpm: Double? = nil,
                camelot: CamelotKey? = nil,
                energy: Double? = nil,
                embedding: [Float]? = nil,
                artistIDs: [Int64] = [],
                albumID: Int64? = nil,
                isExplicit: Bool = false,
                isFullyCached: Bool = false) {
        self.trackID = trackID
        self.durationSec = durationSec
        self.bpm = bpm
        self.camelot = camelot
        self.energy = energy
        self.embedding = embedding
        self.artistIDs = artistIDs
        self.albumID = albumID
        self.isExplicit = isExplicit
        self.isFullyCached = isFullyCached
    }
}

/// The brief's hard and soft sequencing constraints (§28A.2). Stored on the
/// brief as the canonical `.sortedKeys` encoding of `constraintsJSON` (§14.3),
/// so an encode → decode → encode round-trip is byte-exact (NFR-DET-3).
public struct SequencingConstraints: Codable, Sendable, Equatable {
    /// Slots between tracks by the same artist.
    public var minArtistGap: Int = 3
    public var minAlbumGap: Int = 2
    /// Absolute BPM delta between neighbours.
    public var maxBPMJump: Double = 8.0
    /// 0 = ignore key, 1 = Camelot-adjacent only.
    public var keyStrictness: Double = 0.6
    public var allowExplicit: Bool = true
    /// Only fully-local tracks (FR-LIB-8 pre-flight).
    public var requireCached: Bool = false
    /// Stored as lo/hi so the type stays Codable (a `ClosedRange` is not).
    public var bpmLo: Double?
    public var bpmHi: Double?
    public var excludeGenres: [String] = []

    public init(minArtistGap: Int = 3,
                minAlbumGap: Int = 2,
                maxBPMJump: Double = 8.0,
                keyStrictness: Double = 0.6,
                allowExplicit: Bool = true,
                requireCached: Bool = false,
                bpmRange: ClosedRange<Double>? = nil,
                excludeGenres: [String] = []) {
        self.minArtistGap = minArtistGap
        self.minAlbumGap = minAlbumGap
        self.maxBPMJump = maxBPMJump
        self.keyStrictness = keyStrictness
        self.allowExplicit = allowExplicit
        self.requireCached = requireCached
        self.bpmLo = bpmRange?.lowerBound
        self.bpmHi = bpmRange?.upperBound
        self.excludeGenres = excludeGenres
    }

    public var bpmRange: ClosedRange<Double>? {
        get {
            guard let lo = bpmLo, let hi = bpmHi, lo <= hi else { return nil }
            return lo...hi
        }
        set {
            bpmLo = newValue?.lowerBound
            bpmHi = newValue?.upperBound
        }
    }
}

/// The weights of the objective J (§28A.1): arc adherence, semantic score,
/// transition cost, and duration error. Pinned so two devices agree
/// (plan §2.5); sum to 1.0.
public struct SequenceWeights: Sendable, Equatable {
    public var arc: Double
    public var semantic: Double
    public var transition: Double
    public var duration: Double

    public static let `default` = SequenceWeights()

    public init(arc: Double = 0.25,
                semantic: Double = 0.35,
                transition: Double = 0.25,
                duration: Double = 0.15) {
        self.arc = arc
        self.semantic = semantic
        self.transition = transition
        self.duration = duration
    }
}

/// The pure sequencing core (§28A.2–28A.3). `transitionCost` lands in this
/// milestone; the beam search (`sequence`) is added in commit 3.2. Everything
/// here is deterministic (NFR-DET-3) and has no I/O.
public enum PlaylistSequencer {

    /// Neutral value for a missing attribute or unconstrained term — it neither
    /// rewards nor penalizes, so an unanalysed track cannot tilt an ordering.
    public static let neutral: Double = 0.5

    /// §28A.2's transition cost, lower = smoother, range ≈ 0...1:
    /// `0.30·bpm + 0.25·key + 0.30·timbre + 0.15·energy`, with energy **drops**
    /// penalised harder than rises. All four terms are pure functions over data
    /// the analysis pipeline already produces.
    public static func transitionCost(_ a: TrackFeatures, _ b: TrackFeatures,
                                      _ c: SequencingConstraints) -> Double {
        // 1. Tempo continuity — a listener notices a big jump; a DJ cannot
        //    beatmatch one. §28A.2: min(1, ΔBPM / maxBPMJump).
        let bpmCost: Double
        if let aBPM = a.bpm, let bBPM = b.bpm, c.maxBPMJump > 0 {
            bpmCost = min(1.0, abs(aBPM - bBPM) / c.maxBPMJump)
        } else {
            bpmCost = neutral
        }

        // 2. Harmonic compatibility — Camelot wheel distance (0 for same /
        //    relative / adjacent), scaled by the brief's key strictness.
        let keyCost = Camelot.distance(a.camelot, b.camelot)
            * min(1, max(0, c.keyStrictness))

        // 3. Timbral continuity — cosine distance between pooled CLAP vectors.
        //    This is what stops a sequence being harmonically perfect and
        //    tonally absurd (§28A.2).
        let timbreCost = timbreDistance(a.embedding, b.embedding)

        // 4. Energy step — small rises feel intentional, large drops feel like
        //    a mistake. Thresholds calibrated for the [0,1] CDF rank scale.
        let energyCost: Double
        if let aEnergy = a.energy, let bEnergy = b.energy {
            let step = bEnergy - aEnergy
            energyCost = step >= 0 ? min(1.0, step / 0.35)
                                   : min(1.0, -step / 0.20)
        } else {
            energyCost = neutral
        }

        return 0.30 * bpmCost + 0.25 * keyCost + 0.30 * timbreCost + 0.15 * energyCost
    }

    /// Cosine distance `1 − cos` between two pooled vectors; nil, empty or
    /// zero-norm input (no usable embedding) → the neutral 0.5.
    static func timbreDistance(_ a: [Float]?, _ b: [Float]?) -> Double {
        guard let a, let b, !a.isEmpty, a.count == b.count else { return neutral }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var sumA: Float = 0, sumB: Float = 0
        vDSP_svesq(a, 1, &sumA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &sumB, vDSP_Length(b.count))
        let normProduct = sqrt(Double(sumA)) * sqrt(Double(sumB))
        guard normProduct > 1e-12 else { return neutral }
        return 1.0 - Double(dot) / normProduct
    }
}
