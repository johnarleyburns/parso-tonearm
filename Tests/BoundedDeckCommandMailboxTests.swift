#if !os(watchOS)
import XCTest
@testable import TonearmCore

final class BoundedDeckCommandMailboxTests: XCTestCase {
    func testNewestUnreadCommandIsAppliedOnRenderSide() {
        let mixer = BoundedDeckMixer(capacityFrames: 64)
        let mailbox = BoundedDeckCommandMailbox()
        mailbox.begin(total: 1_000, start: 0, tempo: 1)
        mailbox.begin(total: 2_000, start: 300, tempo: 1.1)
        mailbox.consume(into: mixer)
        XCTAssertEqual(mixer.decks[mixer.main].totalFrames, 2_000)
        XCTAssertEqual(mixer.decks[mixer.main].generation, 2)
        // The target is visible to the producer only after it begins filling.
        XCTAssertEqual(mixer.decks[mixer.main].nextRequest().startFrame, 300)
    }

    func testScheduledCommandCarriesBoundedPrebufferRequirement() {
        let mixer = BoundedDeckMixer(capacityFrames: 64)
        let mailbox = BoundedDeckCommandMailbox()
        mailbox.begin(total: 2_000, start: 0, tempo: 1)
        mailbox.consume(into: mixer)
        mailbox.schedule(.init(startClock: 300, fadeFrames: 100, incomingStartFrame: 50,
                               incomingTotalFrames: 900, incomingTempo: 0.98, incomingGain: 0.7,
                               minIncomingBufferedFrames: 40))
        mailbox.consume(into: mixer)
        XCTAssertEqual(mixer.decks[mixer.incomingIndex].totalFrames, 900)
        XCTAssertEqual(mixer.decks[mixer.incomingIndex].nextRequest().startFrame, 50)
    }
}
#endif
