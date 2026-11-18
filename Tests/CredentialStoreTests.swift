import Foundation
import Testing

@testable import TonearmCore

@Suite struct CredentialStoreTests {

    @Test func testRoundTrip() throws {
        let store = makeStore()
        let account = "round-trip"
        let data = try #require("secret".data(using: .utf8))

        try store.save(data, account: account)

        #expect(try store.read(account: account) == data)
        try store.delete(account: account)
    }

    @Test func testOverwrite() throws {
        let store = makeStore()
        let account = "overwrite"
        let first = try #require("first".data(using: .utf8))
        let second = try #require("second".data(using: .utf8))

        try store.save(first, account: account)
        try store.save(second, account: account)

        #expect(try store.read(account: account) == second)
        try store.delete(account: account)
    }

    @Test func testDelete() throws {
        let store = makeStore()
        let account = "delete"
        let data = try #require("secret".data(using: .utf8))

        try store.save(data, account: account)
        try store.delete(account: account)

        #expect(try store.read(account: account) == nil)
    }

    @Test func testMissingCredentialReturnsNil() throws {
        let store = makeStore()

        #expect(try store.read(account: "missing") == nil)
        #expect(throws: Never.self) { try store.delete(account: "missing") }
    }

    private func makeStore() -> CredentialStore {
        CredentialStore(service: "guru.parso.tonearm.tests.\(UUID().uuidString)")
    }
}
