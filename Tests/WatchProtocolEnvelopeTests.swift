import XCTest
@testable import TonearmWatchProtocol

/// §5.1–5.5 codec coverage: every kind round-trips, unknown fields and versions behave as
/// specified, and the error vocabulary stays complete.
final class WatchProtocolEnvelopeTests: XCTestCase {
    func testStatusPushesCoalesceClockChangesButNotRealProgress() {
        var first = WatchDownloadStatusSnapshot(revision: 1, activeTransfers: [.init(trackID: "a", fractionComplete: 0.2)], generatedAt: Date(timeIntervalSince1970: 1))
        var later = first
        later.revision = 99
        later.generatedAt = Date(timeIntervalSince1970: 99)
        later.lastWatchReportAt = Date()
        XCTAssertEqual(first.coalescingContent, later.coalescingContent)
        first.activeTransfers[0].fractionComplete = 0.3
        XCTAssertNotEqual(first.coalescingContent, later.coalescingContent)
    }
    func testSelectedCatalogIsLZFSECompressedAndRoundTrips() throws {
        let tracks = (0..<20).map { index in
            WatchTrackSummary(trackID: WatchTrackID("track-\(index)"),
                title: String(repeating: "Long searchable track title \(index) ", count: 8),
                artist: "Same artist", albumTitle: "Same album")
        }
        let page = WatchLibraryPage(catalogID: "selected", revision: 1, pageIndex: 0,
            pageCount: 1, tracks: tracks, playlists: [], downloadSelectionOnly: true)
        let encoded = try WatchProtocolEnvelope.fromPhone(kind: .catalogPage, payload: page,
            libraryID: "library", revision: 1)
        let dictionary = try XCTUnwrap(PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])
        XCTAssertEqual(dictionary["payloadCompression"] as? String, "lzfse")
        let compressed = try XCTUnwrap(dictionary["payload"] as? Data)
        XCTAssertLessThan(compressed.count, try WatchProtocolEnvelope.encodePayload(page).count)
        let decoded = try WatchProtocolEnvelope.decode(encoded).get().decodePayload(WatchLibraryPage.self)
        XCTAssertEqual(decoded, page)
    }
    func testMinimalTrackMetadataOmitsEmptyAndDerivedFields() throws {
        let track = WatchTrackSummary(trackID: "id", title: "Title")
        let data = try WatchProtocolEnvelope.encodePayload(track)
        let fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["trackID", "title"])
        XCTAssertEqual(try PropertyListDecoder().decode(WatchTrackSummary.self, from: data), track)
    }
    func testCancellationBeforeContinuationInstallationIsNotLost() async {
        let completion = WatchImmediateCompletion()
        completion.finish(.failure(.init(code: .requestTimedOut)))
        do {
            let _: Data = try await withCheckedThrowingContinuation { completion.install($0) }
            XCTFail("Cancelled request must finish")
        } catch { XCTAssertEqual((error as? WatchProtocolFault)?.code, .requestTimedOut) }
        completion.finish(.success(Data([1])))
    }

    func testNativeCallbackThatNeverArrivesDoesNotTrapDeadlineTaskGroup() async {
        let completion = WatchImmediateCompletion()
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let _: Data = try await withWatchRequestDeadline(.milliseconds(25)) {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { completion.install($0) }
                } onCancel: {
                    completion.finish(.failure(.init(code: .requestTimedOut)))
                }
            }
            XCTFail("Missing native reply must time out")
        } catch { XCTAssertEqual((error as? WatchProtocolFault)?.code, .requestTimedOut) }
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
        completion.finish(.success(Data([42])))
    }

    func testWatchReconcilesRootUsingItsOwnFilesNotPhoneReadinessClaims() {
        let stalePhone = WatchDownloadRootStatus(rootID: "r", title: "Playlist", desiredCount: 2,
            readyCount: 2, state: .complete, trackIDs: ["a", "b"])
        let local = stalePhone.reconciled(readyTrackIDs: ["a"])
        XCTAssertEqual(local.readyCount, 1)
        XCTAssertEqual(local.state, .queued)
        let stalePending = WatchDownloadRootStatus(rootID: "r", title: "Playlist", desiredCount: 2,
            readyCount: 0, state: .queued, trackIDs: ["a", "b"])
        XCTAssertEqual(stalePending.reconciled(readyTrackIDs: ["a", "b"]).state, .complete)
    }
    func testImmediateCompletionIgnoresRepeatedErrorsAndLateReply() async {
        do {
            let _: Data = try await withCheckedThrowingContinuation { continuation in
                let completion = WatchImmediateCompletion(continuation)
                completion.finish(.failure(.init(code: .phoneUnavailable)))
                completion.finish(.failure(.init(code: .requestTimedOut)))
                completion.finish(.success(Data([1])))
            }
            XCTFail("The first error must win")
        } catch {
            XCTAssertEqual((error as? WatchProtocolFault)?.code, .phoneUnavailable)
        }
    }

    func testImmediateCompletionIgnoresLateErrorsAfterReply() async throws {
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            let completion = WatchImmediateCompletion(continuation)
            completion.finish(.success(Data([42])))
            completion.finish(.failure(.init(code: .requestTimedOut)))
            completion.finish(.success(Data([99])))
        }
        XCTAssertEqual(result, Data([42]))
    }

    func testImmediateCompletionClaimsExactlyOneConcurrentCallback() async throws {
        let result: Data = try await withCheckedThrowingContinuation { continuation in
            let completion = WatchImmediateCompletion(continuation)
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                completion.finish(.success(Data([UInt8(index)])))
            }
        }
        XCTAssertEqual(result.count, 1)
    }

    func testAudioContainerSurvivesMetadataRoundTripAndCacheNaming() throws {
        let cache = URL(fileURLWithPath: "/cache/" + String(repeating: "a", count: 64) + "-MP3")
        let metadata = WatchAudioFileMetadata(trackID: "cached", expectedBytes: 42,
            fileExtension: WatchAudioFileMetadata.fileExtension(for: cache))
        XCTAssertEqual(metadata.fileExtension, "mp3")
        XCTAssertEqual(WatchAudioFileMetadata(dictionary: metadata.dictionary), metadata)
        XCTAssertEqual(WatchAudioFileMetadata.fileExtension(for: URL(fileURLWithPath: "/music/one.M4A")), "m4a")
        XCTAssertNil(WatchAudioFileMetadata.fileExtension(for: URL(fileURLWithPath: "/cache/arbitrary-mp3")))
        XCTAssertNil(WatchAudioFileMetadata(dictionary: ["trackID": "old", "expectedBytes": "42"])?.fileExtension)
    }

    private let library = WatchPairedLibraryID("library-A")

    // MARK: - Round trips

    func testEveryRequestKindRoundTripsThroughTheEnvelope() throws {
        // One representative payload per §5.3 kind. The point of enumerating all of them is that a
        // new kind added without a codec fails here rather than in the field.
        var covered: Set<WatchMessageKind> = []

        func check(_ kind: WatchMessageKind, _ payload: some Codable & Equatable) throws {
            let data = try WatchProtocolEnvelope.encode(kind: kind, payload: payload,
                                                        pairedLibraryID: library, phoneRevision: 7)
            let envelope = try WatchProtocolEnvelope.decode(data).get()
            XCTAssertEqual(envelope.kind, kind)
            XCTAssertEqual(envelope.pairedLibraryID, library)
            XCTAssertEqual(envelope.phoneRevision, 7)
            XCTAssertEqual(envelope.protocolVersion, WatchProtocolEnvelope.currentProtocolVersion)
            XCTAssertEqual(try envelope.decodePayload(type(of: payload)), payload)
            covered.insert(kind)
        }

        let track = WatchTrackSummary(trackID: "t1", title: "Song", artist: "Artist",
                                      albumTitle: "Record", durationSeconds: 210, artworkID: "a1",
                                      isDownloadedOnWatch: true)
        let row = WatchResultRow(kind: .track, id: "t1", title: "Song", subtitle: "Artist",
                                 durationSeconds: 210)
        let playback = WatchPhonePlaybackSnapshot(
            revision: 3, source: .localLibrary, isPlaying: true, rate: 1, currentItem: track,
            collection: .playlist("p1"), collectionTitle: "Set", queueWindow: [track],
            queueIndex: 0, queueCount: 1, elapsedSeconds: 12, elapsedAnchorDate: Date(timeIntervalSince1970: 1_000),
            shuffleEnabled: true, repeatMode: .all)

        try check(.hello, WatchHello(pairedLibraryID: library, lastAppliedPhoneRevision: 4))
        try check(.helloReply, WatchHelloReply(pairedLibraryID: library, phoneRevision: 9))
        try check(.searchRequest, WatchSearchRequest(query: "song", scope: .tracks, generation: 2))
        try check(.searchResponse, WatchSearchResponse(generation: 2, query: "song", rows: [row],
                                                       nextPageToken: "page-2"))
        try check(.browseRequest, WatchBrowseRequest(category: .playlists, generation: 1))
        try check(.browseResponse, WatchBrowseResponse(category: .playlists, generation: 1, rows: [row]))
        try check(.collectionRequest, WatchCollectionRequest(collection: .playlist("p1")))
        try check(.collectionResponse, WatchCollectionResponse(collection: .playlist("p1"), title: "Set",
                                                               tracks: [track], totalCount: 1))
        try check(.playCommand, WatchPlayCommand.playCollection(.album("al1"), startIndex: 3))
        try check(.commandReply, WatchCommandReply.accepted(playback))
        try check(.phonePlaybackSnapshot, playback)
        try check(.downloadStatusSnapshot, WatchDownloadStatusSnapshot(
            revision: 5, queuedCount: 2, activeCount: 1, failedCount: 1,
            activeTransfers: [WatchTransferProgress(trackID: "t1", fractionComplete: 0.42)]))
        try check(.setDownloadRoots, WatchSetDownloadRoots(revision: 6, roots: [
            WatchDownloadRootDescriptor(rootID: "r1", kind: .playlist, sourceID: "p1", title: "Set",
                                        trackIDs: ["t1", "t2"])
        ]))
        try check(.watchManifest, WatchManifestPayload(manifestID: "m1", readyTrackIDs: ["t1"],
                                                        installedBytes: 4_096, capacityBytes: 8_000,
                                                        freeBytes: 3_000,
                                                        generatedAt: Date(timeIntervalSince1970: 2_000)))
        try check(.requestReconciliation, WatchReconciliationRequest(scope: .manifest, trigger: .storeRecovered))
        try check(.removeAssets, WatchRemoveAssets(revision: 8, trackIDs: ["t1"], reason: .rootRemoved))
        try check(.requestDownload, WatchDownloadRequest(trackID: "t1", wantsDownload: true))
        try check(.downloadControl, WatchDownloadControl(action: .retryFailed, rootID: "r1"))
        try check(.catalogPage, WatchLibraryPage(
            catalogID: "catalog-1", revision: 7, pageIndex: 0, pageCount: 1,
            tracks: [track], playlists: [WatchLibraryPlaylist(playlistID: "p1", title: "Set",
                                                               trackIDs: ["t1"])]) )
        try check(.error, WatchProtocolFault(code: .insufficientWatchStorage, retryAfterSeconds: 30))

        XCTAssertEqual(covered, Set(WatchMessageKind.allCases),
                       "a message kind has no codec test: \(Set(WatchMessageKind.allCases).subtracting(covered))")
    }

    func testEnvelopeIsBinaryPropertyList() throws {
        let data = try WatchProtocolEnvelope.encode(kind: .hello, payload: WatchHello(),
                                                    pairedLibraryID: library)
        var format = PropertyListSerialization.PropertyListFormat.xml
        _ = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        XCTAssertEqual(format, .binary)
    }

    func testTypedIDsEncodeAsBareStrings() throws {
        // A keyed `{"rawValue": …}` shape would silently double the size of every ID in every page.
        let data = try JSONEncoder().encode(WatchTrackID("track-7"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"track-7\"")
        XCTAssertEqual(try JSONDecoder().decode(WatchTrackID.self, from: data), "track-7")
    }

    // MARK: - Version and kind handling

    func testUnsupportedProtocolVersionIsReportedWithBothVersions() throws {
        let data = try WatchProtocolEnvelope.encode(kind: .hello, payload: WatchHello(),
                                                    pairedLibraryID: library, protocolVersion: 99)
        guard case .failure(let failure) = WatchProtocolEnvelope.decode(data) else {
            return XCTFail("a version-99 envelope must not decode")
        }
        XCTAssertEqual(failure, .unsupportedVersion(peer: 99, local: WatchProtocolEnvelope.currentProtocolVersion))
        XCTAssertEqual(failure.errorCode, .protocolUpgradeRequired)
    }

    func testUnknownKindFromASupportedVersionNamesTheKind() throws {
        // Hand-built because the enum cannot express a kind we do not have.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(ForwardCompatibleWire(
            protocolVersion: WatchProtocolEnvelope.currentProtocolVersion, messageID: UUID(), correlationID: nil, pairedLibraryID: "library-A",
            phoneRevision: 0, sentAt: Date(), kind: "teleport", payload: Data(),
            unknownFutureField: "ignored", anotherUnknown: 42))
        guard case .failure(let failure) = WatchProtocolEnvelope.decode(data) else {
            return XCTFail("an unknown kind must not decode")
        }
        XCTAssertEqual(failure, .unsupportedKind("teleport"))
        XCTAssertEqual(failure.errorCode, .protocolUpgradeRequired)
    }

    func testUnknownFieldsFromANewerPeerAreIgnored() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let messageID = UUID()
        let data = try encoder.encode(ForwardCompatibleWire(
            protocolVersion: WatchProtocolEnvelope.currentProtocolVersion, messageID: messageID, correlationID: nil, pairedLibraryID: "library-A",
            phoneRevision: 12, sentAt: Date(timeIntervalSince1970: 500), kind: "hello",
            payload: try WatchProtocolEnvelope.encodePayload(WatchHello()),
            unknownFutureField: "a field we have never heard of", anotherUnknown: 7))
        let envelope = try WatchProtocolEnvelope.decode(data).get()
        XCTAssertEqual(envelope.kind, .hello)
        XCTAssertEqual(envelope.messageID, messageID)
        XCTAssertEqual(envelope.phoneRevision, 12)
    }

    func testMalformedDataIsMalformedNotAVersionProblem() {
        guard case .failure(let failure) = WatchProtocolEnvelope.decode(Data([0x00, 0x01, 0x02])) else {
            return XCTFail("random bytes must not decode")
        }
        XCTAssertEqual(failure, .malformed)
        // A corrupt blob is a transport problem, not a reason to tell the user to update the app.
        XCTAssertEqual(failure.errorCode, .transferFailed)
    }

    func testOptionalPayloadFieldsSurviveOmission() throws {
        let minimal = WatchPlayCommand(action: .pause)
        let data = try WatchProtocolEnvelope.encode(kind: .playCommand, payload: minimal,
                                                    pairedLibraryID: library)
        let decoded = try WatchProtocolEnvelope.decode(data).get().decodePayload(WatchPlayCommand.self)
        XCTAssertEqual(decoded, minimal)
        XCTAssertNil(decoded.collection)
        XCTAssertNil(decoded.startIndex)
    }

    func testArtworkMetadataRoundTripsAndUsesArtworkDiscriminator() throws {
        let metadata = WatchArtworkFileMetadata(
            artworkID: String(repeating: "a", count: 64), expectedBytes: 12_345,
            sha256: String(repeating: "a", count: 64), role: .custom, phoneRevision: 9)
        XCTAssertEqual(WatchArtworkFileMetadata(dictionary: metadata.dictionary), metadata)
        XCTAssertEqual(metadata.dictionary["assetKind"], "artwork")
        XCTAssertNil(WatchArtworkFileMetadata(dictionary: ["assetKind": "audio"]))
    }

    func testTrackSummaryDecodesWhenArtworkBindingsAreAbsent() throws {
        let legacyJSON = Data(#"{"trackID":"t1","title":"Song","artist":"","albumTitle":"","artworkID":null,"isDownloadedOnWatch":false}"#.utf8)
        let decoded = try JSONDecoder().decode(WatchTrackSummary.self, from: legacyJSON)
        XCTAssertNil(decoded.coverArtworkID)
        XCTAssertNil(decoded.customArtworkID)
    }

    func testLegacyManifestDecodesWhenArtworkIDsWereNotPresent() throws {
        let legacyJSON = Data(#"{"manifestID":"m1","readyTrackIDs":["t1"],"installedBytes":42}"#.utf8)
        let decoded = try JSONDecoder().decode(WatchManifestPayload.self, from: legacyJSON)
        XCTAssertEqual(decoded.readyTrackIDs, [WatchTrackID("t1")])
        XCTAssertEqual(decoded.installedBytes, 42)
        XCTAssertEqual(decoded.installedArtworkIDs, [])
        XCTAssertNil(decoded.lastCatalogReceivedAt)
        XCTAssertNil(decoded.lastAudioInstalledAt)
        XCTAssertTrue(decoded.partialAudioDownloads.isEmpty)
        XCTAssertTrue(decoded.audioDownloadFailures.isEmpty)
        XCTAssertTrue(decoded.audioFailureTransferIDs.isEmpty)
    }

    // MARK: - Correlation

    func testReplyCarriesTheRequestsMessageIDAsCorrelation() throws {
        let requestData = try WatchProtocolEnvelope.encode(
            kind: .collectionRequest, payload: WatchCollectionRequest(collection: .album("al1")),
            pairedLibraryID: library)
        let request = try WatchProtocolEnvelope.decode(requestData).get()
        let replyData = try request.reply(
            kind: .collectionResponse,
            payload: WatchCollectionResponse(collection: .album("al1"), title: "Record",
                                             tracks: [], totalCount: 0))
        let reply = try WatchProtocolEnvelope.decode(replyData).get()
        XCTAssertEqual(reply.correlationID, request.messageID)
        XCTAssertNotEqual(reply.messageID, request.messageID)
        XCTAssertFalse(try reply.decodePayload(WatchCollectionResponse.self).isPlayable)
    }

    func testDictionaryChannelUsesOneStableKey() throws {
        let data = try WatchProtocolEnvelope.encode(kind: .hello, payload: WatchHello(),
                                                    pairedLibraryID: library)
        let dictionary = WatchProtocolEnvelope.dictionary(for: data)
        XCTAssertEqual(dictionary.count, 1)
        XCTAssertEqual(WatchProtocolEnvelope.payloadData(in: dictionary), data)
        XCTAssertNil(WatchProtocolEnvelope.payloadData(in: ["someOtherKey": data]))
    }

    // MARK: - §5.5 vocabulary

    func testEveryErrorCodeHasARetryPolicyAndACopyStringWithNoInterpolation() {
        for code in WatchProtocolErrorCode.allCases {
            let message = code.safeDisplayMessage
            XCTAssertFalse(message.isEmpty, "\(code) has no display message")
            // A-06: the copy table is fixed text. If a message ever gains a placeholder, it is one
            // step from carrying a title or a path.
            XCTAssertFalse(message.contains("\\("), "\(code) interpolates into its display message")
            XCTAssertFalse(message.contains("/"), "\(code) display message looks like a path")
        }
        XCTAssertEqual(WatchProtocolErrorCode.requestTimedOut.retryPolicy, .singleUserRetry)
        XCTAssertEqual(WatchProtocolErrorCode.waitingForWiFi.retryPolicy, .automaticWhenPolicyPermits)
        XCTAssertEqual(WatchProtocolErrorCode.storeRecovered.retryPolicy, .informationalOnly)
        XCTAssertEqual(WatchProtocolErrorCode.protocolUpgradeRequired.retryPolicy, .appUpgradeRequired)
    }

    func testFaultPayloadCarriesNoFreeText() throws {
        // The whole of A-06's protocol-side guarantee: there is no string field to leak into.
        let fault = WatchProtocolFault(code: .checksumMismatch)
        let data = try WatchProtocolEnvelope.encodePayload(fault)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dictionary = try XCTUnwrap(plist as? [String: Any])
        XCTAssertEqual(Set(dictionary.keys), ["code"])
    }

    func testDownloadStatusSnapshotToleratesAnOlderPhoneOmittingActiveTransfers() throws {
        let legacyJSON = Data(#"{"revision":3,"queuedCount":1,"activeCount":1}"#.utf8)
        let decoded = try JSONDecoder().decode(WatchDownloadStatusSnapshot.self, from: legacyJSON)
        XCTAssertEqual(decoded.activeCount, 1)
        XCTAssertTrue(decoded.activeTransfers.isEmpty)
        XCTAssertNil(decoded.fraction(for: "t1"))
        XCTAssertTrue(decoded.activities.isEmpty)
        XCTAssertNil(decoded.generatedAt)
        XCTAssertNil(decoded.lastWatchReportAt)
    }

    func testMessageKindsAreRoutedToTheChannelSection5_2Assigns() {
        XCTAssertEqual(WatchMessageKind.searchRequest.channel, .immediate)
        XCTAssertEqual(WatchMessageKind.phonePlaybackSnapshot.channel, .applicationContext)
        XCTAssertEqual(WatchMessageKind.setDownloadRoots.channel, .userInfo)
        XCTAssertEqual(WatchMessageKind.watchManifest.channel, .userInfo)
        XCTAssertEqual(WatchMessageKind.requestDownload.channel, .userInfo)
        XCTAssertTrue(WatchMessageKind.removeAssets.isRevisioned)
        XCTAssertFalse(WatchMessageKind.searchRequest.isRevisioned)
        XCTAssertFalse(WatchMessageKind.requestDownload.isRevisioned)
    }

    // MARK: - Negotiation

    func testCapabilityNegotiationIntersectsAndRejectsAVersionMismatch() {
        let local = WatchHello(capabilities: [.connectedSearch, .connectedBrowse, .downloadRoots, .artworkAssets])
        let remote = WatchHelloReply(pairedLibraryID: library,
                                     capabilities: [.connectedSearch, .phonePlaybackControl, .artworkAssets],
                                     phoneRevision: 4)
        guard case .success(let session) = WatchCapabilityNegotiation.negotiate(local: local, remote: remote) else {
            return XCTFail("same-version peers must negotiate")
        }
        XCTAssertEqual(session.capabilities, [.connectedSearch, .artworkAssets])
        XCTAssertTrue(session.supports(.artworkAssets))
        XCTAssertTrue(session.supports(.connectedSearch))
        XCTAssertFalse(session.supports(.phonePlaybackControl))
        XCTAssertEqual(session.phoneRevision, 4)

        let futureRemote = WatchHelloReply(protocolVersion: WatchProtocolEnvelope.currentProtocolVersion + 1, pairedLibraryID: library)
        guard case .failure(let fault) = WatchCapabilityNegotiation.negotiate(local: local, remote: futureRemote) else {
            return XCTFail("a version mismatch must not negotiate")
        }
        XCTAssertEqual(fault.code, .protocolUpgradeRequired)
    }

    // MARK: - Playback anchoring

    func testElapsedPositionIsProjectedFromTheAnchorAndClampedToDuration() {
        let anchor = Date(timeIntervalSince1970: 1_000)
        let track = WatchTrackSummary(trackID: "t1", title: "Song", durationSeconds: 100)
        let playing = WatchPhonePlaybackSnapshot(revision: 1, isPlaying: true, rate: 1,
                                                 currentItem: track, elapsedSeconds: 10,
                                                 elapsedAnchorDate: anchor)
        XCTAssertEqual(playing.elapsedSeconds(at: anchor), 10, accuracy: 0.001)
        XCTAssertEqual(playing.elapsedSeconds(at: anchor.addingTimeInterval(5)), 15, accuracy: 0.001)
        // A snapshot that arrived after the track ended must not render past the end.
        XCTAssertEqual(playing.elapsedSeconds(at: anchor.addingTimeInterval(500)), 100, accuracy: 0.001)

        let paused = WatchPhonePlaybackSnapshot(revision: 1, isPlaying: false, rate: 0,
                                                currentItem: track, elapsedSeconds: 42,
                                                elapsedAnchorDate: anchor)
        XCTAssertEqual(paused.elapsedSeconds(at: anchor.addingTimeInterval(60)), 42, accuracy: 0.001)
    }

    func testSearchDebouncePolicyMatchesSection6_1() {
        XCTAssertFalse(WatchSearchRequest.isSubmittableWhileTyping("a"))
        XCTAssertFalse(WatchSearchRequest.isSubmittableWhileTyping("  a  "))
        XCTAssertTrue(WatchSearchRequest.isSubmittableWhileTyping("ab"))
        XCTAssertEqual(WatchSearchRequest.debounceInterval, 0.25, accuracy: 0.0001)
        // §6.1 caps a page at 30 mixed results, and the initializer enforces it rather than trusting
        // the caller.
        XCTAssertEqual(WatchSearchRequest(query: "x", generation: 1, limit: 5_000).limit, 30)
    }

    func testDesiredTrackSetDeduplicatesAcrossRoots() {
        // E-04: a track required by two roots is one desired track.
        let roots = WatchSetDownloadRoots(revision: 1, roots: [
            WatchDownloadRootDescriptor(rootID: "r1", kind: .playlist, sourceID: "p1", trackIDs: ["t1", "t2"]),
            WatchDownloadRootDescriptor(rootID: "r2", kind: .albumBatch, sourceID: "al1", trackIDs: ["t2", "t3"])
        ])
        XCTAssertEqual(roots.desiredTrackIDs, ["t1", "t2", "t3"])
    }
}

/// A same-version envelope carrying fields this build has never heard of.
private struct ForwardCompatibleWire: Codable {
    var protocolVersion: Int
    var messageID: UUID
    var correlationID: UUID?
    var pairedLibraryID: String
    var phoneRevision: Int64
    var sentAt: Date
    var kind: String
    var payload: Data
    var unknownFutureField: String
    var anotherUnknown: Int
}
