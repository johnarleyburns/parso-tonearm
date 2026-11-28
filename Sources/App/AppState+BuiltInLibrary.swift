import AVFoundation
import Foundation
import TonearmCore

extension AppState {
    /// `BuiltInContentProvider`'s three CC0 ambient tracks were purely
    /// synthetic `TrackRow`s, never real `track`/`album`/`source`/`asset`
    /// rows — invisible to search/analysis entirely, playable only through
    /// the separate ambient-loop path. Seeding them as real rows once lets
    /// the existing `DiscoveryReconciler`/`BoundedIndexWorker` pipeline
    /// analyze them like any other local file. They are tiny, local, and
    /// network-independent, so they should finish analysis within seconds of
    /// first launch.
    ///
    /// Idempotent — checks for the "Built-in Sounds" source first (matching
    /// `fixLegacySourceTitles()`/`repairDuplicatePlaylistsOnce()`'s existing
    /// "run once, cheaply check first" bootstrap pattern) so a relaunch
    /// never re-inserts duplicates.
    func seedBuiltInLibraryContentIfNeeded() async {
        guard (try? await store.firstSource(title: Self.builtInSourceTitle, kind: .local)) == nil
        else { return }
        do {
            let source = try await store.insertSource(Source(
                id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                title: Self.builtInSourceTitle, addedAt: Date(), lastResolvedAt: nil,
                followUpdates: false, licenseText: "CC0 Public Domain", memberCapHit: false))
            guard let sourceId = source.id else { return }
            let album = try await store.insertAlbum(Album(
                id: nil, sourceId: sourceId, title: "Ambient Sounds",
                artist: nil, year: nil, artworkId: nil))

            for ambient in BuiltInContentProvider.tracks {
                guard let url = BuiltInContentProvider.bundledAudioURL(forChannelId: ambient.channelId)
                else { continue }
                // The synthetic path (`BuiltInContentProvider.row(for:)`)
                // hardcodes `durationSec: 0` — fine for a display-only
                // TrackRow that's never persisted, but a real library row
                // should carry the track's actual duration (Now Playing's
                // scrubber, TrackDetailCard, etc. all read it).
                let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0

                let track = try await store.insertTrack(Track(
                    id: nil, albumId: album.id, sourceId: sourceId,
                    title: ambient.title, trackNo: nil, discNo: nil,
                    durationSec: duration.isFinite ? duration : 0,
                    codec: url.pathExtension.uppercased(), sampleRate: nil, bitDepthOrBitrate: nil,
                    sortKey: ambient.title.lowercased(), genre: "Ambient", composer: nil,
                    artistId: nil))
                guard let trackId = track.id else { continue }
                _ = try await store.insertAsset(Asset(
                    id: nil, trackId: trackId, kind: .builtIn, bookmark: nil,
                    // The resolver (AnalysisAssetResolver/AudioPlayer+Loading)
                    // looks this up via `BuiltInContentProvider
                    // .bundledAudioURL(forChannelId:)` — `relPath` carries the
                    // channel id, not a filesystem-relative path, for a
                    // `.builtIn` asset.
                    relPath: ambient.channelId, remoteURL: nil, altRemoteURL: nil,
                    sizeBytes: nil, unsupportedReason: nil))
            }
            await reload()
        } catch {
            AppLogger.app.error("Seeding built-in library failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let builtInSourceTitle = "Built-in Sounds"
}
