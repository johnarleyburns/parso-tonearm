import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
import UIKit

extension AppState {
    @discardableResult
    func createSmartPlaylistSnapshot(title rawTitle: String, playlist: SmartPlaylist) async throws -> Playlist {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = try await store.smartPlaylistRows(playlist)
        let trackIDs = rows.compactMap(\.track.id)
        let created = try await store.createManualPlaylist(
            title: title.isEmpty ? "Smart Playlist" : title,
            trackIds: trackIDs
        )
        await reload()
        tab = .playlists
        return created
    }

    @discardableResult
    func applyTagEdit(trackIDs: Set<Int64>, proposal: TagEdit.Proposal) async throws -> Int {
        let rows = try await store.allTrackRows()
        let selection = rows
            .filter { row in row.track.id.map(trackIDs.contains) ?? false }
            .map(TagEdit.editableTrack)
        let plan = TagEdit.makePlan(selection: selection, proposal: proposal)
        let applied = try await store.applyTagEditPlan(plan)
        if applied > 0 {
            await reload()
        }
        return applied
    }

    func duplicateGroups(limit: Int = 200) async throws -> [DuplicateDetection.Group] {
        let rows = try await store.allTrackRows()
        var candidates: [DuplicateDetection.Candidate] = []
        for row in rows.prefix(limit) {
            guard let data = localAudioBytes(for: row),
                  let trackID = row.track.id else { continue }
            candidates.append(DuplicateDetection.Candidate(id: "\(trackID): \(row.track.title)", bytes: data))
        }
        return DuplicateDetection.groups(from: candidates)
    }

    private func localAudioBytes(for row: TrackRow) -> Data? {
        guard let asset = row.asset else { return nil }
        let url: URL?
        if let bookmark = asset.bookmark, let resolved = BookmarkVault.resolve(bookmark) {
            url = resolved.url
        } else if let remote = asset.remoteURL.flatMap(URL.init(string:)), remote.isFileURL {
            url = remote
        } else if let relPath = asset.relPath {
            let base = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            url = base?.appendingPathComponent(relPath)
        } else {
            url = nil
        }
        guard let url else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func addSourceInBackground(preview: SourcePreview, followUpdates: Bool) {
        let title = preview.title
        backgroundTitle = title
        backgroundDone = false
        backgroundFailed = false

        let pre = preview
        let upd = followUpdates
        let db = store
        let flac = preferFLAC

        Task {
            let service = SourceService(preferFLAC: flac)
            let source = try? await service.add(preview: pre, followUpdates: upd, store: db)
            if source != nil {
                backgroundDone = true
            } else {
                backgroundFailed = true
            }
            await reload()
            try? await Task.sleep(for: .seconds(4))
            backgroundTitle = nil
            backgroundDone = false
            backgroundFailed = false
        }
    }

    func handleIncomingURL(_ url: URL) async {
        guard let action = TonearmDeepLink.parse(url) else { return }
        switch action {
        case .addSource(let rawURL):
            await handleSharedSourceURL(rawURL)
        case .nowPlaying:
            showNowPlaying = AudioPlayer.shared.currentTrack != nil
        case .resumePlayback:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.resumePlayback() }
        case .pausePlayback:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.pausePlayback() }
        case .togglePlayback:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.togglePlayPause() }
        case .nextTrack:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.next() }
        case .previousTrack:
            await AudioPlayer.shared.withRestoredQueue { AudioPlayer.shared.previous() }
        }
    }

    private func handleSharedSourceURL(_ rawURL: String) async {
        do {
            let service = SourceService(preferFLAC: preferFLAC)
            let preview = try await service.preview(from: rawURL)
            addSourceInBackground(preview: preview, followUpdates: true)
            tab = .sources
        } catch {
            backgroundTitle = "Shared source"
            backgroundDone = false
            backgroundFailed = true
        }
    }

    func playSource(_ source: Source, startAt: Int = 0) async {
        if isBrowseableRemote(source) {
            try? await playRemoteScope(source: source, path: "", startAt: startAt, shuffled: false)
            return
        }
        let tracks = await tracks(for: source)
        guard !tracks.isEmpty else { return }
        AudioPlayer.shared.play(tracks: tracks, startAt: startAt, source: .source(source))
    }

    /// Plays from the current browse scope of a remote library. If the current
    /// level holds no audio nodes (library-level artists, artist-level albums),
    /// it descends to the first playable tracks — library level starts with the
    /// first track of the first album of the first artist, artist level with the
    /// first album's tracks — so "Play" always starts music at any depth.
    func playRemoteScope(source: Source, path: String, startAt: Int = 0, shuffled: Bool = false) async throws {
        let provider = try remoteProvider(for: source)
        let nodes = await RemoteScopePlayback.firstAudioNodes(in: provider, path: path)
        guard !nodes.isEmpty else { return }
        var rows = try await remoteTrackRows(source: source, nodes: nodes)
        if shuffled {
            AudioPlayer.shared.shuffle = true
            rows.shuffle()
        }
        AudioPlayer.shared.play(tracks: rows, startAt: min(startAt, max(rows.count - 1, 0)), source: .source(source))
    }

    private func isBrowseableRemote(_ source: Source) -> Bool {
        guard RemoteLibraryAccessPolicy.isRemoteLibrary(source.kind) else { return false }
        switch source.kind {
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            return false
        default:
            return true
        }
    }

}
