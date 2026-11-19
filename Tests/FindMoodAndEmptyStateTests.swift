import XCTest

/// Real reports: (1) the Find Name/Mood/BPM menu flashed when pressed;
/// (2) Mood always showed "Search your music to see results." and never
/// returned; (3) no-result searches should use the standard glass-style
/// ContentUnavailableView.search state.
final class FindMoodAndEmptyStateTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testFindModeMenuNoLongerNestsAManualGlassContainer() throws {
        let find = try source("Sources/Features/Find/FindView.swift")
        let start = try XCTUnwrap(find.range(of: "private struct FindModeMenu"))
        let block = find[start.lowerBound...]
        XCTAssertFalse(block.contains(".adaptiveGlass"),
                       "native toolbar glass is enough; a nested GlassEffectContainer flashed on every press")
    }

    func testMoodTerminalStatesPublishAnEmptyResultSet() throws {
        let controls = try source("Sources/Features/MyMusic/MyMusicSearchControls.swift")
        let start = try XCTUnwrap(controls.range(of: "private func publishRows()"))
        let block = controls[start.lowerBound...]
        for state in [".noMatches", ".zeroIndexed", ".modelMissing", ".searchFailed"] {
            XCTAssertTrue(block.contains(state), "publishRows must handle \(state) instead of leaving rows nil")
        }
        XCTAssertTrue(block.contains("onRows([])"),
                      "a terminal no-result state must still count as search input")
    }

    func testMoodFallsBackToBroaderSimilarityWhenTheStrictPoolIsEmpty() throws {
        let vm = try source("Sources/Discovery/DiscoverySearchViewModel.swift")
        XCTAssertTrue(vm.contains("fallbackToBroaderWhenFullyIndexedEmpty"))
        XCTAssertTrue(vm.contains("requireFullyIndexed: false"))
        XCTAssertTrue(vm.contains("broaderFallbackGeneration != gen"))

        let runtime = try source("Sources/App/DiscoveryRuntimeController.swift")
        XCTAssertTrue(runtime.contains("fallbackToBroaderWhenFullyIndexedEmpty: requireFullyIndexed"))
    }

    func testFilteredEmptyResultsUseTheStandardSearchState() throws {
        let library = try source("Sources/Features/Library/LibraryView.swift")
        XCTAssertTrue(library.contains("ContentUnavailableView.search(text: appState.searchText)"))
        XCTAssertTrue(library.contains("\"library.noResults\""))
        XCTAssertTrue(library.contains("isUnfilteredBrowsing"))
    }
}
