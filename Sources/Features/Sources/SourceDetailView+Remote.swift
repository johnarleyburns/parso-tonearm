import SwiftUI
import TonearmCore

/// Remote-browsing logic + derived state, split out of `SourceDetailView.swift`.
/// `load()`, `loadStats()`, `isRemoteLibrary`, `isBrowseableServer`,
/// `isArchiveSource`, `remoteProviderName`, `scopeTitle`, `audioNodesInScope`,
/// `icon(for:)`, `subtitle(for:)`, `selectRemoteNode`, `goBackRemote`, and
/// `playVisibleRemote` are all called from `SourceDetailView.swift`'s `body`/
/// `content`/`remoteBrowser`/`navRow`/`hero`/`badgeText`/`cta` (a different
/// file), or from `SourceDetailView+ManagementSection.swift`, so they are
/// `internal` (not `private`) here — the rest (`loadRemote`, `playRemote`,
/// `isCloudSource`, `durationString`) are used only within this file and stay
/// `private`.
extension SourceDetailView {
    func load() async {
        if isBrowseableServer {
            // Real report: reopening a remote source always restarted at the root, even for a
            // drive with the real library several folders deep. Returns to wherever the user
            // last browsed instead (Source.lastBrowsedPath, schema v45).
            await loadRemote(path: source.lastBrowsedPath ?? "")
        } else {
            tracks = await appState.tracks(for: source)
            heroArtworkId = await appState.firstArtworkId(for: source)
        }
    }

    private func loadRemote(path: String) async {
        isLoadingRemote = true
        remoteError = nil
        defer { isLoadingRemote = false }
        do {
            remoteNodes = try await appState.browseRemote(source: source, path: path)
            remotePath = path
            if let id = source.id {
                try? await appState.store.setSourceLastBrowsedPath(id: id, path: path.isEmpty ? nil : path)
            }
        } catch {
            // A remembered folder that no longer resolves (deleted/moved/renamed in a way that
            // breaks it) must not leave the user stuck on a dead error with no way back — forget
            // it and retry once at the root. `path.isEmpty` on that retry skips this branch, so
            // it can't recurse; a genuine root-level failure (e.g. expired auth) still surfaces
            // remoteError exactly as before.
            if !path.isEmpty {
                if let id = source.id {
                    try? await appState.store.setSourceLastBrowsedPath(id: id, path: nil)
                }
                remoteBackStack = []
                await loadRemote(path: "")
                return
            }
            remoteNodes = []
            remoteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func selectRemoteNode(_ node: RemoteNode) async {
        switch node.kind {
        case .directory, .collection:
            remoteBackStack.append(remotePath)
            await loadRemote(path: node.path)
        case .audio:
            let audioNodes = remoteNodes.filter { $0.kind == .audio }
            guard let start = audioNodes.firstIndex(where: { $0.id == node.id }) else { return }
            await playRemote(nodes: audioNodes, startAt: start, shuffled: false)
        case .item:
            break
        }
    }

    func goBackRemote() async {
        guard let previous = remoteBackStack.popLast() else { return }
        await loadRemote(path: previous)
    }

    func playVisibleRemote(startAt: Int, shuffled: Bool) async {
        let audioNodes = remoteNodes.filter { $0.kind == .audio }
        if !audioNodes.isEmpty {
            await playRemote(nodes: audioNodes, startAt: startAt, shuffled: shuffled)
            return
        }
        do {
            try await appState.playRemoteScope(source: source, path: remotePath,
                                               startAt: startAt, shuffled: shuffled)
        } catch {
            remoteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func playRemote(nodes: [RemoteNode], startAt: Int, shuffled: Bool) async {
        do {
            var rows = try await appState.remoteTrackRows(source: source, nodes: nodes)
            if shuffled {
                player.shuffle = true
                rows.shuffle()
            }
            let startIndex = min(startAt, max(rows.count - 1, 0))
            // Real report: playing straight from browsing (never "Add to Library" first) left
            // the starting track's play history and favorite silently unrecorded — it carries a
            // transient, negative id (RemoteTrackRowFactory) until persisted. Matches
            // DiscoveryRuntimeController's own onPlay, which persists the track it's about to
            // start for the same reason.
            if rows.indices.contains(startIndex), rows[startIndex].id < 0,
               let persisted = await appState.persistRemoteTrack(rows[startIndex]) {
                rows[startIndex] = persisted
            }
            player.play(tracks: rows, startAt: startIndex, source: .source(source))
        } catch {
            remoteError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func icon(for node: RemoteNode) -> String {
        switch node.kind {
        case .directory: return "person.crop.circle"
        case .collection: return "rectangle.stack"
        case .audio: return "music.note"
        case .item: return "square.stack"
        }
    }

    func subtitle(for node: RemoteNode) -> String? {
        switch node.kind {
        case .directory:
            return source.kind == .webDAV || source.kind == .smb || isCloudSource ? String(localized: "Folder") : String(localized: "Artist")
        case .collection:
            return String(localized: "Album")
        case .audio:
            var parts: [String] = []
            if let artist = node.metadata?.artist ?? node.metadata?.albumArtist, !artist.isEmpty {
                parts.append(artist)
            }
            if let album = node.metadata?.album, !album.isEmpty {
                parts.append(album)
            }
            if let duration = node.metadata?.durationSec ?? node.durationSec {
                parts.append(durationString(duration))
            }
            return parts.isEmpty ? String(localized: "Song") : parts.joined(separator: " · ")
        case .item:
            return nil
        }
    }

    private func durationString(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func loadStats() async {
        isLoadingStats = true
        statsError = nil
        defer { isLoadingStats = false }
        if let result = await appState.remoteStats(for: source) {
            stats = result
        } else {
            statsError = String(localized: "Stats unavailable")
        }
    }

    var isRemoteLibrary: Bool {
        RemoteLibraryAccessPolicy.isRemoteLibrary(source.kind)
    }

    var audioNodesInScope: [RemoteNode] {
        let visible = remoteNodes.filter { $0.kind == .audio }
        if !visible.isEmpty { return visible }
        return tracks.compactMap { row in
            guard let remoteURL = row.asset?.remoteURL else { return nil }
            return RemoteNode(id: "track-\(row.id)", title: row.track.title, path: remoteURL,
                              kind: .audio, sizeBytes: row.asset?.sizeBytes,
                              durationSec: row.track.durationSec)
        }
    }

    var scopeTitle: String {
        guard !remotePath.isEmpty else { return source.title }
        return remotePath.split(separator: "/").last.map(String.init) ?? source.title
    }

    var isBrowseableServer: Bool {
        isRemoteLibrary && !isArchiveSource
    }

    var isArchiveSource: Bool {
        switch source.kind {
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            return true
        default:
            return false
        }
    }

    private var isCloudSource: Bool {
        CloudDriveAPI.Provider(sourceKind: source.kind) != nil
    }

    var remoteProviderName: String {
        RemoteConnectorCatalog.connector(for: source.kind)?.title ?? "Remote"
    }
}
