import Foundation

/// Typed identifiers for everything that crosses the iPhone↔Watch boundary.
///
/// Phase 3 moves `WatchTrackID` out of `ArchitectureTypes.swift` and gives it siblings, because
/// §5 payloads name four different kinds of ID and a bare `String` in a DTO is exactly how a
/// playlist key ends up being looked up as a track key. Each conforms to `RawRepresentable` with a
/// `String` raw value, so the standard library's conditional conformances give them *single-value*
/// Codable representations: on the wire an ID is the bare string, not `{"rawValue": …}`.
public protocol WatchStableID: RawRepresentable, Codable, Hashable, Sendable,
                               Comparable, CustomStringConvertible, ExpressibleByStringLiteral
where RawValue == String, StringLiteralType == String {
    init(_ rawValue: String)
}

extension WatchStableID {
    public init(rawValue: String) { self.init(rawValue) }
    public init(stringLiteral value: String) { self.init(value) }
    public var description: String { rawValue }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct WatchTrackID: WatchStableID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct WatchPlaylistID: WatchStableID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct WatchAlbumID: WatchStableID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct WatchArtistID: WatchStableID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct WatchDownloadRootID: WatchStableID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Identity of the phone library a watch is bound to. §5.4: this changes after a phone library
/// reset or reinstall, and the watch must prompt before replacing unrelated downloaded content.
public struct WatchPairedLibraryID: WatchStableID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Used before `hello` has completed. Never matches a real library, so an unnegotiated peer
    /// can never be mistaken for the bound one.
    public static let unknown = WatchPairedLibraryID("")
    public var isKnown: Bool { !rawValue.isEmpty }
}

/// A collection the watch can ask the phone to enumerate or play. Album and playlist are the only
/// two kinds §5.3 defines; keeping the pair typed stops a `collectionRequest` from being ambiguous.
public enum WatchCollectionKind: String, Codable, Sendable, CaseIterable {
    case playlist, album
}

public struct WatchCollectionRef: Codable, Equatable, Hashable, Sendable {
    public var kind: WatchCollectionKind
    public var id: String

    public init(kind: WatchCollectionKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public static func playlist(_ id: WatchPlaylistID) -> Self { .init(kind: .playlist, id: id.rawValue) }
    public static func album(_ id: WatchAlbumID) -> Self { .init(kind: .album, id: id.rawValue) }
}
