import XCTest
import AVFoundation

@testable import TonearmDJ

final class AudioDecoderTests: XCTestCase {

    private func makeToneURL(name: String, seconds: Double = 1.0,
                             sampleRate: Int = 8_000, amplitude: Float = 0.25) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioDecoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)

        let frameCount = Int(Double(sampleRate) * seconds)
        var samples = [Int16](repeating: 0, count: frameCount)
        for i in 0..<frameCount {
            let t = Double(i) / Double(sampleRate)
            let value = amplitude * 32_767.0 * Float(sin(2 * Double.pi * 440 * t))
            samples[i] = Int16(value)
        }

        let headerSize = 44
        let bytes = samples.count * 2
        var data = Data(capacity: headerSize + bytes)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: littleEndian(UInt32(36 + bytes)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: littleEndian(UInt32(16)))
        data.append(contentsOf: littleEndian(UInt16(1)))          // PCM
        data.append(contentsOf: littleEndian(UInt16(1)))          // mono
        data.append(contentsOf: littleEndian(UInt32(sampleRate)))
        data.append(contentsOf: littleEndian(UInt32(sampleRate * 2)))
        data.append(contentsOf: littleEndian(UInt16(2)))          // block align
        data.append(contentsOf: littleEndian(UInt16(16)))         // bits
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: littleEndian(UInt32(bytes)))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }

        try data.write(to: url)
        return url
    }

    private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
        return bytes
    }

    func testDecode8kMonoTo48k() throws {
        let url = try makeToneURL(name: "tone.wav", seconds: 1.0, sampleRate: 8_000)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let pcm = try AudioDecoder.decode(url)
        XCTAssertEqual(pcm.sampleRate, 48_000)
        XCTAssertEqual(pcm.channelCount, 1)
        // 1 s at 48 kHz.
        XCTAssertEqual(Double(pcm.frameCount) / 48_000, 1.0, accuracy: 0.05)
        XCTAssertEqual(pcm.mono.count, pcm.frameCount)
    }

    func testDecodeStereoKeepsTwoChannels() throws {
        // Build an interleaved stereo WAV manually.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioDecoderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("stereo.wav")
        defer { try? FileManager.default.removeItem(at: dir) }

        let sampleRate = 8_000
        let frames = sampleRate / 2
        var data = Data(capacity: 44 + frames * 4)
        let bytes = frames * 4
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: littleEndian(UInt32(36 + bytes)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: littleEndian(UInt32(16)))
        data.append(contentsOf: littleEndian(UInt16(1)))
        data.append(contentsOf: littleEndian(UInt16(2)))          // stereo
        data.append(contentsOf: littleEndian(UInt32(sampleRate)))
        data.append(contentsOf: littleEndian(UInt32(sampleRate * 4)))
        data.append(contentsOf: littleEndian(UInt16(4)))
        data.append(contentsOf: littleEndian(UInt16(16)))
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: littleEndian(UInt32(bytes)))
        for _ in 0..<frames {
            data.append(contentsOf: littleEndian(Int16(8_000)))   // L
            data.append(contentsOf: littleEndian(Int16(-8_000)))  // R
        }
        try data.write(to: url)

        let pcm = try AudioDecoder.decode(url)
        XCTAssertEqual(pcm.channelCount, 2)
        XCTAssertEqual(pcm.channels.count, 2)
        XCTAssertEqual(pcm.channels[0].count, pcm.frameCount)
        XCTAssertEqual(pcm.channels[1].count, pcm.frameCount)
    }

    func testDecodeMissingFileThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/does-not-exist.wav")
        XCTAssertThrowsError(try AudioDecoder.decode(missing))
    }
}
