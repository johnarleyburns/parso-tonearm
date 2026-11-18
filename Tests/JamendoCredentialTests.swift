import Testing
@testable import TonearmCore

/// §18A.2 / plan 6.3: which Jamendo key a request uses, and what happens when
/// there is none.
@Suite struct JamendoCredentialTests {

    /// A keychain scoped to this test run, so these never touch the app's own
    /// stored credential or each other's.
    private func makeStore(appKey: String) -> JamendoCredentialStore {
        let service = "guru.parso.tonearm.tests.\(UUID().uuidString)"
        return JamendoCredentialStore(keychain: CredentialStore(service: service),
                                      appClientID: { appKey })
    }

    @Test func testTheAppsOwnKeyIsUsedWhenTheUserHasNotSuppliedOne() throws {
        let store = makeStore(appKey: "app-key")
        let resolved = try #require(store.resolved())
        #expect(resolved.clientID == "app-key")
        #expect(!resolved.isUserSupplied)
        #expect(store.userSupplied() == nil)
    }

    /// The point of offering the setting: if our key is rate-limited, revoked
    /// or pulled, a user who supplied their own keeps working.
    @Test func testAUserSuppliedKeyWins() throws {
        let store = makeStore(appKey: "app-key")
        try store.saveUserSupplied(clientID: "mine", clientSecret: "s3cret")

        let resolved = try #require(store.resolved())
        #expect(resolved.clientID == "mine")
        #expect(resolved.isUserSupplied)
        #expect(resolved.clientSecret == "s3cret")
        try store.clearUserSupplied()
    }

    @Test func testClearingFallsBackToTheAppsKey() throws {
        let store = makeStore(appKey: "app-key")
        try store.saveUserSupplied(clientID: "mine", clientSecret: nil)
        try store.clearUserSupplied()
        #expect(store.resolved()?.clientID == "app-key")
        #expect(store.userSupplied() == nil)
    }

    /// Saving an empty id is how a user goes back to the app's key without
    /// hunting for a delete button.
    @Test func testAnEmptyIdClearsRatherThanStoringNothing() throws {
        let store = makeStore(appKey: "app-key")
        try store.saveUserSupplied(clientID: "mine", clientSecret: nil)
        try store.saveUserSupplied(clientID: "   ", clientSecret: nil)
        #expect(store.userSupplied() == nil)
        #expect(store.resolved()?.clientID == "app-key")
    }

    /// §18A.6, the D-9 lesson: no key anywhere is an honest nil, which the UI
    /// renders as "unavailable". It must never resolve to an empty string that
    /// would go out as `client_id=` and come back as a confusing API error.
    @Test func testNoKeyAnywhereIsHonestlyNil() {
        let store = makeStore(appKey: "")
        #expect(store.resolved() == nil)
    }

    @Test func testAnEmptySecretIsNotStoredAsAnEmptyString() throws {
        let store = makeStore(appKey: "app-key")
        try store.saveUserSupplied(clientID: "mine", clientSecret: "  ")
        #expect(store.userSupplied()?.clientID == "mine")
        #expect(store.userSupplied()?.clientSecret == nil,
                     "an empty secret is absence, not an empty credential")
        try store.clearUserSupplied()
    }

    @Test func testWhitespaceIsTrimmedFromAPastedKey() throws {
        // Pasting from a web page brings a trailing newline with it more often
        // than not, and `client_id=abc%0A` is a rejected request.
        let store = makeStore(appKey: "app-key")
        try store.saveUserSupplied(clientID: "  mine\n", clientSecret: nil)
        #expect(store.userSupplied()?.clientID == "mine")
        try store.clearUserSupplied()
    }
}
