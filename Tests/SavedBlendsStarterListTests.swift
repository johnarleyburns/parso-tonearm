import XCTest
@testable import TonearmCore

final class SavedBlendsStarterListTests: XCTestCase {
    func testStarterBlendsAppearWhenNothingSaved() {
        let ids = StarterBlendCatalog.mergingStarterBlends(into: []).map(\.id)
        XCTAssertEqual(ids, StarterBlendCatalog.blends.map { $0.document.id })
        XCTAssertFalse(ids.isEmpty)
    }

    func testSavedCopyIsNotDuplicated() {
        let doc = StarterBlendCatalog.blends[0].document
        let result = StarterBlendCatalog.mergingStarterBlends(into: [doc])
        XCTAssertEqual(result.filter { $0.id == doc.id }.count, 1)
        XCTAssertTrue(StarterBlendCatalog.isBuiltIn(doc))
    }
}
