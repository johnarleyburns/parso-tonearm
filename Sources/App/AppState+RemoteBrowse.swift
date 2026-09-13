import Foundation
import ParsoAudioStreaming
import SwiftUI
import TonearmCore
import UIKit

extension AppState {
    func browseRemote(source: Source, path: String) async throws -> [RemoteNode] {
        try await remoteProvider(for: source).browse(path: path)
    }

    /// Subscribe to a genre library (§18A, FR-LIB-9): validate the catalogue
    /// is reachable first — an unreachable catalogue must say so, never render
    /// as an empty library (§18A.6) — then insert an ordinary
    /// `Source(kind: .jamendoGenre)` row whose identity is the genre path.
    /// Free tier; no account (FR-LIB-7, §18A.2).
    func addGenreLibrary(path: String, name: String) async throws {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { throw URLError(.badURL) }
        let provider = JamendoGenreProvider(clientID: JamendoAppConfig.clientID,
                                            sourcePath: trimmedPath)
        _ = try await provider.catalogueCount(path: trimmedPath)

        var source = Source(
            id: nil,
            kind: .jamendoGenre,
            iaIdentifier: trimmedPath,
            originalURL: nil,
            title: name.trimmingCharacters(in: .whitespacesAndNewlines),
            addedAt: Date(),
            lastResolvedAt: Date(),
            followUpdates: false,
            licenseText: "Creative Commons — attribution kept",
            memberCapHit: false
        )
        source = try await store.insertSource(source)
        await reload()
        tab = .sources
    }

    func renameSource(_ source: Source, title: String) async {
        guard let id = source.id else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? await store.updateSourceTitle(id: id, title: trimmed)
        await reload()
    }

    func remoteAccountLabel(for source: Source) -> String? {
        switch source.kind {
        case .subsonic, .webDAV, .jellyfin:
            return source.iaIdentifier
        case .plex:
            return "Token saved"
        case .dropbox, .googleDrive, .oneDrive, .pCloud:
            return source.iaIdentifier
        case .smb:
            return "Folder bookmark saved"
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            if let id = source.id,
               let _ = try? CredentialStore().read(account: "ia-private:\(id)") {
                return "Credentials saved"
            }
            return source.originalURL
        default:
            return nil
        }
    }

    func remoteCredentialStatus(for source: Source) -> String? {
        switch source.kind {
        case .subsonic, .webDAV, .jellyfin:
            return "Password saved"
        case .plex:
            return "Token saved"
        case .dropbox, .googleDrive, .oneDrive, .pCloud:
            return "OAuth token saved"
        case .smb:
            return "Bookmark saved"
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            if let id = source.id,
               let _ = try? CredentialStore().read(account: "ia-private:\(id)") {
                return "Password saved"
            }
            return nil
        default:
            return nil
        }
    }

    func remoteStats(for source: Source) async -> RemoteLibraryStats? {
        guard let sourceID = source.id else { return nil }
        switch source.kind {
        case .subsonic:
            let provider = try? SubsonicProvider.from(source: source)
            return try? await provider?.gatherStats()
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            let tracks = (try? await store.tracks(forSource: sourceID)) ?? []
            let totalBytes = tracks.compactMap { $0.asset?.sizeBytes }.reduce(0, +)
            let uniqueAlbums = Set(tracks.compactMap { $0.album?.id })
            let uniqueArtists = Set(tracks.compactMap { $0.artist?.id })
            return RemoteLibraryStats(
                artistCount: uniqueArtists.isEmpty ? nil : uniqueArtists.count,
                albumCount: uniqueAlbums.isEmpty ? nil : uniqueAlbums.count,
                trackCount: tracks.count,
                totalBytes: totalBytes > 0 ? totalBytes : nil
            )
        default:
            return nil
        }
    }

    func offlineEstimate(for source: Source) async -> (trackCount: Int, totalBytes: Int64, resolvedURLs: [URL: Int64])? {
        guard let sourceID = source.id else { return nil }
        switch source.kind {
        case .subsonic:
            guard let provider = try? SubsonicProvider.from(source: source) else { return nil }
            let stats = try? await provider.gatherStats()
            return stats.map { ($0.trackCount ?? 0, $0.totalBytes ?? 0, [:]) }
        case .iaItem, .iaList, .iaCollection, .iaFavorites:
            let tracks = (try? await store.tracks(forSource: sourceID)) ?? []
            var urls: [URL: Int64] = [:]
            var totalBytes: Int64 = 0
            for track in tracks {
                if let remoteStr = track.asset?.remoteURL,
                   let url = URL(string: remoteStr) {
                    let size = track.asset?.sizeBytes ?? 0
                    urls[url] = size
                    totalBytes += size
                }
            }
            return (tracks.count, totalBytes, urls)
        default:
            return nil
        }
    }

    func offlineDiskCheck(requiredBytes: Int64) -> (allowed: Bool, reason: String?) {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let available = (try? cacheDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))
            .flatMap { $0.volumeAvailableCapacityForImportantUsage } ?? 0
        let reserve = max(1_073_741_824, Int64(Double(available) * 0.10))
        if requiredBytes + reserve > available {
            return (false, "Not enough disk space. \(ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)) needed, \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) available.")
        }
        return (true, nil)
    }

}
