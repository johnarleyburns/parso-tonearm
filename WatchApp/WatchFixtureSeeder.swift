import Foundation
import GRDB
import TonearmCore

enum WatchFixtureSeeder {
    static func seed() async {
        do {
            try await seedThrowing()
        } catch {
            // Seeding is a DEBUG/UI-test convenience only; never crash the app if
            // a simulator re-run hits an already-seeded DB or a network fixture
            // is temporarily unavailable.
            NSLog("WatchFixtureSeeder: seeding skipped/failed: \(error)")
        }
    }

    private static func seedThrowing() async throws {
        let store = LibraryStore.shared
        try await seedBuiltIn(store: store)

        let args = ProcessInfo.processInfo.arguments
        if args.contains("SEED_MUSOPEN_FIXTURES") {
            try await seedMusopen(store: store)
        }
    }

    private static func seedBuiltIn(store: LibraryStore) async throws {
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

        let firstTrackKey = trackIds.first.map { "t\($0)" } ?? "t0"
        _ = try? await store.dbQueue.write { db in
            var manifestEntry = WatchManifestRecord(
                trackKey: firstTrackKey,
                bytes: 1_000_000, pinned: true, reportedAt: Date())
            try manifestEntry.insert(db)
        }
    }

    private static func seedMusopen(store: LibraryStore) async throws {
        let existing = (try? await store.allPlaylists()) ?? []
        if existing.contains(where: { $0.title == "Musopen Stream Smoke" }) &&
            existing.contains(where: { $0.title == "Musopen Download Smoke" }) {
            return
        }

        let source = try await ensureMusopenSource(store: store)
        guard let sourceId = source.id else { return }
        let artist = try await store.findOrCreateArtist(
            name: "Frederic Chopin",
            sortName: "chopin frederic")
        let album = try await store.insertAlbum(
            Album(id: nil,
                  sourceId: sourceId,
                  title: "Musopen - The Complete Chopin Collection",
                  artist: "Frederic Chopin",
                  artistId: artist.id,
                  albumArtist: "Frederic Chopin",
                  genre: "Classical",
                  year: 2015,
                  artworkId: "musopen-chopin"))

        if !existing.contains(where: { $0.title == "Musopen Stream Smoke" }) {
            let streamTrack = try await insertMusopenTrack(
                title: "Prelude Op. 28 no. 7",
                remoteURL: "https://archive.org/download/musopen-chopin/Prelude%20Op.%2028%20no.%207.mp3",
                relPath: nil,
                duration: 155.3,
                trackNo: 7,
                sourceId: sourceId,
                albumId: album.id,
                artistId: artist.id,
                store: store)
            if let id = streamTrack.id {
                _ = try await store.createManualPlaylist(
                    title: "Musopen Stream Smoke",
                    trackIds: [id])
            }
        }

        if !existing.contains(where: { $0.title == "Musopen Download Smoke" }) {
            let url = URL(string: "https://archive.org/download/musopen-chopin/Prelude%20Op.%2028%20no.%2010.mp3")!
            let relPath = try await downloadFixtureAudio(
                from: url,
                filename: "musopen-prelude-op28-no10.mp3")
            let localTrack = try await insertMusopenTrack(
                title: "Prelude Op. 28 no. 10",
                remoteURL: nil,
                relPath: relPath.path,
                duration: 32.5,
                trackNo: 10,
                sourceId: sourceId,
                albumId: album.id,
                artistId: artist.id,
                store: store)
            if let id = localTrack.id {
                _ = try await store.createManualPlaylist(
                    title: "Musopen Download Smoke",
                    trackIds: [id])
                _ = try? await store.dbQueue.write { db in
                    var manifestEntry = WatchManifestRecord(
                        trackKey: "t\(id)",
                        bytes: relPath.bytes,
                        pinned: true,
                        reportedAt: Date())
                    try manifestEntry.save(db)
                }
            }
        }
    }

    private static func ensureMusopenSource(store: LibraryStore) async throws -> Source {
        if let existing = try? await store.firstSource(title: "Musopen Watch Smoke", kind: .iaItem) {
            return existing
        }
        let source = Source(
            id: nil,
            kind: .iaItem,
            iaIdentifier: "musopen-chopin",
            originalURL: "https://archive.org/details/musopen-chopin",
            title: "Musopen Watch Smoke",
            addedAt: Date(),
            lastResolvedAt: Date(),
            followUpdates: false,
            licenseText: "CC0 Public Domain",
            memberCapHit: false)
        return try await store.insertSource(source)
    }

    private static func insertMusopenTrack(title: String,
                                           remoteURL: String?,
                                           relPath: String?,
                                           duration: Double,
                                           trackNo: Int,
                                           sourceId: Int64,
                                           albumId: Int64?,
                                           artistId: Int64?,
                                           store: LibraryStore) async throws -> Track {
        let syncID = "musopen-watch-\(trackNo)"
        if let existing = try? await store.trackBySyncID(syncID) {
            if let trackId = existing.id {
                try await upsertMusopenAsset(
                    trackId: trackId,
                    remoteURL: remoteURL,
                    relPath: relPath,
                    store: store)
            }
            return existing
        }
        let track = Track(
            id: nil,
            albumId: albumId,
            sourceId: sourceId,
            title: title,
            trackNo: trackNo,
            discNo: 1,
            durationSec: duration,
            codec: "MP3",
            sampleRate: nil,
            bitDepthOrBitrate: nil,
            sortKey: String(format: "%04d", trackNo),
            genre: "Classical",
            composer: "Frederic Chopin",
            artistId: artistId,
            syncID: syncID)
        let insertedTrack = try await store.insertTrack(track)
        guard let trackId = insertedTrack.id else { return insertedTrack }
        try await upsertMusopenAsset(
            trackId: trackId,
            remoteURL: remoteURL,
            relPath: relPath,
            store: store)
        return insertedTrack
    }

    private static func upsertMusopenAsset(trackId: Int64,
                                           remoteURL: String?,
                                           relPath: String?,
                                           store: LibraryStore) async throws {
        try await store.dbQueue.write { db in
            if var asset = try Asset
                .filter(Column("trackId") == trackId)
                .order(Column("id"))
                .fetchOne(db) {
                asset.kind = relPath == nil ? .remote : .managedCopy
                asset.relPath = relPath
                asset.remoteURL = remoteURL
                asset.altRemoteURL = nil
                asset.unsupportedReason = nil
                try asset.update(db)
            } else {
                var asset = Asset(
                    id: nil,
                    trackId: trackId,
                    kind: relPath == nil ? .remote : .managedCopy,
                    bookmark: nil,
                    relPath: relPath,
                    remoteURL: remoteURL,
                    altRemoteURL: nil,
                    sizeBytes: nil,
                    unsupportedReason: nil)
                try asset.insert(db)
            }
        }
    }

    private static func downloadFixtureAudio(from url: URL,
                                             filename: String) async throws -> (path: String, bytes: Int64) {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let watchDir = appSupport.appendingPathComponent(WatchStorage.watchAudioDirName)
        try FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        let destURL = watchDir.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: destURL.path) {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: destURL.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return ("\(WatchStorage.watchAudioDirName)/\(filename)", bytes)
    }
}
