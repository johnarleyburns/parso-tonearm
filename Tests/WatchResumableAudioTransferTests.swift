import Foundation
import AVFoundation
import Synchronization
import SwiftData
import XCTest
import TonearmCore
import TonearmWatchCore
import TonearmWatchProtocol

final class WatchResumableAudioTransferTests: XCTestCase {
    func testBackgroundRelaunchRemembersChunkCapabilityOnlyForTheSamePairedWatch() async {
        let suite = "watch-capabilities-" + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let first = PhoneWatchNegotiatedCapabilities(suiteName: suite, watchIdentifier: { "watch-a" })
        let unknown = await first.supports(.resumableAudioChunks)
        XCTAssertFalse(unknown)
        await first.set([.resumableAudioChunks])
        let relaunched = PhoneWatchNegotiatedCapabilities(suiteName: suite, watchIdentifier: { "watch-a" })
        let remembered = await relaunched.supports(.resumableAudioChunks)
        XCTAssertTrue(remembered)
        let other = PhoneWatchNegotiatedCapabilities(suiteName: suite, watchIdentifier: { "watch-b" })
        let reused = await other.supports(.resumableAudioChunks)
        XCTAssertFalse(reused)
        await relaunched.set([])
        let revoked = await first.supports(.resumableAudioChunks)
        // A fresh process must see the capability removal, not an old in-memory negotiation.
        let fresh = PhoneWatchNegotiatedCapabilities(suiteName: suite, watchIdentifier: { "watch-a" })
        let freshValue = await fresh.supports(.resumableAudioChunks)
        XCTAssertFalse(freshValue)
        XCTAssertTrue(revoked, "The first actor still represents its original live negotiation")
    }
    func testAcknowledgedChunkStillOwnedBySystemDoesNotOpenAnotherTransferSlot() async throws {
        let fx = try ChunkFixture(bytes: 2_000_000)
        defer { fx.clean() }
        let owned = Mutex<[WatchAudioChunkMetadata]>([])
        let sender = PhoneWatchResumableAudioTransfer(directory: fx.root.appendingPathComponent("phone"),
            transport: fx.transport, systemTransfers: { owned.withLock { $0 } })
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        let first = await fx.transport.files[0]
        owned.withLock { $0 = [first.metadata] }
        _ = await fx.receive(first)
        try await sender.ingestManifest(fx.manifest(await fx.assembler.partialDownloads(), at: 1))
        let held = await fx.transport.files.count
        XCTAssertEqual(held, 1)
        owned.withLock { $0.removeAll() }
        await sender.deliveryFinished(first.metadata, error: nil)
        await sender.tick()
        let next = await fx.transport.files.last!
        XCTAssertEqual(next.metadata.index, 1)
    }

