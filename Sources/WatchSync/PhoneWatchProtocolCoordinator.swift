import Foundation
import TonearmWatchProtocol

/// §5.4: "Phone catalog/download-root revisions are monotonic `Int64` values persisted on phone."
/// Persisted, because a phone that restarts and reuses revision 7 for different content would let a
/// watch that already applied the old 7 discard the new one as stale.
public protocol WatchPhoneRevisionStore: Sendable {
    func currentRevision() async -> Int64
    func nextRevision() async -> Int64
}

public actor WatchInMemoryRevisionStore: WatchPhoneRevisionStore {
    private var revision: Int64
    public init(revision: Int64 = 0) { self.revision = revision }
    public func currentRevision() async -> Int64 { revision }
    public func nextRevision() async -> Int64 { revision += 1; return revision }
}

/// `UserDefaults`-backed, which is enough: the value is a single monotonic counter, and losing it
/// costs one extra reconciliation rather than any user data.
///
/// An actor rather than a struct because `UserDefaults` is not `Sendable`; actor isolation is the
/// honest way to hold one, and the suite is named rather than injected so no non-`Sendable` value
/// ever crosses into the actor.
public actor WatchUserDefaultsRevisionStore: WatchPhoneRevisionStore {
    public static let defaultsKey = "watch.protocol.phoneRevision"

    private let defaults: UserDefaults
    private let key: String

    public init(suiteName: String? = nil, key: String = WatchUserDefaultsRevisionStore.defaultsKey) {
        self.defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.key = key
    }

    public func currentRevision() async -> Int64 { Int64(defaults.integer(forKey: key)) }

    public func nextRevision() async -> Int64 {
        let next = Int64(defaults.integer(forKey: key)) + 1
        defaults.set(Int(next), forKey: key)
        return next
    }
}

/// What the phone app learns from the watch.
public protocol PhoneWatchProtocolObserver: AnyObject, Sendable {
    func watchDidReportManifest(_ manifest: WatchManifestPayload) async
    func watchRequestedReconciliation(_ request: WatchReconciliationRequest) async
    func watchDidNegotiate(_ hello: WatchHello) async
    func connectionStateDidChange(_ state: WatchConnectionReducer.State) async
}

extension PhoneWatchProtocolObserver {
    public func watchDidReportManifest(_ manifest: WatchManifestPayload) async {}
    public func watchRequestedReconciliation(_ request: WatchReconciliationRequest) async {}
    public func watchDidNegotiate(_ hello: WatchHello) async {}
    public func connectionStateDidChange(_ state: WatchConnectionReducer.State) async {}
}

