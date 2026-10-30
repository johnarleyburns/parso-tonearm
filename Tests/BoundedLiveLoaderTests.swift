#if !os(watchOS)
import AVFoundation
import ParsoAudioCore
import XCTest
@testable import TonearmCore

final class BoundedLiveLoaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("BoundedLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func tone(_ name: String, seconds: Double, rate: Double = 22_050, settings: [String: Any]? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: settings ?? format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * rate), block = 8_192
        var written = 0
        while written < total {
            let n = min(block, total - written)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            for f in 0..<n {
                let v = Float(0.5 * sin(2 * Double.pi * 440 * Double(written + f) / rate))
                buffer.floatChannelData![0][f] = v; buffer.floatChannelData![1][f] = -v
            }
            try file.write(from: buffer)
            written += n
        }
        return url
    }

    func testWindowedDecodeMatchesContentForWAVAndAIFF() throws {
        for name in ["a.wav", "a.aiff", "a.caf"] {
            let url = try tone(name, seconds: 3)
            let before = FileRangeAudioSource.rangeCallCount
            let pcm = try MixTrackLoader.decode(url, container: .auto)
            XCTAssertGreaterThan(FileRangeAudioSource.rangeCallCount, before, name)
            XCTAssertEqual(pcm.frameCount, 3 * 22_050, name)
            XCTAssertEqual(pcm.channel(0)[100], 0.5 * Float(sin(2 * Double.pi * 440 * 100 / 22_050)), accuracy: 1e-3, name)
            XCTAssertEqual(pcm.channel(1)[100], -pcm.channel(0)[100], accuracy: 1e-6, name)
        }
    }

    func testAACInM4ADecodesThroughWindows() throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100.0,
                                       AVNumberOfChannelsKey: 2]
        let url = try tone("a.m4a", seconds: 3, rate: 44_100, settings: settings)
        let source = try FileRangeAudioSource.open(url: url, container: .auto)
        XCTAssertTrue(source.supportsRangeAccess)
        let pcm = try MixTrackLoader.decode(url, container: .auto)
        XCTAssertEqual(Double(pcm.frameCount), 3 * 44_100, accuracy: 4_096)
    }

    func testLoaderSourceNoLongerCallsReadAll() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Audio/MixDecks/MixTrackLoader.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("readAll()"))
        XCTAssertFalse(text.contains("AudioFileReader("))
    }

    func testLongSparseFileIsWindowedAndRejectedWithoutDecoding() throws {
        // 3 hours of 8 kHz mono 16-bit PCM WAV as a sparse file: header + truncated length.
        let rate = 8_000, seconds = 3 * 3600, dataBytes = rate * seconds * 2
        var header = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; header.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; header.append(Data(bytes: &x, count: 2)) }
        header.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes); header.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        header.append("data".data(using: .ascii)!); u32(dataBytes)
        let url = dir.appendingPathComponent("long.wav")
        try header.write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(44 + dataBytes))
        try handle.close()

        let source = try FileRangeAudioSource.open(url: url, container: .wav)
        XCTAssertEqual(source.totalFrames, Int64(rate * seconds))
        let tail = try source.decodeRange(startFrame: source.totalFrames - 1_000, frameCount: 10_000)
        XCTAssertEqual(tail.count, 1_000)   // bounded: only the requested tail was read

        let before = FileRangeAudioSource.rangeCallCount
        XCTAssertThrowsError(try MixTrackLoader.decode(url, container: .wav)) {
            XCTAssertEqual($0 as? MixTrackLoaderError, .tooLong(seconds))
        }
        XCTAssertEqual(FileRangeAudioSource.rangeCallCount, before + 1, "only the one-frame capability probe ran")
    }

    func testResidentBytesDoNotGrowWithDuration() throws {
        let short = try tone("s.wav", seconds: 2), longer = try tone("l.wav", seconds: 8)
        let a = try FileRangeAudioSource.open(url: short, container: .wav)
        let b = try FileRangeAudioSource.open(url: longer, container: .wav)
        // Each window request owns at most the requested frames, whatever the file length.
        let wa = try a.decodeRange(startFrame: 0, frameCount: 4_096)
        let wb = try b.decodeRange(startFrame: 0, frameCount: 4_096)
        XCTAssertEqual(wa.count, wb.count)
        XCTAssertEqual(wa.count, 4_096 * 2)
    }

    func testUnsupportedContainerIsRejectedNotWholeDecoded() throws {
        let url = dir.appendingPathComponent("x.ogg")
        try Data(repeating: 1, count: 64).write(to: url)
        XCTAssertThrowsError(try MixTrackLoader.decode(url, container: .oggVorbis)) {
            XCTAssertEqual($0 as? MixTrackLoaderError, .unsupportedBoundedDecode(.oggVorbis))
        }
    }

    func testDeniedScopeNeverDecodesAndLeaseCountBalances() async throws {
        let missing = dir.appendingPathComponent("gone.wav")
        let baseline = SourceAccessLease.activeCount
        do {
            _ = try await MixTrackLoader.load(trackID: 1, source: .file(missing, container: .wav, securityScoped: true),
                                              approximateBPM: 120, sampleRate: 44_100) { _ in }
            XCTFail("expected denial")
        } catch {
            XCTAssertEqual(error as? MixTrackLoaderError, .fileMissing)
        }
        XCTAssertEqual(SourceAccessLease.activeCount, baseline)
        let url = try tone("ok.wav", seconds: 3)
        let lease = try SourceAccessLease(url: url, securityScoped: true, startAccess: { _ in true })
        XCTAssertEqual(SourceAccessLease.activeCount, baseline + 1)
        lease.release(); lease.release()
        XCTAssertEqual(SourceAccessLease.activeCount, baseline)
    }

    func testMissingFileIsDistinctFromDenialAndNeverDecodes() async throws {
        let missing = dir.appendingPathComponent("moved.wav")
        do {
            _ = try await MixTrackLoader.load(trackID: 1, source: .file(missing, container: .wav, securityScoped: false),
                                              approximateBPM: 120, sampleRate: 44_100) { _ in }
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? MixTrackLoaderError, .fileMissing)
        }
    }

    func testDeniedScopeThrowsEvenWhenFileIsReadable() throws {
        let url = try tone("inj.wav", seconds: 1)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: url.path))
        let baseline = SourceAccessLease.activeCount
        var requestedURL: URL?
        XCTAssertThrowsError(try SourceAccessLease(url: url, securityScoped: true, startAccess: {
            requestedURL = $0
            return false
        })) {
            XCTAssertEqual($0 as? MixTrackLoaderError, .accessDenied)
        }
        XCTAssertEqual(requestedURL, url)
        XCTAssertEqual(SourceAccessLease.activeCount, baseline)

        let lease = try SourceAccessLease(url: url, securityScoped: false, startAccess: { _ in false })
        XCTAssertEqual(SourceAccessLease.activeCount, baseline + 1)
        lease.release(); lease.release()
        XCTAssertEqual(SourceAccessLease.activeCount, baseline)
    }

    func testMissingFileClassificationAndLeaseCountWithEitherScopeResult() throws {
        let missing = dir.appendingPathComponent("missing.wav")
        for granted in [false, true] {
            let baseline = SourceAccessLease.activeCount
            XCTAssertThrowsError(try SourceAccessLease(url: missing, securityScoped: true,
                                                       startAccess: { _ in granted })) {
                XCTAssertEqual($0 as? MixTrackLoaderError, .fileMissing)
            }
            XCTAssertEqual(SourceAccessLease.activeCount, baseline)
        }
    }

    func testUnreadableAppOwnedFileThrowsAndLeaseCountBalances() throws {
        let url = try tone("unreadable.wav", seconds: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: url.path), "File permissions do not prevent this user from reading")
        let baseline = SourceAccessLease.activeCount
        XCTAssertThrowsError(try SourceAccessLease(url: url, securityScoped: false, startAccess: { _ in false })) {
            XCTAssertEqual($0 as? MixTrackLoaderError, .accessDenied)
        }
        XCTAssertEqual(SourceAccessLease.activeCount, baseline)
    }

    func testGrantedScopeForUnreadableFileThrowsAndLeaseCountBalances() throws {
        let url = try tone("granted-unreadable.wav", seconds: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: url.path), "File permissions do not prevent this user from reading")
        let baseline = SourceAccessLease.activeCount
        XCTAssertThrowsError(try SourceAccessLease(url: url, securityScoped: true, startAccess: { _ in true })) {
            XCTAssertEqual($0 as? MixTrackLoaderError, .accessDenied)
        }
        XCTAssertEqual(SourceAccessLease.activeCount, baseline)
    }
}
#endif
