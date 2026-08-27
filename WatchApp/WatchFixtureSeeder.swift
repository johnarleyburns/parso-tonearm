import Foundation
import TonearmWatchLegacyCore

enum WatchFixtureSeeder {
    static let pinnedPlaylistTitle = "Built-in Playlist"
    static let pinnedTrackTitle = "ambient-ocean"

    static func seed() async {
        guard let source = Bundle.main.url(forResource: pinnedTrackTitle, withExtension: "wav") else { return }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = root.appendingPathComponent(WatchStorage.watchAudioDirName)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            try await LegacyWatchLibraryStore.shared.seedFixture(
                title: pinnedTrackTitle,
                audioRelativePath: "\(WatchStorage.watchAudioDirName)/\(source.lastPathComponent)")
        } catch {
            NSLog("WatchFixtureSeeder: seeding failed: \(error)")
        }
    }
}
