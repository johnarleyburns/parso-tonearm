import XCTest
@testable import TonearmCore
@testable import TonearmDiscovery

final class TrackGridAnalyzerTests: XCTestCase {
    func testFixtureProducesGridAndPayloadRoundTrip() async throws {
        let caf = try await makeCAF()
        let result = try TrackGridAnalyzer.analyze(url: caf, codec: "caf")

        XCTAssertGreaterThan(result.payload.bpm, 0)
        XCTAssertGreaterThan(result.payload.beatPositions.count, 1)
        XCTAssertGreaterThan(result.payload.downbeatPositions.count, 0)
        XCTAssertFalse(result.payload.sections.isEmpty)

        let decoded = try DJTrackPrepPayload.decoded(result.payload.encoded())
        XCTAssertEqual(decoded, result.payload)
        XCTAssertGreaterThan(result.frameCount, 0)
        XCTAssertFalse(result.usedCached)
    }

    func testMatchingCacheSkipsReanalysis() async throws {
        let caf = try await makeCAF()
        let first = try TrackGridAnalyzer.analyze(url: caf, codec: "caf")
        let cached = try TrackGridAnalyzer.analyze(url: caf,
                                                   codec: "caf", cached: first.payload,
                                                   cachedFrameCount: first.frameCount)

        XCTAssertTrue(cached.usedCached)
        XCTAssertEqual(cached.payload, first.payload)
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/tone_mono.opus")
    }

    private func makeCAF() async throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("track-grid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let opus = root.appendingPathComponent("fixture.opus")
        try Data(contentsOf: fixtureURL).write(to: opus)
        return try await OpusRemuxer().remux(opusFileURL: opus, cacheKey: UUID().uuidString)
    }
}
