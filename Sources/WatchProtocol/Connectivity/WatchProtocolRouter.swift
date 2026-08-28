import Foundation

/// What the phone can be asked to do. Phase 4 supplies the GRDB-backed implementation; Phase 3
/// supplies the router, the envelope handling, and the defaults below.
///
/// Every method that can fail returns or throws a `WatchProtocolFault`, never a bare `Error`: a
/// domain failure has to reach the watch as one of the §5.5 codes, and a leaked `NSError`
/// description is exactly the kind of string A-06 forbids on the wire.
public protocol WatchPhoneRequestHandling: Sendable {
    func handleHello(_ payload: WatchHello) async -> WatchHelloReply
    func handleSearch(_ request: WatchSearchRequest) async throws -> WatchSearchResponse
    func handleBrowse(_ request: WatchBrowseRequest) async throws -> WatchBrowseResponse
    func handleCollection(_ request: WatchCollectionRequest) async throws -> WatchCollectionResponse
    func handlePlayCommand(_ command: WatchPlayCommand) async -> WatchCommandReply
    func handleWatchManifest(_ payload: WatchManifestPayload) async
    func handleReconciliationRequest(_ request: WatchReconciliationRequest) async
    func handleDownloadRequest(_ request: WatchDownloadRequest) async
}

extension WatchPhoneRequestHandling {
    /// Until Phase 4 wires the projections, an unimplemented capability answers `sourceUnavailable`
    /// — "the phone cannot resolve this" — rather than pretending an empty result set is the truth.
    public func handleSearch(_ request: WatchSearchRequest) async throws -> WatchSearchResponse {
        throw WatchProtocolFault(code: .sourceUnavailable)
    }
    public func handleBrowse(_ request: WatchBrowseRequest) async throws -> WatchBrowseResponse {
        throw WatchProtocolFault(code: .sourceUnavailable)
    }
    public func handleCollection(_ request: WatchCollectionRequest) async throws -> WatchCollectionResponse {
        throw WatchProtocolFault(code: .sourceUnavailable)
    }
    public func handlePlayCommand(_ command: WatchPlayCommand) async -> WatchCommandReply {
        .rejected(.sourceUnavailable)
    }
    public func handleWatchManifest(_ payload: WatchManifestPayload) async {}
    public func handleReconciliationRequest(_ request: WatchReconciliationRequest) async {}
    public func handleDownloadRequest(_ request: WatchDownloadRequest) async {}
}

/// Decodes one inbound envelope and produces the reply envelope, if any.
///
/// The router is a free function's worth of logic wrapped in a struct so both coordinators can use
/// it and so the "which kinds are requests" decision lives in exactly one place. It is the last
/// point at which a message is untyped; past `route`, everything is a payload struct.
public struct WatchProtocolRouter: Sendable {
    private let handler: any WatchPhoneRequestHandling
    private let libraryID: WatchPairedLibraryID
    private let revision: @Sendable () async -> Int64

    public init(handler: any WatchPhoneRequestHandling, libraryID: WatchPairedLibraryID,
                revision: @escaping @Sendable () async -> Int64) {
        self.handler = handler
        self.libraryID = libraryID
        self.revision = revision
    }

    public func route(_ envelope: WatchProtocolEnvelope) async -> Data? {
        let phoneRevision = await revision()
        do {
            switch envelope.kind {
            case .hello:
                let hello = try envelope.decodePayload(WatchHello.self)
                var reply = await handler.handleHello(hello)
                reply.pairedLibraryID = libraryID
                reply.phoneRevision = phoneRevision
                return try envelope.reply(kind: .helloReply, payload: reply,
                                          pairedLibraryID: libraryID, phoneRevision: phoneRevision)

            case .searchRequest:
                let request = try envelope.decodePayload(WatchSearchRequest.self)
                let response = try await handler.handleSearch(request)
                return try envelope.reply(kind: .searchResponse, payload: response,
                                          pairedLibraryID: libraryID, phoneRevision: phoneRevision)

            case .browseRequest:
                let request = try envelope.decodePayload(WatchBrowseRequest.self)
                let response = try await handler.handleBrowse(request)
                return try envelope.reply(kind: .browseResponse, payload: response,
                                          pairedLibraryID: libraryID, phoneRevision: phoneRevision)

            case .collectionRequest:
                let request = try envelope.decodePayload(WatchCollectionRequest.self)
                let response = try await handler.handleCollection(request)
                return try envelope.reply(kind: .collectionResponse, payload: response,
                                          pairedLibraryID: libraryID, phoneRevision: phoneRevision)

            case .playCommand:
                let command = try envelope.decodePayload(WatchPlayCommand.self)
                let reply = await handler.handlePlayCommand(command)
                return try envelope.reply(kind: .commandReply, payload: reply,
                                          pairedLibraryID: libraryID, phoneRevision: phoneRevision)

            case .watchManifest:
                await handler.handleWatchManifest(try envelope.decodePayload(WatchManifestPayload.self))
                return nil

            case .requestReconciliation:
                await handler.handleReconciliationRequest(
                    try envelope.decodePayload(WatchReconciliationRequest.self))
                return nil

            case .requestDownload:
                await handler.handleDownloadRequest(
                    try envelope.decodePayload(WatchDownloadRequest.self))
                return nil

            case .helloReply, .searchResponse, .browseResponse, .collectionResponse, .commandReply,
                 .phonePlaybackSnapshot, .setDownloadRoots, .downloadStatusSnapshot, .removeAssets,
                 .error:
                // Replies and phone-authored events are not requests. Answering them would create a
                // loop; ignoring them is the correct read of "never assume delivery order".
                return nil
            }
        } catch let fault as WatchProtocolFault {
            return try? envelope.reply(kind: .error, payload: fault,
                                       pairedLibraryID: libraryID, phoneRevision: phoneRevision)
        } catch {
            // A decode failure on a same-version peer. `transferFailed` is the honest code, and the
            // caught error's description never leaves this function.
            return try? envelope.reply(kind: .error,
                                       payload: WatchProtocolFault(code: .transferFailed),
                                       pairedLibraryID: libraryID, phoneRevision: phoneRevision)
        }
    }
}