/// The phone's half of the §5 protocol.
///
/// Deliberately thinner than the watch's: §1.6 makes the phone the sync *authority*, so it answers
/// requests and publishes state rather than reasoning about whether it trusts the peer. The watch
/// owns the paired-identity decision because the watch is the one holding downloads that could be
/// overwritten.
///
/// Lives in `TonearmCore` rather than `Sources/App/` — where §13 sketches it — for one reason: the
/// Phase 3 definition of done requires host tests that drive *both* coordinators through the fake
/// link, and `Sources/App/` is compiled only by the Xcode application target, which `swift test`
/// never builds. `PhoneWatchProtocolAdapter` in `Sources/App/Watch/` keeps the WCSession half where
/// the plan puts it, and it contains no protocol logic at all.
public actor PhoneWatchProtocolCoordinator: WatchProtocolLifecycle {
    private let transport: any WatchProtocolTransport
    private let handler: any WatchPhoneRequestHandling
    private let revisionStore: any WatchPhoneRevisionStore
    private let ledger: WatchAppliedMessageLedger
    private let libraryID: WatchPairedLibraryID
    private weak var observer: (any PhoneWatchProtocolObserver)?

    private var reducer: WatchConnectionReducer
    private var lastReportedState: WatchConnectionReducer.State
    private var graceTask: Task<Void, Never>?
    private var lastPublishedContext: WatchContextSnapshot?

    public init(transport: any WatchProtocolTransport,
                handler: any WatchPhoneRequestHandling,
                libraryID: WatchPairedLibraryID,
                revisionStore: any WatchPhoneRevisionStore = WatchInMemoryRevisionStore(),
                ledger: WatchAppliedMessageLedger? = nil,
                gracePeriod: TimeInterval = WatchConnectionReducer.defaultGracePeriod,
                observer: (any PhoneWatchProtocolObserver)? = nil) {
        self.transport = transport
        self.handler = handler
        self.libraryID = libraryID
        self.revisionStore = revisionStore
        self.ledger = ledger ?? WatchAppliedMessageLedger()
        self.observer = observer
        let reducer = WatchConnectionReducer(gracePeriod: gracePeriod)
        self.reducer = reducer
        lastReportedState = reducer.state
    }

    public func setObserver(_ observer: (any PhoneWatchProtocolObserver)?) { self.observer = observer }

    public var connectionState: WatchConnectionReducer.State { reducer.state }
    public var publishedContext: WatchContextSnapshot? { lastPublishedContext }
    public var pairedLibraryID: WatchPairedLibraryID { libraryID }

    /// `receivedContext` is symmetric with the watch's: a session hands back whatever context it
    /// was holding, and the phone applies it rather than waiting for a fresh one.
    public func activate(reachable: Bool, receivedContext: Data? = nil) async {
        await run(reducer.apply(.activated(reachable: reachable), at: Date()))
        if let receivedContext { await receiveApplicationContext(receivedContext) }
    }

    public func reachabilityChanged(_ reachable: Bool) async {
        await run(reducer.apply(.reachabilityChanged(reachable), at: Date()))
    }

    // MARK: - Publishing

    /// §5.2: the newest state only.
    ///
    /// One envelope carries the *whole* context, because §5.1 allows exactly one stable key in the
    /// application-context dictionary and `updateApplicationContext` replaces the dictionary
    /// wholesale — publishing download status on its own would erase the now-playing state the
    /// watch is drawing. So the payload is always a merged `WatchContextSnapshot`, and the envelope
    /// `kind` records which half changed. The receiver picks the payload type from the *channel*,
    /// not the kind.
    ///
    /// Republishing an identical context is suppressed: an unchanged dictionary is a wasted wake-up
    /// on both devices, and I-10 forbids idle churn.
    @discardableResult
    public func publishContext(playback: WatchPhonePlaybackSnapshot? = nil,
                               downloads: WatchDownloadStatusSnapshot? = nil,
                               at date: Date = Date()) async -> Bool {
        let merged = WatchContextSnapshot(
            pairedLibraryID: libraryID, phoneRevision: await revisionStore.currentRevision(),
            updatedAt: date,
            playback: playback ?? lastPublishedContext?.playback,
            downloads: downloads ?? lastPublishedContext?.downloads)
        if let previous = lastPublishedContext,
           previous.playback == merged.playback, previous.downloads == merged.downloads {
            return false
        }
        guard let data = try? WatchProtocolEnvelope.fromPhone(
            kind: playback != nil ? .phonePlaybackSnapshot : .downloadStatusSnapshot,
            payload: merged, libraryID: libraryID, revision: merged.phoneRevision,
            sentAt: date) else { return false }
        lastPublishedContext = merged
        try? await transport.updateApplicationContext(data)
        return true
    }

    /// §5.3 `setDownloadRoots` — always the complete desired set, always at a fresh revision.
    @discardableResult
    public func sendDownloadRoots(_ roots: [WatchDownloadRootDescriptor]) async -> Int64 {
        let revision = await revisionStore.nextRevision()
        let payload = WatchSetDownloadRoots(revision: revision, roots: roots)
        if let data = try? WatchProtocolEnvelope.fromPhone(
            kind: .setDownloadRoots, payload: payload, libraryID: libraryID, revision: revision) {
            await transport.transferUserInfo(data)
        }
        return revision
    }

    @discardableResult
    public func sendRemoveAssets(_ trackIDs: [WatchTrackID],
                                 reason: WatchRemovalReason = .userRemoved) async -> Int64 {
        let revision = await revisionStore.nextRevision()
        let payload = WatchRemoveAssets(revision: revision, trackIDs: trackIDs, reason: reason)
        if let data = try? WatchProtocolEnvelope.fromPhone(
            kind: .removeAssets, payload: payload, libraryID: libraryID, revision: revision) {
            await transport.transferUserInfo(data)
        }
        return revision
    }

    public func requestReconciliation(scope: WatchReconciliationScope = .all) async {
        let revision = await revisionStore.currentRevision()
        if let data = try? WatchProtocolEnvelope.fromPhone(
            kind: .requestReconciliation, payload: WatchReconciliationRequest(scope: scope),
            libraryID: libraryID, revision: revision) {
            await transport.transferUserInfo(data)
        }
    }

    // MARK: - WatchProtocolInbound

    public func receiveImmediate(_ data: Data) async -> Data? {
        guard let envelope = await accept(data) else { return errorReply(for: data) }
        if envelope.kind == .hello, let hello = try? envelope.decodePayload(WatchHello.self) {
            await observer?.watchDidNegotiate(hello)
        }
        return await router().route(envelope)
    }

    public func receiveApplicationContext(_ data: Data) async {
        guard let envelope = await accept(data) else { return }
        await applyDurable(envelope)
    }

    public func receiveUserInfo(_ data: Data) async {
        guard let envelope = await accept(data) else { return }
        guard await ledger.admit(envelope.messageID) == .apply else { return }
        await applyDurable(envelope)
    }

    // MARK: - Private

    private func router() -> WatchProtocolRouter {
        let store = revisionStore
        return WatchProtocolRouter(handler: handler, libraryID: libraryID,
                                   revision: { await store.currentRevision() })
    }

    private func accept(_ data: Data) async -> WatchProtocolEnvelope? {
        switch WatchProtocolEnvelope.decode(data) {
        case .failure:
            return nil
        case .success(let envelope):
            await run(reducer.apply(.peerResponded, at: Date()))
            return envelope
        }
    }

    /// A watch on an unsupported version still gets a typed answer instead of silence, so it can
    /// show Upgrade Required rather than a timeout (A-07). The version is read from the raw blob,
    /// which is the only thing we could parse.
    private func errorReply(for data: Data) -> Data? {
        guard case .failure(let failure) = WatchProtocolEnvelope.decode(data) else { return nil }
        return try? WatchProtocolEnvelope.encode(
            kind: .error, payload: WatchProtocolFault(code: failure.errorCode),
            pairedLibraryID: libraryID)
    }

    private func applyDurable(_ envelope: WatchProtocolEnvelope) async {
        switch envelope.kind {
        case .watchManifest:
            guard let manifest = try? envelope.decodePayload(WatchManifestPayload.self) else { return }
            await handler.handleWatchManifest(manifest)
            await observer?.watchDidReportManifest(manifest)
        case .requestReconciliation:
            guard let request = try? envelope.decodePayload(WatchReconciliationRequest.self) else { return }
            await handler.handleReconciliationRequest(request)
            await observer?.watchRequestedReconciliation(request)
        default:
            break
        }
    }

    private func run(_ effects: [WatchConnectionReducer.Effect]) async {
        if reducer.state != lastReportedState {
            lastReportedState = reducer.state
            await observer?.connectionStateDidChange(reducer.state)
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
            case .announceDisconnected, .announceReconnected:
                // C-09's haptic/banner is a watch affordance. The phone only tracks the state.
                break
            }
        }
    }

    private func graceExpired() async {
        graceTask = nil
        await run(reducer.apply(.graceElapsed, at: Date()))
    }
}
