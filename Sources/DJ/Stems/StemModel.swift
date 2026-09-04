import CoreML
import Accelerate
import Foundation
import ParsoAudioNeural

// `SeparationVoice`, `StemChunk`, `StemSeparation`, `StemModelError`, and the
// `StemModelProviding` seam itself moved to `ParsoAudioNeural` in Phase 7c
// (audio-engine unification) — see that target's Separation.swift and
// current_status.md "Phase 7". This file now holds only the Demucs-specific
// conformance, which stays in this app rather than PAE because Demucs'
// pretrained weights are not established as commercially clean (see
// current_status.md "Phase 7", "The Demucs finding") — it is registered as
// a non-default backend in `StemSeparationBackends.makeRegistry`.

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
        // S7 honest ceiling: a device class that cannot hold the model's
        // working set inside its memory ceiling reports stems unavailable —
        // the already-tested honest-absence path (full mix, disabled faders),
        // never a model that gets shed mid-set.
        guard MemoryCeiling.stemsFitInCeiling(
            deviceClass: MemoryCeiling.deviceClass(
                totalRAMBytes: ProcessInfo.processInfo.physicalMemory)) else {
            return false
        }
        guard let url = await resourceURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// The model's source axis order — `['drums', 'bass', 'other', 'vocals']`,
    /// **not** `SeparationVoice.allCases` order (`vocals, drums, bass, other`).
    /// Mapping the S axis straight across silently swaps every stem — the
    /// vocal fader would mute the drums. This table is the one place the
    /// mapping lives, and `DemucsStemModelTests` locks it by name.
    public static let sourceOrder: [SeparationVoice] = [.drums, .bass, .other, .vocals]

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
        var voices: [SeparationVoice: StemChunk] = [:]
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
            // Present-per-ODR but no file resolved — honest absence, never
            // an error (FR-SEM-6).
            throw StemModelError.modelLoadFailed("the ODR tag did not resolve a file")
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
