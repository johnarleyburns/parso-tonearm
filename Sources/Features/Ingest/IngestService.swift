import Foundation
import AVFoundation
import UIKit

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

    func addFolder(_ folderURL: URL, includeSubfolders: Bool, keepOrder: Bool,
                   watch: Bool, into store: LibraryStore) async {
        do {
            let files = scanFolder(folderURL, includeSubfolders: includeSubfolders)
            let ordered = keepOrder ? files
                : files.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }

            var source = Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                                title: folderURL.lastPathComponent, addedAt: Date(),
                                lastResolvedAt: nil, followUpdates: false,
                                licenseText: nil, memberCapHit: false)
            source = try await store.insertSource(source)
            guard let sid = source.id else { return }
            var album = Album(id: nil, sourceId: sid, title: folderURL.lastPathComponent,
                              artist: nil, year: nil, artworkId: nil)
            album = try await store.insertAlbum(album)

            let folderBookmark = BookmarkVault.makeBookmark(for: folderURL)
            var playlist = Playlist(id: nil, title: folderURL.lastPathComponent, kind: .folder,
                                    folderBookmark: folderBookmark, watch: watch)
            playlist = try await store.insertPlaylist(playlist)

            for (i, file) in ordered.enumerated() {
                let trackId = try await ingestOne(file.url, sourceId: sid, albumId: album.id,
                                                  index: i, section: file.relativeSection, store: store)
                if let pid = playlist.id, let trackId {
                    try await store.addToPlaylist(playlistId: pid, trackId: trackId,
                                                  sectionTitle: file.relativeSection)
                }
            }
        } catch {
            print("addFolder error: \(error)")
        }
    }

    func scanFolder(_ folderURL: URL, includeSubfolders: Bool) -> [ScannedFile] {
        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        var results: [ScannedFile] = []
        let options: FileManager.DirectoryEnumerationOptions = includeSubfolders ? [] : [.skipsSubdirectoryDescendants]
        guard let en = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey],
                                     options: options.union(.skipsHiddenFiles)) else { return [] }
        for case let url as URL in en {
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let parent = url.deletingLastPathComponent().lastPathComponent
            let section = parent == folderURL.lastPathComponent ? nil : parent
            results.append(ScannedFile(url: url, relativeSection: section))
        }
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

        var track = Track(id: nil, albumId: albumId, sourceId: sourceId,
                          title: meta.title ?? url.deletingPathExtension().lastPathComponent,
                          trackNo: meta.trackNo ?? (index + 1), discNo: nil,
                          durationSec: meta.duration, codec: ext.uppercased(),
                          sampleRate: nil, bitDepthOrBitrate: nil,
                          sortKey: String(format: "%04d", meta.trackNo ?? (index + 1)))
        track = try await store.insertTrack(track)
        guard let tid = track.id else { return nil }
        let asset = Asset(id: nil, trackId: tid, kind: .localRef, bookmark: bookmark,
                          relPath: nil, remoteURL: url.absoluteString, altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: unsupported)
        try await store.insertAsset(asset)
        return tid
    }

    struct FileMeta {
        var title: String?
        var artist: String?
        var trackNo: Int?
        var duration: Double?
    }

    private func extractMetadata(_ url: URL) async -> FileMeta {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        var meta = FileMeta()
        if let duration = try? await asset.load(.duration) {
            let secs = CMTimeGetSeconds(duration)
            if secs.isFinite && secs > 0 { meta.duration = secs }
        }
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    meta.title = try? await item.load(.stringValue)
                case .commonKeyArtist:
                    meta.artist = try? await item.load(.stringValue)
                default: break
                }
            }
        }
        return meta
    }
}
