import Foundation

/// App Group artwork paths shared by the widget snapshot builder (Core), the
/// widgets extension, and the app's image writer. The UIKit encode/downscale
/// (`save(image:for:)`) lives app-side in an extension of this type.
public enum WidgetArtworkStore {
    public static let targetSize: CGFloat = 180
    public static let compressionQuality: CGFloat = 0.7
    private static let artworkDir = "artwork"

    public static func filename(for artworkID: String) -> String {
        let safe = artworkID.replacingOccurrences(of: "/", with: "_")
                     .replacingOccurrences(of: ":", with: "_")
                     .replacingOccurrences(of: " ", with: "_")
        let truncated = String(safe.prefix(120))
        return "\(truncated).jpg"
    }

    private static func containerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupIdentifier
        )
    }

    public static func artworkDirectory() -> URL? {
        guard let base = containerURL() else { return nil }
        let dir = base.appendingPathComponent(artworkDir)
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func imageURL(for filename: String) -> URL? {
        artworkDirectory()?.appendingPathComponent(filename)
    }

    public static func prune(keeping filenames: Set<String>) {
        guard let dir = artworkDirectory(),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return }
        for url in contents where !filenames.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
