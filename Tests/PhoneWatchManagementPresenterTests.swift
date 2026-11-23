import Foundation
import Testing
import TonearmWatchProtocol
@testable import TonearmCore

/// Watch rearchitecture Phase 8 — the pure Settings › Apple Watch projection (§9 P1–P5).
@Suite struct PhoneWatchManagementPresenterTests {
    typealias P = PhoneWatchManagementPresenter

    private let t0 = Date(timeIntervalSince1970: 100_000)

    @Test func testOnMyWatchMirrorIncludesOnlyInstalledOrSelectedTracksAndNeverChecksSubmittedAudio() {
        let snapshot = P.snapshot(pairing: .pairedNotReachable,
            roots: [root("r", tracks: ["sending", "submitted", "queued"])],
            jobs: [job("sending", roots: ["r"], state: .sent), job("submitted", roots: ["r"], state: .sent)],
            manifestEntries: [entry("installed-orphan")], watchManifest: nil, now: t0,
            transferFractions: ["sending": 0.5, "submitted": 1],
            trackTitles: ["installed-orphan": "Installed", "sending": "Sending", "submitted": "Submitted", "queued": "Queued"])
        #expect(Set(snapshot.watchTracks.map(\.id)) == ["installed-orphan", "sending", "submitted", "queued"])
        #expect(snapshot.watchTracks.filter(\.isInstalled).map(\.id) == ["installed-orphan"])
        #expect(snapshot.watchTracks.first { $0.id == "sending" }?.activity?.fractionComplete == 0.5)
        #expect(snapshot.watchTracks.first { $0.id == "submitted" }?.activity?.stage == .awaitingInstallation)
    }

    @Test func testPlaylistMembersUseLibraryTitlesInsteadOfGUIDs() {
        let id = "C9FBC56A-1F9B-4775-ABF7-BF92F7374A63"
        let snapshot = P.snapshot(pairing: .pairedNotReachable,
            roots: [root("home", title: "Home Cooking", tracks: [id])],
            jobs: [job(id, roots: ["home"], state: .sent)], manifestEntries: [],
            watchManifest: nil, now: t0, trackTitles: [id: "Home Cooking III"])
        #expect(snapshot.activity.first?.title == "Home Cooking III")
    }

    @Test func testChunkProgressShowsSavedCheckpointAndNotWaitingForWholeFileInstallation() {
        let receipt = WatchPartialAudioDownload(trackID: "fred", assetSHA256: String(repeating: "a", count: 64),
            totalBytes: 100 * 1_048_576, chunkBytes: 1_048_576, receivedChunkIndexes: Array(0..<50))
        let snapshot = P.snapshot(pairing: .pairedNotReachable,
            roots: [root("r", tracks: ["fred"])], jobs: [job("fred", roots: ["r"], state: .sent)],
            manifestEntries: [], watchManifest: nil, now: t0,
            chunkProgress: ["fred": .init(checkpoint: receipt, stage: .awaitingChunkConfirmation)])
        #expect(snapshot.activity.first?.stage == .awaitingChunkConfirmation)
        #expect(snapshot.activity.first?.fractionComplete == 0.5)
        #expect(snapshot.activity.first?.receivedChunkCount == 50)
        #expect(snapshot.activity.first?.totalChunkCount == 100)
        #expect(snapshot.storage?.installedBytes == 0)
        #expect(snapshot.storage?.trackCount == 0)
    }

    @Test func testSentJobsUseRealSystemProgressInsteadOfAlwaysWaitingForInstallation() {
        let roots = [root("r", tracks: ["fred"])]
        let jobs = [job("fred", roots: ["r"], state: .sent, bytes: 174_000_000)]
        for (fraction, stage) in [(0.0, P.ActivityStage.waitingForDelivery),
                                  (0.08, .transferring), (1.0, .awaitingInstallation)] {
            let snapshot = P.snapshot(pairing: .pairedNotReachable, roots: roots, jobs: jobs,
                manifestEntries: [], watchManifest: nil, now: t0, transferFractions: ["fred": fraction])
            #expect(snapshot.activity.first?.stage == stage)
            #expect(snapshot.activity.first?.fractionComplete == fraction)
            #expect(snapshot.activity.first?.expectedBytes == 174_000_000)
            #expect(!(snapshot.activity.first?.canRetry ?? true), "Active Apple transfers must not prompt for premature retries")
            #expect(snapshot.storage?.trackCount == 0)
        }
    }

