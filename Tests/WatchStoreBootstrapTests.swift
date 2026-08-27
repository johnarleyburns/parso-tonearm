import SwiftData
import XCTest
@testable import TonearmWatchCore

final class WatchStoreBootstrapTests: XCTestCase {
    private enum Failure: Error { case injected }

    func testInMemoryStoreRoundTrip() throws {
        let container = try WatchStoreBootstrap.inMemory()
        let context = ModelContext(container)
        context.insert(WatchStoreMetadata(key: "paired", value: "yes"))
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<WatchStoreMetadata>()).first?.value, "yes")
    }

    func testPersistentSuccessIsReady() throws {
        let container = try WatchStoreBootstrap.inMemory()
        let result = WatchStoreBootstrap.open(persistent: { container }, recovery: { throw Failure.injected })
        XCTAssertEqual(result.state, .ready)
    }

    func testPersistentFailureRecoversInMemory() throws {
        let fallback = try WatchStoreBootstrap.inMemory()
        let result = WatchStoreBootstrap.open(persistent: { throw Failure.injected }, recovery: { fallback })
        XCTAssertEqual(result.state, .recovered)
        XCTAssertNotNil(result.container)
        XCTAssertNotNil(result.recoveryNotice)
    }

    func testDoubleFailureIsDegradedNotFatal() {
        let result = WatchStoreBootstrap.open(persistent: { throw Failure.injected }, recovery: { throw Failure.injected })
        XCTAssertEqual(result.state, .degraded)
        XCTAssertNil(result.container)
    }
}
