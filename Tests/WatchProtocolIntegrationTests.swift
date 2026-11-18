import Foundation
import Testing
@testable import TonearmCore
@testable import TonearmWatchCore
@testable import TonearmWatchProtocol

/// Phase 3's definition of done: both coordinators are driven through one fake duplex transport, so
/// every case below is the real phone code talking to the real watch code — no simulator, no
/// WatchConnectivity, no wall-clock waits beyond a grace period the test itself picks.
@Suite struct WatchProtocolIntegrationTests {
    @Test func testPushOnlyWatchNeverQueuesSyncOrOtherRequests() async {
        let harness = await makeHarness(boundLibraryID: libraryID, phoneStatus: .init(revision: 1), phonePushOnly: true)
        await harness.link.setReachable(false)
        await harness.watch.activate(reachable: false)
        let result = await harness.watch.synchronizeMetadata()
        #expect(result == .failed(.phoneUnavailable))
        await harness.watch.requestReconciliation()
        await harness.watch.requestDownload(trackID: "forbidden", wantsDownload: true)
        await harness.watch.controlDownloads(.init(action: .retryFailed))
        let offlineDeliveries = await harness.link.deliveries
        #expect(offlineDeliveries.isEmpty)
        await harness.link.setReachable(true)
        await harness.watch.activate(reachable: true)
        await harness.watch.reachabilityChanged(true)
        let beforeSync = await harness.link.deliveries
        #expect(beforeSync.isEmpty, "Activation and reconnection must not send hello or metadata requests")
        let liveResult = await harness.watch.synchronizeMetadata()
        #expect(liveResult == .sent)
        let deliveries = await harness.link.deliveries
        #expect(!deliveries.contains { $0.channel == .userInfo || $0.channel == .file })
    }
    @Test func testPhoneOnlyDownloadsRejectWatchOriginatedRequestsOnLiveAndDurableChannels() async throws {
        let harness = await makeHarness(allowsWatchDownloadCommands: false)
        await harness.phone.activate(reachable: true)
        await harness.watch.activate(reachable: true)
        await harness.watch.requestDownload(trackID: "unselected", wantsDownload: true)
        await harness.watch.controlDownloads(.init(action: .retryFailed))
        let requests = await harness.handler.receivedDownloadRequests
        let controls = await harness.handler.receivedDownloadControls
        #expect(requests.isEmpty)
        #expect(controls.isEmpty)
        let response = await harness.watch.search("music")
        #expect(response == .failed(.init(code: .contentNotFound)))
    }
    @Test func testMetadataRoundTripExchangesBothTruthsWithoutAudioOrDownloadCommands() async throws {
        let harness = await makeConnectedHarness()
        await harness.link.setHoldingUserInfo(true)
        await harness.phone.publishContext(downloads: .init(revision: 1, catalogTrackCount: 400,
            readyTrackIDs: ["local-aac"]))
        let watchResult = await harness.watch.synchronizeMetadata()
        #expect(watchResult == .confirmed)
        let phoneResult = await harness.phone.synchronizeMetadata()
        #expect(phoneResult == .confirmed)
        let manifests = await harness.handler.receivedManifests
        #expect(manifests.last?.readyTrackIDs == ["local-aac"])
        let requests = await harness.handler.receivedDownloadRequests
        let controls = await harness.handler.receivedDownloadControls
        #expect(requests.isEmpty)
        #expect(controls.isEmpty)
        let statuses = await harness.watchObserver.downloadStatuses
        #expect(statuses.last?.catalogTrackCount == 400)
        let deliveries = await harness.link.deliveries
        #expect(!deliveries.contains { $0.channel == .file })
    }

    @Test func testMetadataReplyTimeoutIsNotShownAsSynced() async {
        let harness = await makeHarness(boundLibraryID: libraryID, immediateDeadline: .milliseconds(25))
        await harness.link.setHoldingUserInfo(true)
        await harness.link.setSwallowImmediateReplies(true)
        let result = await harness.watch.synchronizeMetadata()
        #expect(result == .failed(.requestTimedOut))
        let statuses = await harness.watchObserver.downloadStatuses
        #expect(statuses.isEmpty)
    }

    @Test func testUnreadableWatchStoreCannotConfirmMetadataSync() async {
        let harness = await makeHarness(boundLibraryID: libraryID, localManifest: nil,
            phoneStatus: .init(revision: 1))
        await harness.link.setHoldingUserInfo(true)
        let result = await harness.phone.synchronizeMetadata()
        #expect(result == .failed(.installationFailed))
        let watchResult = await harness.watch.synchronizeMetadata()
        #expect(watchResult == .failed(.installationFailed))
        let reports = await harness.phoneObserver.manifests
        #expect(reports.isEmpty)
    }

    @Test func testWatchMetadataCheckCanReadColdPhoneWithoutPriorContextPublication() async {
        let harness = await makeHarness(boundLibraryID: libraryID,
            phoneStatus: .init(revision: 1, catalogTrackCount: 379, readyTrackIDs: []))
        await harness.link.setHoldingUserInfo(true)
        let result = await harness.watch.synchronizeMetadata()
        #expect(result == .confirmed)
        let phoneResult = await harness.phone.synchronizeMetadata()
        #expect(phoneResult == .confirmed)
        let statuses = await harness.watchObserver.downloadStatuses
        #expect(statuses.last?.catalogTrackCount == 379)
        let publications = await harness.link.deliveries
        #expect(!publications.contains { $0.channel == .applicationContext || $0.channel == .file })
    }

    @Test func testMetadataSyncQueuesWhileUnreachableWithoutClaimingConfirmation() async {
        let harness = await makeHarness(boundLibraryID: libraryID)
        await harness.link.setReachable(false)
        await harness.watch.activate(reachable: false)
        await harness.phone.activate(reachable: false)
        let watch = await harness.watch.synchronizeMetadata()
        let phone = await harness.phone.synchronizeMetadata()
        #expect(watch == .queued)
        #expect(phone == .queued)
    }

