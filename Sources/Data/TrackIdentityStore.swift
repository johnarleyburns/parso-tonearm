import Foundation
import GRDB

enum TrackIdentityStore {
    static func rebuild(trackId: Int64, db: Database) throws {
        guard let track = try Track.fetchOne(db, key: trackId) else { return }
        try db.execute(sql: "DELETE FROM track_identity WHERE trackId = ?", arguments: [trackId])
        let asset = try Asset.filter(Column("trackId") == trackId).fetchOne(db)
        let source = try Source.fetchOne(db, key: track.sourceId)
        let artist = try track.artistId.flatMap { try Artist.fetchOne(db, key: $0) }?.name
        let album = try track.albumId.flatMap { try Album.fetchOne(db, key: $0) }?.title
        for key in TrackIdentity.keys(track: track, asset: asset, source: source, artist: artist, album: album) {
            try db.execute(sql: "INSERT OR REPLACE INTO track_identity (trackId, strength, keyHash) VALUES (?, ?, ?)",
                           arguments: [trackId, key.strength.rawValue, key.value])
        }
    }
}
