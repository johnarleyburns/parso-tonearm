import XCTest

@testable import Tonearm

final class CredentialStoreTests: XCTestCase {

    func testRoundTrip() throws {
        let store = makeStore()
        let account = "round-trip"
        let data = try XCTUnwrap("secret".data(using: .utf8))

        try store.save(data, account: account)

        XCTAssertEqual(try store.read(account: account), data)
        try store.delete(account: account)
    }

    func testOverwrite() throws {
        let store = makeStore()
        let account = "overwrite"
        let first = try XCTUnwrap("first".data(using: .utf8))
        let second = try XCTUnwrap("second".data(using: .utf8))

        try store.save(first, account: account)
        try store.save(second, account: account)

        XCTAssertEqual(try store.read(account: account), second)
        try store.delete(account: account)
    }

    func testDelete() throws {
        let store = makeStore()
        let account = "delete"
        let data = try XCTUnwrap("secret".data(using: .utf8))

        try store.save(data, account: account)
        try store.delete(account: account)

        XCTAssertNil(try store.read(account: account))
    }

    func testMissingCredentialReturnsNil() throws {
        let store = makeStore()

        XCTAssertNil(try store.read(account: "missing"))
        XCTAssertNoThrow(try store.delete(account: "missing"))
    }

    private func makeStore() -> CredentialStore {
        CredentialStore(service: "guru.parso.tonearm.tests.\(UUID().uuidString)")
    }
}