    func testRemovalDiscardsPartialBytesAndRejectsLateDeliveryUntilRequestedAgain() async throws {
        let fx = try ChunkFixture(bytes: 2_000_000)
        defer { fx.clean() }
        let sender = fx.sender()
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        let first = await fx.transport.files[0]
        _ = await fx.receive(first)
        await fx.assembler.remove(trackIDs: ["track"], tombstone: true)
        let restored = WatchAudioChunkAssembler(directory: fx.watchDirectory)
        let late = await fx.receive(first, using: restored)
        guard case .rejected = late else { return XCTFail("Removed download resurrected") }
        let receipts = await restored.partialDownloads()
        XCTAssertTrue(receipts.isEmpty)
        await restored.allow(trackIDs: ["track"])
        let requestedAgain = await fx.receive(first, using: restored)
        guard case .retained = requestedAgain else { return XCTFail("Explicit new request must work") }
    }
    func testWatchCrashAfterLastCheckpointCanFinishAssemblyWithoutRedownloading() async throws {
        let fx = try ChunkFixture(bytes: 20)
        defer { fx.clean() }
        let sender = fx.sender()
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        let first = await fx.receive(await fx.transport.files[0])
        guard case .assembled(let uninstalled, _) = first else { return XCTFail("Expected complete chunks") }
        let restarted = WatchAudioChunkAssembler(directory: fx.watchDirectory)
        let outcomes = await restarted.resumeCompleted()
        XCTAssertFalse(FileManager.default.fileExists(atPath: uninstalled.path), "Orphan assembly must not accumulate storage")
        guard case .assembled(let recovered, _) = outcomes.first else { return XCTFail("Did not recover final assembly") }
        XCTAssertEqual(try WatchFileDigest.measure(recovered).sha256, fx.audio.sha256)
    }
    func testProductionWatchRouteInstallsCompleteFileAndMakesOfflinePlaybackAvailable() async throws {
        let original = try XCTUnwrap(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        let fx = try ChunkFixture(bytes: 0, audioBytes: Data(contentsOf: original), fileExtension: "wav")
        defer { fx.clean() }
        let audioDirectory = fx.root.appendingPathComponent("installed")
        let repository = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(), audioDirectory: audioDirectory)
        let installer = WatchFileInstaller(repository: repository, audioDirectory: audioDirectory,
            stagingDirectory: fx.root.appendingPathComponent("staging"))
        let sync = WatchSyncActor(repository: repository, installer: installer, chunkAssembler: fx.assembler)
        let link = WatchFakeDuplexLink()
        let fanout = WatchFanoutObserver([sync])
        defer { withExtendedLifetime(fanout) {} }
        let coordinator = WatchConnectivityCoordinator(transport: link.transport(for: .watch), observer: fanout)
        await sync.setCoordinator(coordinator)
        await coordinator.activate(reachable: false)
        await sync.didReceiveCatalogPage(.init(catalogID: "catalog", revision: 1, pageIndex: 0, pageCount: 1,
            tracks: [.init(trackID: "track", title: "Fred Again")], playlists: []))
        let sender = fx.sender()
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        let count = Int((fx.audio.expectedBytes - 1) / Int64(WatchAudioChunkPolicy.defaultChunkBytes) + 1)
        for index in 0..<count {
            let files = await fx.transport.files
            guard files.indices.contains(index) else { return XCTFail("Missing next chunk after acknowledgement") }
            let file = files[index]
            let staged = fx.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: file.url, to: staged)
            await coordinator.receiveFile(staged, metadata: file.metadata.dictionary)
            let manifest = try await repository.manifest()
            if index == 0 { XCTAssertTrue(manifest.readyTrackIDs.isEmpty, "A partial file must never be playable") }
            var report = fx.manifest(await fx.assembler.partialDownloads(), at: index + 1)
            report.readyTrackIDs = manifest.readyTrackIDs.map(WatchTrackID.init)
            report.installedBytes = manifest.installedBytes
            try await sender.ingestManifest(report)
        }
        let manifest = try await repository.manifest()
        XCTAssertEqual(manifest.readyTrackIDs, ["track"])
        XCTAssertEqual(manifest.installedBytes, fx.audio.expectedBytes)
        let tracks = try await repository.tracks(readyOnly: true)
        let track = try XCTUnwrap(tracks.first)
        let local = audioDirectory.appendingPathComponent(try XCTUnwrap(track.localFilename))
        XCTAssertEqual(try WatchFileDigest.measure(local).sha256, fx.audio.sha256)
        let decoded = try AVAudioFile(forReading: local)
        XCTAssertGreaterThan(decoded.length, 0, "The installed asset must remain decodable audio")
        XCTAssertEqual(decoded.length, try AVAudioFile(forReading: original).length)
        var player = WatchPlayerEngine(queue: ["track"])
        let directives = player.command(.play, urlForTrack: { $0 == "track" ? local : nil })
        XCTAssertEqual(directives, [.loadItem(local), .play])
        let remaining = await fx.assembler.partialDownloads()
        XCTAssertTrue(remaining.isEmpty)
        let outstanding = await sender.activeTrackIDs()
        XCTAssertTrue(outstanding.isEmpty)
    }

    func testWatchRejectionBecomesVisibleFailureWithoutDiscardingSavedProgress() async throws {
        let fx = try ChunkFixture(bytes: 3_000_000)
        defer { fx.clean() }
        let sender = fx.sender()
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        _ = await fx.receive(await fx.transport.files[0])
        var manifest = fx.manifest(await fx.assembler.partialDownloads(), at: 1)
        manifest.audioDownloadFailures = ["track": .insufficientWatchStorage]
        try await sender.ingestManifest(manifest)
        let progress = await sender.progress()["track"]
        XCTAssertEqual(progress?.checkpoint.retainedBytes, 1_048_576)
        let before = await fx.transport.files.count
        await sender.tick()
        let after = await fx.transport.files.count
        XCTAssertEqual(after, before, "A rejected track must wait for retry, not loop silently")
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        let retry = await fx.transport.files.last!
        XCTAssertEqual(retry.metadata.index, 1)
    }
    func testProductionPolicyIsOneUnconfirmedOneMiBChunkGlobally() async throws {
        XCTAssertEqual(WatchAudioChunkPolicy.defaultChunkBytes, 1_048_576)
        XCTAssertEqual(WatchAudioChunkPolicy.maximumUnconfirmedChunks, 1)
        let fx = try ChunkFixture(bytes: 3 * 1_048_576 + 17)
        defer { fx.clean() }
        let sender = fx.sender()
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        var second = fx.audio; second.trackID = "other"
        try await sender.begin(fileURL: fx.source, audio: second)
        await sender.tick()
        let sent = await fx.transport.files
        XCTAssertEqual(sent.count, 1, "The window is global, not one chunk per track")
        XCTAssertEqual(try Data(contentsOf: sent[0].url).count, 1_048_576)
        _ = await fx.receive(sent[0])
        await sender.deliveryFinished(sent[0].metadata, error: nil)
        await sender.tick()
        let afterDelivery = await fx.transport.files.count
        XCTAssertEqual(afterDelivery, 1, "Native completion is not a durable watch acknowledgement")
        let progress = await sender.progress()["track"]
        XCTAssertEqual(progress?.checkpoint.retainedBytes, 0)
        XCTAssertEqual(progress?.stage, .awaitingChunkConfirmation)
        try await sender.ingestManifest(fx.manifest(await fx.assembler.partialDownloads(), at: 1))
        let afterAck = await fx.transport.files.count
        XCTAssertEqual(afterAck, 2)
    }

    func testHundredMiBTransferResumesAtFiftyPercentAfterBothAppsRestart() async throws {
        let fx = try ChunkFixture(bytes: 100 * 1_048_576)
        defer { fx.clean() }
        var sender = fx.sender()
        var assembler = fx.assembler
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        for index in 0..<50 {
            let file = await fx.transport.files[index]
            let outcome = await fx.receive(file, using: assembler)
            guard case .retained = outcome else { return XCTFail("Unexpected outcome at chunk \(index)") }
            await sender.deliveryFinished(file.metadata, error: nil)
            try await sender.ingestManifest(fx.manifest(await assembler.partialDownloads(), at: index + 1))
        }
        let halfway = await assembler.partialDownloads()
        XCTAssertEqual(halfway.first?.retainedBytes, 50 * 1_048_576)
        XCTAssertEqual(halfway.first?.fractionRetained, 0.5)
        await sender.suspend(trackID: "track")
        sender = fx.sender()
        assembler = WatchAudioChunkAssembler(directory: fx.watchDirectory)
        let recovered = await assembler.partialDownloads()
        XCTAssertEqual(recovered, halfway)
        try await sender.ingestManifest(fx.manifest(recovered, at: 51))
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        let resumed = await fx.transport.files.last!
        XCTAssertEqual(resumed.metadata.index, 50, "Must not start over from chunk zero")
        var final: URL?
        for index in 50..<100 {
            let file = await fx.transport.files.last!
            XCTAssertEqual(file.metadata.index, index)
            let outcome = await fx.receive(file, using: assembler)
            if case .assembled(let url, let audio) = outcome { final = url; XCTAssertEqual(audio, fx.audio) }
            await sender.deliveryFinished(file.metadata, error: nil)
            try await sender.ingestManifest(fx.manifest(await assembler.partialDownloads(), at: index + 2))
        }
        let digest = try WatchFileDigest.measure(XCTUnwrap(final))
        XCTAssertEqual(digest.bytes, 100 * 1_048_576)
        XCTAssertEqual(digest.sha256, fx.audio.sha256)
        let all = await fx.transport.files
        XCTAssertEqual(all.filter { $0.metadata.index == 0 }.count, 1)
    }

    func testMissingAcknowledgementRetriesOnlyUnconfirmedChunkAndIgnoresLateFailure() async throws {
        let fx = try ChunkFixture(bytes: 2_000_000)
        defer { fx.clean() }
        let clock = ChunkClock()
        let sender = fx.sender(now: { clock.date })
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        let first = await fx.transport.files[0]
        _ = await fx.receive(first)
        await sender.deliveryFinished(first.metadata, error: nil)
        clock.advance(301)
        await sender.tick()
        let retry = await fx.transport.files[1]
        XCTAssertEqual(retry.metadata.index, 0)
        XCTAssertNotEqual(retry.metadata.transferID, first.metadata.transferID)
        let accepted = await sender.deliveryFinished(first.metadata, error: .transferFailed)
        XCTAssertFalse(accepted)
        _ = await fx.receive(retry)
        try await sender.ingestManifest(fx.manifest(await fx.assembler.partialDownloads(), at: 1))
        let next = await fx.transport.files.last!
        XCTAssertEqual(next.metadata.index, 1)
        try await sender.ingestManifest(fx.manifest([], at: 0))
        let progress = await sender.progress()["track"]
        XCTAssertEqual(progress?.checkpoint.retainedBytes, 1_048_576, "An old report cannot erase checkpoints")
    }

    func testFreshPhoneJournalAdoptsWatchCheckpointsInsteadOfStartingOver() async throws {
        let fx = try ChunkFixture(bytes: 2_000_000)
        defer { fx.clean() }
        let first = fx.sender()
        try await first.begin(fileURL: fx.source, audio: fx.audio)
        _ = await fx.receive(await fx.transport.files[0])
        let fresh = PhoneWatchResumableAudioTransfer(directory: fx.root.appendingPathComponent("new-phone"), transport: fx.transport)
        try await fresh.ingestManifest(fx.manifest(await fx.assembler.partialDownloads(), at: 1))
        try await fresh.begin(fileURL: fx.source, audio: fx.audio)
        let next = await fx.transport.files.last!
        XCTAssertEqual(next.metadata.index, 1)
    }

    func testCorruptCheckpointOnDiskLosesOnlyThatPieceAfterRelaunch() async throws {
        let fx = try ChunkFixture(bytes: 4_000_000)
        defer { fx.clean() }
        let sender = fx.sender()
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        for index in 0..<2 {
            _ = await fx.receive(await fx.transport.files[index])
            try await sender.ingestManifest(fx.manifest(await fx.assembler.partialDownloads(), at: index + 1))
        }
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: fx.watchDirectory, includingPropertiesForKeys: nil).first)
        try Data("corrupt".utf8).write(to: folder.appendingPathComponent("0.chunk"))
        let recovered = WatchAudioChunkAssembler(directory: fx.watchDirectory)
        let receipts = await recovered.partialDownloads()
        XCTAssertEqual(receipts.first?.receivedChunkIndexes, [1])
        await sender.suspend(trackID: "track")
        try await sender.ingestManifest(fx.manifest(receipts, at: 3))
        try await sender.begin(fileURL: fx.source, audio: fx.audio)
        let next = await fx.transport.files.last!
        XCTAssertEqual(next.metadata.index, 0)
    }

    func testOutOfOrderDuplicateAndCorruptChunksNeverProduceCorruptCompleteAudio() async throws {
        let fx = try ChunkFixture(bytes: 2_000_000)
        defer { fx.clean() }
        let bytes = try Data(contentsOf: fx.source)
        func piece(_ index: Int) throws -> ChunkRecordingTransport.File {
            let start = index * 1_048_576
            let data = bytes.subdata(in: start..<min(bytes.count, start + 1_048_576))
            let url = fx.root.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            return .init(url: url, metadata: WatchAudioChunkMetadata(audio: fx.audio, chunkBytes: 1_048_576,
                index: index, chunkSHA256: WatchFileDigest.hex(data)))
        }
        _ = await fx.receive(try piece(1))
        _ = await fx.receive(try piece(1))
        var receipt = await fx.assembler.partialDownloads()
        XCTAssertEqual(receipt.first?.receivedChunkIndexes, [1])
        let bad = try piece(0)
        try Data("bad".utf8).write(to: bad.url)
        let rejected = await fx.receive(bad)
        guard case .rejected(_, let fault) = rejected else { return XCTFail("Corrupt chunk accepted") }
        XCTAssertEqual(fault.code, .checksumMismatch)
        receipt = await fx.assembler.partialDownloads()
        XCTAssertEqual(receipt.first?.receivedChunkIndexes, [1])
        let complete = await fx.receive(try piece(0))
        guard case .assembled(let url, _) = complete else { return XCTFail("Did not assemble") }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testChunkMetadataCannotBeMisinterpretedAsLegacyWholeAudio() throws {
        let fx = try ChunkFixture(bytes: 20)
        defer { fx.clean() }
        let metadata = WatchAudioChunkMetadata(audio: fx.audio, chunkBytes: 1_048_576, index: 0, chunkSHA256: fx.audio.sha256!)
        XCTAssertEqual(WatchAudioChunkMetadata(dictionary: metadata.dictionary), metadata)
        XCTAssertNil(WatchAudioFileMetadata(dictionary: metadata.dictionary))
        var malformed = metadata.dictionary; malformed["chunkBytes"] = "0"
        XCTAssertNil(WatchAudioChunkMetadata(dictionary: malformed))
        malformed = metadata.dictionary; malformed["chunkIndex"] = "-1"
        XCTAssertNil(WatchAudioChunkMetadata(dictionary: malformed))
        malformed = metadata.dictionary; malformed["chunkSHA256"] = "bad"
        XCTAssertNil(WatchAudioChunkMetadata(dictionary: malformed))
    }
}