    @Test func testPeriodicCatalogReportsWorkOfflineInBothDirectionsWithoutAudioSends() async throws {
        let harness = await makeHarness(boundLibraryID: libraryID)
        await harness.link.setReachable(false)
        await harness.watch.activate(reachable: false)
        await harness.phone.activate(reachable: false)
        let watchReport = WatchManifestPayload(manifestID: "watch-truth", readyTrackIDs: ["installed"],
            installedBytes: 512, catalogTrackCount: 379, inProgressTrackIDs: ["received-not-installed"])
        await harness.watch.publishManifestContext(watchReport)
        await harness.link.replayApplicationContext(from: .watch)
        let reports = await harness.handler.receivedManifests
        #expect(reports.last == watchReport)
        await harness.phone.publishContext(downloads: .init(revision: 1, readyCount: 1,
            activities: [.init(trackID: "submitted", stage: .waitingForDelivery)],
            catalogTrackCount: 400, readyTrackIDs: ["installed"]))
        await harness.link.replayApplicationContext(from: .phone)
        let statuses = await harness.watchObserver.downloadStatuses
        #expect(statuses.last?.catalogTrackCount == 400)
        #expect(statuses.last?.readyTrackIDs == ["installed"])
        #expect(statuses.last?.activities.first?.trackID == "submitted")
        let watchState = await harness.watch.connectionState
        let phoneState = await harness.phone.connectionState
        #expect(watchState.isConfirmedDisconnected)
        #expect(phoneState.isConfirmedDisconnected)
    }
    @Test func testCachedPreChunkProtocolPacketsDoNotPoisonAnUpdatedSession() async throws {
        let harness = await makeConnectedHarness()
        let stale = try WatchProtocolEnvelope.encode(kind: .downloadStatusSnapshot,
            payload: WatchDownloadStatusSnapshot(revision: 999, activeCount: 1),
            pairedLibraryID: libraryID, protocolVersion: 1)
        await harness.watch.receiveApplicationContext(stale)
        await harness.watch.receiveUserInfo(stale)
        let state = await harness.watch.connectionState
        guard case .connected = state else {
            Issue.record("Cached v1 data poisoned the v2 session")
            return
        }
        await harness.phone.publishContext(downloads: .init(revision: 1, readyCount: 3))
        let received = await harness.watchObserver.downloadStatuses
        #expect(received.last?.readyCount == 3)
        #expect(!received.contains { $0.revision == 999 })
    }
    @Test func testLiveDownloadProgressDoesNotWaitForCoalescedApplicationContext() async {
        let harness = await makeConnectedHarness()
        await harness.link.setHoldingApplicationContext(true)
        await harness.phone.publishContext(downloads: .init(revision: 1, activeCount: 1,
            activities: [.init(trackID: "fred", stage: .transferring, fractionComplete: 0.08)]))
        await harness.phone.publishContext(downloads: .init(revision: 1, activeCount: 1,
            activities: [.init(trackID: "fred", stage: .transferring, fractionComplete: 0.09)]))
        let live = await harness.watchObserver.downloadStatuses
        #expect(live.map { $0.activities.first?.fractionComplete } == [0.08, 0.09])
        await harness.link.replayApplicationContext(from: .phone)
        let afterReplay = await harness.watchObserver.downloadStatuses
        #expect(afterReplay.count == 2, "Delayed context must not duplicate or replace newer live progress")
    }

    @Test func testBackgroundPacketsDoNotClaimLiveReachabilityOnEitherDevice() async throws {
        let harness = await makeHarness(boundLibraryID: libraryID)
        await harness.phone.activate(reachable: false)
        await harness.watch.activate(reachable: false)
        let context = WatchContextSnapshot(pairedLibraryID: libraryID,
            downloads: WatchDownloadStatusSnapshot(revision: 1, queuedCount: 3))
        let data = try WatchProtocolEnvelope.fromPhone(kind: .downloadStatusSnapshot,
            payload: context, libraryID: libraryID, revision: 1)
        await harness.watch.receiveApplicationContext(data)
        let roots = try WatchProtocolEnvelope.fromPhone(kind: .setDownloadRoots,
            payload: WatchSetDownloadRoots(revision: 2, roots: []), libraryID: libraryID, revision: 2)
        await harness.watch.receiveUserInfo(roots)
        await harness.watch.receiveFile(URL(fileURLWithPath: "/tmp/unused-background-probe"), metadata: [:])
        let manifest = try WatchProtocolEnvelope.encode(kind: .watchManifest,
            payload: WatchManifestPayload(manifestID: "background", readyTrackIDs: [], installedBytes: 0),
            pairedLibraryID: libraryID)
        await harness.phone.receiveUserInfo(manifest)
        let watch = await harness.watch.connectionState
        let phone = await harness.phone.connectionState
        #expect(watch.isConfirmedDisconnected)
        #expect(phone.isConfirmedDisconnected)
        let received = await harness.watchObserver.downloadStatuses
        #expect(received.last?.queuedCount == 3, "Background state still applies while unreachable")
    }

    @Test func testSuccessiveDownloadStatusUpdatesReceiveFreshRevisions() async {
        let harness = await makeConnectedHarness()
        await harness.phone.publishContext(downloads: .init(revision: 10, queuedCount: 3))
        await harness.phone.publishContext(downloads: .init(revision: 10, activeCount: 1,
            activities: [.init(trackID: "home", stage: .transferring, fractionComplete: 0.5)]))
        await harness.phone.publishContext(downloads: .init(revision: 10, readyCount: 3))
        let received = await harness.watchObserver.downloadStatuses
        #expect(received.count == 3, "Progress changes at one root revision must not be discarded")
        #expect(received.last?.readyCount == 3)
        #expect(Set(received.map(\.revision)).count == 3)
        let repeated = await harness.phone.publishContext(downloads: .init(revision: 10, readyCount: 3))
        #expect(!repeated, "An identical status does not need another publication")
    }