    @Test func testSyncReceiptsAndSystemStorageAreSeparateFromInstalledMusic() {
        let history = P.SyncHistory(lastWatchReportAt: t0, lastCatalogSentAt: t0,
            lastCatalogReceivedAt: t0.addingTimeInterval(-5))
        let snapshot = P.snapshot(pairing: .pairedNotReachable, roots: [], jobs: [], manifestEntries: [],
            watchManifest: .init(manifestID: "m", readyTrackIDs: [], installedBytes: 0,
                capacityBytes: 1000, freeBytes: 680), now: t0, syncHistory: history)
        #expect(snapshot.storage?.usedFraction == 0.32)
        #expect(snapshot.storage?.installedBytes == 0)
        #expect(snapshot.storage?.trackCount == 0)
        #expect(snapshot.syncHistory == history)
        #expect(snapshot.syncHistory.lastAudioInstalledAt == nil)
        let restored = try? JSONDecoder().decode(P.SyncHistory.self, from: JSONEncoder().encode(history))
        #expect(restored == history, "Receipt history must survive app relaunch without becoming a success claim")
    }

    private func root(_ id: String, kind: WatchRootKind = .playlist, title: String = "",
                      tracks: [String], paused: Bool = false) -> PhoneWatchDownloadRoot {
        PhoneWatchDownloadRoot(rootID: id, kind: kind, sourceID: "src-\(id)",
                               title: title.isEmpty ? id : title, desiredTrackIDs: tracks,
                               phoneRevision: 1, createdAt: Date(timeIntervalSince1970: 1), paused: paused)
    }

    private func job(_ track: String, roots: [String], state: PhoneWatchJobState,
                     failure: PhoneWatchFailureClass? = nil, bytes: Int64? = nil,
                     message: String? = nil) -> PhoneWatchDownloadJob {
        PhoneWatchDownloadJob(trackID: track, rootIDs: roots, state: state, failureClass: failure,
                              expectedBytes: bytes, message: message,
                              createdAt: t0, updatedAt: t0)
    }

    private func entry(_ track: String, bytes: Int64 = 1_000) -> PhoneWatchManifestEntry {
        PhoneWatchManifestEntry(trackID: track, bytes: bytes, manifestID: "m")
    }

    // MARK: pairing / storage

    @Test func testUnpairedHasNoStorageCard() {
        let snap = P.snapshot(pairing: .notPaired, roots: [], jobs: [], manifestEntries: [],
                              watchManifest: nil, now: t0)
        #expect(snap.storage == nil)
        #expect(snap.isEmpty)
    }

    @Test func testStorageUsesWatchReportedCapacityAndFreeBytes() {
        let payload = WatchManifestPayload(manifestID: "m", readyTrackIDs: [WatchTrackID("a")],
                                           installedBytes: 300, capacityBytes: 1_000, freeBytes: 400)
        let snap = P.snapshot(pairing: .connected(since: t0.addingTimeInterval(-5)),
                              roots: [root("r", tracks: ["a"])],
                              jobs: [], manifestEntries: [entry("a", bytes: 300)],
                              watchManifest: payload, now: t0)
        let storage = try? #require(snap.storage)
        #expect(storage?.installedBytes == 300)
        #expect(storage?.capacityBytes == 1_000)
        #expect(storage?.trackCount == 1)
        #expect(abs((storage?.usedFraction ?? 0) - (0.6)) <= 0.0001)
        #expect(storage?.spaceShortfall == nil)
        #expect(abs((snap.connectedForSeconds ?? 0) - (5)) <= 0.01)
    }

    @Test func testUnknownCapacityLeavesUsedFractionNil() {
        let payload = WatchManifestPayload(manifestID: "m", readyTrackIDs: [], installedBytes: 100)
        let snap = P.snapshot(pairing: .pairedNotReachable, roots: [], jobs: [],
                              manifestEntries: [], watchManifest: payload, now: t0)
        #expect(snap.storage?.usedFraction == nil)
        #expect(!(snap.storage?.hasReportedCapacity ?? true))
    }

    @Test func testSpaceShortfallWhenRemainingExceedsFree() {
        let payload = WatchManifestPayload(manifestID: "m", readyTrackIDs: [], installedBytes: 0,
                                           capacityBytes: 5_000_000_000, freeBytes: 10_000_000)
        let snap = P.snapshot(pairing: .connected(since: nil),
                              roots: [root("r", tracks: ["a"])],
                              jobs: [job("a", roots: ["r"], state: .queued, bytes: 640_000_000)],
                              manifestEntries: [], watchManifest: payload, now: t0)
        let shortfall = try? #require(snap.storage?.spaceShortfall)
        #expect(shortfall?.requiredBytes == 640_000_000)
        #expect(shortfall?.freeBytes == 10_000_000)
    }

