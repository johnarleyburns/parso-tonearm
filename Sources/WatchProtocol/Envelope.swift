import Foundation

/// The §5.2 channel a message travelled over. Named here rather than in the adapters because
/// `WatchMessageKind.channel` is part of the contract, not an implementation detail of WCSession.
public enum WatchTransportChannel: String, Codable, Sendable, CaseIterable {
    /// `sendMessageData` — reachable-only request/reply with a UI deadline.
    case immediate
    /// `updateApplicationContext` — coalesced, newest state only.
    case applicationContext
    /// `transferUserInfo` — durable, idempotent by message ID.
    case userInfo
    /// `transferFile` — background/opportunistic, checksum required.
    case file
}

/// §5.1 — the one envelope every logical payload travels in, encoded as a binary property list.
///
/// Two deliberate choices are worth the ink. **The payload stays `Data`**: the envelope can be
/// decoded, deduplicated, revision-gated, and routed without knowing what kind of message it is,
/// which is what lets the ledger and the reducer be shared by both sides. And **decoding is a
/// `Result`, not a `throws`**, because the three ways an envelope fails are three different product
/// behaviors — a malformed blob is dropped, an unsupported version shows Upgrade Required while
/// leaving local downloads alone (A-07), and an unknown kind from a same-version peer is a bug we
/// want to see rather than swallow.
public struct WatchProtocolEnvelope: Equatable, Sendable {
    public static let currentProtocolVersion = 1

    /// §5.1: application-context and user-info dictionaries put the encoded envelope under one
    /// stable key. Everything else in those dictionaries is ignored.
    public static let payloadKey = "watchProtocolEnvelope"

    public var protocolVersion: Int
    public var messageID: UUID
    public var correlationID: UUID?
    public var pairedLibraryID: WatchPairedLibraryID
    public var phoneRevision: Int64
    public var sentAt: Date
    public var kind: WatchMessageKind
    public var payload: Data

    public init(protocolVersion: Int = WatchProtocolEnvelope.currentProtocolVersion,
                messageID: UUID = UUID(), correlationID: UUID? = nil,
                pairedLibraryID: WatchPairedLibraryID, phoneRevision: Int64 = 0,
                sentAt: Date = Date(), kind: WatchMessageKind, payload: Data) {
        self.protocolVersion = protocolVersion
        self.messageID = messageID
        self.correlationID = correlationID
        self.pairedLibraryID = pairedLibraryID
        self.phoneRevision = phoneRevision
        self.sentAt = sentAt
        self.kind = kind
        self.payload = payload
    }

    // MARK: - Coding

    /// The literal wire shape. `kind` is a `String` here and an enum on `WatchProtocolEnvelope`, so
    /// an unrecognized kind produces `unsupportedKind` with the offending raw value rather than a
    /// generic `DecodingError` that loses it.
    private struct Wire: Codable {
        var protocolVersion: Int
        var messageID: UUID
        var correlationID: UUID?
        var pairedLibraryID: String
        var phoneRevision: Int64
        var sentAt: Date
        var kind: String
        var payload: Data
    }

    /// Reads only the version, so an envelope from a future peer whose `kind` we cannot parse still
    /// tells us the one thing we need in order to say "update the app".
    private struct VersionProbe: Codable { var protocolVersion: Int }

    private static func encoder() -> PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }

    public func encoded() throws -> Data {
        try Self.encoder().encode(Wire(
            protocolVersion: protocolVersion, messageID: messageID, correlationID: correlationID,
            pairedLibraryID: pairedLibraryID.rawValue, phoneRevision: phoneRevision,
            sentAt: sentAt, kind: kind.rawValue, payload: payload))
    }

    public static func encodePayload(_ payload: some Encodable) throws -> Data {
        try encoder().encode(payload)
    }

    /// Build and encode in one step — the form every caller actually wants.
    public static func encode(kind: WatchMessageKind, payload: some Encodable,
                              pairedLibraryID: WatchPairedLibraryID, phoneRevision: Int64 = 0,
                              messageID: UUID = UUID(), correlationID: UUID? = nil,
                              sentAt: Date = Date(),
                              protocolVersion: Int = WatchProtocolEnvelope.currentProtocolVersion) throws -> Data {
        try WatchProtocolEnvelope(
            protocolVersion: protocolVersion, messageID: messageID, correlationID: correlationID,
            pairedLibraryID: pairedLibraryID, phoneRevision: phoneRevision, sentAt: sentAt,
            kind: kind, payload: encodePayload(payload)).encoded()
    }

    public static func decode(_ data: Data,
                              localVersion: Int = WatchProtocolEnvelope.currentProtocolVersion)
    -> Result<WatchProtocolEnvelope, WatchEnvelopeFailure> {
        let decoder = PropertyListDecoder()
        guard let probe = try? decoder.decode(VersionProbe.self, from: data) else {
            return .failure(.malformed)
        }
        guard probe.protocolVersion == localVersion else {
            return .failure(.unsupportedVersion(peer: probe.protocolVersion, local: localVersion))
        }
        guard let wire = try? decoder.decode(Wire.self, from: data) else { return .failure(.malformed) }
        guard let kind = WatchMessageKind(rawValue: wire.kind) else {
            return .failure(.unsupportedKind(wire.kind))
        }
        return .success(WatchProtocolEnvelope(
            protocolVersion: wire.protocolVersion, messageID: wire.messageID,
            correlationID: wire.correlationID, pairedLibraryID: WatchPairedLibraryID(wire.pairedLibraryID),
            phoneRevision: wire.phoneRevision, sentAt: wire.sentAt, kind: kind, payload: wire.payload))
    }

    public func decodePayload<Payload: Decodable>(_ type: Payload.Type) throws -> Payload {
        try PropertyListDecoder().decode(type, from: payload)
    }

    /// A reply addressed to this message. Correlation is set from `messageID`, never regenerated,
    /// which is the whole basis of the dispatcher's late-reply handling.
    public func reply(kind: WatchMessageKind, payload: some Encodable,
                      pairedLibraryID: WatchPairedLibraryID? = nil,
                      phoneRevision: Int64? = nil, sentAt: Date = Date()) throws -> Data {
        try Self.encode(kind: kind, payload: payload,
                        pairedLibraryID: pairedLibraryID ?? self.pairedLibraryID,
                        phoneRevision: phoneRevision ?? self.phoneRevision,
                        correlationID: messageID, sentAt: sentAt)
    }

    /// Wraps the envelope for the dictionary-shaped channels. This and `envelope(from:)` are the
    /// only places a `[String: Any]` is allowed to appear outside a transport adapter.
    public static func dictionary(for data: Data) -> [String: Any] { [payloadKey: data] }

    public static func payloadData(in dictionary: [String: Any]) -> Data? {
        dictionary[payloadKey] as? Data
    }
}

extension WatchProtocolEnvelope {
    /// A phone-authored envelope: the phone is the only side that owns `pairedLibraryID` and
    /// `phoneRevision` (§1.6), so this spelling keeps the watch from inventing either.
    public static func fromPhone(kind: WatchMessageKind, payload: some Encodable,
                                 libraryID: WatchPairedLibraryID, revision: Int64,
                                 messageID: UUID = UUID(), correlationID: UUID? = nil,
                                 sentAt: Date = Date()) throws -> Data {
        try encode(kind: kind, payload: payload, pairedLibraryID: libraryID, phoneRevision: revision,
                   messageID: messageID, correlationID: correlationID, sentAt: sentAt)
    }
}
