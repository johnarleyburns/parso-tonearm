#if !os(watchOS)
import CoreML
import Foundation
import ParsoAudioNeural

/// Owns the shared CLAP audio encoder resource lease and lazy load (plan
/// §8): resolve actual resource URLs, then initialize an encoder — never
/// substitute a fake embedding when the real resource is missing (plan §8:
/// "Do not substitute fake embeddings when resources are missing").
///
/// The one sanctioned exception is deterministic test automation (plan C04:
/// "Use synthetic test encoders for deterministic automation") —
/// `injectModelForTesting` bypasses resource resolution entirely so tests
/// can drive the real `BoundedIndexWorker` end to end against
/// `DeterministicFakeSemanticModel` without real CLAP weights on the test
/// host.
public actor ModelManager {
    /// Foreground may use the known-working CPU/GPU configuration;
    /// background is always CPU-only (plan §7: "Configure background CLAP
    /// execution for `.cpuOnly`; foreground may use the known working
    /// CPU/GPU configuration... never reuse a GPU-configured instance for
    /// background work").
    public enum ExecutionContext: Equatable, Sendable {
        case foreground
        case background
    }

    /// Where the converted model package and its mel filterbank sidecar
    /// live, resolved by the caller (ODR/App Support/bundle path — plan §8:
    /// "Resolve actual resource URLs AFTER successful acquisition"). `nil`
    /// fields mean "not currently available", not an error.
    public struct Resources: Sendable {
        public var audioEncoderURL: URL?
        public var melFilterBankURL: URL?
        /// Converted CLAP TEXT encoder (`.mlmodelc` compiled by the build, or
        /// `.mlpackage` for a bare checkout) — ODR tag `clap-text`.
        public var textEncoderURL: URL?
        /// RoBERTa byte-level-BPE tokenizer sidecars (`vocab.json` /
        /// `merges.txt`), bundled in `Resources/CLAP/`. Both required for text.
        public var tokenizerVocabURL: URL?
        public var tokenizerMergesURL: URL?

        public init(
            audioEncoderURL: URL?,
            melFilterBankURL: URL?,
            textEncoderURL: URL? = nil,
            tokenizerVocabURL: URL? = nil,
            tokenizerMergesURL: URL? = nil
        ) {
            self.audioEncoderURL = audioEncoderURL
            self.melFilterBankURL = melFilterBankURL
            self.textEncoderURL = textEncoderURL
            self.tokenizerVocabURL = tokenizerVocabURL
            self.tokenizerMergesURL = tokenizerMergesURL
        }

        public static let unavailable = Resources(audioEncoderURL: nil, melFilterBankURL: nil)
    }

    public enum ModelManagerError: Error, LocalizedError, Equatable {
        /// The model file / tokenizer sidecars are not on disk yet — the
        /// distinct retryable "missing model" state (plan §8: "missing model,
        /// failed download and failed inference are distinct states").
        case resourcesUnavailable
        case melFilterBankLoadFailed(String)
        /// The tokenizer sidecars are present but could not be parsed — a
        /// distinct retryable "download/load failed" state, not "missing".
        case tokenizerLoadFailed(String)
        /// The resolved `.mlpackage` exists but `CompiledModelCache` could not
        /// compile it into a form `MLModel(contentsOf:)` will load — a
        /// distinct retryable "download/load failed" state, not "missing"
        /// (the file is there; it just isn't a usable model yet).
        case modelCompileFailed(String)

        public var errorDescription: String? {
            switch self {
            case .resourcesUnavailable:
                return String(localized: "The sound-search model has not been downloaded yet.", bundle: .module)
            case .melFilterBankLoadFailed(let detail):
                return String(localized: "Could not load the model's mel filterbank: \(detail)", bundle: .module)
            case .tokenizerLoadFailed(let detail):
                return String(localized: "Could not load the text model's tokenizer: \(detail)", bundle: .module)
            case .modelCompileFailed(let detail):
                return String(localized: "Could not prepare the sound-search model: \(detail)", bundle: .module)
            }
        }
    }

    private let resourceProvider: @Sendable () -> Resources
    private var cachedModel: (any SemanticModel)?
    private var cachedContext: ExecutionContext?
    private var cachedTextModel: (any SemanticModel)?
    private var cachedTextContext: ExecutionContext?
    private var testInjected = false

    public init(resourceProvider: @escaping @Sendable () -> Resources) {
        self.resourceProvider = resourceProvider
    }

    /// Resolve (or reuse) the shared audio encoder for `context`. A context
    /// change invalidates any cached instance rather than reusing a
    /// GPU-configured one for background work (plan §7). Throws
    /// `.resourcesUnavailable` rather than fabricating an embedding when the
    /// converted package/mel filterbank are not present on disk (plan §8).
    public func audioEncoder(context: ExecutionContext) throws -> any SemanticModel {
        if testInjected, let cachedModel { return cachedModel }
        if let cachedModel, cachedContext == context { return cachedModel }

        let resources = resourceProvider()
        guard let encoderURL = resources.audioEncoderURL, let melURL = resources.melFilterBankURL,
            FileManager.default.fileExists(atPath: melURL.path)
        else {
            throw ModelManagerError.resourcesUnavailable
        }

        let melFilterBank: [Float]
        do {
            melFilterBank = try EmbeddingModelSpec.loadMelFilterBank(from: melURL)
        } catch {
            throw ModelManagerError.melFilterBankLoadFailed(error.localizedDescription)
        }
        let spec = EmbeddingModelSpec.musicCLAP(melFilterBank: melFilterBank)
        // The shipped int4 checkpoints expose the frozen 512 -> 128 projection, exactly like the
        // persisted vector index and the text encoder. `musicCLAPMetadata` describes the upstream
        // 512-D checkpoint, so override its width before Core ML output extraction.
        var outputSpec = spec
        outputSpec.dimensions = EmbeddingSpace.current.dimensions
        // A resolved `.mlpackage` is a raw, uncompiled package on a real device (see
        // `CompiledModelCache`'s doc) — `MLModel(contentsOf:)` cannot load it directly. A resolved
        // `.mlmodelc` (a bare SwiftPM/dev checkout) passes through unchanged.
        let loadableURL: URL
        do {
            loadableURL = try CompiledModelCache.loadableURL(for: encoderURL)
        } catch {
            throw ModelManagerError.modelCompileFailed(error.localizedDescription)
        }
        let computeUnits: MLComputeUnits = context == .background ? .cpuOnly : .cpuAndGPU
        let model = SynchronousCoreMLSemanticModel(
            kind: .audio, url: loadableURL, spec: outputSpec, computeUnits: computeUnits,
            reload: { try CompiledModelCache.loadableURL(for: encoderURL, forceRecompile: true) })
        cachedModel = model
        cachedContext = context
        return model
    }

    /// Resolve (or reuse) the shared CLAP TEXT encoder for a text/semantic
    /// search (plan §9's text mode). Filter-only and similar-track search do
    /// NOT call this (plan §9: "Filter-only: apply scope/BPM/key directly in
    /// SQL, WITHOUT requiring CLAP models"; "Similar: ... no text model
    /// required").
    ///
    /// Production text-encoder resolution (session 10): the converted
    /// `CLAPTextEncoder` package (ODR tag `clap-text`, `.mlmodelc` preferred /
    /// `.mlpackage` fallback) plus the bundled RoBERTa `vocab.json` /
    /// `merges.txt` sidecars, resolved by `ModelResourceLocator` exactly the
    /// way `audioEncoder` resolves its package + mel filterbank. Throws a
    /// distinct retryable error rather than fabricating an embedding when the
    /// resources are missing (`.resourcesUnavailable` → `modelMissing`) or the
    /// tokenizer is present but unparseable (`.tokenizerLoadFailed` →
    /// `modelDownloadFailed`). A context change invalidates any cached
    /// instance (never reuse a GPU-configured encoder for background work —
    /// plan §7).
    public func textEncoder(context: ExecutionContext) throws -> any SemanticModel {
        if testInjected, let cachedModel { return cachedModel }
        if let cachedTextModel, cachedTextContext == context { return cachedTextModel }

        let resources = resourceProvider()
        guard let encoderURL = resources.textEncoderURL,
            let vocabURL = resources.tokenizerVocabURL,
            let mergesURL = resources.tokenizerMergesURL,
            FileManager.default.fileExists(atPath: encoderURL.path),
            FileManager.default.fileExists(atPath: vocabURL.path),
            FileManager.default.fileExists(atPath: mergesURL.path)
        else {
            throw ModelManagerError.resourcesUnavailable
        }

        let tokenizer: RoBERTaTokenizer
        do {
            tokenizer = try RoBERTaTokenizer(vocabURL: vocabURL, mergesURL: mergesURL)
        } catch {
            throw ModelManagerError.tokenizerLoadFailed(error.localizedDescription)
        }

        // Text spec: shared embedding space (`EmbeddingSpace.current`), the model's real 77-token limit
        // (`EmbeddingModelSpec.musicCLAPMetadata.textMaxLength`) — the
        // tokenizer enforces it, keeping `<s>` and re-appending `</s>` on
        // truncation (`RoBERTaTokenizer.encode`). No mel filterbank is needed
        // for the text path.
        var spec = EmbeddingModelSpec.musicCLAPMetadata
        // The bundled int4 text encoder includes the same frozen 512 -> 128
        // projection as the audio encoder and the persisted vector index.
        // `musicCLAPMetadata` describes the upstream 512-D checkpoint, so
        // override its legacy width before Core ML output extraction.
        spec.dimensions = EmbeddingSpace.current.dimensions
        let loadableURL: URL
        do {
            loadableURL = try CompiledModelCache.loadableURL(for: encoderURL)
        } catch {
            throw ModelManagerError.modelCompileFailed(error.localizedDescription)
        }
        let computeUnits: MLComputeUnits = context == .background ? .cpuOnly : .all
        let model = SynchronousCoreMLSemanticModel(
            kind: .text, url: loadableURL, spec: spec, tokenizer: tokenizer,
            computeUnits: computeUnits,
            reload: { try CompiledModelCache.loadableURL(for: encoderURL, forceRecompile: true) })
        cachedTextModel = model
        cachedTextContext = context
        return model
    }

    /// Whether the real AUDIO model resources currently resolve, without
    /// loading the (possibly large) model itself.
    public func isModelResourceAvailable() -> Bool {
        let resources = resourceProvider()
        guard let encoderURL = resources.audioEncoderURL, let melURL = resources.melFilterBankURL else {
            return false
        }
        return FileManager.default.fileExists(atPath: melURL.path)
            || FileManager.default.fileExists(atPath: encoderURL.path)
    }

    /// Whether the real TEXT model resources (encoder package + both tokenizer
    /// sidecars) currently resolve, without loading the model.
    public func isTextModelResourceAvailable() -> Bool {
        let resources = resourceProvider()
        guard let encoderURL = resources.textEncoderURL,
            let vocabURL = resources.tokenizerVocabURL,
            let mergesURL = resources.tokenizerMergesURL
        else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: encoderURL.path)
            && fm.fileExists(atPath: vocabURL.path)
            && fm.fileExists(atPath: mergesURL.path)
    }

    /// Test-only seam (plan C04's sanctioned synthetic encoder path): inject
    /// a ready-made `SemanticModel` (typically `DeterministicFakeSemanticModel`)
    /// directly, bypassing resource resolution.
    public func injectModelForTesting(_ model: any SemanticModel) {
        cachedModel = model
        cachedContext = nil
        testInjected = true
    }

    /// Release the cached encoder (plan §6/§7: release models/buffers on
    /// thermal serious/critical or memory warning when safe).
    public func releaseCachedModel() {
        guard !testInjected else { return }
        cachedModel = nil
        cachedContext = nil
        cachedTextModel = nil
        cachedTextContext = nil
    }
}