    @Test func testManifestLiveCopyArrivesBeforeQueuedCopyAndIsAppliedOnce() async {
        let harness = await makeConnectedHarness()
        await harness.link.setHoldingUserInfo(true)
        await harness.watch.sendManifest(.init(manifestID: "installed", readyTrackIDs: ["home"], installedBytes: 42))
        let immediate = await harness.phoneObserver.manifests
        #expect(immediate.count == 1)
        await harness.link.flushHeldUserInfo()
        let afterQueued = await harness.phoneObserver.manifests
        #expect(afterQueued.count == 1, "Live and durable copies share message identity")
    }

    @Test func testWatchSyncAndDownloadControlsUseLiveCopyWithoutWaitingForBackgroundDelivery() async {
        let harness = await makeConnectedHarness()
        await harness.link.setHoldingUserInfo(true)
        await harness.watch.requestReconciliation()
        await harness.watch.requestDownload(trackID: "home", wantsDownload: true)
        await harness.watch.controlDownloads(.init(action: .retryFailed))
        let liveReconciliations = await harness.handler.receivedReconciliations
        let liveDownloads = await harness.handler.receivedDownloadRequests
        let liveControls = await harness.handler.receivedDownloadControls
        #expect(liveReconciliations.count == 1)
        #expect(liveDownloads.count == 1)
        #expect(liveControls.count == 1)
        await harness.link.flushHeldUserInfo()
        let queuedReconciliations = await harness.handler.receivedReconciliations
        let queuedDownloads = await harness.handler.receivedDownloadRequests
        let queuedControls = await harness.handler.receivedDownloadControls
        #expect(queuedReconciliations.count == 1)
        #expect(queuedDownloads.count == 1)
        #expect(queuedControls.count == 1)
    }

    private let libraryID = WatchPairedLibraryID("library-A")

    private struct Harness {
        let link: WatchFakeDuplexLink
        let phone: PhoneWatchProtocolCoordinator
        let watch: WatchConnectivityCoordinator
        let handler: FakePhoneHandler
        let watchObserver: RecordingWatchObserver
        let phoneObserver: RecordingPhoneObserver
        let watchState: WatchInMemorySyncStateStore
        let revisions: WatchInMemoryRevisionStore
        let diagnostics: WatchDiagnosticsRecorder?
    }

    private func makeHarness(
        libraryID: WatchPairedLibraryID? = nil,
        watchCapabilities: [WatchCapability] = WatchCapability.allCases,
        phoneCapabilities: [WatchCapability] = WatchCapability.allCases,
        boundLibraryID: WatchPairedLibraryID? = nil,
        gracePeriod: TimeInterval = 0.05,
        immediateDeadline: Duration = .milliseconds(200),
        phoneRevision: Int64 = 0,
        diagnostics: WatchDiagnosticsRecorder? = nil,
        localManifest: WatchManifestPayload? = .init(manifestID: "local-truth", readyTrackIDs: ["local-aac"], installedBytes: 512),
        phoneStatus: WatchDownloadStatusSnapshot? = nil,
        allowsWatchDownloadCommands: Bool = true,
        phonePushOnly: Bool = false
    ) async -> Harness {
        let id = libraryID ?? self.libraryID
        let link = WatchFakeDuplexLink()
        let handler = FakePhoneHandler(libraryID: id, capabilities: phoneCapabilities)
        let revisions = WatchInMemoryRevisionStore(revision: phoneRevision)
        let phoneObserver = RecordingPhoneObserver()
        let phone = PhoneWatchProtocolCoordinator(
            transport: link.transport(for: .phone), handler: handler, libraryID: id,
            revisionStore: revisions, gracePeriod: gracePeriod, observer: phoneObserver,
            allowsWatchDownloadCommands: allowsWatchDownloadCommands,
            downloadStatusProvider: { phoneStatus })

        let watchState = WatchInMemorySyncStateStore(pairedLibraryID: boundLibraryID)
        let watchObserver = RecordingWatchObserver()
        let watch = WatchConnectivityCoordinator(
            transport: link.transport(for: .watch), stateStore: watchState,
            configuration: .init(capabilities: watchCapabilities,
                                 immediateDeadline: immediateDeadline, gracePeriod: gracePeriod,
                                 phonePushOnly: phonePushOnly),
            diagnostics: diagnostics,
            observer: watchObserver,
            manifestProvider: { localManifest })

        await link.attach(phone, as: .phone)
        await link.attach(watch, as: .watch)
        return Harness(link: link, phone: phone, watch: watch, handler: handler,
                       watchObserver: watchObserver, phoneObserver: phoneObserver,
                       watchState: watchState, revisions: revisions, diagnostics: diagnostics)
    }

    private func makeConnectedHarness(diagnostics: WatchDiagnosticsRecorder? = nil) async -> Harness {
        let harness = await makeHarness(boundLibraryID: libraryID, diagnostics: diagnostics)
        await harness.phone.activate(reachable: true)
        await harness.watch.activate(reachable: true)
        return harness
    }

    // MARK: - Negotiation

    @Test func testActivationNegotiatesAcrossTheLinkAndBothSidesReportConnected() async {
        let harness = await makeHarness()
        await harness.phone.activate(reachable: true)
        await harness.watch.activate(reachable: true)

        let session = await harness.watch.negotiatedSession
        #expect(session != nil)
        #expect(session?.pairedLibraryID == libraryID)
        let watchState = await harness.watch.connectionState
        #expect(watchState == .connected(lastReplyAt: watchState.lastReplyAt ?? Date.distantPast))
        let showsConnected = await harness.watch.showsConnectedFeatures
        #expect(showsConnected)

        // A watch with no prior binding adopts the phone's identity silently — there is nothing to
        // lose, so there is nothing to ask about.
        let bound = await harness.watch.pairedLibraryID
        #expect(bound == libraryID)
        let saved = await harness.watchState.loadPairedLibraryID()
        #expect(saved == libraryID)
        let hellos = await harness.phoneObserver.hellos
        #expect(hellos.count == 1)
    }

