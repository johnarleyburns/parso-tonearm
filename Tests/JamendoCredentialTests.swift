import XCTest
@testable import TonearmCore

/// §18A.2 / plan 6.3: which Jamendo key a request uses, and what happens when
/// there is none.
final class JamendoCredentialTests: XCTestCase {

    /// A keychain scoped to this test run, so these never touch the app's own
    /// stored credential or each other's.
    private func makeStore(appKey: String) -> JamendoCredentialStore {
        let service = "guru.parso.tonearm.tests.\(UUID().uuidString)"
        return JamendoCredentialStore(keychain: CredentialStore(service: service),
                                      appClientID: { appKey })
    }

    func testTheAppsOwnKeyIsUsedWhenTheUserHasNotSuppliedOne() throws {
        let store = makeStore(appKey: "app-key")
        let resolved = try XCTUnwrap(store.resolved())
        XCTAssertEqual(resolved.clientID, "app-key")
        XCTAssertFalse(resolved.isUserSupplied)
        XCTAssertNil(store.userSupplied())
    }

    /// The point of offering the setting: if our key is rate-limited, revoked
    /// or pulled, a user who supplied their own keeps working.
    func testAUserSuppliedKeyWins() throws {
        let store = makeStore(appKey: "app-key")
        try store.saveUserSupplied(clientID: "mine", clientSecret: "s3cret")

        let resolved = try XCTUnwrap(store.resolved())
        XCTAssertEqual(resolved.clientID, "mine")
        XCTAssertTrue(resolved.isUserSupplied)
        XCTAssertEqual(resolved.clientSecret, "s3cret")
        try store.clearUserSupplied()
    }

    func testClearingFallsBackToTheAppsKey() throws {
        let store = makeStore(appKey: "app-key")
        try store.saveUserSupplied(clientID: "mine", clientSecret: nil)
        try store.clearUserSupplied()
        XCTAssertEqual(store.resolved()?.clientID, "app-key")
        XCTAssertNil(store.userSupplied())
    }

    /// Saving an empty id is how a user goes back to the app's key without
    /// hunting for a delete button.
    func testAnEmptyIdClearsRatherThanStoringNothing() throws {
        let store = makeStore(appKey: "app-key")
        try store.saveUserSupplied(clientID: "mine", clientSecret: nil)
        try store.saveUserSupplied(clientID: "   ", clientSecret: nil)
        XCTAssertNil(store.userSupplied())
        XCTAssertEqual(store.resolved()?.clientID, "app-key")
    }

    /// §18A.6, the D-9 lesson: no key anywhere is an honest nil, which the UI
    /// renders as "unavailable". It must never resolve to an empty string that
    /// would go out as `client_id=` and come back as a confusing API error.
    func testNoKeyAnywhereIsHonestlyNil() {
        let store = makeStore(appKey: "")
        XCTAssertNil(store.resolved())
    }

    func testAnEmptySecretIsNotStoredAsAnEmptyString() throws {
        let store = makeStore(appKey: "app-key")
        try store.saveUserSupplied(clientID: "mine", clientSecret: "  ")
        XCTAssertEqual(store.userSupplied()?.clientID, "mine")
        XCTAssertNil(store.userSupplied()?.clientSecret,
                     "an empty secret is absence, not an empty credential")
        try store.clearUserSupplied()
    }

    func testWhitespaceIsTrimmedFromAPastedKey() throws {
        // Pasting from a web page brings a trailing newline with it more often
        // than not, and `client_id=abc%0A` is a rejected request.
        let store = makeStore(appKey: "app-key")
        try store.saveUserSupplied(clientID: "  mine\n", clientSecret: nil)
        XCTAssertEqual(store.userSupplied()?.clientID, "mine")
        try store.clearUserSupplied()
    }
}
