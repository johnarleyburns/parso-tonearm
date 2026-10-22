#if !os(watchOS)
import XCTest
@testable import TonearmCore

final class CatalogEdgeRendererTests: XCTestCase {
    func testRecipeSchedulesOnlyItsPersistedEdgeCoordinates() {
        let recipe = CatalogEdgePlan(fromCatalogTrackID: "a", toCatalogTrackID: "b", analysisVersion: 1,
                                     style: "bass-swap", outgoingPhraseSeconds: 64, incomingPhraseSeconds: 0,
                                     overlapBeats: 64, blendStartSeconds: 100, swapSeconds: 112,
                                     blendEndSeconds: 124, incomingOffsetSeconds: 8, tempo: 1.02, incomingGain: 0.8)
        let plan = recipe.boundedOverlap(sampleRate: 44_100, outgoingZeroFrame: 1_024,
                                         incomingTotalFrames: 10_000_000, minimumBufferedFrames: 44_100)
        XCTAssertEqual(plan?.startClock, 4_411_024)
        XCTAssertEqual(plan?.incomingStartFrame, 352_800)
        XCTAssertEqual(plan?.fadeFrames, 1_058_400)
        XCTAssertEqual(plan?.incomingTempo, 1.02)
    }

    func testIncompleteLegacyRecipeCannotSchedule() {
        let recipe = CatalogEdgePlan(fromCatalogTrackID: "a", toCatalogTrackID: "b", analysisVersion: 1,
                                     style: "bass-swap", outgoingPhraseSeconds: 1, incomingPhraseSeconds: 1,
                                     overlapBeats: 64)
        XCTAssertNil(recipe.boundedOverlap(sampleRate: 44_100, outgoingZeroFrame: 0,
                                            incomingTotalFrames: 1_000_000, minimumBufferedFrames: 1))
    }
}
#endif
