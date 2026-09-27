import XCTest
@testable import TonearmCore

final class DJGridLayoutTests: XCTestCase {
    func testEightByEightLayoutFillsSurfaceWithEqualCells() {
        let layout = DJGridLayout(size: CGSize(width: 800, height: 400), gap: 8)
        XCTAssertEqual(layout.frame(col: 0, row: 0).width, layout.cellWidth)
        XCTAssertEqual(layout.frame(col: 0, row: 0).height, layout.rowHeight)
        XCTAssertEqual(layout.frame(col: 0, row: 0, span: 8).maxX, 800, accuracy: 0.001)
        XCTAssertEqual(layout.frame(col: 0, row: 0, span: 8).maxY, layout.rowHeight, accuracy: 0.001)
        XCTAssertEqual(layout.frame(col: 2, row: 3, span: 3).width,
                       layout.cellWidth * 3 + layout.gap * 2, accuracy: 0.001)
    }

    func testKeyFormatterKeepsCamelotAndRejectsUnknownValues() {
        XCTAssertEqual(DJKeyFormatter.format("8A"), "8A")
        XCTAssertEqual(DJKeyFormatter.format("12B"), "12B")
        XCTAssertEqual(DJKeyFormatter.format("C major"), "—")
        XCTAssertEqual(DJKeyFormatter.format(nil), "—")
    }
}
