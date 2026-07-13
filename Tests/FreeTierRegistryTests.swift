import XCTest
@testable import Tonearm

/// T0.1 — pins the free/paid split so later phases can't silently gate an
/// identity feature. If someone adds a `ProFeature` case for a format, gapless,
/// IA sources, local import, or privacy, this test fails loudly.
final class FreeTierRegistryTests: XCTestCase {

    func testProFeatureCasesAreExactlyTheGatedConveniences() {
        let actual = Set(ProFeature.allCases.map { $0.rawValue })
        let expected: Set<String> = ["cachePresets", "prefetchDepth", "folderWatch", "eq", "carplay", "icloudSync"]
        XCTAssertEqual(actual, expected,
                       "ProFeature must gate ONLY conveniences — never identity features")
    }

    func testIdentityCapabilitiesAreNeverProFeatures() {
        // Identity features that must stay free forever (Ground rule #3).
        let identityCapabilities = ["flac", "opus", "mp3", "nearGapless",
                                    "iaSources", "localImport", "privacy"]
        let gated = Set(ProFeature.allCases.map { $0.rawValue.lowercased() })
        for capability in identityCapabilities {
            XCTAssertFalse(gated.contains(capability.lowercased()),
                           "\(capability) is an identity feature and must not be gated")
        }
    }

    func testGatedCountIsStable() {
        // Guard against accidental additions/removals without updating the spec.
        XCTAssertEqual(ProFeature.allCases.count, 6)
    }
}
