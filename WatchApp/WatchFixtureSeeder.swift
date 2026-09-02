import Foundation
import TonearmWatchCore

/// DEBUG-only deterministic seed for the watch UI smoke test. Copies the bundled `ambient-ocean.wav`
/// into the store's audio directory, marks it ready with its real checksum, and builds the two
/// playlists the smoke test browses. No network, no seed-time transfer.
enum WatchFixtureSeeder {
    static let trackID = "fixture-ambient-ocean"
    static let trackTitle = "ambient-ocean"

    static func seed(repository: WatchLibraryRepository, audioDirectory: URL) async {
        guard let source = bundledOceanURL() else {
            NSLog("WatchFixtureSeeder: ambient-ocean.wav not found in bundle")
            return
        }
        let fm = FileManager.default
        let filename = "ambient-ocean.wav"
        let destination = audioDirectory.appendingPathComponent(filename)
        do {
            try fm.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            // UI tests may reuse a simulator's application container after a failed run. Replace
            // the fixture so a stale/partial prior copy cannot make a ready library point at a
            // different or corrupt AVPlayer input.
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
            let measured = try WatchFileDigest.measure(destination)
            try await repository.upsertTrack(.init(
                trackID: trackID, title: trackTitle, artist: "Built-in", albumTitle: "Built-in Sounds"))
            try await repository.markAsset(
                trackID: trackID, relativeFilename: filename,
                installedBytes: measured.bytes, sha256: measured.sha256, state: .ready)
            try await repository.upsertPlaylist(
                .init(playlistID: "fixture-builtin", title: "Built-in Playlist", trackIDs: [trackID]),
                desiredOnWatch: true)
            try await repository.upsertPlaylist(
                .init(playlistID: "fixture-pinned", title: "Pinned Track Smoke", trackIDs: [trackID]),
                desiredOnWatch: true)
        } catch {
            NSLog("WatchFixtureSeeder: seeding failed: \(error)")
        }
    }

    /// The bundled WAV lives in the `TonearmCore` SPM resource bundle nested inside the watch app
    /// (`TonearmCore_TonearmCore.bundle/Audio/`), not at the main-bundle root — so a plain
    /// `Bundle.main.url(forResource:)` misses it. Search the main bundle, then every nested `.bundle`.
    private static func bundledOceanURL() -> URL? {
        let fm = FileManager.default
        for bundle in [Bundle.main] + nestedBundles(in: Bundle.main) {
            if let url = bundle.url(forResource: trackTitle, withExtension: "wav") { return url }
            if let url = bundle.url(forResource: trackTitle, withExtension: "wav", subdirectory: "Audio") {
                return url
            }
        }
        // Last resort: a direct filesystem walk of the app bundle.
        if let enumerator = fm.enumerator(at: Bundle.main.bundleURL,
                                          includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.lastPathComponent == "\(trackTitle).wav" {
                return url
            }
        }
        return nil
    }

    private static func nestedBundles(in bundle: Bundle) -> [Bundle] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: bundle.bundleURL, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "bundle" }.compactMap(Bundle.init(url:))
    }
}
