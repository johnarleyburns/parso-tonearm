import Foundation

// MARK: - Stem identity

/// The four Demucs voices (§35.1, §36.2, FR-ENG-3). The order matters — it is
/// the order the separator, cache and reader all agree on.
public enum StemKind: String, CaseIterable, Sendable, Equatable, Codable {
    case vocals
    case drums
    case bass
    case other

    /// The on-disk file name for this voice in the stem cache (`vocals.caf`, …).
    public var fileName: String { "\(rawValue).caf" }

    /// The fixed index of this voice in `StemKind.allCases` order (§35.1).
    /// This is the compact payload the `RTCommand` stem tags carry (the raw
    /// value is a String, which has no place on the render ring) and the index
    /// into the deck's per-voice gain/mute/solo state (§12.2).
    public var index: Int {
        switch self {
        case .vocals: return 0
        case .drums: return 1
        case .bass: return 2
        case .other: return 3
        }
    }

    /// The voice at a fixed index; out-of-range indices clamp to `.other` so a
    /// malformed command payload degrades instead of crashing the render
    /// thread (§46.2).
    public init(index: Int) {
        switch index {
        case 0: self = .vocals
        case 1: self = .drums
        case 2: self = .bass
        default: self = .other
        }
    }
}

// MARK: - Audio shapes

/// A stereo Float32 pair at a known sample rate — the unit the model runs on
/// and the shape of every full-length voice the separator produces (§36.2).
/// Both channels have equal length; mono sources are duplicated into L/R.
public struct StemChunk: Sendable, Equatable {
    public let sampleRate: Double
    public let left: [Float]
    public let right: [Float]

    public init(sampleRate: Double, left: [Float], right: [Float]) {
        precondition(left.count == right.count, "stereo channels must have equal length")
        self.sampleRate = sampleRate
        self.left = left
        self.right = right
    }

    public var frameCount: Int { left.count }
}

/// The four voices produced for one track (or one chunk) by a stem model.
/// A single container serves both the per-chunk model output and the
/// full-length reconstruction, so the separator and cache share one shape.
public struct StemSeparation: Sendable, Equatable {
    public let sampleRate: Double
    public let vocals: StemChunk
    public let drums: StemChunk
    public let bass: StemChunk
    public let other: StemChunk

    public init(sampleRate: Double, vocals: StemChunk, drums: StemChunk,
                bass: StemChunk, other: StemChunk) {
        self.sampleRate = sampleRate
        self.vocals = vocals
        self.drums = drums
        self.bass = bass
        self.other = other
    }

    public func voice(_ kind: StemKind) -> StemChunk {
        switch kind {
        case .vocals: return vocals
        case .drums: return drums
        case .bass: return bass
        case .other: return other
        }
    }

    /// The four voices keyed by kind, in `StemKind.allCases` order.
    public var all: [(kind: StemKind, audio: StemChunk)] {
        StemKind.allCases.map { ($0, voice($0)) }
    }
}

// MARK: - The model seam

/// Errors the separator/model can surface. Absence is **not** an error —
/// a missing model yields `nil` from `separate` (FR-SEM-6); these are real
/// failures (ADR-10: fail loud, never a plausible-but-wrong result).
public enum StemModelError: Error, LocalizedError, Equatable {
    /// The converted model file exists but the prediction call has not been
    /// wired yet — the user-owned conversion step (plan decision 1, App. D).
    case conversionPending(String)
    case modelLoadFailed(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .conversionPending(let note):
            return "The stem model is present but not yet wired: \(note)"
        case .modelLoadFailed(let detail):
            return "Could not load the stem model: \(detail)"
        case .inferenceFailed(let detail):
            return "Stem separation failed: \(detail)"
        }
    }
}

/// The seam between `StemSeparator` and the Demucs model (plan decision 1).
/// Everything above this protocol — chunking, overlap-add, caching, the
/// service, the UI — is identical for both conformances. Absence is a value:
/// a missing model means "no separation", and the deck plays the full mix
/// (FR-ENG-3's fallback, §36.5) — never an error and never a lie.
public protocol StemModelProviding: Sendable {
    /// The model version stamp that drives stem-cache invalidation (§36.4 —
    /// a model upgrade invalidates the cache, like `analysis_version`).
    var version: Int { get }
    /// The rate and segment the model was trained at (S4). The separator
    /// resamples the track to this rate **once**, chunks at this length, and
    /// resamples the voices back — an off-by-a-few-hundred-samples drift here
    /// shifts every stem against the full mix by milliseconds, which sounds
    /// like "the stems are a bit weird" rather than failing.
    var nativeSampleRate: Double { get }
    var segmentFrames: Int { get }
    /// Whether the model is currently available (FR-SEM-6 absence).
    func isAvailable() async -> Bool
    /// Runs one fixed-length stereo chunk through the model, producing the four
    /// voices at the same length. Returns nil when the model is absent.
    func separate(chunk: StemChunk) async throws -> StemSeparation?
}

public extension StemModelProviding {
    /// Working-rate default (S4): a model that runs at the separator's own
    /// 48 kHz rate and 2¹⁷-frame chunk needs no resampling, so the default
    /// implementations let every existing fake compile untouched.
    var nativeSampleRate: Double { StemChunking.workingSampleRate }
    var segmentFrames: Int { StemChunking.chunkFrames }
}

/// Loads the converted `DemucsStems.mlpackage` from an ODR-provided URL
/// (plan decision 1, §36.2): the model is never in the binary, and every
/// separation is "not available" until a real file exists at the tag's URL.
/// The actual prediction call is the user-owned post-M5 step — until the
/// `.mlpackage` is registered and wired, a present file is an *explicit*
/// `conversionPending` state, never a silent passthrough (ADR-10).
public actor DemucsStemModel: StemModelProviding {
    public nonisolated let version: Int
    private let resource: ModelResourceService
    private let fileName: String

    public init(resource: ModelResourceService,
                version: Int = AnalysisVersions.stems,
                fileName: String = "DemucsStems.mlpackage") {
        self.resource = resource
        self.version = version
        self.fileName = fileName
    }

    public func isAvailable() async -> Bool {
        guard let url = await resourceURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func separate(chunk: StemChunk) async throws -> StemSeparation? {
        guard await isAvailable() else { return nil }
        // The real prediction is wired with the model conversion (plan decision 1,
        // Appendix D). Until then a present-but-unwired model is an explicit
        // state — the separator never fabricates voices (§46.2, ADR-10).
        throw StemModelError.conversionPending(
            "DemucsStems.mlpackage prediction is the owner's post-M5 step")
    }

    private func resourceURL() async -> URL? {
        await resource.url(for: .stems)
    }
}
