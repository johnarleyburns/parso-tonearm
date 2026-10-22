#if !os(watchOS)
import XCTest
@testable import TonearmCore

final class StreamingDeckFeederTests: XCTestCase {
    final class Source: DeckChunkSource, @unchecked Sendable {
        func read(startFrame: Int64, count: Int) throws -> [[Float]] {
            [Array(repeating: 0.25, count: count), Array(repeating: 0.25, count: count)]
        }
    }
    func testFillWritesOnlyBoundedDeckStorage() async {
        let deck = BoundedDeckBuffer(capacityFrames: 128, channelCount: 2)
        deck.retarget(totalFrames: 1_000, startFrame: 0)
        let feeder = StreamingDeckFeeder(buffer: deck, source: Source(), maxChunkFrames: 32)
        await feeder.requestFill()
        for _ in 0..<20 where deck.bufferedFrames == 0 { await Task.yield() }
        XCTAssertEqual(deck.bufferedFrames, 128)
        XCTAssertEqual(deck.residentBytes, 128 * 2 * MemoryLayout<Float>.size)
    }
}
#endif
