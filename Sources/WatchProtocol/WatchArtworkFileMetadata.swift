import Foundation

public enum WatchArtworkRole: String, Codable, Sendable, CaseIterable {
    case cover, custom
}

/// Property-list-safe metadata for a content-addressed artwork delivery.
public struct WatchArtworkFileMetadata: Equatable, Sendable {
    public static let assetKind = "artwork"

    public var artworkID: String
    public var expectedBytes: Int64
    public var sha256: String
    public var role: WatchArtworkRole
    public var phoneRevision: Int64

    public init(artworkID: String, expectedBytes: Int64, sha256: String,
                role: WatchArtworkRole, phoneRevision: Int64 = 0) {
        self.artworkID = artworkID
        self.expectedBytes = expectedBytes
        self.sha256 = sha256
        self.role = role
        self.phoneRevision = phoneRevision
    }

    public var dictionary: [String: String] {
        [Key.assetKind: Self.assetKind, Key.artworkID: artworkID,
         Key.expectedBytes: String(expectedBytes), Key.sha256: sha256,
         Key.role: role.rawValue, Key.phoneRevision: String(phoneRevision)]
    }

    public init?(dictionary: [String: String]) {
        guard dictionary[Key.assetKind] == Self.assetKind,
              let artworkID = dictionary[Key.artworkID], !artworkID.isEmpty,
              let rawBytes = dictionary[Key.expectedBytes], let expectedBytes = Int64(rawBytes),
              let sha256 = dictionary[Key.sha256], !sha256.isEmpty,
              let rawRole = dictionary[Key.role], let role = WatchArtworkRole(rawValue: rawRole) else {
            return nil
        }
        self.artworkID = artworkID
        self.expectedBytes = expectedBytes
        self.sha256 = sha256
        self.role = role
        self.phoneRevision = dictionary[Key.phoneRevision].flatMap(Int64.init) ?? 0
    }

    private enum Key {
        static let assetKind = "assetKind"
        static let artworkID = "artworkID"
        static let expectedBytes = "expectedBytes"
        static let sha256 = "sha256"
        static let role = "role"
        static let phoneRevision = "phoneRevision"
    }
}
