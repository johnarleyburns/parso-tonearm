import Foundation
import XCTest
import TonearmWatchProtocol
@testable import TonearmCore

/// Watch rearchitecture Phase 8 — the pure Settings › Apple Watch projection (§9 P1–P5).
final class PhoneWatchManagementPresenterTests: XCTestCase {
    typealias P = PhoneWatchManagementPresenter

    private let t0 = Date(timeIntervalSince1970: 100_000)

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

    func testUnpairedHasNoStorageCard() {
        let snap = P.snapshot(pairing: .notPaired, roots: [], jobs: [], manifestEntries: [],
                              watchManifest: nil, now: t0)
        XCTAssertNil(snap.storage)
        XCTAssertTrue(snap.isEmpty)
    }

    func testStorageUsesWatchReportedCapacityAndFreeBytes() {
        let payload = WatchManifestPayload(manifestID: "m", readyTrackIDs: [WatchTrackID("a")],
                                           installedBytes: 300, capacityBytes: 1_000, freeBytes: 400)
        let snap = P.snapshot(pairing: .connected(since: t0.addingTimeInterval(-5)),
                              roots: [root("r", tracks: ["a"])],
                              jobs: [], manifestEntries: [entry("a", bytes: 300)],
                              watchManifest: payload, now: t0)
        let storage = try? XCTUnwrap(snap.storage)
        XCTAssertEqual(storage?.installedBytes, 300)
        XCTAssertEqual(storage?.capacityBytes, 1_000)
        XCTAssertEqual(storage?.trackCount, 1)
        XCTAssertEqual(storage?.usedFraction ?? 0, 0.6, accuracy: 0.0001)
        XCTAssertNil(storage?.spaceShortfall)
        XCTAssertEqual(snap.connectedForSeconds ?? 0, 5, accuracy: 0.01)
    }

    func testUnknownCapacityLeavesUsedFractionNil() {
        let payload = WatchManifestPayload(manifestID: "m", readyTrackIDs: [], installedBytes: 100)
        let snap = P.snapshot(pairing: .pairedNotReachable, roots: [], jobs: [],
                              manifestEntries: [], watchManifest: payload, now: t0)
        XCTAssertNil(snap.storage?.usedFraction)
        XCTAssertFalse(snap.storage?.hasReportedCapacity ?? true)
    }

    func testSpaceShortfallWhenRemainingExceedsFree() {
        let payload = WatchManifestPayload(manifestID: "m", readyTrackIDs: [], installedBytes: 0,
                                           capacityBytes: 5_000_000_000, freeBytes: 10_000_000)
        let snap = P.snapshot(pairing: .connected(since: nil),
                              roots: [root("r", tracks: ["a"])],
                              jobs: [job("a", roots: ["r"], state: .queued, bytes: 640_000_000)],
                              manifestEntries: [], watchManifest: payload, now: t0)
        let shortfall = try? XCTUnwrap(snap.storage?.spaceShortfall)
        XCTAssertEqual(shortfall?.requiredBytes, 640_000_000)
        XCTAssertEqual(shortfall?.freeBytes, 10_000_000)
    }

    // MARK: activity

    func testActivityOrdersTransferringBeforeWaitingBeforeFailed() {
        let jobs = [
            job("c", roots: ["r"], state: .failed, failure: .transient, message: "Network error"),
            job("b", roots: ["r"], state: .waitingForWiFi),
            job("a", roots: ["r"], state: .transferring),
        ]
        let snap = P.snapshot(pairing: .connected(since: t0), roots: [root("r", tracks: ["a", "b", "c"])],
                              jobs: jobs, manifestEntries: [], watchManifest: nil, now: t0)
        XCTAssertEqual(snap.activity.map(\.stage),
                       [.transferring, .waitingForWiFi, .failed])
        XCTAssertEqual(snap.activity.last?.failureMessage, "Network error")
        XCTAssertTrue(snap.activity.last?.canRetry ?? false)
        XCTAssertFalse(snap.activity.last?.canCancel ?? true)
    }

    func testActivityStageIsPausedWhenEveryRootPaused() {
        let snap = P.snapshot(pairing: .connected(since: t0),
                              roots: [root("r", tracks: ["a"], paused: true)],
                              jobs: [job("a", roots: ["r"], state: .queued)],
                              manifestEntries: [], watchManifest: nil, now: t0)
        XCTAssertEqual(snap.activity.first?.stage, .paused)
    }

    func testSentAndCancelledJobsAreNotActivity() {
        let jobs = [job("a", roots: ["r"], state: .sent), job("b", roots: ["r"], state: .cancelled)]
        let snap = P.snapshot(pairing: .connected(since: t0), roots: [root("r", tracks: ["a", "b"])],
                              jobs: jobs, manifestEntries: [], watchManifest: nil, now: t0)
        XCTAssertTrue(snap.activity.isEmpty)
    }

