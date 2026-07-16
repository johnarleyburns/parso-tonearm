import XCTest
import AVFoundation
@testable import TonearmCore

/// T2.2 — CAF output opens via AVAudioFile; decoded frame count matches the
/// granule-derived count; priming frames equal the OpusHead pre-skip.
final class CAFOpusWriterTests: XCTestCase {

    private func writeCAF(_ fixture: String) throws -> (url: URL, stream: OggOpusStream) {
        let stream = try OggPageReader.parse(Fixtures.data(fixture, ext: "opus"))
        let caf = try CAFOpusWriter.makeCAF(from: stream)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(fixture)-\(UUID().uuidString).caf")
        try caf.write(to: url)
        return (url, stream)
    }

    func testMonoOpensAndDecodesToGranuleCount() throws {
        let (url, stream) = try writeCAF("tone_mono")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.sampleRate, 48000)
        // Decoded length == finalGranule − preSkip (priming trimmed).
        let expected = stream.finalGranule - Int64(stream.head.preSkip)
        XCTAssertEqual(file.length, expected)
    }

    func testStereoOpensAndDecodes() throws {
        let (url, stream) = try writeCAF("tone_stereo")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        let expected = stream.finalGranule - Int64(stream.head.preSkip)
        XCTAssertEqual(file.length, expected)
    }

    func testDecodedAudioIsNonSilent() throws {
        let (url, _) = try writeCAF("tone_mono")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buf)
        var peak: Float = 0
        if let ch = buf.floatChannelData {
            for c in 0..<Int(file.processingFormat.channelCount) {
                for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(ch[c][i])) }
            }
        }
        // A 440 Hz tone must decode to real, non-silent audio.
        XCTAssertGreaterThan(peak, 0.01)
    }

    func testEmptyStreamThrows() {
        let empty = OggOpusStream(head: OpusHead(channelCount: 1, preSkip: 312,
                                                 inputSampleRate: 48000, outputGain: 0,
                                                 channelMappingFamily: 0),
                                  audioPackets: [], finalGranule: 0, decodedSampleCount: 0)
        XCTAssertThrowsError(try CAFOpusWriter.makeCAF(from: empty))
    }
}
