import Foundation
import Testing

/// Real reports: (1) the Find Name/Mood/BPM menu flashed when pressed;
/// (2) Mood always showed "Search your music to see results." and never
/// returned; (3) no-result searches should use the standard glass-style
/// ContentUnavailableView.search state.
@Suite struct FindMoodAndEmptyStateTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func testFindModeMenuNoLongerNestsAManualGlassContainer() throws {
        let find = try source("Sources/Features/Find/FindView.swift")
        let start = try #require(find.range(of: "private struct FindModeMenu"))
        let block = find[start.lowerBound...]
        #expect(!block.contains(".adaptiveGlass(cornerRadius:"),
                "native toolbar glass is enough; a nested GlassEffectContainer flashed on every press")
    }

    @Test func testMoodTerminalStatesPublishAnEmptyResultSet() throws {
        let controls = try source("Sources/Features/MyMusic/MyMusicSearchControls.swift")
        let start = try #require(controls.range(of: "private func publishRows()"))
        let block = controls[start.lowerBound...]
        for state in [".noMatches", ".zeroIndexed", ".modelMissing", ".searchFailed"] {
            #expect(block.contains(state), "publishRows must handle \(state) instead of leaving rows nil")
        }
        #expect(block.contains("onRows([])"),
                "a terminal no-result state must still count as search input")
    }

    @Test func testMoodFallsBackToBroaderSimilarityWhenTheStrictPoolIsEmpty() throws {
        let vm = try source("Sources/Discovery/DiscoverySearchViewModel.swift")
        #expect(vm.contains("fallbackToBroaderWhenFullyIndexedEmpty"))
        #expect(vm.contains("requireFullyIndexed: false"))
        #expect(vm.contains("broaderFallbackGeneration != gen"))

        let runtime = try source("Sources/App/DiscoveryRuntimeController.swift")
        #expect(runtime.contains("fallbackToBroaderWhenFullyIndexedEmpty: requireFullyIndexed"))
    }

    @Test func testFilteredEmptyResultsUseTheStandardSearchState() throws {
        let library = try source("Sources/Features/Library/LibraryView.swift")
        #expect(library.contains("ContentUnavailableView.search(text: appState.searchText)"))
        #expect(library.contains("\"library.noResults\""))
        #expect(library.contains("isUnfilteredBrowsing"))
    }
}
