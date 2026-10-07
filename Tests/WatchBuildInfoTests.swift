import XCTest
@testable import TonearmWatchCore

final class WatchBuildInfoTests: XCTestCase {
    func testInstalledBuildLabelIncludesVersionAndBuild() {
        XCTAssertEqual(WatchBuildInfo.label(version: "1.4.0", build: "87"), "Version 1.4.0 (87)")
    }

    func testInstalledBuildLabelDegradesWhenBundleFieldsAreMissing() {
        XCTAssertEqual(WatchBuildInfo.label(version: nil, build: "87"), "Build 87")
        XCTAssertEqual(WatchBuildInfo.label(version: "1.4.0", build: nil), "Version 1.4.0")
        XCTAssertEqual(WatchBuildInfo.label(version: nil, build: nil), "Build unavailable")
    }
}
