import Foundation
import TonearmWatchProtocol

/// The result of one connected search. `superseded` is a first-class outcome rather than an empty
/// result set: §6.1 requires that a late reply from a cancelled query never repaints the list, and a
/// caller that cannot tell "no results" from "you already asked something else" will repaint it.
public enum WatchSearchOutcome: Equatable, Sendable {
    case results(WatchSearchResponse)
    case superseded
    case failed(WatchProtocolFault)
}

public enum WatchBrowseOutcome: Equatable, Sendable {
    case results(WatchBrowseResponse)
    case superseded
    case failed(WatchProtocolFault)
}

/// The watch's half of the §5 protocol: negotiation, immediate requests with deadlines, durable
/// event application, and the §6.3 connection reducer.
///
/// It owns no UI and no store. Everything it learns leaves through `WatchConnectivityObserver`, and
/// everything it persists goes through `WatchSyncStateStore` — which is what lets the whole thing be
/// driven by `WatchFakeDuplexLink` in `swift test` with no simulator and no timers longer than the
/// grace period the test itself chooses.
public actor WatchConnectivityCoordinator: WatchProtocolLifecycle {
    public struct Configuration: Sendable {
        public var capabilities: [WatchCapability]
        public var immediateDeadline: Duration
        public var gracePeriod: TimeInterval
        public var ledgerCapacity: Int

        public init(capabilities: [WatchCapability] = WatchCapability.allCases,
                    immediateDeadline: Duration = WatchRequestDeadline.immediate,
                    gracePeriod: TimeInterval = WatchConnectionReducer.defaultGracePeriod,
                    ledgerCapacity: Int = WatchAppliedMessageLedger.defaultCapacity) {
            self.capabilities = capabilities
            self.immediateDeadline = immediateDeadline
            self.gracePeriod = gracePeriod
            self.ledgerCapacity = ledgerCapacity
        }
    }

    private let transport: any WatchProtocolTransport
    private let stateStore: any WatchSyncStateStore
    private let ledger: WatchAppliedMessageLedger
    private let configuration: Configuration
    private weak var observer: (any WatchConnectivityObserver)?

    private var reducer: WatchConnectionReducer
    private var lastReportedState: WatchConnectionReducer.State
    private var graceTask: Task<Void, Never>?
    private var revisions = WatchRevisionGate()

    private var boundLibraryID: WatchPairedLibraryID?
    private var pendingLibraryChange: WatchPairedLibraryID?
    private var negotiated: WatchNegotiatedSession?
    private var searchGeneration = 0
    private var browseGeneration = 0

    public init(transport: any WatchProtocolTransport,
                stateStore: any WatchSyncStateStore = WatchInMemorySyncStateStore(),
                ledger: WatchAppliedMessageLedger? = nil,
                configuration: Configuration = Configuration(),
                observer: (any WatchConnectivityObserver)? = nil) {
        self.transport = transport
        self.stateStore = stateStore
        self.configuration = configuration
        self.ledger = ledger ?? WatchAppliedMessageLedger(capacity: configuration.ledgerCapacity)
        self.observer = observer
        let reducer = WatchConnectionReducer(gracePeriod: configuration.gracePeriod)
        self.reducer = reducer
        lastReportedState = reducer.state
    }

    public func setObserver(_ observer: (any WatchConnectivityObserver)?) { self.observer = observer }

    // MARK: - Observable state

    public var connectionState: WatchConnectionReducer.State { reducer.state }
    public var connectivity: WatchConnectivityState { reducer.connectivity }
    public var showsConnectedFeatures: Bool { reducer.isConnectedForUI }
    public var negotiatedSession: WatchNegotiatedSession? { negotiated }
    public var pairedLibraryID: WatchPairedLibraryID? { boundLibraryID }
    public var awaitingPairedLibraryConfirmation: WatchPairedLibraryID? { pendingLibraryChange }

    // MARK: - Lifecycle

    /// Called when the session finishes activating. `receivedContext` is whatever the session was
    /// already holding — C-01 requires that it be applied, not waited for.
    public func activate(reachable: Bool, receivedContext: Data? = nil) async {
        boundLibraryID = await stateStore.loadPairedLibraryID()
        let lastApplied = await stateStore.loadLastAppliedPhoneRevision()
        if lastApplied > 0 { _ = revisions.evaluate(scope: .catalog, revision: lastApplied) }
        await run(reducer.apply(.activated(reachable: reachable), at: Date()))
        // C-01: the session hands back whatever context it was already holding, which may have been
        // published hours ago. Draw it, but do not let it argue that the phone is awake — a watch
        // out of range would otherwise show a connected UI built entirely from cached state.
        if let receivedContext { await applyContext(receivedContext, provesPeerIsAlive: false) }
        guard reachable else { return }
        await negotiate()
    }

    public func reachabilityChanged(_ reachable: Bool) async {
        // Coming back from a *confirmed* outage re-negotiates: the phone may have been updated, or
        // switched libraries, while it was away. Coming back from a sub-grace blip does not — the
        // session was never in doubt, and a round trip per flap is exactly the churn §6.3 exists to
        // prevent.
        let wasConfirmedDown = reducer.state.isConfirmedDisconnected
        await run(reducer.apply(.reachabilityChanged(reachable), at: Date()))
        guard reachable else { return }
        if negotiated == nil || wasConfirmedDown { await negotiate() }
    }

    /// §5.3 `hello`. Failure here is not fatal: an unreachable or incompatible phone leaves every
    /// downloaded track playable, which is A-07's whole point.
    @discardableResult
    public func negotiate() async -> Result<WatchNegotiatedSession, WatchProtocolFault> {
        let hello = WatchHello(
            pairedLibraryID: boundLibraryID ?? .unknown,
            capabilities: configuration.capabilities,
            lastAppliedPhoneRevision: await stateStore.loadLastAppliedPhoneRevision())
        do {
            let envelope = try await request(kind: .hello, payload: hello, expecting: .helloReply)
            let reply = try envelope.decodePayload(WatchHelloReply.self)
            switch WatchCapabilityNegotiation.negotiate(local: hello, remote: reply) {
            case .success(let session):
                guard await acceptLibraryIdentity(session.pairedLibraryID) else {
                    let fault = WatchProtocolFault(code: .pairedLibraryChanged)
                    await observer?.negotiationDidFail(fault)
                    return .failure(fault)
                }
                negotiated = session
                await observer?.didNegotiate(session)
                return .success(session)
            case .failure(let fault):
                await markIncompatible()
                await observer?.negotiationDidFail(fault)
                return .failure(fault)
            }
        } catch let fault as WatchProtocolFault {
            if fault.code == .protocolUpgradeRequired { await markIncompatible() }
            await observer?.negotiationDidFail(fault)
            return .failure(fault)
        } catch {
            let fault = WatchProtocolFault(code: .transferFailed)
            await observer?.negotiationDidFail(fault)
            return .failure(fault)
        }
    }

    // MARK: - Immediate requests

    public func search(_ query: String, scope: WatchSearchScope = .all,
                       pageToken: String? = nil) async -> WatchSearchOutcome {
        searchGeneration += 1
        let generation = searchGeneration
        let request = WatchSearchRequest(query: query, scope: scope, pageToken: pageToken,
                                         generation: generation)
        do {
            let envelope = try await self.request(kind: .searchRequest, payload: request,
                                                  expecting: .searchResponse)
            let response = try envelope.decodePayload(WatchSearchResponse.self)
            // Two guards, not one. The generation inside the payload catches a phone that answered
            // an older request; `searchGeneration` catches a reply that was merely slow. C-04 needs
            // both, because either alone lets a stale list win a race.
            guard response.generation == generation, generation == searchGeneration else {
                return .superseded
            }
            return .results(response)
        } catch let fault as WatchProtocolFault {
            return generation == searchGeneration ? .failed(fault) : .superseded
        } catch {
            return .failed(WatchProtocolFault(code: .transferFailed))
        }
    }

    public func browse(_ category: WatchBrowseCategory, pageToken: String? = nil) async -> WatchBrowseOutcome {
        browseGeneration += 1
        let generation = browseGeneration
        let request = WatchBrowseRequest(category: category, pageToken: pageToken, generation: generation)
        do {
            let envelope = try await self.request(kind: .browseRequest, payload: request,
                                                  expecting: .browseResponse)
            let response = try envelope.decodePayload(WatchBrowseResponse.self)
            guard response.generation == generation, generation == browseGeneration else {
                return .superseded
            }
            return .results(response)
        } catch let fault as WatchProtocolFault {
            return generation == browseGeneration ? .failed(fault) : .superseded
        } catch {
            return .failed(WatchProtocolFault(code: .transferFailed))
        }
    }

    public func collection(_ ref: WatchCollectionRef, pageToken: String? = nil) async
    -> Result<WatchCollectionResponse, WatchProtocolFault> {
        do {
            let envelope = try await request(
                kind: .collectionRequest,
                payload: WatchCollectionRequest(collection: ref, pageToken: pageToken),
                expecting: .collectionResponse)
            return .success(try envelope.decodePayload(WatchCollectionResponse.self))
        } catch let fault as WatchProtocolFault {
            return .failure(fault)
        } catch {
            return .failure(WatchProtocolFault(code: .transferFailed))
        }
    }

    /// §7.1: this only ever moves the *phone's* player. Watch-local transport never leaves the watch.
    public func send(_ command: WatchPlayCommand) async -> WatchCommandReply {
        do {
            let envelope = try await request(kind: .playCommand, payload: command,
                                             expecting: .commandReply)
            let reply = try envelope.decodePayload(WatchCommandReply.self)
            if let snapshot = reply.snapshot { await applyPlayback(snapshot) }
            return reply
        } catch let fault as WatchProtocolFault {
            return WatchCommandReply(accepted: false, fault: fault)
        } catch {
            return .rejected(.transferFailed)
        }
    }

    /// §7.1: ask the phone for a fresh authoritative snapshot without changing anything. The reply
    /// flows through the same `applyPlayback` path as a command reply, so the observer is corrected.
    public func refreshPlaybackSnapshot() async {
        _ = await send(WatchPlayCommand(action: .requestSnapshot))
    }

    // MARK: - Durable sends

    public func sendManifest(_ manifest: WatchManifestPayload) async {
        guard let data = try? WatchProtocolEnvelope.encode(
            kind: .watchManifest, payload: manifest,
            pairedLibraryID: boundLibraryID ?? .unknown) else { return }
        await transport.transferUserInfo(data)
    }

    public func requestReconciliation(scope: WatchReconciliationScope = .all,
                                      trigger: WatchProtocolErrorCode? = nil) async {
        let payload = WatchReconciliationRequest(scope: scope, trigger: trigger)
        guard let data = try? WatchProtocolEnvelope.encode(
            kind: .requestReconciliation, payload: payload,
            pairedLibraryID: boundLibraryID ?? .unknown) else { return }
        await transport.transferUserInfo(data)
    }

    // MARK: - Paired library identity (A-08)

    /// The user said "yes, replace it". Only now does the watch rebind and clear its revision
    /// history, so a different phone starts from zero instead of inheriting the old one's numbers.
    public func confirmPairedLibraryReplacement() async {
        guard let incoming = pendingLibraryChange else { return }
        pendingLibraryChange = nil
        boundLibraryID = incoming
        revisions.resetAll()
        await stateStore.savePairedLibraryID(incoming)
        await stateStore.saveLastAppliedPhoneRevision(0)
        await ledger.reset()
        // The old session described a library this watch is no longer bound to, so it is void until
        // a fresh hello succeeds against the new identity.
        negotiated = nil
        await negotiate()
        await requestReconciliation(scope: .all, trigger: .pairedLibraryChanged)
    }

    public func rejectPairedLibraryReplacement() {
        pendingLibraryChange = nil
    }

    // MARK: - WatchProtocolInbound

    public func receiveImmediate(_ data: Data) async -> Data? {
        guard let envelope = await accept(data) else { return nil }
        switch envelope.kind {
        case .requestReconciliation:
            if let request = try? envelope.decodePayload(WatchReconciliationRequest.self) {
                await observer?.phoneRequestedReconciliation(request)
            }
        default:
            await apply(envelope)
        }
        // The watch is a requester, not a server: it acknowledges rather than answering, so a phone
        // waiting on `sendMessageData` is never left to time out.
        return try? envelope.reply(kind: .commandReply, payload: WatchCommandReply.accepted())
    }

    /// The coalesced context. Its payload type is fixed by the *channel*, not by `kind`: §5.1
    /// allows one stable key in the application-context dictionary, so the phone publishes the whole
    /// `WatchContextSnapshot` every time and uses `kind` only to say which half changed.
    public func receiveApplicationContext(_ data: Data) async {
        await applyContext(data, provesPeerIsAlive: true)
    }

    private func applyContext(_ data: Data, provesPeerIsAlive: Bool) async {
        guard let envelope = await accept(data, notesLiveness: provesPeerIsAlive) else { return }
        guard let context = try? envelope.decodePayload(WatchContextSnapshot.self) else {
            // Not a context snapshot after all — treat it as a plain message rather than dropping it.
            await apply(envelope)
            return
        }
        await noteAppliedPhoneRevision(context.phoneRevision)
        if let playback = context.playback { await applyPlayback(playback) }
        if let downloads = context.downloads {
            guard revisions.evaluate(scope: .downloadStatus, revision: downloads.revision) == .apply else { return }
            await observer?.didReceiveDownloadStatus(downloads)
        }
    }

    public func receiveUserInfo(_ data: Data) async {
        guard let envelope = await accept(data) else { return }
        // §5.4: durable events are deduplicated by message ID before anything else looks at them.
        guard await ledger.admit(envelope.messageID) == .apply else { return }
        await apply(envelope)
    }

    public func receiveFile(_ url: URL, metadata: [String: String]) async {
        // A delivered file proves the phone is alive, then goes to the installer via the observer.
        await run(reducer.apply(.peerResponded, at: Date()))
        await observer?.didReceiveAudioFile(at: url, metadata: metadata)
    }

    // MARK: - Private

    /// Decode, version-check, and identity-check one inbound blob. Returns `nil` when the message
    /// must not be applied — and in every such case the reason has already been reported.
    private func accept(_ data: Data, notesLiveness: Bool = true) async -> WatchProtocolEnvelope? {
        switch WatchProtocolEnvelope.decode(data) {
        case .failure(let failure):
            if case .unsupportedVersion = failure { await markIncompatible() }
            if case .unsupportedKind = failure { await markIncompatible() }
            await observer?.negotiationDidFail(WatchProtocolFault(code: failure.errorCode))
            return nil
        case .success(let envelope):
            if notesLiveness { await run(reducer.apply(.peerResponded, at: Date())) }
            guard await acceptLibraryIdentity(envelope.pairedLibraryID) else { return nil }
            return envelope
        }
    }

    /// A-08. An unknown identity binds silently on first contact — there is nothing to overwrite. A
    /// *different* identity binds nothing at all until the user confirms.
    private func acceptLibraryIdentity(_ incoming: WatchPairedLibraryID) async -> Bool {
        guard incoming.isKnown else { return true }
        guard let bound = boundLibraryID else {
            boundLibraryID = incoming
            await stateStore.savePairedLibraryID(incoming)
            return true
        }
        guard bound != incoming else { return true }
        guard pendingLibraryChange != incoming else { return false }
        pendingLibraryChange = incoming
        await observer?.pairedLibraryChangeRequiresConfirmation(current: bound, incoming: incoming)
        return false
    }

    private func apply(_ envelope: WatchProtocolEnvelope) async {
        switch envelope.kind {
        case .phonePlaybackSnapshot:
            guard let snapshot = try? envelope.decodePayload(WatchPhonePlaybackSnapshot.self) else { return }
            await applyPlayback(snapshot)

        case .downloadStatusSnapshot:
            guard let snapshot = try? envelope.decodePayload(WatchDownloadStatusSnapshot.self) else { return }
            guard revisions.evaluate(scope: .downloadStatus, revision: snapshot.revision) == .apply else { return }
            await observer?.didReceiveDownloadStatus(snapshot)

        case .setDownloadRoots:
            guard let payload = try? envelope.decodePayload(WatchSetDownloadRoots.self) else { return }
            guard revisions.evaluate(scope: .downloadRoots, revision: payload.revision) == .apply else { return }
            await noteAppliedPhoneRevision(envelope.phoneRevision)
            await observer?.didReceiveDownloadRoots(payload)

        case .removeAssets:
            guard let payload = try? envelope.decodePayload(WatchRemoveAssets.self) else { return }
            guard revisions.evaluate(scope: .downloadRoots, revision: payload.revision) == .apply else { return }
            await noteAppliedPhoneRevision(envelope.phoneRevision)
            await observer?.didReceiveRemoveAssets(payload)

        case .requestReconciliation:
            guard let request = try? envelope.decodePayload(WatchReconciliationRequest.self) else { return }
            await observer?.phoneRequestedReconciliation(request)

        case .error:
            guard let fault = try? envelope.decodePayload(WatchProtocolFault.self) else { return }
            await observer?.negotiationDidFail(fault)

        case .hello, .helloReply, .searchRequest, .searchResponse, .browseRequest, .browseResponse,
             .collectionRequest, .collectionResponse, .playCommand, .commandReply, .watchManifest:
            // Request/reply kinds are consumed by the caller that correlated them; a stray copy
            // arriving over a broadcast channel is not something to act on twice.
            break
        }
    }

    private func applyPlayback(_ snapshot: WatchPhonePlaybackSnapshot) async {
        guard revisions.evaluate(scope: .playback, revision: snapshot.revision) == .apply else { return }
        await observer?.didReceivePhonePlayback(snapshot)
    }

    private func noteAppliedPhoneRevision(_ revision: Int64) async {
        guard revision > 0 else { return }
        guard revisions.evaluate(scope: .catalog, revision: revision) == .apply else { return }
        await stateStore.saveLastAppliedPhoneRevision(revision)
    }

    /// One immediate round trip: encode, enforce the deadline, decode, and insist the reply is both
    /// correlated to this request and of the kind we asked for.
    private func request(kind: WatchMessageKind, payload: some Encodable,
                         expecting: WatchMessageKind) async throws -> WatchProtocolEnvelope {
        if let blocked = reducer.blockingErrorCode { throw WatchProtocolFault(code: blocked) }
        let messageID = UUID()
        let data = try WatchProtocolEnvelope.encode(
            kind: kind, payload: payload, pairedLibraryID: boundLibraryID ?? .unknown,
            messageID: messageID)
        let transport = self.transport
        do {
            let replyData = try await withWatchRequestDeadline(configuration.immediateDeadline) {
                try await transport.sendImmediate(data)
            }
            let envelope = try WatchProtocolEnvelope.decode(replyData).get()
            await run(reducer.apply(.peerResponded, at: Date()))
            if envelope.kind == .error {
                throw try envelope.decodePayload(WatchProtocolFault.self)
            }
            guard envelope.correlationID == messageID, envelope.kind == expecting else {
                // A reply for a different request reached us. Dropping it is the only safe read;
                // treating it as ours is how a search result lands in a collection detail view.
                throw WatchProtocolFault(code: .requestTimedOut)
            }
            return envelope
        } catch let failure as WatchEnvelopeFailure {
            if case .unsupportedVersion = failure { await markIncompatible() }
            throw WatchProtocolFault(code: failure.errorCode)
        } catch let fault as WatchProtocolFault {
            await noteCommandFailure(fault)
            throw fault
        }
    }

    /// §6.3: a failed command may surface immediately, but the global mode still waits out the
    /// grace period. Only transport-shaped failures count — a `contentNotFound` says the link is
    /// working fine.
    private func noteCommandFailure(_ fault: WatchProtocolFault) async {
        switch fault.code {
        case .phoneUnavailable, .requestTimedOut, .transferFailed:
            await run(reducer.apply(.immediateCommandFailed, at: Date()))
        default:
            break
        }
    }

    private func markIncompatible() async {
        negotiated = nil
        await run(reducer.apply(.protocolIncompatible, at: Date()))
    }

    /// Reports the reducer's state (only when it actually moved — every inbound message calls
    /// `peerResponded`, and a coordinator that republished "still connected" on each one would give
    /// the UI a redraw per message) and then performs the effects it asked for.
    private func run(_ effects: [WatchConnectionReducer.Effect]) async {
        if reducer.state != lastReportedState {
            lastReportedState = reducer.state
            await observer?.connectionStateDidChange(reducer.state, connectivity: reducer.connectivity)
        }
        for effect in effects {
            switch effect {
            case .scheduleGraceExpiry(let interval):
                graceTask?.cancel()
                graceTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    await self?.graceExpired()
                }
            case .cancelGraceExpiry:
                graceTask?.cancel()
                graceTask = nil
            case .announceDisconnected:
                await observer?.didConfirmDisconnection()
            case .announceReconnected:
                await observer?.didReconnect()
            }
        }
    }

    private func graceExpired() async {
        graceTask = nil
        await run(reducer.apply(.graceElapsed, at: Date()))
    }
}