    // MARK: activity

    @Test func testActivityOrdersTransferringBeforeWaitingBeforeFailed() {
        let jobs = [
            job("c", roots: ["r"], state: .failed, failure: .transient, message: "Network error"),
            job("b", roots: ["r"], state: .waitingForWiFi),
            job("a", roots: ["r"], state: .transferring),
        ]
        let snap = P.snapshot(pairing: .connected(since: t0), roots: [root("r", tracks: ["a", "b", "c"])],
                              jobs: jobs, manifestEntries: [], watchManifest: nil, now: t0)
        #expect(snap.activity.map(\.stage) == [.transferring, .waitingForWiFi, .failed])
        #expect(snap.activity.last?.failureMessage == "Network error")
        #expect(snap.activity.last?.canRetry ?? false)
        #expect(!(snap.activity.last?.canCancel ?? true))
    }

    @Test func testActivityStageIsPausedWhenEveryRootPaused() {
        let snap = P.snapshot(pairing: .connected(since: t0),
                              roots: [root("r", tracks: ["a"], paused: true)],
                              jobs: [job("a", roots: ["r"], state: .queued)],
                              manifestEntries: [], watchManifest: nil, now: t0)
        #expect(snap.activity.first?.stage == .paused)
    }

    @Test func testUnconfirmedSentJobsRemainActivityAndCancelledJobsAreHidden() {
        let jobs = [job("a", roots: ["r"], state: .sent), job("b", roots: ["r"], state: .cancelled)]
        let snap = P.snapshot(pairing: .connected(since: t0), roots: [root("r", tracks: ["a", "b"])],
                              jobs: jobs, manifestEntries: [], watchManifest: nil, now: t0)
        #expect(snap.activity.map(\.trackID) == ["a"])
        #expect(snap.activity.first?.stage == .awaitingInstallation)
        #expect(snap.banner?.activeCount == 1)
        #expect(snap.collections.first?.readyCount == 0)
        #expect(!(snap.collections.first?.isFullyReady ?? true))
        let confirmed = P.snapshot(pairing: .connected(since: t0), roots: [root("r", tracks: ["a"])],
            jobs: [jobs[0]], manifestEntries: [entry("a")], watchManifest: nil, now: t0)
        #expect(confirmed.activity.isEmpty)
    }

    // MARK: collections

    @Test func testCollectionCountsBucketByState() {
        let root = root("pl", kind: .playlist, title: "Deep Focus", tracks: ["a", "b", "c", "d"])
        let jobs = [
            job("b", roots: ["pl"], state: .waitingForWiFi),
            job("c", roots: ["pl"], state: .failed, failure: .sourceUnavailable, message: "Unavailable at source"),
            job("d", roots: ["pl"], state: .failed, failure: .transient),
        ]
        let snap = P.snapshot(pairing: .connected(since: t0), roots: [root], jobs: jobs,
                              manifestEntries: [entry("a")], watchManifest: nil, now: t0)
        let row = try? #require(snap.collections.first)
        #expect(row?.kind == .playlist)
        #expect(row?.readyCount == 1)
        #expect(row?.waitingForWiFiCount == 1)
        #expect(row?.unavailableCount == 1)
        #expect(row?.failedCount == 1)
        #expect(row?.isPartial ?? false)
    }

    // MARK: banner

    @Test func testBannerNilWithNoActiveOrFailed() {
        let snap = P.snapshot(pairing: .connected(since: t0), roots: [root("r", tracks: ["a"])],
                              jobs: [job("a", roots: ["r"], state: .sent)],
                              manifestEntries: [entry("a")], watchManifest: nil, now: t0)
        #expect(snap.banner == nil)
    }

    @Test func testBannerCountsActiveAndFailedAndFlagsFailure() {
        let jobs = [
            job("a", roots: ["r"], state: .transferring),
            job("b", roots: ["r"], state: .queued),
            job("c", roots: ["r"], state: .failed, failure: .needsAuth),
        ]
        let snap = P.snapshot(pairing: .connected(since: t0), roots: [root("r", tracks: ["a", "b", "c"])],
                              jobs: jobs, manifestEntries: [], watchManifest: nil, now: t0)
        #expect(snap.banner?.activeCount == 2)
        #expect(snap.banner?.failedCount == 1)
        #expect(snap.banner?.hasFailure ?? false)
    }

