import XCTest
import ParsoAudioCore

@testable import TonearmDJ

/// Phase 9 (docs/GPL-BACKENDS.md): Demucs is this app's active stem-separation
/// backend (diverging from PAE's own Spleeter-default stance), and LAME is
/// this app's `MP3Encoding` conformance for MP3 export (docs/BYO-CODEC.md in
/// parso-audio-engine).
final class Phase9GPLBackendsTests: XCTestCase {

    private final class EmptyProvider: ModelResourceProviding, @unchecked Sendable {
        let tagFileNames: [ModelTag: String] = [:]
        func isAvailable(_ tag: ModelTag) -> Bool { false }
        func url(for tag: ModelTag) async -> URL? { nil }
        func fetch(_ tag: ModelTag) -> AsyncStream<Double> {
            AsyncStream { $0.finish() }
        }
        func release(_ tag: ModelTag) async {}
    }

    func testDemucsIsTheActiveBackendByDefault() async {
        let resource = ModelResourceService(provider: EmptyProvider())
        let registry = await StemSeparationBackends.makeRegistry(resource: resource)
        let activeID = await registry.activeID
        XCTAssertEqual(activeID, StemSeparationBackends.demucs)
        let registered = await registry.registeredIDs
        XCTAssertTrue(registered.contains(.spleeter), "Spleeter should stay registered as a fallback")
    }

    func testLAMEEncoderProducesDecodableCBRMP3() throws {
        let sampleRate = 44_100.0
        let frameCount = Int(sampleRate * 0.5)
        let buffer = ParsoAudioCore.PCMBuffer(
            format: AudioFormat(sampleRate: sampleRate, channelCount: 1),
            capacity: frameCount
        )
        let channel = buffer.channel(0)
        for i in 0..<frameCount {
            channel[i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sampleRate)) * 0.6
        }

        let data = try LAMEEncoder().encode(buffer, bitrateKbps: 128)
        XCTAssertGreaterThan(data.count, 1000)
        // A real MP3 frame sync word (11 set bits) must open the stream —
        // LAME writes no ID3/Xing header in this bridge (app_lame.c disables
        // bWriteVbrTag), so byte 0 is the first frame header.
        XCTAssertEqual(data[data.startIndex], 0xFF)
        XCTAssertEqual(data[data.startIndex + 1] & 0xE0, 0xE0)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let decoded = try AudioFileReader(url: url, container: .mp3).readAll()
        XCTAssertGreaterThan(decoded.frameCount, 0)
    }

    func testAudioFileWriterCallsLAMEInsteadOfGlintWhenSupplied() throws {
        let sampleRate = 44_100.0
        let frameCount = Int(sampleRate * 0.2)
        let buffer = ParsoAudioCore.PCMBuffer(
            format: AudioFormat(sampleRate: sampleRate, channelCount: 1),
            capacity: frameCount
        )
        let channel = buffer.channel(0)
        for i in 0..<frameCount { channel[i] = Float(sin(2.0 * .pi * 220.0 * Double(i) / sampleRate)) * 0.5 }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileWriter(url: url, format: buffer.format,
                                          codec: .mp3(bitrate: 128), mp3Encoder: LAMEEncoder())
        try writer.write(buffer)
        try writer.finish()

        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes[bytes.startIndex], 0xFF, "expected a raw MP3 frame sync byte from LAME, not Glint's own header")
    }
}
