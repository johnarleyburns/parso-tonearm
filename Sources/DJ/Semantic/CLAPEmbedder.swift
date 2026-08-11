import Foundation

/// Serializes text/audio predictions through a `SemanticModel` (§27.1). The actor
/// gives the encoder concurrency-1 (the ANE serializes anyway); preprocessing can
/// still pipeline ahead of it because only `embed*` is actor-isolated.
public actor CLAPEmbedder {
    private let model: any SemanticModel

    /// The active model's spec — what `Preprocess`, the store and the registry
    /// must agree with.
    public nonisolated var spec: EmbeddingModelSpec { model.spec }

    public init(model: any SemanticModel) {
        self.model = model
    }

    /// Embed a text query → 512-D L2-normalized (idempotent: the models already
    /// normalize; the re-normalization guards the fake and any future non-L2 model).
    public func embedText(_ text: String) async throws -> [Float] {
        try DeterministicFakeSemanticModel.l2Normalized(await model.embedText(text))
    }

    /// Embed each window → one L2-normalized 512-D vector per window.
    public func embedWindows(_ windows: [Preprocess.MelWindow]) async throws -> [[Float]] {
        var out: [[Float]] = []
        out.reserveCapacity(windows.count)
        for window in windows {
            out.append(try DeterministicFakeSemanticModel.l2Normalized(
                await model.embedAudio(logMel: window.logMel)))
        }
        return out
    }
}