    @Test func testNegotiationIntersectsCapabilitiesToWhatBothSidesOffer() async {
        let harness = await makeHarness(
            watchCapabilities: [.connectedSearch, .connectedBrowse, .collectionDetail],
            phoneCapabilities: [.connectedSearch, .phonePlaybackControl])
        await harness.phone.activate(reachable: true)
        await harness.watch.activate(reachable: true)

        let session = await harness.watch.negotiatedSession
        #expect(session?.capabilities == Set([WatchCapability.connectedSearch]))
        // The watch must not offer connected browse in its UI when the phone cannot serve it.
        #expect(session?.supports(.connectedBrowse) == false)
    }

    @Test func testAPhoneOnANewerProtocolLeavesTheWatchInATerminalUpgradeState() async {
        let harness = await makeHarness()
        await harness.handler.setHelloProtocolVersion(WatchProtocolEnvelope.currentProtocolVersion + 1)
        await harness.phone.activate(reachable: true)
        await harness.watch.activate(reachable: true)

        let state = await harness.watch.connectionState
        #expect(state == .incompatibleProtocol)
        let faults = await harness.watchObserver.negotiationFaults
        #expect(faults.map(\.code) == [.protocolUpgradeRequired])
        // A-07: an unusable peer must not take the downloads with it.
        let removals = await harness.watchObserver.removals
        #expect(removals.isEmpty)
    }

