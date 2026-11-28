import Foundation
import Testing

/// Source-level contract for the Listen tab's single resume surface: the
/// Continue card appears there, and the system mini player is suppressed only
/// while that card is on screen.
@Suite struct ListenContinueListeningContractTests {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func testListenShowsTheContinueCardAboveJumpBackIn() throws {
        let listen = try source("Sources/Features/Listen/ListenView.swift")
        #expect(listen.contains("ContinueListeningCard("))
        #expect(listen.contains("player.continueListeningPresentation"))
        let card = try #require(listen.range(of: "ContinueListeningCard("))
        let jumpBackIn = try #require(listen.range(of: "cardRow(title: \"Jump Back In\""))
        #expect(card.lowerBound < jumpBackIn.lowerBound, "the continue card is the first item")
    }

    @Test func testCardNamesAlbumPlaylistOrQueue() throws {
        let card = try source("Sources/Features/Listen/ContinueListeningCard.swift")
        #expect(card.contains("listen.continueListening"))
        #expect(card.contains("\"Continue your album\""))
        #expect(card.contains("\"Continue your playlist\""))
        #expect(card.contains("\"Continue your queue\""))
        #expect(card.contains("presentation.progressText"))
    }

    @Test func testMiniPlayerIsSuppressedOnlyOnListenWhileCardIsVisible() throws {
        let root = try source("Sources/Features/RootView.swift")
        #expect(root.contains("isListenActive: appState.tab == .listen"))
        #expect(root.contains("showsListenContinue:"))
        let chrome = try source("Sources/Domain/FindSearchChromeState.swift")
        #expect(chrome.contains("!(isListenActive && showsListenContinue)"))
    }

    @Test func testOtherTabsDoNotHostTheCard() throws {
        let myMusic = try source("Sources/Features/MyMusic/MyMusicView.swift")
        let find = try source("Sources/Features/Find/FindView.swift")
        #expect(!myMusic.contains("ContinueListeningCard"))
        #expect(!find.contains("ContinueListeningCard"))
    }
}