/// The app's Core ML semantic encoder.
///
/// This is deliberately a local wrapper instead of `ParsoAudioNeural.CoreMLSemanticModel`: that
/// type uses Core ML's `async` prediction overload, whose ML Program path fails on the OS 27
/// runtime with "Unable to compute the asynchronous prediction using ML Program…" even for a
/// static-shape, valid model. Calling the synchronous `MLModel.prediction(from:options:)` API from
/// this actor (never the SwiftUI main actor) keeps prediction off the main thread while using the
/// execution path that still works.
private actor SynchronousCoreMLSemanticModel: SemanticModel {
    enum Kind: Sendable { case audio, text }

    let spec: EmbeddingModelSpec
    private let kind: Kind
    private var url: URL
    private let tokenizer: RoBERTaTokenizer?
    private let computeUnits: MLComputeUnits
    private let reload: (@Sendable () throws -> URL)?
    private var box: ModelBox?
    /// A compiled program can be left behind by an older OS. Retry one reload/recompile per model
    /// instance before surfacing the prediction failure, not once per window.
    private var didRetryReload = false

    /// `MLModel` is not `Sendable`. The actor serializes every touch, so the unchecked box is safe.
    private final class ModelBox: @unchecked Sendable {
        let model: MLModel
        init(_ model: MLModel) { self.model = model }

        func predict(provider: MLDictionaryFeatureProvider, outputName: String,
                     count: Int) throws -> [Float] {
            let output = try model.prediction(from: provider, options: MLPredictionOptions())
            guard let value = output.featureValue(for: outputName)?.multiArrayValue else {
                throw SemanticModelError.inferenceFailed("missing \(outputName) output")
            }
            var result = [Float](repeating: 0, count: count)
            for i in 0..<count { result[i] = value[i].floatValue }
            return result
        }
    }

    init(kind: Kind, url: URL, spec: EmbeddingModelSpec, tokenizer: RoBERTaTokenizer? = nil,
         computeUnits: MLComputeUnits? = nil,
         reload: (@Sendable () throws -> URL)? = nil) {
        self.kind = kind
        self.url = url
        self.spec = spec
        self.tokenizer = tokenizer
        self.computeUnits = computeUnits ?? (kind == .audio ? .cpuAndGPU : .all)
        self.reload = reload
    }

    func embedText(_ text: String) async throws -> [Float] {
        guard kind == .text else {
            throw SemanticModelError.inferenceFailed("text input on an audio encoder")
        }
        guard let tokenizer else { throw SemanticModelError.tokenizerUnavailable }
        let encoded = try tokenizer.encode(text, maxLength: spec.textMaxLength)
        let ids = try MLMultiArray(shape: [1, NSNumber(value: spec.textMaxLength)], dataType: .int32)
        let mask = try MLMultiArray(shape: [1, NSNumber(value: spec.textMaxLength)], dataType: .int32)
        for i in 0..<encoded.ids.count {
            ids[i] = NSNumber(value: encoded.ids[i])
            mask[i] = NSNumber(value: encoded.mask[i])
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: ids),
            "attention_mask": MLFeatureValue(multiArray: mask),
        ])
        return try predictWithRetry(provider: provider, outputName: "text_embedding",
                                    count: spec.dimensions)
    }

    func embedAudio(logMel: [Float]) async throws -> [Float] {
        guard kind == .audio else {
            throw SemanticModelError.inferenceFailed("audio input on a text encoder")
        }
        let total = spec.frames * spec.melBins
        guard logMel.count == total else {
            throw SemanticModelError.inferenceFailed(
                "log-mel has \(logMel.count) samples, expected \(total)")
        }
        let input = try MLMultiArray(
            shape: [1, 1, NSNumber(value: spec.frames), NSNumber(value: spec.melBins)],
            dataType: .float32)
        for i in 0..<total { input[i] = NSNumber(value: logMel[i]) }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "log_mel": MLFeatureValue(multiArray: input),
        ])
        return try predictWithRetry(provider: provider, outputName: "audio_embedding",
                                    count: spec.dimensions)
    }

    /// Run the encoder, and once per model instance retry after dropping a compiled program that
    /// may predate the current OS. An OS update can leave a cached `.mlmodelc` that compiles but
    /// fails at execution; recompiling under the current runtime is the only recovery available
    /// without shipping a new model.
    private func predictWithRetry(provider: MLDictionaryFeatureProvider, outputName: String,
                                  count: Int) throws -> [Float] {
        do {
            return try load().predict(provider: provider, outputName: outputName, count: count)
        } catch {
            guard !didRetryReload, let reload else { throw error }
            didRetryReload = true
            box = nil
            do {
                url = try reload()
                return try load().predict(provider: provider, outputName: outputName, count: count)
            } catch {
                throw error
            }
        }
    }

    private func load() throws -> ModelBox {
        if let box { return box }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SemanticModelError.modelUnavailable(url.lastPathComponent)
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            let loaded = try MLModel(contentsOf: url, configuration: configuration)
            let box = ModelBox(loaded)
            self.box = box
            return box
        } catch {
            throw SemanticModelError.modelLoadFailed(error.localizedDescription)
        }
    }
}
#endif
