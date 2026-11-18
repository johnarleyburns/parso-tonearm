import Foundation
import Testing
@testable import TonearmCore

/// The Support row must distinguish "no such product" from a StoreKit/network failure, and
/// must never fall back to the old generic "couldn't reach the App Store" message.
@Suite struct SupportDevelopmentStoreUnavailableReasonTests {
    @Test func testNilWhileLoadingOrReady() {
        #expect(SupportDevelopmentStore.unavailableReason(for: .notLoaded) == nil)
        #expect(SupportDevelopmentStore.unavailableReason(for: .ready) == nil)
    }

    @Test func testUnavailableAndFailedHaveDistinctReasons() throws {
        let unavailable = try #require(SupportDevelopmentStore.unavailableReason(for: .unavailable))
        let failed = try #require(SupportDevelopmentStore.unavailableReason(for: .failed(diagnostic: "x")))
        #expect(unavailable != failed)
        #expect(!unavailable.contains("Couldn't reach the App Store"))
        #expect(!failed.contains("Couldn't reach the App Store"))
    }
}

/// Source-level pins (no simulator) for the Voxglass-equivalent Support row.
@Suite struct SupportRowStructureTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func testRowIsCompactHeartDisclosureRow() throws {
        let s = try source("Sources/Features/Settings/SupportDevelopmentCard.swift")
        #expect(s.contains("\"heart.fill\""))
        #expect(s.contains(".buttonStyle(.plain)"))
        #expect(s.contains("\"settings.support\""))
        #expect(s.contains(".disabled(store.purchasing)"))
        #expect(s.contains("Contribute to Development"))
        #expect(s.contains("A one-time, optional \\(store.displayPrice) — every feature is already free"))
        #expect(s.contains("Thanks for supporting Platterhead"))
        #expect(s.contains("You have the Supporter badge"))
        #expect(!s.contains("glassSurface"))
        #expect(!s.contains("settings.support.buy"))
        #expect(!s.contains("Contribute ·"))
        #expect(!s.contains("borderedProminent"))
    }

    @Test func testSettingsHasOneSupportGroupAndRow() throws {
        let s = try source("Sources/Features/Settings/SettingsView.swift")
        #expect(s.components(separatedBy: "settingsSection(\"Support\"").count - 1 == 1)
        #expect(s.components(separatedBy: "SupportDevelopmentCard()").count - 1 == 1)
    }
}
