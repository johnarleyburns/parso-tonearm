#if !os(watchOS)
import XCTest
@testable import TonearmCore

final class BlendEdgePlanModelTests: XCTestCase {
    func testPersistedEdgePlanRoundTripsWithoutSourceSpecificType() throws {
        let plan = BlendEdgePlan(
            blendID: "saved.example", edge: 1, outgoingTrackID: "catalog-a", incomingTrackID: "catalog-b",
            style: .bassSwap, tempo: 1, overlapBeats: 32, incomingGain: 1,
            outgoingSwapBeat: 32, incomingSwapBeat: 16,
            blendStartSeconds: 90, swapSeconds: 105, blendEndSeconds: 120, incomingOffsetSeconds: 90)
        let decoded = try JSONDecoder().decode(BlendEdgePlan.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)
        XCTAssertNotNil(decoded.schedule())
    }

    func testProductionSourcesDoNotSpellTheOldPlanType() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for line in text.split(separator: "\n", omittingEmptySubsequences: false)
            where line.contains("StarterEdgePlan")
                && line.trimmingCharacters(in: .whitespaces) != "public typealias StarterEdgePlan = BlendEdgePlan" {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
#endif
