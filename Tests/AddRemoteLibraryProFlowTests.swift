import XCTest
@testable import TonearmCore

final class AddRemoteLibraryProFlowTests: XCTestCase {
    func testFreeAddRemoteEntryPointShowsPaywall() {
        XCTAssertEqual(RemoteLibraryGate.entryPointDecision(isPro: false), .showPaywall)
    }

    func testExistingProAddRemoteEntryPointOpensSheet() {
        XCTAssertEqual(RemoteLibraryGate.entryPointDecision(isPro: true), .openSheet)
    }

    func testAddRemotePurchaseCompletionShowsCompletionSheetOnlyForThatEntryPoint() {
        XCTAssertEqual(
            AddRemoteLibraryProFlow.presentationAfterProCompletion(
                entryPoint: .addRemoteLibrary,
                didBecomePro: true
            ),
            .showAddRemoteLibraryCompletion
        )
        XCTAssertEqual(
            AddRemoteLibraryProFlow.presentationAfterProCompletion(
                entryPoint: .generic,
                didBecomePro: true
            ),
            .none
        )
        XCTAssertEqual(
            AddRemoteLibraryProFlow.presentationAfterProCompletion(
                entryPoint: .addRemoteLibrary,
                didBecomePro: false
            ),
            .none
        )
    }

    func testAddLibraryNowOpensLibrariesAndServerSheet() {
        XCTAssertEqual(
            AddRemoteLibraryProFlow.outcome(for: .addLibraryNow),
            RemoteLibraryPostPurchaseOutcome(openLibrariesTab: true, openAddServerSheet: true)
        )
    }

    func testMaybeLaterDismissesCompletionSheet() {
        XCTAssertEqual(
            AddRemoteLibraryProFlow.outcome(for: .maybeLater),
            RemoteLibraryPostPurchaseOutcome(openLibrariesTab: false, openAddServerSheet: false)
        )
    }
}
