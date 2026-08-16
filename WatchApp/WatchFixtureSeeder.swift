import Foundation
import GRDB
import TonearmCore

enum WatchFixtureSeeder {
    /// The second smoke playlist: one track already on the watch and pinned in
    /// the manifest. `WatchSmokeUITests` browses to it by this name.
    static let pinnedPlaylistTitle = "Pinned Track Smoke"

    /// The bundled track that playlist holds — the smoke asserts this title in
    /// Now Playing, so the two have to agree.
    static let pinnedTrackTitle = "ambient-ocean"

    static func seed() async {
        do {
            try await seedThrowing()
        } catch {
            // Seeding is a DEBUG/UI-test convenience only; never crash the app if
            // a simulator re-run hits an already-seeded DB.
            NSLog("WatchFixtureSeeder: seeding skipped/failed: \(error)")
        }
    }

    private static func seedThrowing() async throws {
        let store = LibraryStore.shared
        // Two independent, individually idempotent steps. They are separate
        // because the simulator container outlives a run: whichever fixture is
        // already there must be left alone, and re-entering the insert path for
        // one must not stop the other from being created.
        try await seedBuiltIn(store: store)
        try await seedPinnedSmoke(store: store)
    }

    /// Seeds both smoke playlists from the **bundled** ambient WAVs.
    ///
    /// NOTHING HERE TOUCHES THE NETWORK, deliberately. Until 2026-08-16 the two
    /// extra playlists were "Musopen Stream Smoke" (an archive.org URL streamed
    /// live) and "Musopen Download Smoke" (the same item downloaded at seed
    /// time). Both asserted that the elapsed clock advances — the assertion that
    /// catches a dead transport — and both stopped working the moment
    /// archive.org did: on 2026-08-16 `archive.org/metadata/musopen-chopin`
    /// answered 200 while every audio file under `archive.org/download/…`
    /// returned HTTP 500, so playback reported `playing`, no bytes ever arrived,
    /// the elapsed label sat at 0:00 and **the pre-commit hook blocked every
    /// commit in the repository**. A smoke test is a gate on our own code; a
    /// third party's uptime must not be able to close it.
    ///
    /// Live remote servers belong to the UI regression suite
    /// (`RemoteLibraryRegressionUITests`, §53), which is run by hand and is
    /// allowed to skip when a prerequisite is missing. The stream-versus-local
    /// decision itself is pure and unit-tested in `swift test`
    /// (`WatchTrackResolverTests`, 12 cases), so what actually leaves this file
    /// is only "watchOS pulls audio over HTTP", which no smoke test can assert
    /// without depending on somebody else's server being up.
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
        var bytesByTrackID: [Int64: Int64] = [:]

        // Sorted, so the fixtures are the same tracks in the same order on every
        // run — `contentsOfDirectory` promises no ordering, and a smoke test that
        // asserts a track title cannot be built on a set.
        let wavs = files
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for (index, fileURL) in wavs.enumerated() {
            let title = fileURL.deletingPathExtension().lastPathComponent
            let destDir = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            let watchDir = destDir?.appendingPathComponent(WatchStorage.watchAudioDirName)
            var copiedBytes: Int64 = 0
            if let watchDir {
                try? FileManager.default.createDirectory(
                    at: watchDir, withIntermediateDirectories: true)
                let destURL = watchDir.appendingPathComponent("\(title).wav")
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    try? FileManager.default.copyItem(at: fileURL, to: destURL)
                }
                let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
                copiedBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
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
            bytesByTrackID[tid] = copiedBytes

            let asset = Asset(
                id: nil, trackId: tid, kind: .managedCopy,
                bookmark: nil, relPath: "\(WatchStorage.watchAudioDirName)/\(title).wav",
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

        // Real file sizes, not a round number: the storage screen renders these,
        // and a fabricated 1 MB against a 5 MB file is a small lie that would
        // survive right up until someone read it.
        for trackID in trackIds {
            let bytes = bytesByTrackID[trackID] ?? 0
            guard bytes > 0 else { continue }
            _ = try? await store.dbQueue.write { db in
                var manifestEntry = WatchManifestRecord(
                    trackKey: "t\(trackID)",
                    bytes: bytes,
                    pinned: true,
                    reportedAt: Date())
                try manifestEntry.save(db)
            }
        }
    }

    /// The **downloaded-and-pinned** shape the old "Musopen Download Smoke"
    /// covered: a track whose audio is already on the watch, in a playlist of its
    /// own, reached by a second browse from the root — so the smoke still walks
    /// the list twice and plays two different things. The only difference from
    /// the old fixture is where the bytes came from: the app bundle, not a
    /// download at seed time.
    ///
    /// Looked up by title rather than by index: a container seeded before the
    /// bundle listing was sorted can hold a different `t-fixture-N` ordering, and
    /// the smoke asserts this exact track name.
    private static func seedPinnedSmoke(store: LibraryStore) async throws {
        let existing = (try? await store.allPlaylists()) ?? []
        if existing.contains(where: { $0.title == pinnedPlaylistTitle }) { return }

        let track = try await store.dbQueue.read { db in
            try Track.filter(Column("title") == pinnedTrackTitle).fetchOne(db)
        }
        guard let track, let trackID = track.id else { return }
        _ = try? await store.createManualPlaylist(
            title: pinnedPlaylistTitle,
            trackIds: [trackID])
    }
}
