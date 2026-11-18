import Testing
@testable import TonearmCore

@Suite struct QueueAccessibilityTests {
    @Test func testRowLabelIncludesPositionTitleAndArtist() {
        #expect(QueueAccessibility.rowLabel(position: 2, title: "Song", artist: "Band") == "2, Song, Band")
        #expect(QueueAccessibility.rowLabel(position: 3, title: "Song", artist: "") == "3, Song")
    }

    @Test func testRowStateAndHintDifferForCurrentTrack() {
        #expect(QueueAccessibility.rowValue(isCurrent: true) == "Now playing")
        #expect(QueueAccessibility.rowValue(isCurrent: false) == "")
        #expect(QueueAccessibility.rowHint(isCurrent: true) != QueueAccessibility.rowHint(isCurrent: false))
    }

    @Test func testControlLabelsAndTargetSize() {
        #expect(QueueAccessibility.reorderLabel(isReordering: true) == "Done Reordering")
        #expect(QueueAccessibility.reorderLabel(isReordering: false) == "Reorder Up Next")
        #expect(QueueAccessibility.keepPlayingValue(isOn: true) == "on")
        #expect(QueueAccessibility.keepPlayingValue(isOn: false) == "off")
        #expect(QueueAccessibility.minimumTargetSide >= 44)
    }
}
