import XCTest
import AVFoundation
import TonearmWatchCore
import TonearmWatchProtocol
@testable import TonearmCore

/// Exercises the real AVPlayerItem state machine on the host. AVAudioSession itself is an iOS/watchOS
/// service and is therefore exercised by WatchSmokeUITests plus the on-device audio pass.
@MainActor
final class WatchAVPlayerItemTests: XCTestCase {
    func testDocumentAccessCoversCopyAndBackgroundSnapshotSurvivesRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("document.wav")
        let bundled = try XCTUnwrap(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        let prepared = try await PhoneWatchAudioPreparation.prepare(
            sourceURL: external, directory: root.appendingPathComponent("owned"),
            startAccess: { url in
                // Model a provider that exposes bytes only while document access is held.
                try? FileManager.default.copyItem(at: bundled, to: url)
                return true
            },
            stopAccess: { url in try? FileManager.default.removeItem(at: url) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.path))
        let expected = try WatchFileDigest.measure(bundled)
        let actual = try WatchFileDigest.measure(prepared)
        XCTAssertEqual(actual.bytes, expected.bytes)
        XCTAssertEqual(actual.sha256, expected.sha256)
    }

    func testDocumentAccessIsReleasedWhenPreparationFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseMarker = root.appendingPathComponent("released")
        do {
            _ = try await PhoneWatchAudioPreparation.prepare(
                sourceURL: root.appendingPathComponent("missing.wav"), directory: root,
                startAccess: { _ in true },
                stopAccess: { _ in try? Data().write(to: releaseMarker) })
            XCTFail("Missing document must fail preparation")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: releaseMarker.path))
        }
    }

    func testFLACIsConvertedToPlayableWatchAAC() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("imported.flac")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100)) * 0.1 }
        do {
            let file = try AVAudioFile(forWriting: source, settings: [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16])
            try file.write(from: buffer)
        }
        let prepared = try await PhoneWatchAudioPreparation.prepare(
            sourceURL: source, directory: root.appendingPathComponent("owned"))
        XCTAssertEqual(prepared.pathExtension, "m4a")
        let decoded = try AVAudioFile(forReading: prepared)
        XCTAssertGreaterThan(decoded.length, 0)
        let item = AVPlayerItem(url: prepared)
        let player = AVPlayer(playerItem: item)
        player.play()
        let status = await waitForStatus(of: item)
        XCTAssertEqual(status, .readyToPlay)
        XCTAssertGreaterThan(item.duration.seconds, 0)
        player.pause()
        // Re-preparing unchanged content must preserve the background transfer's snapshot.
        let again = try await PhoneWatchAudioPreparation.prepare(
            sourceURL: source, directory: root.appendingPathComponent("owned"))
        XCTAssertEqual(again, prepared)
    }

    func testRealCachedAudioDefersInstallsAndPlaysOffline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-cache-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Match the production stream-cache blob name, which has no dotted extension.
        let cacheBlob = root.appendingPathComponent(String(repeating: "a", count: 64) + "-wav")
        let source = try XCTUnwrap(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        try FileManager.default.copyItem(at: source, to: cacheBlob)
        let audio = root.appendingPathComponent("audio")
        let repository = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(),
            audioDirectory: audio, artworkDirectory: root.appendingPathComponent("artwork"))
        let installer = WatchFileInstaller(repository: repository, audioDirectory: audio,
            stagingDirectory: root.appendingPathComponent("staging"))
        let measured = try WatchFileDigest.measure(cacheBlob)
        let metadata = WatchAudioFileMetadata(trackID: "cached", expectedBytes: measured.bytes,
            sha256: measured.sha256, fileExtension: WatchAudioFileMetadata.fileExtension(for: cacheBlob))
        let deferred = await installer.install(stagedURL: cacheBlob, metadata: metadata.dictionary)
        XCTAssertEqual(deferred, .deferredAwaitingMetadata(trackID: "cached"))
        try await repository.upsertTrack(.init(trackID: "cached", title: "Cached"))
        _ = await installer.retryDeferred()
        let readyTracks = try await repository.tracks(readyOnly: true)
        let track = try XCTUnwrap(readyTracks.first)
        let installed = audio.appendingPathComponent(try XCTUnwrap(track.localFilename))
        let item = AVPlayerItem(url: installed)
        let player = AVPlayer(playerItem: item)
        player.play()
        let status = await waitForStatus(of: item)
        XCTAssertEqual(status, .readyToPlay)
        XCTAssertGreaterThan(item.duration.seconds, 0)
        player.pause()
    }

    func testRealAVPlayerItemReachesReadyToPlayForRemuxedWatchAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-av-item-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let opus = root.appendingPathComponent("fixture.opus")
        try Fixtures.data("tone_mono", ext: "opus").write(to: opus)
        let caf = try await OpusRemuxer().remux(opusFileURL: opus, cacheKey: "watch-av-item")
        let item = AVPlayerItem(url: caf)
        let player = AVPlayer(playerItem: item)
        player.play()

        let status = await waitForStatus(of: item)

        XCTAssertEqual(status, .readyToPlay)
        let duration = item.duration
        XCTAssertTrue(duration.seconds.isFinite)
        XCTAssertGreaterThan(duration.seconds, 0)
    }

    func testRealAVPlayerItemReportsFailureForMalformedWatchAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-av-item-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let malformed = root.appendingPathComponent("fixture.opus")
        try Fixtures.data("corrupt_notogg", ext: "opus").write(to: malformed)
        let item = AVPlayerItem(url: malformed)
        let player = AVPlayer(playerItem: item)
        player.play()

        let status = await waitForStatus(of: item)

        XCTAssertEqual(status, .failed)
        XCTAssertNotNil(item.error)
    }

    private func waitForStatus(of item: AVPlayerItem) async -> AVPlayerItem.Status {
        // Keep this a bounded readiness assertion, but leave room for the
        // host suite's Core ML and media tests to contend for AVFoundation.
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if item.status != .unknown { return item.status }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return item.status
    }
}
