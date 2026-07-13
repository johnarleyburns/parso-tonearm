import XCTest

@testable import Tonearm

final class PlatformSupportTests: XCTestCase {
    func testAppBundleDeclaresUniversalDeviceFamily() {
        let families = Bundle.main.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int]

        XCTAssertEqual(families, [1, 2])
    }

    func testAppBundleSupportsPortraitAndLandscape() {
        let orientations = Bundle.main.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String]

        XCTAssertEqual(orientations, [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ])
    }
}
