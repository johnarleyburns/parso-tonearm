import Foundation
import XCTest

/// `SettingsView` lives under the excluded `Sources/Features`, so pin the removal by source
/// inspection. My Music > Sound Index is the sole entry point.
final class SettingsSoundIndexRemovalTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testSettingsNoLongerHasSoundIndexEntryPoint() throws {
        let settings = try source("Sources/Features/Settings/SettingsView.swift")
        XCTAssertFalse(settings.contains("case .soundIndex"))
        XCTAssertFalse(settings.contains("soundIndexCard"))
        XCTAssertFalse(settings.contains("struct SoundIndexSheet"))
        let library = try source("Sources/Features/Settings/SettingsView+LibrarySections.swift")
        XCTAssertFalse(library.contains("var soundIndexCard"))
    }

    func testMyMusicStillHostsSoundIndex() throws {
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        XCTAssertTrue(myMusic.contains("IndexStatusView(model: indexStatusModel)"))
    }
}
