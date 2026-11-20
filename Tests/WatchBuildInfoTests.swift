import Testing
@testable import TonearmWatchCore

@Suite struct WatchBuildInfoTests {
    @Test func testInstalledBuildLabelIncludesVersionAndBuild() {
        #expect(WatchBuildInfo.label(version: "1.4.0", build: "87") == "Version 1.4.0 (87)")
    }

    @Test func testInstalledBuildLabelDegradesWhenBundleFieldsAreMissing() {
        #expect(WatchBuildInfo.label(version: nil, build: "87") == "Build 87")
        #expect(WatchBuildInfo.label(version: "1.4.0", build: nil) == "Version 1.4.0")
        #expect(WatchBuildInfo.label(version: nil, build: nil) == "Build unavailable")
    }
}