    // MARK: failure badge (My Music "On My Watch")

    @Test func testFailureBadgeMessageNilWithNoFailures() {
        #expect(P.failureBadgeMessage(failedCount: 0) == nil)
    }

    @Test func testFailureBadgeMessagePointsAtTheFailedTrack() {
        #expect(P.failureBadgeMessage(failedCount: 1) == "Go to the track below and try again")
        #expect(P.failureBadgeMessage(failedCount: 3) == "Go to the track below and try again")
    }

    // MARK: reference-aware removal

    @Test func testRemovingRootReleasesOnlyUnsharedInstalledTracks() {
        let roots = [
            root("a", kind: .playlist, tracks: ["t1", "t2", "t3"]),
            root("b", kind: .playlist, tracks: ["t2"]),
        ]
        let released = P.tracksReleasedByRemoving(rootID: "a", roots: roots,
                                                  installed: ["t1", "t2", "t3"])
        #expect(released.released.sorted() == ["t1", "t3"])
        #expect(released.retainedShared == ["t2"])
    }

    @Test func testPausedOtherRootDoesNotRetainSharedTrack() {
        let roots = [
            root("a", kind: .playlist, tracks: ["t1", "t2"]),
            root("b", kind: .playlist, tracks: ["t2"], paused: true),
        ]
        let released = P.tracksReleasedByRemoving(rootID: "a", roots: roots, installed: ["t1", "t2"])
        #expect(released.released.sorted() == ["t1", "t2"])
        #expect(released.retainedShared.isEmpty)
    }

    @Test func testCollectionDetailReportsReferenceCountsAndReason() {
        let roots = [
            root("a", kind: .playlist, title: "A", tracks: ["t1", "t2", "t3"]),
            root("b", kind: .playlist, title: "B", tracks: ["t2"]),
        ]
        let jobs = [
            job("t3", roots: ["a"], state: .failed, failure: .fileUnsupported,
                bytes: 0, message: "Unsupported format"),
        ]
        let detail = try? #require(
            P.collectionDetail(rootID: "a", roots: roots, jobs: jobs,
                               manifestEntries: [entry("t1"), entry("t2")]))
        #expect(detail?.readyCount == 2)
        #expect(detail?.unavailableCount == 1)
        #expect(detail?.unavailableReason == "Unsupported format")
        #expect(detail?.releasedTrackCount == 1)         // t1 only
        #expect(detail?.retainedSharedTrackCount == 1)   // t2 kept for root b
        #expect(detail?.autoSyncs ?? false)
    }

    @Test func testTrackRootDetailDoesNotAutoSync() {
        let detail = P.collectionDetail(rootID: "tr", roots: [root("tr", kind: .track, tracks: ["x"])],
                                        jobs: [], manifestEntries: [])
        #expect(detail?.autoSyncs == false)
        #expect(detail?.kind == .track)
    }
}

@Suite struct WatchTransferEstimateTests {
    @Test func testEstimateUsesAAC128NotOriginalFileSize() {
        // 4-minute FLAC (~40 MB) -> 240 s * 128 kbps / 8 = 3.84 MB
        let bytes = PhoneWatchAudioPreparation.estimatedWatchBytes(durationSec: 240, sourceBytes: 40_000_000)
        #expect(bytes == 3_840_000)
    }

    @Test func testEstimateNeverExceedsSmallerSourceAndFallsBackWithoutDuration() {
        #expect(PhoneWatchAudioPreparation.estimatedWatchBytes(durationSec: 240, sourceBytes: 1_000_000) == 1_000_000)
        #expect(PhoneWatchAudioPreparation.estimatedWatchBytes(durationSec: nil, sourceBytes: 5) == 5)
    }
}

@Suite struct WatchHeaderCardSourceTests {
    @Test func testHeaderCardReadsUsedAndAvailableFields() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/Features/Settings/WatchSettingsView.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "headerCard"))
        let end = try #require(source.range(of: "private func shortfallCard"))
        let body = String(source[start.lowerBound..<end.lowerBound])
        for field in ["storage.capacityBytes", "storage.freeBytes", "storage.usedFraction"] {
            #expect(body.contains(field), "headerCard must render \(field)")
        }
    }
}
