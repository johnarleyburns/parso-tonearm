import Foundation
import ParsoDJEngine
import TonearmCore

@MainActor
extension DJAudioBacker {
    func resolve(_ asset: Asset?) -> URL? {
        guard let asset else { return nil }
        if asset.kind == .builtIn, let channel = asset.relPath {
            return BuiltInContentProvider.bundledAudioURL(forChannelId: channel)
        }
        if let bookmark = asset.bookmark, let resolved = BookmarkVault.resolve(bookmark) {
            return resolved.url
        }
        if let remote = asset.remoteURL.flatMap({ URL(string: $0) }), remote.isFileURL { return remote }
        if let path = asset.relPath,
           let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: false) {
            let url = base.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func index(for deck: DJDeckID) -> Int { deck == .a ? 0 : 1 }
    func channel(_ deck: DJDeckID) -> Channel { deck == .a ? engine.mixer.channelA : engine.mixer.channelB }

    func restoreHotCues(_ deck: DJDeckID) {
        // Hot-cue positions are restored by DJPerformanceModel's persisted
        // state; PAE receives the exact sample address when the user jumps.
    }
}
