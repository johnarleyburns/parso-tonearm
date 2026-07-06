import Foundation

/// Seeds a small local-only demo library so the app is populated on first run
/// without any network contact. Real IA sources are added by the user via URL.
enum SampleData {
    static func seed(into store: LibraryStore) async {
        do {
            try await seedFieldRecordings(store)
            try await seedLocalTrack(store)
        } catch {
            print("sample seed error: \(error)")
        }
    }

    private static func seedFieldRecordings(_ store: LibraryStore) async throws {
        var source = Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                            title: "Field Recordings ’24", addedAt: Date(),
                            lastResolvedAt: nil, followUpdates: false,
                            licenseText: nil, memberCapHit: false)
        source = try await store.insertSource(source)
        guard let sid = source.id else { return }
        var album = Album(id: nil, sourceId: sid, title: "Field Recordings ’24",
                          artist: "On Device", year: 2024, artworkId: nil)
        album = try await store.insertAlbum(album)
        guard let aid = album.id else { return }
        let titles = ["Marsh Dawn Chorus", "Harbor Fog Signal", "Aspen Wind", "Night Rail Yard"]
        for (i, title) in titles.enumerated() {
            var track = Track(id: nil, albumId: aid, sourceId: sid, title: title,
                              trackNo: i + 1, discNo: nil, durationSec: Double(120 + i * 40),
                              codec: "FLAC", sampleRate: 96000, bitDepthOrBitrate: "24-bit",
                              sortKey: String(format: "%04d", i + 1))
            track = try await store.insertTrack(track)
            if let tid = track.id {
                let asset = Asset(id: nil, trackId: tid, kind: .localRef, bookmark: nil,
                                  relPath: nil, remoteURL: nil, sizeBytes: nil,
                                  unsupportedReason: "Demo entry — add your own files")
                try await store.insertAsset(asset)
            }
        }
    }

    private static func seedLocalTrack(_ store: LibraryStore) async throws {
        var pl = Playlist(id: nil, title: "Starter Playlist", kind: .manual,
                          folderBookmark: nil, watch: false)
        pl = try await store.insertPlaylist(pl)
    }
}
