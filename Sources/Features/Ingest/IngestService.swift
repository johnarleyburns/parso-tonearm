import Foundation
import AVFoundation
import UIKit

enum IngestError: LocalizedError {
    case noAudioFiles
    case failedToInsertSource
    case failedToCreateBookmark
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .noAudioFiles: return "No audio files found in this folder"
        case .failedToInsertSource: return "Failed to create source in library"
        case .failedToCreateBookmark: return "Failed to secure folder access"
        case .accessDenied: return "Cannot access folder — permission denied"
        }
    }
}

/// FR-1 local ingestion: files and folders referenced in place via security-scoped
/// bookmarks. Metadata via AVFoundation with filename fallback.
struct IngestService {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf"]

    struct ScannedFile {
        let url: URL
        let relativeSection: String?
    }

    // MARK: - Add individual files (FR-1.1)

    func addFiles(_ urls: [URL], into store: LibraryStore) async {
        guard !urls.isEmpty else { return }
        do {
            // Reuse a single persistent "Local Files" source rather than creating
            // a new source per import.
            let source: Source
            if let existing = try await store.firstSource(title: "Local Files", kind: .local) {
                source = existing
            } else {
                let s = Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                               title: "Local Files", addedAt: Date(), lastResolvedAt: nil,
                               followUpdates: false, licenseText: nil, memberCapHit: false)
                source = try await store.insertSource(s)
            }
            guard let sid = source.id else { return }
            let album: Album
            if let existing = try await store.firstAlbum(sourceId: sid, title: "Local Files") {
                album = existing
            } else {
                let a = Album(id: nil, sourceId: sid, title: "Local Files", artist: nil, year: nil, artworkId: nil)
                album = try await store.insertAlbum(a)
            }
            let existingCount = (try? await store.tracks(forSource: sid).count) ?? 0
            for (i, url) in urls.enumerated() {
                try await ingestOne(url, sourceId: sid, albumId: album.id, index: existingCount + i,
                                    section: nil, store: store)
            }
        } catch {
            print("addFiles error: \(error)")
        }
    }

    // MARK: - Add folder as playlist (FR-1.2)

    /// Appends new files into an existing source + its (first) album, keeping the
    /// folder playlist in sync. Used by folder-watch rescans so freshly
    /// dropped files join the same source rather than the generic "Local Files".
    func addFiles(_ urls: [URL], toSourceId sid: Int64, into store: LibraryStore) async {
        guard !urls.isEmpty else { return }
        do {
            let album = try await store.firstAlbumForSource(sid)
            let existingCount = (try? await store.tracks(forSource: sid).count) ?? 0
            let playlist = try? await store.folderPlaylist(matchingSourceId: sid)
            for (i, url) in urls.enumerated() {
                let trackId = try await ingestOne(url, sourceId: sid, albumId: album?.id,
                                                  index: existingCount + i, section: nil, store: store)
                if let pid = playlist?.id, let trackId {
                    try await store.addToPlaylist(playlistId: pid, trackId: trackId, sectionTitle: nil)
                }
            }
        } catch {
            print("addFiles(toSourceId:) error: \(error)")
        }
    }
    func addFolder(_ folderURL: URL, includeSubfolders: Bool, keepOrder: Bool,
                   watch: Bool, into store: LibraryStore) async throws {
        let files = scanFolder(folderURL, includeSubfolders: includeSubfolders)
        guard !files.isEmpty else {
            print("[IngestService] addFolder: no audio files found in \(folderURL.lastPathComponent)")
            throw IngestError.noAudioFiles
        }
        let ordered = keepOrder ? files
            : files.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }

        var source = Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                            title: folderURL.lastPathComponent, addedAt: Date(),
                            lastResolvedAt: nil, followUpdates: false,
                            licenseText: nil, memberCapHit: false,
                            localIsFolder: true)
        source = try await store.insertSource(source)
        guard let sid = source.id else { throw IngestError.failedToInsertSource }
        var album = Album(id: nil, sourceId: sid, title: folderURL.lastPathComponent,
                          artist: nil, year: nil, artworkId: nil)
        album = try await store.insertAlbum(album)

        let folderBookmark = BookmarkVault.makeBookmark(for: folderURL)
        var playlist = Playlist(id: nil, title: folderURL.lastPathComponent, kind: .folder,
                                folderBookmark: folderBookmark, watch: watch)
        playlist = try await store.insertPlaylist(playlist)

        print("[IngestService] importing \(ordered.count) files from \(folderURL.lastPathComponent)")
        for (i, file) in ordered.enumerated() {
            let trackId = try await ingestOne(file.url, sourceId: sid, albumId: album.id,
                                              index: i, section: file.relativeSection, store: store)
            if let pid = playlist.id, let trackId {
                try await store.addToPlaylist(playlistId: pid, trackId: trackId,
                                              sectionTitle: file.relativeSection)
            }
        }
        print("[IngestService] addFolder complete: \(ordered.count) tracks imported")
    }

    func scanFolder(_ folderURL: URL, includeSubfolders: Bool) -> [ScannedFile] {
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
        if !accessed {
            print("[IngestService] scanFolder: cannot access \(folderURL.path) — security scope denied")
        }
        let fm = FileManager.default
        var results: [ScannedFile] = []
        let options: FileManager.DirectoryEnumerationOptions = includeSubfolders ? [] : [.skipsSubdirectoryDescendants]
        guard let en = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: options.union(.skipsHiddenFiles)) else {
            print("[IngestService] scanFolder: cannot enumerate \(folderURL.path)")
            return []
        }
        for case let url as URL in en {
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let parent = url.deletingLastPathComponent().lastPathComponent
            let section = parent == folderURL.lastPathComponent ? nil : parent
            results.append(ScannedFile(url: url, relativeSection: section))
        }
        print("[IngestService] scanFolder: found \(results.count) audio files in \(folderURL.lastPathComponent)")
        return results
    }

    // MARK: - Metadata extraction (FR-1.3)

    @discardableResult
    private func ingestOne(_ url: URL, sourceId: Int64, albumId: Int64?, index: Int,
                           section: String?, store: LibraryStore) async throws -> Int64? {
        let bookmark = BookmarkVault.makeBookmark(for: url)
        let meta = await extractMetadata(url)
        let ext = url.pathExtension.lowercased()
        let supported = AVURLAsset(url: url)
        let unsupported = Self.audioExtensions.contains(ext) ? nil : "unsupported format"
        _ = supported

        let artistName = meta.artist ?? meta.albumArtist
        let artistRow = try await artist(for: artistName, store: store)
        if let albumId {
            let albumArtist = meta.albumArtist ?? meta.artist
            let albumArtistRow = try await artist(for: albumArtist, store: store)
            try await store.fillAlbumMetadataIfEmpty(id: albumId,
                                                     artistId: albumArtistRow?.id ?? artistRow?.id,
                                                     albumArtist: albumArtist,
                                                     genre: meta.genre,
                                                     year: meta.year)
        }

        let trackNo = meta.trackNo ?? (index + 1)
        var track = Track(id: nil, albumId: albumId, sourceId: sourceId,
                          title: meta.title ?? url.deletingPathExtension().lastPathComponent,
                          trackNo: trackNo, discNo: meta.discNo,
                          durationSec: meta.durationSec, codec: ext.uppercased(),
                          sampleRate: meta.sampleRate, bitDepthOrBitrate: meta.bitDepthOrBitrate,
                          sortKey: String(format: "%04d", trackNo),
                          genre: meta.genre, composer: meta.composer, artistId: artistRow?.id)
        track = try await store.insertTrack(track)
        guard let tid = track.id else { return nil }
        let asset = Asset(id: nil, trackId: tid, kind: .localRef, bookmark: bookmark,
                          relPath: nil, remoteURL: url.absoluteString, altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: unsupported)
        try await store.insertAsset(asset)
        return tid
    }

    private func extractMetadata(_ url: URL) async -> TrackMetadata {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        var metadataItems: [AVMetadataItem] = []
        if let items = try? await asset.load(.metadata) {
            metadataItems.append(contentsOf: items)
        }
        if let items = try? await asset.load(.commonMetadata) {
            metadataItems.append(contentsOf: items)
        }
        let normalizedItems = await Self.normalizeMetadataItems(metadataItems)
        var meta = MetadataNormalizer.normalize(
            items: normalizedItems,
            fallbackFilename: url.lastPathComponent)
        if let duration = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(duration)
            if secs.isFinite && secs > 0 { meta.durationSec = secs }
        }
        if let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
           let audioTrack = audioTracks.first,
           let descriptions = try? await audioTrack.load(.formatDescriptions) {
            for description in descriptions {
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                    continue
                }
                if meta.sampleRate == nil, asbd.mSampleRate.isFinite, asbd.mSampleRate > 0 {
                    meta.sampleRate = Int(asbd.mSampleRate.rounded())
                }
                if meta.bitDepthOrBitrate == nil, asbd.mBitsPerChannel > 0 {
                    meta.bitDepthOrBitrate = "\(asbd.mBitsPerChannel)-bit"
                }
            }
        }
        return meta
    }

    private func artist(for rawName: String?, store: LibraryStore) async throws -> Artist? {
        guard let rawName else { return nil }
        guard let name = ArtistNamePolicy.normalize(rawName) else { return nil }
        return try await store.findOrCreateArtist(name: name, sortName: ArtistNamePolicy.sortName(for: name))
    }

    private static func normalizeMetadataItems(_ items: [AVMetadataItem]) async -> [MetadataNormalizer.Item] {
        var result: [MetadataNormalizer.Item] = []
        for item in items {
            let stringValue = try? await item.load(.stringValue)
            let numberValue = try? await item.load(.numberValue)
            let dataValue = try? await item.load(.dataValue)
            let key = item.key.map { String(describing: $0) }
            result.append(
                MetadataNormalizer.Item(
                    key: key,
                    commonKey: item.commonKey?.rawValue,
                    identifier: item.identifier?.rawValue,
                    keySpace: item.keySpace?.rawValue,
                    stringValue: stringValue,
                    numberValue: numberValue?.doubleValue,
                    dataValue: dataValue))
        }
        return result
    }
}
