import Foundation
import TonearmCore

enum WatchFixtureSeeder {
    static func seed() {
        Task {
            let store = LibraryStore.shared
            let source = try? await store.firstSource(title: "Local Files", kind: .local)
            let sourceId: Int64
            if let s = source, let id = s.id {
                sourceId = id
            } else {
                var src = Source(
                    id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                    title: "Local Files", addedAt: Date(), lastResolvedAt: Date(),
                    followUpdates: false, licenseText: nil, memberCapHit: false,
                    localIsFolder: false)
                let inserted = try! await store.insertSource(src)
                sourceId = inserted.id!
            }

            let artist = try! await store.findOrCreateArtist(
                name: "Built-in", sortName: "built-in")

            var album = Album(id: nil, sourceId: sourceId, title: "Built-in Sounds",
                              artist: "Built-in", artistId: artist.id,
                              albumArtist: "Built-in", year: 2025, artworkId: nil)
            let insertedAlbum = try! await store.insertAlbum(album)
            album = insertedAlbum

            let audioDir = Bundle.main.resourceURL?
                .appendingPathComponent("TonearmCore_TonearmCore.bundle/Audio")
            let files = (try? FileManager.default.contentsOfDirectory(
                at: audioDir ?? URL(fileURLWithPath: "/"),
                includingPropertiesForKeys: nil)) ?? []

            var trackIds: [Int64] = []

            for (index, fileURL) in files.filter({ $0.pathExtension.lowercased() == "wav" }).enumerated() {
                let title = fileURL.deletingPathExtension().lastPathComponent
                let destDir = try? FileManager.default.url(
                    for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true)
                let watchDir = destDir?.appendingPathComponent("WatchAudio")
                try? FileManager.default.createDirectory(at: watchDir!,
                                                         withIntermediateDirectories: true)
                let destURL = watchDir?.appendingPathComponent("\(title).wav")
                if let dest = destURL, !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.copyItem(at: fileURL, to: dest)
                }

                var track = Track(
                    id: nil, albumId: album.id, sourceId: sourceId,
                    title: title, trackNo: index + 1, discNo: 1,
                    durationSec: 30.0, codec: "wav", sampleRate: nil,
                    bitDepthOrBitrate: nil, sortKey: title, artistId: artist.id,
                    syncID: "t-fixture-\(index)")
                let insertedTrack = try! await store.insertTrack(track)
                trackIds.append(insertedTrack.id!)

                let asset = Asset(
                    id: nil, trackId: insertedTrack.id!, kind: .managedCopy,
                    bookmark: nil, relPath: "WatchAudio/\(title).wav",
                    remoteURL: nil, altRemoteURL: nil,
                    sizeBytes: nil, unsupportedReason: nil)
                _ = try! await store.dbQueue.write { db in
                    _ = try asset.insertAndFetch(db)
                }
            }

            if !trackIds.isEmpty {
                _ = try? await store.createManualPlaylist(
                    title: "Built-in Playlist",
                    trackIds: trackIds)
            }

            var manifestEntry = WatchManifestRecord(
                trackKey: trackIds.first.map { "t\($0)" } ?? "t0",
                bytes: 1000000, pinned: true, reportedAt: Date())
            _ = try? await store.dbQueue.write { db in
                try manifestEntry.insert(db)
            }
        }
    }
}
