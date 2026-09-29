import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
import UIKit

extension AppState {
    func assignCustomArtwork(trackId: Int64, data: Data) async -> Bool {
        let previous = (try? await store.customArtworkId(for: trackId)) ?? nil
        guard let sourceID = await ArtworkStore.shared.store(data) else { return false }
        var variantID: String?
        var temporaryURL: URL?
        do {
            guard let sourceURL = await ArtworkStore.shared.fileURLIfPresent(id: sourceID) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let variant = try WatchArtworkVariant.make(from: sourceURL)
            variantID = variant.artworkID
            temporaryURL = variant.fileURL
            let variantData = try Data(contentsOf: variant.fileURL)
            guard await ArtworkStore.shared.storeWatchVariant(variantData, artworkID: variant.artworkID) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try await store.setCustomArtwork(trackId: trackId, artworkId: variant.artworkID)
            let stillUsed = (try? await store.allCustomArtworkIds()) ?? []
            for oldID in Set([sourceID, previous].compactMap { $0 })
                where oldID != variant.artworkID && !stillUsed.contains(oldID) {
                await ArtworkStore.shared.delete(id: oldID)
            }
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            await watchRuntime.artworkDidChange()
            return true
        } catch {
            await ArtworkStore.shared.delete(id: sourceID)
            if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
            if let variantID, variantID != previous,
               !((try? await store.allCustomArtworkIds()) ?? []).contains(variantID) {
                await ArtworkStore.shared.delete(id: variantID)
            }
            return false
        }
    }

    /// Persist-if-needed then assign: a remote/streamed `TrackRow` can carry a
    /// negative, transient id until it's actually written into the core
    /// library. Assigning custom artwork straight to that transient id would
    /// either no-op or write a `custom_artwork` row keyed to an id that never
    /// becomes the track's real, lasting one. Ensures a real id first, then
    /// assigns to it. Shared by every UI picker call site so none of them can
    /// skip the guard.
    func assignCustomArtwork(toTrack row: TrackRow, data: Data) async -> Bool {
        var target = row
        if target.id < 0 {
            guard let persisted = await persistRemoteTrack(target) else { return false }
            target = persisted
        }
        return await assignCustomArtwork(trackId: target.id, data: data)
    }

    func clearCustomArtwork(trackId: Int64) async {
        let oldID = try? await store.customArtworkId(for: trackId)
        try? await store.deleteCustomArtwork(trackId: trackId)
        if let oldID, !((try? await store.allCustomArtworkIds()) ?? []).contains(oldID) {
            await ArtworkStore.shared.delete(id: oldID)
        }
        await watchRuntime.artworkDidChange()
    }

    /// Sets one image to represent an entire album (falls back to it for every
    /// track in the album that has no track-level custom artwork of its own).
    /// Album/source rows are always durable (never a transient id like a
    /// not-yet-persisted remote track), so there's no persist-first step here.
    func assignCustomArtwork(albumId: Int64, data: Data) async -> Bool {
        let previous = (try? await store.albumCustomArtworkId(for: albumId)) ?? nil
        guard let newID = await ArtworkStore.shared.store(data) else { return false }
        do {
            try await store.setAlbumCustomArtwork(albumId: albumId, artworkId: newID)
            if let previous, previous != newID,
               !((try? await store.allAlbumCustomArtworkIds()) ?? []).contains(previous) {
                await ArtworkStore.shared.delete(id: previous)
            }
            return true
        } catch {
            await ArtworkStore.shared.delete(id: newID)
            return false
        }
    }

    func clearCustomArtwork(albumId: Int64) async {
        let oldID = try? await store.albumCustomArtworkId(for: albumId)
        try? await store.deleteAlbumCustomArtwork(albumId: albumId)
        if let oldID, !((try? await store.allAlbumCustomArtworkIds()) ?? []).contains(oldID) {
            await ArtworkStore.shared.delete(id: oldID)
        }
    }

    /// Sets one image to represent an entire source/library (the last rung
    /// before the remote/embedded/iTunes/generated fallback chain).
    func assignCustomArtwork(sourceId: Int64, data: Data) async -> Bool {
        let previous = (try? await store.sourceCustomArtworkId(for: sourceId)) ?? nil
        guard let newID = await ArtworkStore.shared.store(data) else { return false }
        do {
            try await store.setSourceCustomArtwork(sourceId: sourceId, artworkId: newID)
            if let previous, previous != newID,
               !((try? await store.allSourceCustomArtworkIds()) ?? []).contains(previous) {
                await ArtworkStore.shared.delete(id: previous)
            }
            return true
        } catch {
            await ArtworkStore.shared.delete(id: newID)
            return false
        }
    }

    func clearCustomArtwork(sourceId: Int64) async {
        let oldID = try? await store.sourceCustomArtworkId(for: sourceId)
        try? await store.deleteSourceCustomArtwork(sourceId: sourceId)
        if let oldID, !((try? await store.allSourceCustomArtworkIds()) ?? []).contains(oldID) {
            await ArtworkStore.shared.delete(id: oldID)
        }
    }

}