    // MARK: collections

    func testCollectionCountsBucketByState() {
        let root = root("pl", kind: .playlist, title: "Deep Focus", tracks: ["a", "b", "c", "d"])
        let jobs = [
            job("b", roots: ["pl"], state: .waitingForWiFi),
            job("c", roots: ["pl"], state: .failed, failure: .sourceUnavailable, message: "Unavailable at source"),
            job("d", roots: ["pl"], state: .failed, failure: .transient),
        ]
        let snap = P.snapshot(pairing: .connected(since: t0), roots: [root], jobs: jobs,
                              manifestEntries: [entry("a")], watchManifest: nil, now: t0)
        let row = try? XCTUnwrap(snap.collections.first)
        XCTAssertEqual(row?.kind, .playlist)
        XCTAssertEqual(row?.readyCount, 1)
        XCTAssertEqual(row?.waitingForWiFiCount, 1)
        XCTAssertEqual(row?.unavailableCount, 1)
        XCTAssertEqual(row?.failedCount, 1)
        XCTAssertTrue(row?.isPartial ?? false)
    }

    // MARK: banner

    func testBannerNilWithNoActiveOrFailed() {
        let snap = P.snapshot(pairing: .connected(since: t0), roots: [root("r", tracks: ["a"])],
                              jobs: [job("a", roots: ["r"], state: .sent)],
                              manifestEntries: [entry("a")], watchManifest: nil, now: t0)
        XCTAssertNil(snap.banner)
    }

    func testBannerCountsActiveAndFailedAndFlagsFailure() {
        let jobs = [
            job("a", roots: ["r"], state: .transferring),
            job("b", roots: ["r"], state: .queued),
            job("c", roots: ["r"], state: .failed, failure: .needsAuth),
        ]
        let snap = P.snapshot(pairing: .connected(since: t0), roots: [root("r", tracks: ["a", "b", "c"])],
                              jobs: jobs, manifestEntries: [], watchManifest: nil, now: t0)
        XCTAssertEqual(snap.banner?.activeCount, 2)
        XCTAssertEqual(snap.banner?.failedCount, 1)
        XCTAssertTrue(snap.banner?.hasFailure ?? false)
    }

    // MARK: reference-aware removal

    func testRemovingRootReleasesOnlyUnsharedInstalledTracks() {
        let roots = [
            root("a", kind: .playlist, tracks: ["t1", "t2", "t3"]),
            root("b", kind: .playlist, tracks: ["t2"]),
        ]
        let released = P.tracksReleasedByRemoving(rootID: "a", roots: roots,
                                                  installed: ["t1", "t2", "t3"])
        XCTAssertEqual(released.released.sorted(), ["t1", "t3"])
        XCTAssertEqual(released.retainedShared, ["t2"])
    }

    func testPausedOtherRootDoesNotRetainSharedTrack() {
        let roots = [
            root("a", kind: .playlist, tracks: ["t1", "t2"]),
            root("b", kind: .playlist, tracks: ["t2"], paused: true),
        ]
        let released = P.tracksReleasedByRemoving(rootID: "a", roots: roots, installed: ["t1", "t2"])
        XCTAssertEqual(released.released.sorted(), ["t1", "t2"])
        XCTAssertTrue(released.retainedShared.isEmpty)
    }

    func testCollectionDetailReportsReferenceCountsAndReason() {
        let roots = [
            root("a", kind: .playlist, title: "A", tracks: ["t1", "t2", "t3"]),
            root("b", kind: .playlist, title: "B", tracks: ["t2"]),
        ]
        let jobs = [
            job("t3", roots: ["a"], state: .failed, failure: .fileUnsupported,
                bytes: 0, message: "Unsupported format"),
        ]
        let detail = try? XCTUnwrap(
            P.collectionDetail(rootID: "a", roots: roots, jobs: jobs,
                               manifestEntries: [entry("t1"), entry("t2")]))
        XCTAssertEqual(detail?.readyCount, 2)
        XCTAssertEqual(detail?.unavailableCount, 1)
        XCTAssertEqual(detail?.unavailableReason, "Unsupported format")
        XCTAssertEqual(detail?.releasedTrackCount, 1)         // t1 only
        XCTAssertEqual(detail?.retainedSharedTrackCount, 1)   // t2 kept for root b
        XCTAssertTrue(detail?.autoSyncs ?? false)
    }

    func testTrackRootDetailDoesNotAutoSync() {
        let detail = P.collectionDetail(rootID: "tr", roots: [root("tr", kind: .track, tracks: ["x"])],
                                        jobs: [], manifestEntries: [])
        XCTAssertEqual(detail?.autoSyncs, false)
        XCTAssertEqual(detail?.kind, .track)
    }
}
