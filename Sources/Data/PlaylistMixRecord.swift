import Foundation
import GRDB

/// Persisted configuration for the mix associated with a playlist.
///
/// The mix table is deliberately a single row per playlist: the playlist
/// remains the durable ordered result, while this record preserves the
/// inputs needed to explain or regenerate that result.
public struct PlaylistMixRecord: Codable, Equatable, Sendable, FetchableRecord,
    MutablePersistableRecord {
    public static let databaseTableName = "playlist_mix"

    public var playlistId: Int64
    public var shape: String
    public var seed: Int64
    public var lockedJSON: Data
    public var transitionOverridesJSON: Data
    public var updatedAt: Date
    public var syncID: String?

    public init(playlistId: Int64, shape: MixShape = .risingBPM, seed: UInt64 = 0,
                lockedJSON: Data = Data("{}".utf8),
                transitionOverridesJSON: Data = Data("{}".utf8),
                updatedAt: Date = Date(), syncID: String? = nil) {
        self.playlistId = playlistId
        self.shape = shape.rawValue
        self.seed = Int64(bitPattern: seed)
        self.lockedJSON = lockedJSON
        self.transitionOverridesJSON = transitionOverridesJSON
        self.updatedAt = updatedAt
        self.syncID = syncID
    }

    public var mixShape: MixShape { MixShape(rawValue: shape) ?? .risingBPM }
    public var unsignedSeed: UInt64 { UInt64(bitPattern: seed) }
}
