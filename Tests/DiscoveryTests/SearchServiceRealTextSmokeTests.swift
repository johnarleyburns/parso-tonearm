#if !os(watchOS) && canImport(CoreML)
import CoreML
import Foundation
import GRDB
import ParsoAudioNeural
import XCTest

@testable import TonearmCore
@testable import TonearmDiscovery

/// Session 10 real-weights end-to-end smoke (IMPLEMENT_CLAP_PLAN.md §8/§9):
/// the PRODUCTION `ModelManager.textEncoder` path (no injected fake) encodes a
/// real text prompt with the converted `CLAPTextEncoder` weights + RoBERTa
/// tokenizer, and `SearchService` ranks real pipeline-quantized audio
/// embeddings against it — a finite 512-d query vector and a stable ranking.
///
/// Gated: skipped when the converted text package / tokenizer sidecars are
/// not on this host (a clean checkout that has not run `make models`).
final class SearchServiceRealTextSmokeTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func realTextResources() async throws -> ModelManager.Resources {
        let r = ModelResourceLocator(searchDirectories: [
            repoRoot.appendingPathComponent("Resources/Models", isDirectory: true),
            repoRoot.appendingPathComponent("Resources/CLAP", isDirectory: true),
        ]).resolve()
        try XCTSkipUnless(
            r.textEncoderURL != nil && r.tokenizerVocabURL != nil && r.tokenizerMergesURL != nil,
            "converted CLAP text package / tokenizer sidecars not on this host — run `make models`")
        var encoderURL = r.textEncoderURL!
        if encoderURL.pathExtension == "mlpackage" {
            let compiled = try await MLModel.compileModel(at: encoderURL)
            addTeardownBlock { try? FileManager.default.removeItem(at: compiled) }
            encoderURL = compiled
        }
        return ModelManager.Resources(
            audioEncoderURL: nil, melFilterBankURL: nil, textEncoderURL: encoderURL,
            tokenizerVocabURL: r.tokenizerVocabURL, tokenizerMergesURL: r.tokenizerMergesURL)
    }

    func testRealTextEncoderRanksRealEmbeddings() async throws {
        let resources = try await realTextResources()
        let dims = 512

        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssrt-\(UUID().uuidString).bin")
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheURL) }

        let queue = try SearchFixture.makeQueue()
        try await queue.write { db in
            let s = try SearchFixture.seedSource(db)
            for i in 0..<6 {
                let t = try SearchFixture.seedTrack(db, sourceId: s, title: "t\(i)", sortKey: "t\(i)")
                let a = try SearchFixture.seedAsset(db, trackId: t)
                var v = [Float](repeating: 0, count: dims)
                for d in 0..<dims { v[d] = Float(((d &* 31) &+ i &* 7) % 17) - 8 }
                try SearchFixture.seedEmbedding(db, trackId: t, assetId: a, vector: v)
                try SearchFixture.seedJob(db, trackId: t, state: .complete, embedding: .complete)
            }
        }

        let models = ModelManager(resourceProvider: { resources })
        let index = VectorIndex(writer: queue, cacheURL: cacheURL)
        // `.background` → `.cpuOnly` on the text encoder: real weights + real
        // ranking without the multi-minute ANE specialization `.all` triggers.
        let service = SearchService(
            writer: queue, index: index, models: models, executionContext: { .background })

        let response = await service.search(
            DiscoverySearchQuery(text: "gentle acoustic guitar with soft vocals"))

        XCTAssertEqual(response.mode, .semantic)
        XCTAssertEqual(response.state, .ready, "real text encoder + real embeddings should rank")
        XCTAssertEqual(response.results.count, 6)
        for r in response.results {
            XCTAssertNotNil(r.similarity)
            XCTAssertTrue(r.similarity!.isFinite)
            XCTAssertGreaterThanOrEqual(r.similarity!, -1.0001)
            XCTAssertLessThanOrEqual(r.similarity!, 1.0001)
        }
        let scores = response.results.compactMap(\.finalScore)
        XCTAssertEqual(scores, scores.sorted(by: >), "results must be ranked by finalScore desc")

        let index2 = VectorIndex(writer: queue, cacheURL: cacheURL)
        let service2 = SearchService(writer: queue, index: index2, models: models)
        let again = await service2.search(
            DiscoverySearchQuery(text: "gentle acoustic guitar with soft vocals"))
        XCTAssertEqual(
            response.results.map(\.trackID), again.results.map(\.trackID),
            "ranking must be deterministic for the same prompt + embeddings")
    }
}
#endif
