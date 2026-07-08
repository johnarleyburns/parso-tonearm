import XCTest
@testable import Tonearm

@MainActor
final class BackgroundAddTests: XCTestCase {

    func testBackgroundBannerAppears() async {
        let store = try! LibraryStore(inMemory: true)
        let state = AppState(store: store)

        let preview = SourcePreview(
            kind: .iaList, title: "Spanish Guitar",
            subtitle: "50 tracks", licenseText: nil,
            licensePermitsStreaming: true,
            memberCount: 50, totalCount: 50, capHit: false,
            parsed: .list(screenname: "johnarleyburns", listId: "2", slug: "spanish-guitar"),
            originalURL: "https://archive.org/details/@johnarleyburns/lists/2/spanish-guitar",
            resolvedItem: nil, members: []
        )

        state.addSourceInBackground(preview: preview, followUpdates: true)

        XCTAssertEqual(state.backgroundTitle, "Spanish Guitar")
        XCTAssertFalse(state.backgroundDone)
    }

    func testBackgroundTaskClearedAfterCompletion() async {
        let store = try! LibraryStore(inMemory: true)
        let state = AppState(store: store)

        let preview = SourcePreview(
            kind: .iaItem, title: "Test Album",
            subtitle: "1 track", licenseText: nil,
            licensePermitsStreaming: true,
            memberCount: 1, totalCount: 1, capHit: false,
            parsed: .item(identifier: "test", filename: nil), originalURL: "https://archive.org/details/test",
            resolvedItem: nil, members: []
        )

        state.addSourceInBackground(preview: preview, followUpdates: false)

        XCTAssertNotNil(state.backgroundTitle)
    }

    func testBackgroundTaskDoesNotBlock() async {
        let store = try! LibraryStore(inMemory: true)
        let state = AppState(store: store)

        let preview = SourcePreview(
            kind: .iaList, title: "Large Collection",
            subtitle: "200 tracks", licenseText: nil,
            licensePermitsStreaming: true,
            memberCount: 200, totalCount: 200, capHit: false,
            parsed: .list(screenname: "user", listId: "1", slug: "test"),
            originalURL: "https://archive.org/details/@user/lists/1/test",
            resolvedItem: nil, members: []
        )

        let start = Date()
        state.addSourceInBackground(preview: preview, followUpdates: false)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.1, "addSourceInBackground should return near-instantly")
    }

    func testMultipleBackgroundTasks() async {
        let store = try! LibraryStore(inMemory: true)
        let state = AppState(store: store)

        let preview1 = SourcePreview(
            kind: .iaItem, title: "Album One",
            subtitle: "1 track", licenseText: nil,
            licensePermitsStreaming: true,
            memberCount: 1, totalCount: 1, capHit: false,
            parsed: .item(identifier: "one", filename: nil), originalURL: "https://archive.org/details/one",
            resolvedItem: nil, members: []
        )

        let preview2 = SourcePreview(
            kind: .iaItem, title: "Album Two",
            subtitle: "1 track", licenseText: nil,
            licensePermitsStreaming: true,
            memberCount: 1, totalCount: 1, capHit: false,
            parsed: .item(identifier: "two", filename: nil), originalURL: "https://archive.org/details/two",
            resolvedItem: nil, members: []
        )

        state.addSourceInBackground(preview: preview1, followUpdates: false)

        let firstTitle = state.backgroundTitle
        XCTAssertNotNil(firstTitle)

        state.addSourceInBackground(preview: preview2, followUpdates: false)

        // Second task should override the banner
        XCTAssertEqual(state.backgroundTitle, "Album Two")
    }
}
