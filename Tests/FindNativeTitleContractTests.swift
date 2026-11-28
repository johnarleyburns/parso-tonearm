#if !os(watchOS)
import Foundation
import Testing

/// Find uses the native large navigation title and keeps its result identifiers.
@Suite struct FindNativeTitleContractTests {
    @Test func testFindUsesNativeLargeTitle() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/Find/FindView.swift"),
                           encoding: .utf8)
        #expect(!s.contains("ScreenHeader("), "custom Find header must be gone")
        #expect(!s.contains(".hiddenNavigationBar()"), "Find root must only hide its bar conditionally")
        #expect(s.contains(".navigationTitle(\"Find\")"), "unfocused Find keeps the native title")
        #expect(s.contains(".largeNavigationTitle()"))
        // Focused query: conditional bar hiding driven by the same signal the root shell reads.
        #expect(s.contains("hiddenNavigationBar(when: queryFocused"))
        #expect(s.contains("appState.findQueryFocused = "))
        #expect(s.contains("\"find.results\""))
        #expect(s.contains("\"find.awaitingQuery\""))
    }

    @Test func testFindModeButtonsUseByLabels() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: repo.appendingPathComponent("Sources/Features/MyMusic/MyMusicSearchControls.swift"),
                           encoding: .utf8)
        #expect(s.contains("case all = \"Name\""))
        #expect(s.contains("case mix = \"BPM/Key\""))
        #expect(!s.contains("case sound"))
        #expect(!s.contains("case all = \"All\""))
        #expect(!s.contains("Find Mood"))
        #expect(!s.contains("Find Mix"))
        #expect(!s.contains("Find by BPM/Key"))
        #expect(s.contains("\"find.mode.mix\"") && s.contains("\"find.mode.all\""))
        #expect(!s.contains("\"find.mode.mood\""))
    }
}
#endif