private struct ChunkFixture: Sendable {
    let root: URL
    let source: URL
    let watchDirectory: URL
    let transport: ChunkRecordingTransport
    let assembler: WatchAudioChunkAssembler
    let audio: WatchAudioFileMetadata
    init(bytes: Int, audioBytes: Data? = nil, fileExtension: String = "m4a") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-chunks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        source = root.appendingPathComponent("track." + fileExtension)
        try (audioBytes ?? Data(repeating: 0x5a, count: bytes)).write(to: source)
        let measured = try WatchFileDigest.measure(source)
        audio = WatchAudioFileMetadata(trackID: "track", expectedBytes: measured.bytes, sha256: measured.sha256, fileExtension: fileExtension)
        watchDirectory = root.appendingPathComponent("watch")
        assembler = WatchAudioChunkAssembler(directory: watchDirectory)
        transport = ChunkRecordingTransport()
    }
    func sender(now: @escaping @Sendable () -> Date = { Date() }) -> PhoneWatchResumableAudioTransfer {
        PhoneWatchResumableAudioTransfer(directory: root.appendingPathComponent("phone"), transport: transport, now: now)
    }
    func receive(_ file: ChunkRecordingTransport.File, using assembler: WatchAudioChunkAssembler? = nil) async -> WatchAudioChunkOutcome {
        let inbox = root.appendingPathComponent(UUID().uuidString)
        do { try FileManager.default.copyItem(at: file.url, to: inbox) }
        catch { return .rejected(nil, .init(code: .transferFailed)) }
        return await (assembler ?? self.assembler).receive(stagedURL: inbox, metadata: file.metadata.dictionary)
    }
    func manifest(_ receipts: [WatchPartialAudioDownload], at: Int) -> WatchManifestPayload {
        .init(manifestID: "receipt-\(at)", readyTrackIDs: [], installedBytes: 0,
              generatedAt: Date(timeIntervalSince1970: Double(at)), partialAudioDownloads: receipts)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

private actor ChunkRecordingTransport: WatchProtocolTransport {
    struct File: Sendable { let url: URL; let metadata: WatchAudioChunkMetadata }
    private(set) var files: [File] = []
    func isReachable() -> Bool { true }
    func sendImmediate(_ data: Data) -> Data { Data() }
    func updateApplicationContext(_ data: Data) {}
    func transferUserInfo(_ data: Data) {}
    func transferFile(_ url: URL, metadata: [String: String]) throws {
        guard let chunk = WatchAudioChunkMetadata(dictionary: metadata) else { throw WatchProtocolFault(code: .installationFailed) }
        files.append(.init(url: url, metadata: chunk))
    }
}

private final class ChunkClock: Sendable {
    private let value = Synchronization.Mutex(Date(timeIntervalSince1970: 1000))
    var date: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