    @Test func testAWatchOnAnOlderProtocolGetsAnErrorReplyRatherThanSilence() async {
        // The phone cannot decode a v99 envelope, but answering nothing would leave that watch
        // spinning for its whole deadline instead of showing Upgrade Required.
        let harness = await makeHarness()
        let future = try? WatchProtocolEnvelope.encode(kind: .hello, payload: WatchHello(),
                                                       pairedLibraryID: libraryID, protocolVersion: 99)
        let reply = await harness.phone.receiveImmediate(try! #require(future))
        let envelope = try? WatchProtocolEnvelope.decode(try #require(reply)).get()
        #expect(envelope?.kind == .error)
        #expect((try? envelope?.decodePayload(WatchProtocolFault.self).code) == .protocolUpgradeRequired)
    }

    // MARK: - Immediate requests

    @Test func testSearchRoundTripsAndReturnsThePhonesRows() async {
        let harness = await makeConnectedHarness()
        await harness.handler.setRows([
            WatchResultRow(kind: .track, id: "t1", title: "Blue Monday", subtitle: "New Order"),
            WatchResultRow(kind: .album, id: "al1", title: "Power, Corruption & Lies")
        ])

        let outcome = await harness.watch.search("blue")
        guard case .results(let response) = outcome else {
            Issue.record("expected results, got \(outcome)")
            return
        }
        #expect(response.query == "blue")
        #expect(response.rows.map(\.id) == ["t1", "al1"])
        let kinds = await harness.link.deliveredKinds(from: .watch)
        #expect(kinds.contains(.searchRequest))
    }

    @Test func testALateReplyFromASupersededSearchIsDiscarded() async {
        // C-04. The first query is held open on the phone while the user keeps typing.
        let harness = await makeConnectedHarness()
        await harness.handler.setRows([WatchResultRow(kind: .track, id: "stale", title: "Stale")])
        await harness.handler.hold(query: "blu")

        async let first = harness.watch.search("blu")
        await harness.handler.waitForHeldRequest()

        await harness.handler.setRows([WatchResultRow(kind: .track, id: "fresh", title: "Fresh")])
        let second = await harness.watch.search("blue")
        guard case .results(let fresh) = second else {
            Issue.record("expected results, got \(second)")
            return
        }
        #expect(fresh.rows.map(\.id) == ["fresh"])

        await harness.handler.releaseHeldRequest()
        let late = await first
        #expect(late == .superseded, "the answer to a query the user has already replaced must not repaint the list")
    }

    @Test func testAnUnansweredRequestFailsOnItsDeadlineAndOpensTheGracePeriod() async {
        let harness = await makeConnectedHarness()
        await harness.link.setSwallowImmediateReplies(true)

        let outcome = await harness.watch.search("anything")
        guard case .failed(let fault) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(fault.code == .requestTimedOut)

        // §6.3: the command failed loudly, but the global mode waits out the grace period first.
        let state = await harness.watch.connectionState
        if case .suspectedDisconnected = state {} else { Issue.record("expected suspicion, got \(state)") }
        let confirmed = await harness.watchObserver.confirmedDisconnections
        #expect(confirmed == 0)
    }

    @Test func testADomainFailureOnThePhoneArrivesAsATypedCodeNotAString() async {
        let harness = await makeConnectedHarness()
        await harness.handler.setSearchFault(WatchProtocolFault(code: .authenticationRequired))

        let outcome = await harness.watch.search("anything")
        guard case .failed(let fault) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(fault.code == .authenticationRequired)
        #expect(fault.code.retryPolicy == .externalActionRequired)
    }

    @Test func testAPlayCommandReachesThePhoneAndItsSnapshotUpdatesTheWatch() async {
        let harness = await makeConnectedHarness()
        let snapshot = playbackSnapshot(revision: 4, isPlaying: true)
        await harness.handler.setCommandReply(.accepted(snapshot))

        let reply = await harness.watch.send(.playCollection(.playlist("p1"), startIndex: 2))
        #expect(reply.accepted)
        let commands = await harness.handler.commands
        #expect(commands.first?.action == .playCollection)
        #expect(commands.first?.startIndex == 2)
        // The reply doubles as a snapshot, so the watch's now-playing updates without a second trip.
        let playbacks = await harness.watchObserver.playbacks
        #expect(playbacks.last?.revision == 4)
    }

    // MARK: - Application context (C-01)

    @Test func testTheWatchAppliesTheContextTheSessionAlreadyHeldAtActivation() async {
        // C-01: a watch launched while the phone is asleep must draw the last known state rather
        // than an empty screen waiting for a message that will not come.
        let harness = await makeHarness(boundLibraryID: libraryID)
        await harness.phone.activate(reachable: true)
        await harness.phone.publishContext(playback: playbackSnapshot(revision: 9, isPlaying: true))

        let held = await harness.link.latestApplicationContext(from: .phone)
        await harness.link.setReachable(false)
        await harness.watch.activate(reachable: false, receivedContext: held)

        let playbacks = await harness.watchObserver.playbacks
        #expect(playbacks.last?.revision == 9)
        #expect(playbacks.last?.isPlaying == true)
        // Honest about the link even while showing the cached state.
        let showsConnected = await harness.watch.showsConnectedFeatures
        #expect(!showsConnected)
    }

    @Test func testPublishingContextSendsTheWholeSnapshotSoNeitherHalfErasesTheOther() async {
        let harness = await makeConnectedHarness()
        await harness.phone.publishContext(playback: playbackSnapshot(revision: 2, isPlaying: true))
        await harness.phone.publishContext(downloads: WatchDownloadStatusSnapshot(
            revision: 3, queuedCount: 4, activeCount: 1, failedCount: 0))

        // `updateApplicationContext` replaces the dictionary wholesale, so a downloads-only publish
        // that dropped the playback half would blank the watch's Now Playing.
        let playbacks = await harness.watchObserver.playbacks
        let downloads = await harness.watchObserver.downloadStatuses
        #expect(playbacks.last?.revision == 2)
        #expect(downloads.last?.queuedCount == 4)
    }

    @Test func testRepublishingAnIdenticalContextIsSuppressed() async {
        let harness = await makeConnectedHarness()
        let snapshot = playbackSnapshot(revision: 2, isPlaying: true)
        let first = await harness.phone.publishContext(playback: snapshot)
        let second = await harness.phone.publishContext(playback: snapshot)
        #expect(first)
        #expect(!second, "an unchanged context is a wasted wake-up on both devices")
    }

    @Test func testAReplayedContextAtActivationIsAppliedWithoutRegressingNewerState() async {
        // A session hands back its stored context on every activation, including one the watch has
        // already applied.
        let harness = await makeConnectedHarness()
        await harness.phone.publishContext(playback: playbackSnapshot(revision: 5, isPlaying: true))
        await harness.link.replayApplicationContext(from: .phone)
        await harness.link.replayApplicationContext(from: .phone)

        let playbacks = await harness.watchObserver.playbacks
        #expect(playbacks.last?.revision == 5)
        #expect(Set(playbacks.map(\.revision)) == [5], "a replay must not move state backward")
    }

    // MARK: - Durable events (C-05, C-06, C-07)

    @Test func testConnectedRemovalDoesNotWaitForBackgroundQueueAndReplayIsSafe() async {
        let harness = await makeConnectedHarness()
        await harness.link.setHoldingUserInfo(true)
        await harness.phone.sendRemoveAssets(["t1"], reason: .userRemoved)
        let immediate = await harness.watchObserver.removals
        #expect(immediate.count == 1)
        #expect(immediate.first?.trackIDs == ["t1"])
        await harness.link.flushHeldUserInfo()
        let replayed = await harness.watchObserver.removals
        #expect(replayed.count == 1, "Durable replay must not repeat an immediately applied removal")
    }

    @Test func testADuplicatedUserInfoDeliveryIsAppliedOnce() async {
        let harness = await makeConnectedHarness()
        await harness.link.setDuplicateDeliveries(true)
        await harness.phone.sendRemoveAssets(["t1", "t2"], reason: .rootRemoved)

        let removals = await harness.watchObserver.removals
        #expect(removals.count == 1, "a redelivered delete must not run twice")
        #expect(removals.first?.trackIDs == ["t1", "t2"])
    }

    @Test func testOutOfOrderDurableEventsConvergeOnTheNewestRevision() async {
        let harness = await makeConnectedHarness()
        await harness.link.setHoldingUserInfo(true)
        await harness.phone.sendDownloadRoots([root(id: "r1", trackIDs: ["t1"])])
        await harness.phone.sendDownloadRoots([root(id: "r1", trackIDs: ["t1", "t2"])])
        await harness.phone.sendDownloadRoots([root(id: "r1", trackIDs: ["t1", "t2", "t3"])])
        let held = await harness.link.heldUserInfoCount()
        #expect(held == 3)

        // Delivered newest-first, which `transferUserInfo` makes no promise against.
        await harness.link.flushHeldUserInfo(reversed: true)

        let roots = await harness.watchObserver.downloadRoots
        #expect(roots.count == 1, "the two older revisions are stale on arrival")
        #expect(roots.first?.desiredTrackIDs == ["t1", "t2", "t3"])
    }

    @Test func testAStaleRevisionIsAcknowledgedWithoutBeingApplied() async {
        let harness = await makeConnectedHarness()
        await harness.phone.sendDownloadRoots([root(id: "r1", trackIDs: ["t1", "t2"])])
        let applied = await harness.watchObserver.downloadRoots
        #expect(applied.count == 1)

        // Same content, older revision — a retransmission from a phone that lost its place.
        let stale = try? WatchProtocolEnvelope.fromPhone(
            kind: .setDownloadRoots,
            payload: WatchSetDownloadRoots(revision: 0, roots: [root(id: "r1", trackIDs: [])]),
            libraryID: libraryID, revision: 0)
        await harness.watch.receiveUserInfo(try! #require(stale))

        let after = await harness.watchObserver.downloadRoots
        #expect(after.count == 1, "an older revision must not empty the download roots")
        #expect(after.first?.desiredTrackIDs == ["t1", "t2"])
    }

    @Test func testTheWatchSendsItsManifestAndReconciliationRequestsToThePhone() async {
        let harness = await makeConnectedHarness()
        let manifest = WatchManifestPayload(manifestID: "m1", readyTrackIDs: ["t1", "t2"],
                                            installedBytes: 2_048, capacityBytes: 8_192, freeBytes: 6_144)
        await harness.watch.sendManifest(manifest)
        await harness.watch.requestReconciliation(scope: .manifest, trigger: .storeRecovered)

        let manifests = await harness.handler.receivedManifests
        let reconciliations = await harness.handler.receivedReconciliations
        #expect(manifests.map(\.manifestID) == ["m1"])
        #expect(reconciliations.first?.scope == .manifest)
        #expect(reconciliations.first?.trigger == .storeRecovered)
    }

    @Test func testFileIngressRoutesArtworkByDiscriminatorAndLegacyFilesToAudio() async {
        let harness = await makeConnectedHarness()
        let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-audio-\(UUID().uuidString).m4a")
        let artworkURL = FileManager.default.temporaryDirectory.appendingPathComponent("art-\(UUID().uuidString).jpg")
        await harness.watch.receiveFile(audioURL, metadata: ["trackID": "t1", "expectedBytes": "1"])
        await harness.watch.receiveFile(artworkURL, metadata: ["assetKind": "artwork", "artworkID": "a"])

        let audioFiles = await harness.watchObserver.audioFiles
        let artworkFiles = await harness.watchObserver.artworkFiles
        #expect(audioFiles == [audioURL.lastPathComponent])
        #expect(artworkFiles == [artworkURL.lastPathComponent])
    }

    @Test func testTheWatchCanAskThePhoneToDownloadAndDropASingleTrack() async {
        let harness = await makeConnectedHarness()
        await harness.watch.requestDownload(trackID: "t9", wantsDownload: true)
        await harness.watch.requestDownload(trackID: "t9", wantsDownload: false)

        let requests = await harness.handler.receivedDownloadRequests
        #expect(requests.map(\.trackID) == ["t9", "t9"])
        #expect(requests.map(\.wantsDownload) == [true, false])
    }

    @Test func testARedeliveredWatchDownloadRequestIsAppliedOnce() async {
        let harness = await makeConnectedHarness()
        await harness.link.setDuplicateDeliveries(true)
        await harness.watch.requestDownload(trackID: "t9", wantsDownload: true)

        let requests = await harness.handler.receivedDownloadRequests
        #expect(requests.count == 1, "a redelivered download request must not download twice")
    }

    @Test func testThePhoneAppliesAWatchManifestOnlyOnceWhenItIsRedelivered() async {
        let harness = await makeConnectedHarness()
        await harness.link.setDuplicateDeliveries(true)
        await harness.watch.sendManifest(WatchManifestPayload(manifestID: "m1", readyTrackIDs: ["t1"], installedBytes: 1_024))

        let manifests = await harness.handler.receivedManifests
        #expect(manifests.count == 1, "the phone needs the same idempotency the watch has")
    }

    // MARK: - Reconnect (C-08, C-09, C-10)

    @Test func testAConfirmedOutageAnnouncesOnceAndReconnectRestoresConnectedFeatures() async {
        let harness = await makeConnectedHarness()
        await harness.link.setReachable(false)
        await harness.watch.reachabilityChanged(false)

        // Still connected as far as the screen is concerned, until the grace period expires.
        let duringGrace = await harness.watch.showsConnectedFeatures
        #expect(duringGrace)

        await waitUntil("the grace period is confirmed") {
            await harness.watchObserver.confirmedDisconnections == 1
        }
        let showsConnected = await harness.watch.showsConnectedFeatures
        #expect(!showsConnected, "C-09: a confirmed outage drops to Downloads-only mode")

        await harness.link.setReachable(true)
        await harness.watch.reachabilityChanged(true)
        let reconnects = await harness.watchObserver.reconnections
        #expect(reconnects == 1)
        let confirmed = await harness.watchObserver.confirmedDisconnections
        #expect(confirmed == 1, "one alert per outage")
        let restored = await harness.watch.showsConnectedFeatures
        #expect(restored)

        // C-10: reconnecting re-negotiates rather than replaying whatever it last knew.
        let hellos = await harness.phoneObserver.hellos
        #expect(hellos.count == 2)
    }

    @Test func testASubGracePeriodBlipNeverConfirmsADisconnection() async {
        let harness = await makeConnectedHarness()
        for _ in 0..<5 {
            await harness.link.setReachable(false)
            await harness.watch.reachabilityChanged(false)
            await harness.link.setReachable(true)
            await harness.watch.reachabilityChanged(true)
        }
        let confirmed = await harness.watchObserver.confirmedDisconnections
        let reconnects = await harness.watchObserver.reconnections
        #expect(confirmed == 0, "C-08: a blip must not switch the UI or fire a haptic")
        #expect(reconnects == 0)
        let showsConnected = await harness.watch.showsConnectedFeatures
        #expect(showsConnected)
    }

    // MARK: - Pairing identity (A-08)

    @Test func testAChangedLibraryIdentityAsksBeforeAnythingIsApplied() async {
        // The watch is bound to library A; the phone now says it is library B.
        let harness = await makeHarness(libraryID: "library-B", boundLibraryID: libraryID)
        await harness.phone.activate(reachable: true)
        await harness.watch.activate(reachable: true)

        let prompts = await harness.watchObserver.libraryChangePrompts
        #expect(prompts.count == 1)
        #expect(prompts.first?.current == libraryID)
        #expect(prompts.first?.incoming == "library-B")

        // Nothing is applied and nothing is deleted while the question is open.
        let bound = await harness.watch.pairedLibraryID
        #expect(bound == libraryID)
        let negotiated = await harness.watch.negotiatedSession
        #expect(negotiated == nil)
        let faults = await harness.watchObserver.negotiationFaults
        #expect(faults.map(\.code) == [.pairedLibraryChanged])
        let awaiting = await harness.watch.awaitingPairedLibraryConfirmation
        #expect(awaiting == "library-B")
    }

    @Test func testConfirmingALibraryReplacementRebindsAndRenegotiates() async {
        let harness = await makeHarness(libraryID: "library-B", boundLibraryID: libraryID)
        await harness.phone.activate(reachable: true)
        await harness.watch.activate(reachable: true)
        await harness.watch.confirmPairedLibraryReplacement()

        let bound = await harness.watch.pairedLibraryID
        #expect(bound == "library-B")
        let saved = await harness.watchState.loadPairedLibraryID()
        #expect(saved == "library-B")
        let session = await harness.watch.negotiatedSession
        #expect(session?.pairedLibraryID == "library-B")
        let awaiting = await harness.watch.awaitingPairedLibraryConfirmation
        #expect(awaiting == nil)
    }

    @Test func testRejectingALibraryReplacementKeepsTheExistingBinding() async {
        let harness = await makeHarness(libraryID: "library-B", boundLibraryID: libraryID)
        await harness.phone.activate(reachable: true)
        await harness.watch.activate(reachable: true)
        await harness.watch.rejectPairedLibraryReplacement()

        let bound = await harness.watch.pairedLibraryID
        #expect(bound == libraryID)
        let awaiting = await harness.watch.awaitingPairedLibraryConfirmation
        #expect(awaiting == nil)
        let saved = await harness.watchState.loadPairedLibraryID()
        #expect(saved == libraryID, "declining must not quietly rebind")
    }

    @Test func testAnEnvelopeFromAnotherLibraryIsNotApplied() async {
        let harness = await makeConnectedHarness()
        let foreign = try? WatchProtocolEnvelope.fromPhone(
            kind: .removeAssets,
            payload: WatchRemoveAssets(revision: 99, trackIDs: ["t1"], reason: .rootRemoved),
            libraryID: "library-B", revision: 99)
        await harness.watch.receiveUserInfo(try! #require(foreign))

        let removals = await harness.watchObserver.removals
        #expect(removals.isEmpty, "a delete signed by a library we are not bound to is not ours to run")
    }

    // MARK: - Threading

    @Test func testDeliveriesFromNonMainQueuesAreAppliedSafely() async {
        // WatchConnectivity calls back on its own queues. The coordinators are actors precisely so
        // this is boring; the test exists so it stays boring.
        let harness = await makeConnectedHarness()
        await harness.phone.publishContext(playback: playbackSnapshot(revision: 11, isPlaying: true))
        let context = await harness.link.latestApplicationContext(from: .phone)
        let userInfo = try? WatchProtocolEnvelope.fromPhone(
            kind: .removeAssets,
            payload: WatchRemoveAssets(revision: 12, trackIDs: ["t9"], reason: .userRemoved),
            libraryID: libraryID, revision: 12)

        let watch = harness.watch
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await offMainQueue()
                    #expect(!isOnMainThread())
                    if let context { await watch.receiveApplicationContext(context) }
                    if let userInfo { await watch.receiveUserInfo(userInfo) }
                }
            }
        }

        let removals = await harness.watchObserver.removals
        #expect(removals.count == 1, "eight concurrent redeliveries are still one delete")
        let playbacks = await harness.watchObserver.playbacks
        #expect(playbacks.last?.revision == 11)
    }

    // MARK: - §12 diagnostics wiring (Phase 10e)

    @Test func testASearchRoundTripRecordsARequestLatencyDiagnostic() async {
        let diag = WatchDiagnosticsRecorder()
        let harness = await makeConnectedHarness(diagnostics: diag)
        await harness.handler.setRows([WatchResultRow(kind: .track, id: "t1", title: "Blue Monday")])
        _ = await harness.watch.search("blue")

        let events = await diag.events()
        let requests = events.filter { $0.category == .request }
        #expect(requests.contains { $0.stateCode == "hello" }, "negotiation is a recorded request")
        let search = requests.first { $0.stateCode == "searchRequest" }
        #expect(search != nil, "the search round trip is recorded by its message kind")
        #expect(search?.durationMillis != nil)
        #expect((search?.durationMillis ?? -1) >= 0)
        // No event may carry a correlation id or any free text — only kinds and numbers.
        #expect(events.allSatisfy { $0.correlationID == nil })
    }

    @Test func testAFailedRequestRecordsTheFaultCodeNotTheKind() async {
        let diag = WatchDiagnosticsRecorder()
        let harness = await makeConnectedHarness(diagnostics: diag)
        await harness.link.setSwallowImmediateReplies(true)
        _ = await harness.watch.search("anything")

        let codes = await diag.events().filter { $0.category == .request }.map(\.stateCode)
        #expect(codes.contains("requestTimedOut"), "a timed-out request is recorded by its fault code")
    }

    // MARK: - Helpers

    private func playbackSnapshot(revision: Int64, isPlaying: Bool) -> WatchPhonePlaybackSnapshot {
        WatchPhonePlaybackSnapshot(
            revision: revision, source: .localLibrary, isPlaying: isPlaying, rate: isPlaying ? 1 : 0,
            currentItem: WatchTrackSummary(trackID: "t1", title: "Blue Monday", artist: "New Order",
                                           durationSeconds: 448),
            collection: .playlist("p1"), collectionTitle: "Set", queueIndex: 0, queueCount: 1,
            elapsedSeconds: 30, elapsedAnchorDate: Date(timeIntervalSince1970: 5_000))
    }

    private func root(id: WatchDownloadRootID, trackIDs: [WatchTrackID]) -> WatchDownloadRootDescriptor {
        WatchDownloadRootDescriptor(rootID: id, kind: .playlist, sourceID: "p1", title: "Set",
                                    trackIDs: trackIDs)
    }

    /// Polls an async condition instead of sleeping a fixed interval, so the grace-period tests are
    /// as fast as the machine allows and do not flake on a slow one.
    private func waitUntil(_ description: String, timeout: TimeInterval = 5,
                           _ condition: @Sendable () async -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting until \(description)", sourceLocation: sourceLocation)
    }
}

private func offMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume() }
    }
}

