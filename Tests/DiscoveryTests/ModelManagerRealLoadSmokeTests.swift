#if !os(watchOS) && canImport(CoreML)
import ParsoAudioNeural
import Foundation
import Testing

@testable import TonearmDiscovery

/// C04 / C08 Apple-host real-resource smoke test (IMPLEMENT_CLAP_PLAN.md §8:
/// "Run real-resource loading smoke tests on the Apple build host").
///
/// Gated: when the converted `CLAPAudioEncoder` package and the bundled mel
/// filterbank are not present under `Resources/` on this host (a clean
/// checkout that has not run `make models`), the test is skipped rather than
/// failed. When they ARE present, it loads the real Core ML weights through
/// `ModelManager` + `CoreMLSemanticModel` and asserts a real embedding in the
/// current persisted embedding space — not the deterministic fake.
@Suite struct ModelManagerRealLoadSmokeTests {
    /// `.../parso-tonearm` — this file lives at `Tests/DiscoveryTests/`.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func realResources() -> ModelManager.Resources {
        ModelResourceLocator(searchDirectories: [
            repoRoot.appendingPathComponent("Resources/Models", isDirectory: true),
            repoRoot.appendingPathComponent("Resources/CLAP", isDirectory: true),
        ]).resolve()
    }

    @Test func testResolverFindsRealResourcesOrSkips() throws {
        let resources = realResources()
        if !(resources.audioEncoderURL != nil && resources.melFilterBankURL != nil) {
            try Test.cancel("converted CLAP audio package / mel filterbank not on this host — run `make models`")
        }
        #expect(
            FileManager.default.fileExists(atPath: resources.audioEncoderURL!.path))
        #expect(
            FileManager.default.fileExists(atPath: resources.melFilterBankURL!.path))
    }

    // MARK: - Text encoder (session 10)

    @Test func testResolverFindsRealTextResourcesOrSkips() throws {
        let r = realResources()
        if !(r.textEncoderURL != nil && r.tokenizerVocabURL != nil && r.tokenizerMergesURL != nil) {
            try Test.cancel("converted CLAP text package / tokenizer sidecars not on this host — run `make models`")
        }
        #expect(FileManager.default.fileExists(atPath: r.textEncoderURL!.path))
        #expect(FileManager.default.fileExists(atPath: r.tokenizerVocabURL!.path))
        #expect(FileManager.default.fileExists(atPath: r.tokenizerMergesURL!.path))
    }

    /// Loads the REAL converted `CLAPTextEncoder` weights + RoBERTa tokenizer
    /// through `ModelManager.textEncoder` and asserts a real 128-d, finite,
    /// non-zero-norm text embedding — not the deterministic fake. This is the
    /// text-side parallel of `testLoadsRealEncoderAndProducesExpectedShapeEmbedding`.
    @Test func testLoadsRealTextEncoderAndProducesEmbeddingInCurrentSpace() async throws {
        let r = realResources()
        if !(r.textEncoderURL != nil && r.tokenizerVocabURL != nil && r.tokenizerMergesURL != nil) {
            try Test.cancel("converted CLAP text package / tokenizer sidecars not on this host — run `make models`")
        }

        // `ModelManager` now compiles a raw `.mlpackage` itself (`CompiledModelCache`) — on a real
        // device the ODR asset pack never contains a build-compiled `.mlmodelc` (it is a plain
        // Xcode "folder" resource; see that type's doc), so this passes the resolved package
        // straight through, exactly as production does, rather than pre-compiling by hand.
        let resolved = ModelManager.Resources(
            audioEncoderURL: nil, melFilterBankURL: nil,
            textEncoderURL: r.textEncoderURL,
            tokenizerVocabURL: r.tokenizerVocabURL, tokenizerMergesURL: r.tokenizerMergesURL)

        // `.background` → `.cpuOnly`: real weights, real tokenizer, real
        // forward pass, but skips the multi-minute one-time ANE specialization
        // of the RoBERTa graph that `.all` (foreground) triggers — keeps this
        // gated smoke test runnable in a normal `make test-local`.
        let manager = ModelManager(resourceProvider: { resolved })
        let encoder = try await manager.textEncoder(context: .background)
        #expect(encoder.spec.dimensions == EmbeddingSpace.current.dimensions)
        #expect(encoder.spec.textMaxLength == 77)

        let a = try await encoder.embedText("gentle acoustic guitar")
        #expect(a.count == EmbeddingSpace.current.dimensions,
                       "real CLAP text embedding must match the persisted embedding space")
        #expect(a.allSatisfy { $0.isFinite }, "embedding must be finite")
        let norm = sqrt(a.reduce(0) { $0 + Double($1) * Double($1) })
        #expect(norm > 0.01, "embedding must have non-zero norm")

        // Distinct phrases produce distinct vectors (the encoder is doing real
        // work, not returning a constant).
        let b = try await encoder.embedText("aggressive thrash metal")
        let cos = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        #expect(cos < 0.999, "different prompts must not collapse to the same vector")
    }

    @Test func testLoadsRealEncoderAndProducesExpectedShapeEmbedding() async throws {
        let resources = realResources()
        if !(resources.audioEncoderURL != nil && resources.melFilterBankURL != nil) {
            try Test.cancel("converted CLAP audio package / mel filterbank not on this host — run `make models`")
        }

        // `ModelManager` now compiles a raw `.mlpackage` itself (`CompiledModelCache`) — pass the
        // resolved package straight through, exactly as production does.
        let resolved = ModelManager.Resources(
            audioEncoderURL: resources.audioEncoderURL, melFilterBankURL: resources.melFilterBankURL)

        let manager = ModelManager(resourceProvider: { resolved })
        let encoder = try await manager.audioEncoder(context: .foreground)
        let spec = encoder.spec

        #expect(spec.dimensions == 512)
        #expect(spec.sampleRate == 48_000)

        // A valid-shape log-mel clip (values themselves are arbitrary; a
        // constant floor is fine for a shape/finiteness smoke check).
        let logMel = [Float](repeating: -6.0, count: spec.frames * spec.melBins)
        let embedding = try await encoder.embedAudio(logMel: logMel)

        #expect(embedding.count == 512, "real CLAP audio embedding must be 512-dim")
        #expect(embedding.allSatisfy { $0.isFinite }, "embedding must be finite")
        let norm = sqrt(embedding.reduce(0) { $0 + Double($1) * Double($1) })
        #expect(norm > 0, "embedding must have non-zero norm")
    }
}
#endif
