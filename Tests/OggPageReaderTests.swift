import XCTest
@testable import Tonearm

/// T2.1 — Ogg demux + OpusHead parsing over real fixtures.
final class OggPageReaderTests: XCTestCase {

    func testParsesMonoHeaderAndReassemblesPackets() throws {
        let stream = try OggPageReader.parse(Fixtures.data("tone_mono", ext: "opus"))
        XCTAssertEqual(stream.head.channelCount, 1)
        // libopus default pre-skip is nonzero (guards the start click).
        XCTAssertGreaterThan(stream.head.preSkip, 0)
        XCTAssertEqual(stream.head.inputSampleRate, 48000)
        // Multi-page reassembly: many audio packets across several pages.
        XCTAssertGreaterThan(stream.audioPackets.count, 50)
    }

    func testParsesStereoHeader() throws {
        let stream = try OggPageReader.parse(Fixtures.data("tone_stereo", ext: "opus"))
        XCTAssertEqual(stream.head.channelCount, 2)
        XCTAssertGreaterThan(stream.audioPackets.count, 40)
    }

    func testGranuleAndDecodedCountConsistent() throws {
        let stream = try OggPageReader.parse(Fixtures.data("tone_mono", ext: "opus"))
        // Decoded samples (sum of per-packet frame counts) should be >= the final
        // granule (which excludes trailing padding but includes pre-skip).
        XCTAssertGreaterThanOrEqual(stream.decodedSampleCount, stream.finalGranule)
        XCTAssertGreaterThan(stream.finalGranule, 0)
    }

    func testRejectsChainedStream() {
        XCTAssertThrowsError(try OggPageReader.parse(Fixtures.data("chained", ext: "opus"))) { error in
            XCTAssertEqual(error as? OggOpusError, .chainedStream)
        }
    }

    func testRejectsNonOgg() {
        XCTAssertThrowsError(try OggPageReader.parse(Fixtures.data("corrupt_notogg", ext: "opus"))) { error in
            XCTAssertEqual(error as? OggOpusError, .notOgg)
        }
    }

    func testRejectsTruncatedStream() {
        XCTAssertThrowsError(try OggPageReader.parse(Fixtures.data("corrupt_truncated", ext: "opus")))
    }

    // MARK: - Packet duration (TOC parsing)

    func testPacketSampleCountForCELT20ms() {
        // config 15 (Hybrid FB 20ms) code 0 → 960 samples at 48 kHz.
        let toc = UInt8((15 << 3) | 0)
        let packet = Data([toc, 0x00, 0x00])
        XCTAssertEqual(OggPageReader.packetSampleCount(packet), 960)
    }
}
