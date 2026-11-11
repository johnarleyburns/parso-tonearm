import XCTest
@testable import TonearmCore

/// The Support row must distinguish "no such product" from a StoreKit/network failure, and
/// must never fall back to the old generic "couldn't reach the App Store" message.
final class SupportDevelopmentStoreUnavailableReasonTests: XCTestCase {
    func testNilWhileLoadingOrReady() {
        XCTAssertNil(SupportDevelopmentStore.unavailableReason(for: .notLoaded))
        XCTAssertNil(SupportDevelopmentStore.unavailableReason(for: .ready))
    }

    func testUnavailableAndFailedHaveDistinctReasons() throws {
        let unavailable = try XCTUnwrap(SupportDevelopmentStore.unavailableReason(for: .unavailable))
        let failed = try XCTUnwrap(SupportDevelopmentStore.unavailableReason(for: .failed(diagnostic: "x")))
        XCTAssertNotEqual(unavailable, failed)
        XCTAssertFalse(unavailable.contains("Couldn't reach the App Store"))
        XCTAssertFalse(failed.contains("Couldn't reach the App Store"))
    }
}

/// Source-level pins (no simulator) for the Voxglass-equivalent Support row.
final class SupportRowStructureTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testRowIsCompactHeartDisclosureRow() throws {
        let s = try source("Sources/Features/Settings/SupportDevelopmentCard.swift")
        XCTAssertTrue(s.contains("\"heart.fill\""))
        XCTAssertTrue(s.contains(".buttonStyle(.plain)"))
        XCTAssertTrue(s.contains("\"settings.support\""))
        XCTAssertTrue(s.contains(".disabled(store.purchasing)"))
        XCTAssertTrue(s.contains("Contribute to Development"))
        XCTAssertTrue(s.contains("A one-time, optional \\(store.displayPrice) — every feature is already free"))
        XCTAssertTrue(s.contains("Thanks for supporting Platterhead"))
        XCTAssertTrue(s.contains("You have the Supporter badge"))
        XCTAssertFalse(s.contains("glassSurface"))
        XCTAssertFalse(s.contains("settings.support.buy"))
        XCTAssertFalse(s.contains("Contribute ·"))
        XCTAssertFalse(s.contains("borderedProminent"))
    }

    func testSettingsHasOneSupportGroupAndRow() throws {
        let s = try source("Sources/Features/Settings/SettingsView.swift")
        XCTAssertEqual(s.components(separatedBy: "settingsSection(\"Support\"").count - 1, 1)
        XCTAssertEqual(s.components(separatedBy: "SupportDevelopmentCard()").count - 1, 1)
    }
}
