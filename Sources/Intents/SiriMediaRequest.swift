import Foundation

/// A spoken SiriKit media request ("Play Hotel California on Platterhead"),
/// carried from the `TonearmSiriIntents` extension to the app.
///
/// The library lives in the app's own SQLite (Application Support, not the app
/// group), so the extension can't search it. It packs what Siri heard into an
/// `INMediaItem.identifier` (`identifier`), answers `.handleInApp`, and the app
/// unpacks it (`init?(identifier:)`) and resolves it with the same
/// `IntentResolver` pipeline the App Intents use (`attempts`). Pure and
/// host-testable; no Intents import.
public struct SiriMediaRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case song, artist, album, playlist, unspecified
    }

    /// One way to satisfy the request, tried in order until one matches.
    public enum Attempt: Equatable, Sendable {
        case resume
        case song(title: String, artist: String?)
        case artist(String)
        case playlist(String)
    }

    public static let identifierPrefix = "tonearm.siri.v1:"

    public var query: String
    public var artist: String?
    public var kind: Kind

    public init(query: String?, artist: String?, kind: Kind) {
        self.query = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedArtist = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = trimmedArtist.isEmpty ? nil : trimmedArtist
        self.kind = kind
    }

    /// Nothing named: "Hey Siri, play Platterhead".
    public var isResume: Bool { query.isEmpty && artist == nil }

    /// What Siri shows and says back for the placeholder item.
    public var displayTitle: String {
        if isResume { return "Platterhead" }
        if query.isEmpty { return artist ?? "" }
        if let artist { return "\(query) by \(artist)" }
        return query
    }

    public var identifier: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return Self.identifierPrefix + data.base64EncodedString()
    }

    public init?(identifier: String) {
        guard identifier.hasPrefix(Self.identifierPrefix),
              let data = Data(base64Encoded: String(identifier.dropFirst(Self.identifierPrefix.count))),
              let decoded = try? JSONDecoder().decode(SiriMediaRequest.self, from: data)
        else { return nil }
        self = decoded
    }

    /// Resolution order. A request Siri couldn't classify tries song, then
    /// artist, then playlist, so "play Road Trip" finds a playlist when no song
    /// is called that. Albums have no dedicated resolver yet, so they search
    /// songs (an honest gap, not a guess).
    public var attempts: [Attempt] {
        if isResume { return [.resume] }
        if query.isEmpty, let artist { return [.artist(artist)] }
        switch kind {
        case .playlist: return [.playlist(query)]
        case .artist: return [.artist(query)]
        case .song, .album: return [.song(title: query, artist: artist)]
        case .unspecified: return [.song(title: query, artist: artist), .artist(query), .playlist(query)]
        }
    }
}
