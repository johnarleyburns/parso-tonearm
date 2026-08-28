import Foundation
import XCTest
@testable import TonearmWatchCore
import TonearmWatchProtocol

/// Phase 10e — the §12 diagnostics call sites in `WatchSyncActor` (install result, manifest
/// convergence) and `WatchDiagnosticsObserver` (activation, transfer state, route events).
final class WatchDiagnosticsWiringTests: XCTestCase {

    // MARK: - WatchSyncActor

    private struct SyncFixture {
        let root: URL
        let audio: URL
        let inbox: URL
        let repository: WatchLibraryRepository
        let installer: WatchFileInstaller
        let syncActor: WatchSyncActor
        let diagnostics: WatchDiagnosticsRecorder
        let link: WatchFakeDuplexLink
        /// Retained: `WatchSyncActor` holds its coordinator weakly.
        let coordinator: WatchConnectivityCoordinator

        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            audio = root.appendingPathComponent("audio")
            let staging = root.appendingPathComponent("staging")
            inbox = root.appendingPathComponent("inbox")
            for dir in [audio, staging, inbox] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let container = try WatchStoreBootstrap.inMemory()
            repository = WatchLibraryRepository(container: container, audioDirectory: audio)
            installer = WatchFileInstaller(repository: repository, audioDirectory: audio,
                                           stagingDirectory: staging)
            diagnostics = WatchDiagnosticsRecorder()
            link = WatchFakeDuplexLink()
            coordinator = WatchConnectivityCoordinator(transport: link.transport(for: .watch))
            syncActor = WatchSyncActor(repository: repository, installer: installer,
                                       coordinator: coordinator, diagnostics: diagnostics)
        }

        func stage(_ name: String, bytes: Data) throws -> URL {
            let url = inbox.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }
    }

    func testInstallOutcomeAndManifestConvergenceAreRecorded() async throws {
        let fx = try await SyncFixture()
        await fx.syncActor.didReceiveDownloadRoots(WatchSetDownloadRoots(revision: 1, roots: [
            WatchDownloadRootDescriptor(rootID: "r", kind: .track, sourceID: "one",
                                        title: "One", trackIDs: ["one"])
        ]))
        let staged = try fx.stage("one.m4a", bytes: Data("song-one-audio".utf8))
        let digest = try WatchFileDigest.measure(staged)
        await fx.syncActor.didReceiveAudioFile(at: staged, metadata: WatchAudioFileMetadata(
            trackID: "one", expectedBytes: digest.bytes, sha256: digest.sha256).dictionary)

        let events = await fx.diagnostics.events()

        let install = events.first { $0.category == .installResult }
        XCTAssertEqual(install?.stateCode, "installed")
        XCTAssertEqual(install?.byteCount, digest.bytes)

        let convergence = events.filter { $0.category == .manifestConvergence && $0.stateCode == "reported" }
        XCTAssertFalse(convergence.isEmpty)
        XCTAssertEqual(convergence.last?.count, 1, "one ready track after the install")
        XCTAssertTrue(events.allSatisfy { $0.correlationID == nil })
    }

    func testARejectedInstallIsRecordedByItsFaultCode() async throws {
        let fx = try await SyncFixture()
        await fx.syncActor.didReceiveDownloadRoots(WatchSetDownloadRoots(revision: 1, roots: [
            WatchDownloadRootDescriptor(rootID: "r", kind: .track, sourceID: "bad",
                                        title: "Bad", trackIDs: ["bad"])
        ]))
        let staged = try fx.stage("bad.m4a", bytes: Data("actual-bytes".utf8))
        await fx.syncActor.didReceiveAudioFile(at: staged, metadata: WatchAudioFileMetadata(
            trackID: "bad", expectedBytes: 999_999, sha256: nil).dictionary)

        let codes = await fx.diagnostics.events().filter { $0.category == .installResult }.map(\.stateCode)
        XCTAssertEqual(codes, ["checksumMismatch"])
    }

    // MARK: - WatchDiagnosticsObserver

    func testObserverRecordsTransferStateActivationAndRoute() async {
        let diag = WatchDiagnosticsRecorder()
        let observer = WatchDiagnosticsObserver(diagnostics: diag)

        await observer.didReceiveDownloadRoots(WatchSetDownloadRoots(revision: 1, roots: [
            WatchDownloadRootDescriptor(rootID: "r", kind: .playlist, sourceID: "p",
                                        trackIDs: ["a", "b", "c"])
        ]))
        await observer.didReceiveDownloadStatus(WatchDownloadStatusSnapshot(
            revision: 1, failedCount: 2, readyCount: 4))
        await observer.negotiationDidFail(WatchProtocolFault(code: .protocolUpgradeRequired))
        await observer.connectionStateDidChange(.connected(lastReplyAt: Date()), connectivity: .connected)

        let events = await diag.events()
        XCTAssertEqual(events.first { $0.category == .transferState && $0.stateCode == "rootsReceived" }?.count, 3)
        XCTAssertEqual(events.first { $0.stateCode == "failing" }?.count, 4)
        XCTAssertTrue(events.contains { $0.category == .activation && $0.stateCode == "protocolUpgradeRequired" })
        XCTAssertTrue(events.contains { $0.category == .routeEvent && $0.stateCode == "connected" })
        XCTAssertTrue(events.allSatisfy { $0.correlationID == nil })
    }
}
