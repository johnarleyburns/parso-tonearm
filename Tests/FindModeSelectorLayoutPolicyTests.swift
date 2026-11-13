#if !os(watchOS)
import XCTest

/// Sources/Features is excluded from the SwiftPM targets, so the selector is checked as a source contract.
/// Rendered hit-testing at compact width / accessibility sizes belongs to the by-hand UI regression suite.
final class FindModeSelectorLayoutPolicyTests: XCTestCase {
    private func source() throws -> String {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repo.appendingPathComponent("Sources/Features/MyMusic/MyMusicSearchControls.swift"),
                          encoding: .utf8)
    }

    func testSelectorAdaptsInsteadOfOverflowing() throws {
        let s = try source()
        XCTAssertTrue(s.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(s.contains("FindModeSelectorLayoutPolicy.alwaysStacked(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)"))
        XCTAssertTrue(s.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(s.contains(".contentShape(Capsule())"))
        XCTAssertTrue(s.contains(".isSelected"))
    }

    func testStableIdentifiers() throws {
        let s = try source()
        for id in ["find.mode.all", "find.mode.mood", "find.mode.mix", "mymusic.search.mode"] {
            XCTAssertTrue(s.contains("\"\(id)\""), id)
        }
    }
}
#endif
