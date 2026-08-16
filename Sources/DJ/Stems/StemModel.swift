import CoreML
import Accelerate
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

/// Loads the converted `DemucsStems.mlpackage` from an ODR-provided URL and
/// runs one chunk through it (plan decision 1, §36.2): the model is never in
/// the binary, and every separation is "not available" until a real file
/// exists at the tag's URL. The model is loaded **once** and held — a
/// per-chunk load is the classic performance bug and dominates the runtime.
///
/// The Core ML package takes `(mag, audio)` and returns `(spec, waveform)`
/// (S1): the STFT/ISTFT live in Swift (`DemucsSpectrogram`). This wrapper owns
/// forward → prediction → per-source inverse → the waveform sum → the source
/// order mapping.
public actor DemucsStemModel: StemModelProviding {
    public nonisolated let version: Int
    public nonisolated let nativeSampleRate: Double = DemucsSpectrogram.sampleRate
    public nonisolated let segmentFrames: Int = DemucsSpectrogram.segmentFrames
    private let resource: ModelResourceService
    private let fileName: String
    /// The loaded model, held for the actor's lifetime. Loaded lazily on the
    /// first present chunk so an absent model costs nothing.
    private var engine: CoreMLModelBox?

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

    /// The model's source axis order — `['drums', 'bass', 'other', 'vocals']`,
    /// **not** `StemKind.allCases` order (`vocals, drums, bass, other`).
    /// Mapping the S axis straight across silently swaps every stem — the
    /// vocal fader would mute the drums. This table is the one place the
    /// mapping lives, and `DemucsStemModelTests` locks it by name.
    public static let sourceOrder: [StemKind] = [.drums, .bass, .other, .vocals]

    public func separate(chunk: StemChunk) async throws -> StemSeparation? {
        guard await isAvailable() else { return nil }
        guard chunk.frameCount == segmentFrames else {
            throw StemModelError.inferenceFailed(
                "chunk is \(chunk.frameCount) frames, the model expects \(segmentFrames)")
        }
        let engine = try await loadedModel()
        let (spec, waveform) = try await Self.predict(chunk: chunk, engine: engine)
        return try handleOutput(spec: spec, waveform: waveform, chunk: chunk)
    }

    /// The prediction path, isolated off the actor: `MLModel` and `MLMultiArray`
    /// are not `Sendable`, so the whole forward → prediction → flatten happens
    /// here, receiving only `Sendable` values and returning only `[Float]`.
    private nonisolated static func predict(chunk: StemChunk,
                                            engine: CoreMLModelBox) async throws -> (spec: [Float], waveform: [Float]) {
        let frames = DemucsSpectrogram.frames
        let segmentFrames = DemucsSpectrogram.segmentFrames
        let bins = DemucsSpectrogram.bins
        guard let mag = try? MLMultiArray(shape: [1, 4, bins, frames] as [NSNumber],
                                          dataType: .float32),
              let audio = try? MLMultiArray(shape: [1, 2, segmentFrames] as [NSNumber],
                                            dataType: .float32) else {
            throw StemModelError.inferenceFailed("could not allocate the model inputs")
        }
        // Forward: the chunk's PCM → the real spectrogram `mag`.
        let magValues = DemucsSpectrogram.forward(left: chunk.left, right: chunk.right)
        magValues.withUnsafeBufferPointer { src in
            mag.dataPointer.assumingMemoryBound(to: Float.self)
                .update(from: src.baseAddress!, count: magValues.count)
        }
        let audioPtr = audio.dataPointer.assumingMemoryBound(to: Float.self)
        chunk.left.withUnsafeBufferPointer { src in
            audioPtr.update(from: src.baseAddress!, count: chunk.left.count)
        }
        chunk.right.withUnsafeBufferPointer { src in
            audioPtr.advanced(by: segmentFrames).update(from: src.baseAddress!, count: chunk.right.count)
        }

        let features = try MLDictionaryFeatureProvider(dictionary: [
            featureName: MLFeatureValue(multiArray: mag),
            audioName: MLFeatureValue(multiArray: audio),
        ])
        let output: MLFeatureProvider
        do {
            output = try await engine.model.prediction(from: features)
        } catch {
            throw StemModelError.inferenceFailed("the Core ML prediction failed: \(error)")
        }
        guard let specValue = output.featureValue(for: specName)?.multiArrayValue,
              let waveformValue = output.featureValue(for: waveformName)?.multiArrayValue else {
            throw StemModelError.inferenceFailed(
                "the model output was missing `\(specName)` or `\(waveformName)`")
        }
        return (flatten(specValue), flatten(waveformValue))
    }

    /// The inverse + waveform-sum + source-order half of `separate`.
    private func handleOutput(spec: [Float], waveform: [Float],
                              chunk: StemChunk) throws -> StemSeparation {
        let specPlane = 4 * bins * frames
        let wavePlane = 2 * segmentFrames
        guard spec.count == 4 * specPlane,
              waveform.count == 4 * wavePlane else {
            throw StemModelError.inferenceFailed("unexpected model output shapes")
        }

        // Per source: inverse the masked spectrogram, add the waveform branch,
        // and map through the source order (S1 §5.4).
        var voices: [StemKind: StemChunk] = [:]
        for s in 0..<4 {
            let inv = spec.withUnsafeBufferPointer { buf in
                DemucsSpectrogram.inverse(
                    spec: UnsafeBufferPointer(start: buf.baseAddress!.advanced(by: s * specPlane),
                                              count: specPlane))
            }
            let waveBase = s * wavePlane
            let left = addVoice(inv.left,
                                wave: Array(waveform[waveBase ..< waveBase + segmentFrames]))
            let right = addVoice(inv.right,
                                 wave: Array(waveform[waveBase + segmentFrames ..< waveBase + wavePlane]))
            voices[Self.sourceOrder[s]] = StemChunk(sampleRate: chunk.sampleRate,
                                                    left: left, right: right)
        }
        return StemSeparation(sampleRate: chunk.sampleRate,
                              vocals: voices[.vocals]!,
                              drums: voices[.drums]!,
                              bass: voices[.bass]!,
                              other: voices[.other]!)
    }

    // MARK: - Internals

    private func loadedModel() async throws -> CoreMLModelBox {
        if let engine { return engine }
        guard let url = await resourceURL() else {
            // Present-per-ODR but no file resolved — honest absence, never an
            // error (FR-SEM-6).
            throw StemModelError.conversionPending("the ODR tag did not resolve a file")
        }
        let configuration = MLModelConfiguration()
        // The ANE path is the one that matters for a 42M-parameter transformer;
        // measure on-device (S7) before choosing anything narrower.
        configuration.computeUnits = .all
        do {
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let engine = CoreMLModelBox(model)
            self.engine = engine
            return engine
        } catch {
            throw StemModelError.modelLoadFailed("\(error)")
        }
    }

    private func resourceURL() async -> URL? {
        await resource.url(for: .stems)
    }

    /// `voice[s] = ispec[s] + waveform[s]` (plan §5.4).
    private func addVoice(_ ispec: [Float], wave: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: ispec.count)
        vDSP_vadd(ispec, 1, wave, 1, &out, 1, vDSP_Length(ispec.count))
        return out
    }

    // MARK: - Feature names (match the conversion, tools/demucs-coreml)

    private static let featureName = "mag"
    private static let audioName = "audio"
    private static let specName = "spec"
    private static let waveformName = "waveform"

    private var bins: Int { DemucsSpectrogram.bins }
    private var frames: Int { DemucsSpectrogram.frames }

    private static func flatten(_ array: MLMultiArray) -> [Float] {
        let count = array.count
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            let src = array.dataPointer.assumingMemoryBound(to: Float.self)
            buffer.baseAddress!.update(from: src, count: count)
            initialized = count
        }
    }
}

/// Core ML's `MLModel` is documented thread-safe for prediction, so this box
/// is a justified `@unchecked Sendable` — the same pattern as `AudioGraph`
/// wrapping `AVAudioEngine` (both are CoreMedia/CoreML objects that guarantee
/// thread-safe use). Without it the async `prediction(from:options:)` API,
/// which requires sending the model across, would be unusable from an actor.
private final class CoreMLModelBox: @unchecked Sendable {
    let model: MLModel
    init(_ model: MLModel) { self.model = model }
}
