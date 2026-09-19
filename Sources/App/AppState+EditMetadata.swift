import Foundation
import TonearmCore

extension AppState {
    /// Persist-if-needed then edit: a remote/streamed `TrackRow` can carry a
    /// negative, transient id until it's actually written into the core
    /// library — same guard `assignCustomArtwork(toTrack:data:)` uses, so
    /// editing metadata on a not-yet-downloaded remote row doesn't silently
    /// no-op or write against an id that never becomes the track's real one.
    func editTrackMetadata(row: TrackRow, title: String, artistName: String?) async -> Bool {
        var target = row
        if target.id < 0 {
            guard let persisted = await persistRemoteTrack(target) else { return false }
            target = persisted
        }
        guard target.id > 0 else { return false }
        do {
            try await store.updateTrackMetadata(trackId: target.id, title: title, artistName: artistName)
            await reload()
            return true
        } catch {
            return false
        }
    }
}
