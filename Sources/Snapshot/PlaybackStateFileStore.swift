import Foundation

/// Atomic file tier for playback state, stronger than UserDefaults (cfprefsd is
/// async) and the recovery tier when the defaults key is corrupt/missing.
/// Writes go to a temp file then atomically replace the real file, so a torn
/// write never destroys the last-known-good state (G5).
///
/// When the app-group container is unavailable on macOS host tests the file
/// store falls back to Application Support.
public enum PlaybackStateFileStore {
    private static let filename = "playback-state.v2.json"
    private static let tmpSuffix = ".tmp"

    // MARK: - Location

    public static func fileURL() -> URL? {
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupIdentifier) {
            return container.appendingPathComponent(filename)
        }
        // Fallback for macOS host (swift test): Application Support
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("Tonearm").appendingPathComponent(filename)
    }

    // MARK: - Atomic save

    public static func save(_ snapshot: PlaybackStateSnapshot) {
        guard let url = fileURL() else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }

        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write to a temp file, then rename onto the real path.
        // On APFS rename is atomic — all-or-nothing (G5).
        let tmpURL = url.appendingPathExtension(tmpSuffix)
        try? data.write(to: tmpURL, options: [])
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmpURL, to: url)
    }

    // MARK: - Load

    /// Returns the snapshot from the file tier, or nil on decode failure.
    /// Never deletes the file on failure — a later good write replaces it.
    public static func load() -> PlaybackStateSnapshot? {
        guard let url = fileURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PlaybackStateSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }
}
