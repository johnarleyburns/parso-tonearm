import XCTest

@testable import TonearmDJ

final class DJSmokeTests: XCTestCase {
    func testDJModuleBuildsAndLinks() {
        XCTAssertEqual(DJ.moduleVersion, 1)
    }
}
