import Testing
@testable import TonearmCore

/// T2.1 — Ogg demux + OpusHead parsing over real fixtures.
@Suite struct OggPageReaderTests {

    @Test func testParsesMonoHeaderAndReassemblesPackets() throws {
        let stream = try OggPageReader.parse(Fixtures.data("tone_mono", ext: "opus"))
        #expect(stream.head.channelCount == 1)
        // libopus default pre-skip is nonzero (guards the start click).
        #expect(stream.head.preSkip > 0)
        #expect(stream.head.inputSampleRate == 48000)
        // Multi-page reassembly: many audio packets across several pages.
        #expect(stream.audioPackets.count > 50)
    }

    @Test func testParsesStereoHeader() throws {
        let stream = try OggPageReader.parse(Fixtures.data("tone_stereo", ext: "opus"))
        #expect(stream.head.channelCount == 2)
        #expect(stream.audioPackets.count > 40)
    }

    @Test func testGranuleAndDecodedCountConsistent() throws {
        let stream = try OggPageReader.parse(Fixtures.data("tone_mono", ext: "opus"))
        // Decoded samples (sum of per-packet frame counts) should be >= the final
        // granule (which excludes trailing padding but includes pre-skip).
        #expect(stream.decodedSampleCount >= stream.finalGranule)
        #expect(stream.finalGranule > 0)
    }

    @Test func testRejectsChainedStream() {
        do {
            _ = try OggPageReader.parse(Fixtures.data("chained", ext: "opus"))
            Issue.record("expected parse of a chained stream to throw")
        } catch {
            #expect(error as? OggOpusError == .chainedStream)
        }
    }

    @Test func testRejectsNonOgg() {
        do {
            _ = try OggPageReader.parse(Fixtures.data("corrupt_notogg", ext: "opus"))
            Issue.record("expected parse of a non-Ogg stream to throw")
        } catch {
            #expect(error as? OggOpusError == .notOgg)
        }
    }

    @Test func testRejectsTruncatedStream() {
        do {
            _ = try OggPageReader.parse(Fixtures.data("corrupt_truncated", ext: "opus"))
            Issue.record("expected parse of a truncated stream to throw")
        } catch {}
    }

    // MARK: - Packet duration (TOC parsing)

    @Test func testPacketSampleCountForCELT20ms() {
        // config 15 (Hybrid FB 20ms) code 0 → 960 samples at 48 kHz.
        let toc = UInt8((15 << 3) | 0)
        let packet = Data([toc, 0x00, 0x00])
        #expect(OggPageReader.packetSampleCount(packet) == 960)
    }
}
