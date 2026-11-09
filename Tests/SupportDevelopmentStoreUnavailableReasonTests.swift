import XCTest
@testable import TonearmCore

/// `SupportDevelopmentCard`'s purchase button disables itself whenever the product hasn't
/// loaded, with zero explanation (CLAUDE.md's "no silent/magic background work" rule: "When
/// work can't proceed, say the specific reason... never collapse a real blocked/waiting state
/// into a generic in-progress label"). If `loadProduct()` ever fails (no network, App Store
/// unreachable, product not configured for this account/region), the user sees a permanently
/// greyed-out button with no message — indistinguishable from "still loading."
///
/// A pure static helper (rather than requiring the full injectable-purchasing seam from the
/// companion issue, which may not have landed yet) keeps this testable independently of merge
/// order — see that issue for the DI seam this can be rewired through later without maintaining
/// two.
final class SupportDevelopmentStoreUnavailableReasonTests: XCTestCase {
    func testNilBeforeAnyLoadAttempt() {
        XCTAssertNil(SupportDevelopmentStore.unavailableReason(didAttemptLoad: false, isAvailable: false))
    }

    func testNilOnceProductLoadsSuccessfully() {
        XCTAssertNil(SupportDevelopmentStore.unavailableReason(didAttemptLoad: true, isAvailable: true))
    }

    func testSetWhenLoadAttemptFailedToFindAProduct() {
        XCTAssertNotNil(SupportDevelopmentStore.unavailableReason(didAttemptLoad: true, isAvailable: false))
    }

    /// `SupportDevelopmentCard` is a SwiftUI view with no simulator-free way to render it, so
    /// this pins the one thing that matters at the source level: the reason actually gets
    /// surfaced next to the button it explains, not just computed and left unused.
    func testCardRendersTheUnavailableReasonNextToThePurchaseButton() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Features/Settings/SupportDevelopmentCard.swift"),
            encoding: .utf8)
        let buyIdentifier = try XCTUnwrap(source.range(of: "\"settings.support.buy\""))
        let reasonCheck = try XCTUnwrap(source.range(of: "if let reason = store.unavailableReason {"))
        let reasonIdentifier = try XCTUnwrap(source.range(of: "\"settings.support.unavailable\""))
        XCTAssertLessThan(buyIdentifier.lowerBound, reasonCheck.lowerBound,
            "the unavailable-reason check must sit right after the purchase button")
        XCTAssertLessThan(reasonCheck.lowerBound, reasonIdentifier.lowerBound)
    }
}
