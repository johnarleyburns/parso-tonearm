import XCTest
import AVFoundation
import TonearmWatchCore
import TonearmWatchProtocol
@testable import TonearmCore

/// Exercises the real AVPlayerItem state machine on the host. AVAudioSession itself is an iOS/watchOS
/// service and is therefore exercised by WatchSmokeUITests plus the on-device audio pass.
@MainActor
final class WatchAVPlayerItemTests: XCTestCase {
    func testInboxSaveFailureReportsCurrentAttemptWithoutClaimingInstalledAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(), audioDirectory: root.appendingPathComponent("watch"))
        let installer = WatchFileInstaller(repository: repository, audioDirectory: root.appendingPathComponent("watch"), stagingDirectory: root.appendingPathComponent("stage"))
        let sync = WatchSyncActor(repository: repository, installer: installer, requiresNormalizedAAC: true)
        let fanout = WatchFanoutObserver([sync])
        defer { withExtendedLifetime(fanout) {} }
        let transport = WholeAACRecordingTransport()
        let coordinator = WatchConnectivityCoordinator(transport: transport, observer: fanout)
        await sync.setCoordinator(coordinator)
        let metadata = WatchAudioFileMetadata(trackID: "failed", expectedBytes: 100, codec: "aac", fileExtension: "m4a", transferID: "current-attempt")
        await coordinator.receiveFileFailure(metadata: metadata.dictionary, code: .installationFailed)
        let reports = await transport.reportedManifests
        XCTAssertEqual(reports.last?.audioDownloadFailures["failed"], .installationFailed)
        XCTAssertEqual(reports.last?.audioFailureTransferIDs["failed"], "current-attempt")
        XCTAssertEqual(reports.last?.readyTrackIDs, [])
        XCTAssertEqual(reports.last?.installedBytes, 0)
    }
    func testProductionAssembliesUseWholeAACRouteAndNeverInstantiateChunkActors() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let phone = try String(contentsOf: repository.appendingPathComponent("Sources/App/Watch/PhoneWatchRuntime.swift"), encoding: .utf8)
        let watch = try String(contentsOf: repository.appendingPathComponent("WatchApp/App/WatchAppAssembly.swift"), encoding: .utf8)
        let facade = try String(contentsOf: repository.appendingPathComponent("Sources/App/Watch/PhoneWatchDownloadAdapter.swift"), encoding: .utf8)
        XCTAssertFalse(phone.contains("PhoneWatchResumableAudioTransfer("))
        XCTAssertFalse(watch.contains("WatchAudioChunkAssembler("))
        XCTAssertFalse(watch.contains(".resumableAudioChunks"))
        XCTAssertTrue(watch.contains("observer: fan"), "A file delivered at activation must already have a receiver")
        let activation = try XCTUnwrap(phone.range(of: "func activate() async"))
        let activationBody = String(phone[activation.lowerBound...])
        let receiver = try XCTUnwrap(activationBody.range(of: "await inbound.connect(self)"))
        let native = try XCTUnwrap(activationBody.range(of: "protocolAdapter.activate()"))
        XCTAssertLessThan(receiver.lowerBound, native.lowerBound,
            "Early metadata and file callbacks must not arrive before the phone receiver is connected")
        XCTAssertTrue(watch.contains("requiresNormalizedAAC: true"))
        XCTAssertTrue(facade.contains("PhoneWatchAudioPreparation.transferWholeFile("))
        XCTAssertFalse(facade.contains("chunkSender"))
    }

    func testBundledWatchSimulatorFixtureIsRealAAC128() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("Resources/Audio/ambient-ocean-watch-aac128.m4a")
        let audio = try AVAudioFile(forReading: fixture)
        XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        let tracks = try await AVURLAsset(url: fixture).loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let rate = try await track.load(.estimatedDataRate)
        XCTAssertEqual(Double(rate), 128_000, accuracy: 8_000)
        XCTAssertGreaterThan(audio.length, 44_100 * 20, "The real fixture must be long enough for advancing/pause assertions")
    }
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
        XCTAssertLessThan(actual.bytes, expected.bytes)
        XCTAssertNotEqual(actual.sha256, expected.sha256)
        XCTAssertEqual(prepared.pathExtension, "m4a")
        let encoded = try AVAudioFile(forReading: prepared)
        let format = encoded.fileFormat
        XCTAssertEqual(format.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
    }

    func testWholeAAC128UsesOneTransferFileAndPlaysRealCC0Audio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try XCTUnwrap(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        let prepared = try await PhoneWatchAudioPreparation.prepare(sourceURL: original, directory: root.appendingPathComponent("phone"))
        XCTAssertEqual(PhoneWatchAudioPreparation.bitRate, 128_000)
        let decoded = try AVAudioFile(forReading: prepared)
        XCTAssertEqual(decoded.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(decoded.fileFormat.channelCount, 2)
        XCTAssertEqual(decoded.fileFormat.sampleRate, 44_100)
        let encodedTracks = try await AVURLAsset(url: prepared).loadTracks(withMediaType: .audio)
        let encodedTrack = try XCTUnwrap(encodedTracks.first)
        let rate = try await encodedTrack.load(.estimatedDataRate)
        XCTAssertEqual(Double(rate), 128_000, accuracy: 8_000)
        let digest = try WatchFileDigest.measure(prepared)
        let transport = WholeAACRecordingTransport()
        let metadata = WatchAudioFileMetadata(trackID: "cc0-ocean", expectedBytes: digest.bytes,
            sha256: digest.sha256, codec: "aac", fileExtension: "m4a")
        try await PhoneWatchAudioPreparation.transferWholeFile(prepared, metadata: metadata, transport: transport)
        let files = await transport.files
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first?.0, prepared)
        XCTAssertEqual(files.first?.1, metadata.dictionary)
        XCTAssertNil(WatchAudioChunkMetadata(dictionary: metadata.dictionary))
        let nonFileSends = await transport.nonFileSends
        XCTAssertEqual(nonFileSends, 0)
        let repository = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(), audioDirectory: root.appendingPathComponent("watch"))
        let installer = WatchFileInstaller(repository: repository, audioDirectory: root.appendingPathComponent("watch"),
            stagingDirectory: root.appendingPathComponent("stage"))
        try await repository.upsertTrack(.init(trackID: "cc0-ocean", title: "Ocean — Nox_Sound (CC0)"))
        let incoming = root.appendingPathComponent("incoming.m4a")
        try FileManager.default.copyItem(at: prepared, to: incoming)
        let sync = WatchSyncActor(repository: repository, installer: installer, requiresNormalizedAAC: true)
        let fanout = WatchFanoutObserver([sync])
        defer { withExtendedLifetime(fanout) {} }
        let link = WatchFakeDuplexLink()
        await link.setReachable(false)
        let coordinator = WatchConnectivityCoordinator(transport: link.transport(for: .watch), observer: fanout)
        await sync.setCoordinator(coordinator)
        // Deliver before activation, reproducing the background-startup timing edge.
        await coordinator.receiveFile(incoming, metadata: metadata.dictionary)
        let snapshot = try await repository.tracks(readyOnly: true).first
        let installed = root.appendingPathComponent("watch").appendingPathComponent(try XCTUnwrap(snapshot?.localFilename))
        let item = AVPlayerItem(url: installed)
        let player = AVPlayer(playerItem: item)
        player.play()
        let status = await waitForStatus(of: item)
        XCTAssertEqual(status, .readyToPlay)
        XCTAssertGreaterThan(item.duration.seconds, 0)
        player.pause()
        if let output = ProcessInfo.processInfo.environment["WATCH_AAC_FIXTURE_OUTPUT"] {
            try FileManager.default.copyItem(at: prepared, to: URL(fileURLWithPath: output))
        }
    }

    func testProductionWatchRejectsUnconvertedLegacyWholeAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        let incoming = root.appendingPathComponent("legacy.wav")
        try FileManager.default.copyItem(at: source, to: incoming)
        let digest = try WatchFileDigest.measure(incoming)
        let repository = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(), audioDirectory: root.appendingPathComponent("watch"))
        try await repository.upsertTrack(.init(trackID: "legacy", title: "Legacy"))
        let installer = WatchFileInstaller(repository: repository, audioDirectory: root.appendingPathComponent("watch"),
            stagingDirectory: root.appendingPathComponent("stage"))
        let diagnostics = WatchDiagnosticsRecorder()
        let sync = WatchSyncActor(repository: repository, installer: installer,
            requiresNormalizedAAC: true, diagnostics: diagnostics)
        await sync.didReceiveAudioFile(at: incoming, metadata: WatchAudioFileMetadata(trackID: "legacy", expectedBytes: digest.bytes,
            sha256: digest.sha256, codec: "wav", fileExtension: "wav").dictionary)
        let installed = try await repository.tracks(readyOnly: true)
        XCTAssertTrue(installed.isEmpty)
        let events = await diagnostics.events()
        XCTAssertEqual(events.last?.stateCode, "unsupportedAudio")
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

    func testFortyEightKHzMonoSourceIsNormalizedToStereoAAC128() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("48k-mono.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<24_000 { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) * 0.1 }
        do {
            let writer = try AVAudioFile(forWriting: source, settings: format.settings)
            try writer.write(from: buffer)
        }
        let prepared = try await PhoneWatchAudioPreparation.prepare(sourceURL: source, directory: root.appendingPathComponent("prepared"))
        let audio = try AVAudioFile(forReading: prepared)
        XCTAssertEqual(audio.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(audio.fileFormat.channelCount, 2)
        XCTAssertEqual(audio.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        XCTAssertEqual(Double(audio.length) / 44_100, 0.5, accuracy: 0.15)
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

private actor WholeAACRecordingTransport: WatchProtocolTransport {
    var files: [(URL, [String: String])] = []
    var nonFileSends = 0
    var reportedManifests: [WatchManifestPayload] = []
    func isReachable() -> Bool { false }
    func sendImmediate(_ data: Data) throws -> Data { nonFileSends += 1; throw WatchProtocolFault(code: .phoneUnavailable) }
    func updateApplicationContext(_ data: Data) { nonFileSends += 1 }
    func transferUserInfo(_ data: Data) {
        nonFileSends += 1
        if let envelope = try? WatchProtocolEnvelope.decode(data).get(), envelope.kind == .watchManifest,
           let manifest = try? envelope.decodePayload(WatchManifestPayload.self) {
            reportedManifests.append(manifest)
        }
    }
    func transferFile(_ url: URL, metadata: [String: String]) { files.append((url, metadata)) }
}
