#if !os(watchOS) && canImport(CoreML)
import CoreML
import ParsoAudioNeural
import XCTest

@testable import TonearmDiscovery

/// C04 / C08 Apple-host real-resource smoke test (IMPLEMENT_CLAP_PLAN.md §8:
/// "Run real-resource loading smoke tests on the Apple build host").
///
/// Gated: when the converted `CLAPAudioEncoder` package and the bundled mel
/// filterbank are not present under `Resources/` on this host (a clean
/// checkout that has not run `make models`), the test is skipped rather than
/// failed. When they ARE present, it loads the real Core ML weights through
/// `ModelManager` + `CoreMLSemanticModel` and asserts a real embedding of the
/// expected 512-dim shape — not the deterministic fake.
final class ModelManagerRealLoadSmokeTests: XCTestCase {
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

    func testResolverFindsRealResourcesOrSkips() throws {
        let resources = realResources()
        try XCTSkipUnless(
            resources.audioEncoderURL != nil && resources.melFilterBankURL != nil,
            "converted CLAP audio package / mel filterbank not on this host — run `make models`")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resources.audioEncoderURL!.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: resources.melFilterBankURL!.path))
    }

    // MARK: - Text encoder (session 10)

    func testResolverFindsRealTextResourcesOrSkips() throws {
        let r = realResources()
        try XCTSkipUnless(
            r.textEncoderURL != nil && r.tokenizerVocabURL != nil && r.tokenizerMergesURL != nil,
            "converted CLAP text package / tokenizer sidecars not on this host — run `make models`")
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.textEncoderURL!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.tokenizerVocabURL!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.tokenizerMergesURL!.path))
    }

    /// Loads the REAL converted `CLAPTextEncoder` weights + RoBERTa tokenizer
    /// through `ModelManager.textEncoder` and asserts a real 512-d, finite,
    /// non-zero-norm text embedding — not the deterministic fake. This is the
    /// text-side parallel of `testLoadsRealEncoderAndProducesExpectedShapeEmbedding`.
    func testLoadsRealTextEncoderAndProducesFinite512DEmbedding() async throws {
        let r = realResources()
        try XCTSkipUnless(
            r.textEncoderURL != nil && r.tokenizerVocabURL != nil && r.tokenizerMergesURL != nil,
            "converted CLAP text package / tokenizer sidecars not on this host — run `make models`")

        var encoderURL = r.textEncoderURL!
        if encoderURL.pathExtension == "mlpackage" {
            let compiled = try await MLModel.compileModel(at: encoderURL)
            addTeardownBlock { try? FileManager.default.removeItem(at: compiled) }
            encoderURL = compiled
        }
        let resolved = ModelManager.Resources(
            audioEncoderURL: nil, melFilterBankURL: nil,
            textEncoderURL: encoderURL,
            tokenizerVocabURL: r.tokenizerVocabURL, tokenizerMergesURL: r.tokenizerMergesURL)

        // `.background` → `.cpuOnly`: real weights, real tokenizer, real
        // forward pass, but skips the multi-minute one-time ANE specialization
        // of the RoBERTa graph that `.all` (foreground) triggers — keeps this
        // gated smoke test runnable in a normal `make test-local`.
        let manager = ModelManager(resourceProvider: { resolved })
        let encoder = try await manager.textEncoder(context: .background)
        XCTAssertEqual(encoder.spec.dimensions, 512)
        XCTAssertEqual(encoder.spec.textMaxLength, 77)

        let a = try await encoder.embedText("gentle acoustic guitar")
        XCTAssertEqual(a.count, 512, "real CLAP text embedding must be 512-dim")
        XCTAssertTrue(a.allSatisfy { $0.isFinite }, "embedding must be finite")
        let norm = sqrt(a.reduce(0) { $0 + Double($1) * Double($1) })
        XCTAssertGreaterThan(norm, 0.01, "embedding must have non-zero norm")

        // Distinct phrases produce distinct vectors (the encoder is doing real
        // work, not returning a constant).
        let b = try await encoder.embedText("aggressive thrash metal")
        let cos = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertLessThan(cos, 0.999, "different prompts must not collapse to the same vector")
    }

    func testLoadsRealEncoderAndProducesExpectedShapeEmbedding() async throws {
        let resources = realResources()
        try XCTSkipUnless(
            resources.audioEncoderURL != nil && resources.melFilterBankURL != nil,
            "converted CLAP audio package / mel filterbank not on this host — run `make models`")

        // On a bare SwiftPM host the ODR delivers `.mlpackage`; Xcode would
        // compile it to `.mlmodelc` in the app build. Do that compile step
        // here so the smoke test exercises the real weights end to end.
        var encoderURL = resources.audioEncoderURL!
        if encoderURL.pathExtension == "mlpackage" {
            let compiled = try await MLModel.compileModel(at: encoderURL)
            addTeardownBlock { try? FileManager.default.removeItem(at: compiled) }
            encoderURL = compiled
        }
        let resolved = ModelManager.Resources(
            audioEncoderURL: encoderURL, melFilterBankURL: resources.melFilterBankURL)

        let manager = ModelManager(resourceProvider: { resolved })
        let encoder = try await manager.audioEncoder(context: .foreground)
        let spec = encoder.spec

        XCTAssertEqual(spec.dimensions, 512)
        XCTAssertEqual(spec.sampleRate, 48_000)

        // A valid-shape log-mel clip (values themselves are arbitrary; a
        // constant floor is fine for a shape/finiteness smoke check).
        let logMel = [Float](repeating: -6.0, count: spec.frames * spec.melBins)
        let embedding = try await encoder.embedAudio(logMel: logMel)

        XCTAssertEqual(embedding.count, 512, "real CLAP audio embedding must be 512-dim")
        XCTAssertTrue(embedding.allSatisfy { $0.isFinite }, "embedding must be finite")
        let norm = sqrt(embedding.reduce(0) { $0 + Double($1) * Double($1) })
        XCTAssertGreaterThan(norm, 0, "embedding must have non-zero norm")
    }
}
#endif
