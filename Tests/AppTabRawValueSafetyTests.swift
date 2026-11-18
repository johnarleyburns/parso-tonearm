import Testing

/// `AppTab`'s raw values are persisted under `UserDefaults` (`lastActiveTab.v6`) and read back
/// via `AppTab(rawValue:)`, which already fails closed (no match → nothing restored → stays at
/// the `.listen` default) rather than crashing. Removing the standalone Mood tab (rawValue 2)
/// must leave `find`/`libraries` at their existing values (3/4) rather than letting Swift's
/// implicit case-by-case auto-numbering renumber them down to fill the gap — that would silently
/// hand a value a different user's install still has persisted (e.g. 3, meaning Find) to
/// whatever case happens to claim it after a shift, instead of to Find.
@Suite struct AppTabRawValueSafetyTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/App/AppState.swift"), encoding: .utf8)
    }

    @Test func testRemainingTabsKeepTheirExistingRawValuesAfterMoodWasRemoved() throws {
        let s = try source()
        #expect(s.contains("case listen = 0, myMusic = 1, find = 3, libraries = 4"),
                     "find/libraries must keep their pre-removal raw values (3/4) explicitly, " +
                     "not inherit whatever Swift's implicit auto-numbering assigns once mood's " +
                     "case is gone")
        #expect(!s.contains("case mood"))
    }

    @Test func testStaleTabRestoreFailsClosedRatherThanCrashingOrMisrouting() throws {
        let s = try source()
        #expect(s.contains("let restored = AppTab(rawValue: saved)"),
                     "restore must go through the failable initializer, which already fails " +
                     "closed (no match -> nothing restored) for a persisted value no case claims " +
                     "anymore")
    }
}
