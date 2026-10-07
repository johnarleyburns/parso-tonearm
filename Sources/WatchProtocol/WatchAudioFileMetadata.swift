import Foundation

/// The property-list-safe descriptor that rides with every §5.2 `transferFile` audio delivery.
///
/// §5.1: "File metadata remains property-list-safe and includes only IDs, versions, sizes,
/// checksum, codec, and pin intent." It is expressed as `[String: String]` on the wire so a
/// transport adapter never has to parse a dynamic dictionary shape — the keys are fixed, and
/// `init?(dictionary:)` is the only place a raw metadata dictionary is ever read.
public struct WatchAudioFileMetadata: Codable, Equatable, Sendable {
    public var trackID: WatchTrackID
    public var expectedBytes: Int64
    public var sha256: String?
    public var codec: String?
    public var fileExtension: String?
    public var pinned: Bool
    public var phoneRevision: Int64
    public var transferID: String?

    public init(trackID: WatchTrackID, expectedBytes: Int64, sha256: String? = nil,
                codec: String? = nil, fileExtension: String? = nil,
                pinned: Bool = true, phoneRevision: Int64 = 0, transferID: String? = nil) {
        self.transferID = transferID
        self.trackID = trackID
        self.expectedBytes = expectedBytes
        self.sha256 = sha256.flatMap { $0.isEmpty ? nil : $0 }
        self.codec = codec.flatMap { $0.isEmpty ? nil : $0 }
        self.fileExtension = fileExtension.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        self.pinned = pinned
        self.phoneRevision = phoneRevision
    }

    public var dictionary: [String: String] {
        var out = [
            Key.trackID: trackID.rawValue,
            Key.expectedBytes: String(expectedBytes),
            Key.pinned: pinned ? "1" : "0",
            Key.phoneRevision: String(phoneRevision)
        ]
        if let sha256 { out[Key.sha256] = sha256 }
        if let codec { out[Key.codec] = codec }
        if let fileExtension { out[Key.fileExtension] = fileExtension }
        if let transferID { out["audioTransferID"] = transferID }
        return out
    }

    /// Total decode: a missing track ID or an unparseable byte count is the only way this fails,
    /// and both mean the delivery cannot be attributed to a job at all.
    public init?(dictionary: [String: String]) {
        guard let rawID = dictionary[Key.trackID], !rawID.isEmpty,
              let rawBytes = dictionary[Key.expectedBytes], let bytes = Int64(rawBytes) else {
            return nil
        }
        self.trackID = WatchTrackID(rawID)
        self.transferID = dictionary["audioTransferID"]
        self.expectedBytes = bytes
        self.sha256 = dictionary[Key.sha256].flatMap { $0.isEmpty ? nil : $0 }
        self.codec = dictionary[Key.codec].flatMap { $0.isEmpty ? nil : $0 }
        self.fileExtension = dictionary[Key.fileExtension].flatMap { $0.isEmpty ? nil : $0.lowercased() }
        self.pinned = dictionary[Key.pinned] != "0"
        self.phoneRevision = dictionary[Key.phoneRevision].flatMap(Int64.init) ?? 0
    }

    private enum Key {
        static let trackID = "trackID"
        static let expectedBytes = "expectedBytes"
        static let sha256 = "sha256"
        static let codec = "codec"
        static let fileExtension = "fileExtension"
        static let pinned = "pinned"
        static let phoneRevision = "phoneRevision"
    }

    /// Streaming cache blobs use `<sha256>-<ext>`, not a dotted filename. Carry the
    /// container explicitly so inbox staging and deferred installation preserve it.
    public static func fileExtension(for url: URL) -> String? {
        if !url.pathExtension.isEmpty { return url.pathExtension.lowercased() }
        let parts = url.lastPathComponent.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 64,
              parts[0].allSatisfy({ $0.isHexDigit }), !parts[1].isEmpty else { return nil }
        return String(parts[1]).lowercased()
    }
}
