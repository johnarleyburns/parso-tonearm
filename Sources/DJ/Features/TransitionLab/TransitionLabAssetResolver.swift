import Foundation
import TonearmCore

/// Resolves a core `Asset` to its local audio file `URL`, or `nil` when only
/// a remote/undownloaded asset exists. Mirrors `DeckLoader.resolveAudioURL`,
/// `PhoneWatchLibraryAudioResolver.localURL(for:)`, and
/// `PlaylistCrateImporter.localURL(for:)` — the established pattern for this
/// exact lookup elsewhere in the codebase.
///
/// Transition Lab has no sparse/remote path at all (unlike Discovery's
/// embedding indexer): `ParsoAudioAnalysis.FullAnalysis` and
/// `ParsoAudioCore.AudioFileReader` both require the complete file decoded
/// into memory — there is no partial-read variant. A track with no local
/// asset is mechanically "Download required", full stop.
public enum TransitionLabAssetResolver {
    public static func localURL(for asset: Asset) -> URL? {
        if let bookmark = asset.bookmark, let (url, _) = BookmarkVault.resolve(bookmark) {
            return url
        }
        if let remote = asset.remoteURL.flatMap(URL.init(string:)), remote.isFileURL {
            return remote
        }
        if let relPath = asset.relPath,
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: false)
        {
            let url = base.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let remote = asset.remoteURL.flatMap(URL.init(string:)),
            AudioCache.completeCacheExists(for: remote)
        {
            return AudioCache.fileURL(for: AudioCache.key(for: remote))
        }
        return nil
    }
}
