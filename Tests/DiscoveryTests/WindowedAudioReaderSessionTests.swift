#if !os(watchOS)
import AVFoundation
import XCTest
@testable import StarterGeneratorSupport

/// `LocalAnalysisReaderSession` (Phase C of the LeanAnalysis/indexing-efficiency pass) opens an
/// `AVAudioFile`/`AVAudioConverter` once and reuses them across a job's ~13 window reads, instead
/// of `WindowedAudioReader.readWindow(url:...)`'s open-fresh-every-call. The real risk of reuse:
/// `AVAudioConverter` carries internal resampling filter state across calls, which must not bleed
/// from one (possibly non-contiguous) window into the next. These tests pin that a session's
/// output is byte-identical to the non-reusing baseline for the exact same windows, read in a
/// deliberately out-of-order sequence.
/// A `@Sendable` closure cannot capture a mutable local `var` by reference; this tiny box lets
/// the test's `release` closure record that it ran without tripping that.
private final class ReleaseFlag: @unchecked Sendable {
    var value = false
}

final class WindowedAudioReaderSessionTests: XCTestCase {
    private func writeToneWAV(seconds: Double, to url: URL) throws {
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let totalFrames = Int((seconds * sampleRate).rounded())
        let chunkFrames = AVAudioFrameCount(sampleRate)
        var written = 0
        var phase = 0.0
        let increment = 2.0 * Double.pi * 330.0 / sampleRate
        while written < totalFrames {
            let n = min(Int(chunkFrames), totalFrames - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            let ch = buffer.floatChannelData![0]
            for i in 0..<n {
                ch[i] = Float(sin(phase) * 0.5)
                phase += increment
            }
            try file.write(from: buffer)
            written += n
        }
    }

    func testSessionReadsMatchFreshReadsForTheSameWindowsReadOutOfOrder() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("tone.wav")
        try writeToneWAV(seconds: 60, to: wav)

        let reader = WindowedAudioReader()
        // Deliberately non-contiguous and out of chronological order — the exact shape that
        // would expose stale `AVAudioConverter` filter state bleeding between calls.
        let windows: [(start: Double, length: Double)] = [
            (0, 10), (45, 10), (10, 10), (30, 5), (5, 5),
        ]
        let expected = try windows.map { w in
            try reader.readWindow(url: wav, startSeconds: w.start, windowSeconds: w.length)
        }

        let releaseFlag = ReleaseFlag()
        let session = try reader.openSession(url: wav, release: { releaseFlag.value = true })
        let actual = try windows.map { w in
            try session.readWindow(startSeconds: w.start, windowSeconds: w.length)
        }
        session.close()

        XCTAssertTrue(releaseFlag.value, "close() must run the release closure")
        XCTAssertEqual(expected.count, actual.count)
        for (i, (e, a)) in zip(expected, actual).enumerated() {
            XCTAssertEqual(e, a, "window \(i) (\(windows[i])) diverged between a fresh read and the session")
        }
    }

    func testSessionZeroPadsATailWindowPastEndOfFileSameAsAFreshRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("short.wav")
        try writeToneWAV(seconds: 4, to: wav)

        let reader = WindowedAudioReader()
        let expected = try reader.readWindow(url: wav, startSeconds: 0, windowSeconds: 10)

        let session = try reader.openSession(url: wav, release: {})
        let actual = try session.readWindow(startSeconds: 0, windowSeconds: 10)
        session.close()

        XCTAssertEqual(expected, actual)
        XCTAssertEqual(actual.count, Int(10 * reader.targetSampleRate))
    }
}
#endif
