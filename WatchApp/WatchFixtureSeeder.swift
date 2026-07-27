import Foundation
import TonearmCore

enum WatchFixtureSeeder {
    static func seed() {
        Task {
            do {
                try await seedThrowing()
            } catch {
                // Seeding is a DEBUG/UI-test convenience only — never crash the
                // app if it fails (e.g. a re-run over an already-seeded DB).
                NSLog("WatchFixtureSeeder: seeding skipped/failed: \(error)")
            }
        }
    }

    private static func seedThrowing() async throws {
        let store = LibraryStore.shared

        // Idempotent: if the fixture playlist already exists (persisted from a
        // prior launch), don't seed again — re-inserting would hit unique
        // constraints and previously crashed the app on the second run.
        let existing = (try? await store.allPlaylists()) ?? []
        if existing.contains(where: { $0.title == "Built-in Playlist" }) { return }

        let source = try? await store.firstSource(title: "Local Files", kind: .local)
        let sourceId: Int64
        if let s = source, let id = s.id {
            sourceId = id
        } else {
            let src = Source(
                id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                title: "Local Files", addedAt: Date(), lastResolvedAt: Date(),
                followUpdates: false, licenseText: nil, memberCapHit: false,
                localIsFolder: false)
            let inserted = try await store.insertSource(src)
            sourceId = inserted.id!
        }

        let artist = try await store.findOrCreateArtist(
            name: "Built-in", sortName: "built-in")

        let album = try await store.insertAlbum(
            Album(id: nil, sourceId: sourceId, title: "Built-in Sounds",
                  artist: "Built-in", artistId: artist.id,
                  albumArtist: "Built-in", year: 2025, artworkId: nil))

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
            if let watchDir {
                try? FileManager.default.createDirectory(
                    at: watchDir, withIntermediateDirectories: true)
                let destURL = watchDir.appendingPathComponent("\(title).wav")
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    try? FileManager.default.copyItem(at: fileURL, to: destURL)
                }
            }

            let track = Track(
                id: nil, albumId: album.id, sourceId: sourceId,
                title: title, trackNo: index + 1, discNo: 1,
                durationSec: 30.0, codec: "wav", sampleRate: nil,
                bitDepthOrBitrate: nil, sortKey: title, artistId: artist.id,
                syncID: "t-fixture-\(index)")
            let insertedTrack = try await store.insertTrack(track)
            guard let tid = insertedTrack.id else { continue }
            trackIds.append(tid)

            let asset = Asset(
                id: nil, trackId: tid, kind: .managedCopy,
                bookmark: nil, relPath: "WatchAudio/\(title).wav",
                remoteURL: nil, altRemoteURL: nil,
                sizeBytes: nil, unsupportedReason: nil)
            _ = try await store.dbQueue.write { db in
                _ = try asset.insertAndFetch(db)
            }
        }

        guard !trackIds.isEmpty else { return }

        _ = try? await store.createManualPlaylist(
            title: "Built-in Playlist",
            trackIds: trackIds)

        _ = try? await store.dbQueue.write { db in
            var manifestEntry = WatchManifestRecord(
                trackKey: trackIds.first.map { "t\($0)" } ?? "t0",
                bytes: 1_000_000, pinned: true, reportedAt: Date())
            try manifestEntry.insert(db)
        }
    }
}
