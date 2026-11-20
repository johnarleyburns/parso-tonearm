import Foundation
import Testing

/// `SettingsView` lives under the excluded `Sources/Features`, so pin the removal by source
/// inspection. My Music > Sound Index is the sole entry point.
@Suite struct SettingsSoundIndexRemovalTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func testSettingsNoLongerHasSoundIndexEntryPoint() throws {
        let settings = try source("Sources/Features/Settings/SettingsView.swift")
        #expect(!settings.contains("case .soundIndex"))
        #expect(!settings.contains("soundIndexCard"))
        #expect(!settings.contains("struct SoundIndexSheet"))
        let library = try source("Sources/Features/Settings/SettingsView+LibrarySections.swift")
        #expect(!library.contains("var soundIndexCard"))
    }

    @Test func testMyMusicStillHostsSoundIndex() throws {
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        #expect(myMusic.contains("IndexStatusView(model: indexStatusModel)"))
    }
}
