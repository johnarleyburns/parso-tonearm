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

        public var errorDescription: String? {
            switch self {
            case .resourcesUnavailable:
                return "The sound-search model has not been downloaded yet."
            case .melFilterBankLoadFailed(let detail):
                return "Could not load the model's mel filterbank: \(detail)"
            case .tokenizerLoadFailed(let detail):
                return "Could not load the text model's tokenizer: \(detail)"
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
        // `.mlmodelc` (build-compiled) and `.mlpackage` (runtime-compiled)
        // are both just a URL to `MLModel(contentsOf:)` — no distinct
        // handling needed here (plan §8: "Recognize compiled `.mlmodelc`
        // when supplied by the build as well as `.mlpackage`").
        let computeUnits: MLComputeUnits = context == .background ? .cpuOnly : .cpuAndGPU
        let model = CoreMLSemanticModel(
            kind: .audio, url: encoderURL, spec: spec, computeUnits: computeUnits)
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

        // Text spec: 512-d shared space, the model's real 77-token limit
        // (`EmbeddingModelSpec.musicCLAPMetadata.textMaxLength`) — the
        // tokenizer enforces it, keeping `<s>` and re-appending `</s>` on
        // truncation (`RoBERTaTokenizer.encode`). No mel filterbank is needed
        // for the text path.
        let spec = EmbeddingModelSpec.musicCLAPMetadata
        let computeUnits: MLComputeUnits = context == .background ? .cpuOnly : .all
        let model = CoreMLSemanticModel(
            kind: .text, url: encoderURL, spec: spec, tokenizer: tokenizer,
            computeUnits: computeUnits)
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
#endif