private func isOnMainThread() -> Bool { Thread.isMainThread }

extension WatchConnectionReducer.State {
    fileprivate var lastReplyAt: Date? {
        if case .connected(let date) = self { return date }
        return nil
    }
}

// MARK: - Doubles

/// The phone's Phase 4 request handling, stubbed. Everything it answers is set by the test.
private actor FakePhoneHandler: WatchPhoneRequestHandling {
    private let libraryID: WatchPairedLibraryID
    private var capabilities: [WatchCapability]
    private var helloProtocolVersion = WatchProtocolEnvelope.currentProtocolVersion
    private var rows: [WatchResultRow] = []
    private var searchFault: WatchProtocolFault?
    private var commandReply: WatchCommandReply = .accepted(nil)

    private(set) var commands: [WatchPlayCommand] = []
    private(set) var receivedManifests: [WatchManifestPayload] = []
    private(set) var receivedReconciliations: [WatchReconciliationRequest] = []
    private(set) var receivedDownloadRequests: [WatchDownloadRequest] = []
    private(set) var receivedDownloadControls: [WatchDownloadControl] = []

    private var heldQuery: String?
    private var heldRequestArrived = false
    private var arrivalWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(libraryID: WatchPairedLibraryID, capabilities: [WatchCapability]) {
        self.libraryID = libraryID
        self.capabilities = capabilities
    }

    func setHelloProtocolVersion(_ version: Int) { helloProtocolVersion = version }
    func setRows(_ rows: [WatchResultRow]) { self.rows = rows }
    func setSearchFault(_ fault: WatchProtocolFault?) { searchFault = fault }
    func setCommandReply(_ reply: WatchCommandReply) { commandReply = reply }

    func hold(query: String) {
        heldQuery = query
        heldRequestArrived = false
    }

    func waitForHeldRequest() async {
        guard !heldRequestArrived else { return }
        await withCheckedContinuation { arrivalWaiter = $0 }
    }

    func releaseHeldRequest() {
        heldQuery = nil
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func handleHello(_ payload: WatchHello) async -> WatchHelloReply {
        WatchHelloReply(protocolVersion: helloProtocolVersion, pairedLibraryID: libraryID,
                        capabilities: capabilities, phoneRevision: 0)
    }

    func handleSearch(_ request: WatchSearchRequest) async throws -> WatchSearchResponse {
        if request.query == heldQuery {
            heldRequestArrived = true
            arrivalWaiter?.resume()
            arrivalWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        if let searchFault { throw searchFault }
        return WatchSearchResponse(generation: request.generation, query: request.query, rows: rows)
    }

    func handleBrowse(_ request: WatchBrowseRequest) async throws -> WatchBrowseResponse {
        WatchBrowseResponse(category: request.category, generation: request.generation, rows: rows)
    }

    func handleCollection(_ request: WatchCollectionRequest) async throws -> WatchCollectionResponse {
        WatchCollectionResponse(collection: request.collection, title: "Set", tracks: [], totalCount: 0)
    }

    func handlePlayCommand(_ command: WatchPlayCommand) async -> WatchCommandReply {
        commands.append(command)
        return commandReply
    }

    func handleWatchManifest(_ payload: WatchManifestPayload) async {
        receivedManifests.append(payload)
    }

    func handleReconciliationRequest(_ request: WatchReconciliationRequest) async {
        receivedReconciliations.append(request)
    }

    func handleDownloadRequest(_ request: WatchDownloadRequest) async {
        receivedDownloadRequests.append(request)
    }

    func handleDownloadControl(_ control: WatchDownloadControl) async {
        receivedDownloadControls.append(control)
    }
}

private final actor RecordingWatchObserver: WatchConnectivityObserver {
    private(set) var states: [WatchConnectionReducer.State] = []
    private(set) var confirmedDisconnections = 0
    private(set) var reconnections = 0
    private(set) var sessions: [WatchNegotiatedSession] = []
    private(set) var negotiationFaults: [WatchProtocolFault] = []
    private(set) var playbacks: [WatchPhonePlaybackSnapshot] = []
    private(set) var downloadStatuses: [WatchDownloadStatusSnapshot] = []
    private(set) var downloadRoots: [WatchSetDownloadRoots] = []
    private(set) var removals: [WatchRemoveAssets] = []
    private(set) var reconciliations: [WatchReconciliationRequest] = []
    private(set) var libraryChangePrompts: [(current: WatchPairedLibraryID, incoming: WatchPairedLibraryID)] = []
    private(set) var audioFiles: [String] = []
    private(set) var artworkFiles: [String] = []

    func connectionStateDidChange(_ state: WatchConnectionReducer.State,
                                  connectivity: WatchConnectivityState) async {
        states.append(state)
    }
    func didConfirmDisconnection() async { confirmedDisconnections += 1 }
    func didReconnect() async { reconnections += 1 }
    func didNegotiate(_ session: WatchNegotiatedSession) async { sessions.append(session) }
    func negotiationDidFail(_ fault: WatchProtocolFault) async { negotiationFaults.append(fault) }
    func didReceivePhonePlayback(_ snapshot: WatchPhonePlaybackSnapshot) async { playbacks.append(snapshot) }
    func didReceiveDownloadStatus(_ snapshot: WatchDownloadStatusSnapshot) async { downloadStatuses.append(snapshot) }
    func didReceiveDownloadRoots(_ payload: WatchSetDownloadRoots) async { downloadRoots.append(payload) }
    func didReceiveRemoveAssets(_ payload: WatchRemoveAssets) async { removals.append(payload) }
    func phoneRequestedReconciliation(_ request: WatchReconciliationRequest) async { reconciliations.append(request) }
    func didReceiveAudioFile(at stagedURL: URL, metadata: [String: String]) async {
        audioFiles.append(stagedURL.lastPathComponent)
    }
    func didReceiveArtworkFile(at stagedURL: URL, metadata: [String: String]) async {
        artworkFiles.append(stagedURL.lastPathComponent)
    }
    func pairedLibraryChangeRequiresConfirmation(current: WatchPairedLibraryID,
                                                 incoming: WatchPairedLibraryID) async {
        libraryChangePrompts.append((current, incoming))
    }
}

private final actor RecordingPhoneObserver: PhoneWatchProtocolObserver {
    private(set) var manifests: [WatchManifestPayload] = []
    private(set) var reconciliations: [WatchReconciliationRequest] = []
    private(set) var hellos: [WatchHello] = []
    private(set) var states: [WatchConnectionReducer.State] = []

    func watchDidReportManifest(_ manifest: WatchManifestPayload) async { manifests.append(manifest) }
    func watchRequestedReconciliation(_ request: WatchReconciliationRequest) async { reconciliations.append(request) }
    func watchDidNegotiate(_ hello: WatchHello) async { hellos.append(hello) }
    func connectionStateDidChange(_ state: WatchConnectionReducer.State) async { states.append(state) }
}
