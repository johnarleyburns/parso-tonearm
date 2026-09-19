import Foundation
import AVFoundation

public enum IngestError: LocalizedError {
    case noAudioFiles
    case failedToInsertSource
    case failedToCreateBookmark
    case accessDenied

    public var errorDescription: String? {
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
public struct IngestService {
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf"]

    public struct ScannedFile {
        public let url: URL
        public let relativeSection: String?
    }

    /// Real, current counts for an import pass — never collapse "skipped
    /// because it's already in your library" into a silently-smaller
    /// imported count with no explanation (CLAUDE.md "no silent/magic
    /// background work").
    public struct IngestSummary: Sendable, Equatable {
        public var imported: Int = 0
        public var skippedDuplicates: Int = 0
        static func + (lhs: IngestSummary, rhs: IngestSummary) -> IngestSummary {
            IngestSummary(imported: lhs.imported + rhs.imported,
                          skippedDuplicates: lhs.skippedDuplicates + rhs.skippedDuplicates)
        }
        mutating func record(_ outcome: IngestOutcome) {
            switch outcome {
            case .inserted: imported += 1
            case .skippedDuplicate: skippedDuplicates += 1
            case .failed: break
            }
        }
    }

    public init() {}

    // MARK: - Add individual files (FR-1.1)

    @discardableResult
    public func addFiles(_ urls: [URL], into store: LibraryStore) async -> IngestSummary {
        guard !urls.isEmpty else { return IngestSummary() }
        var summary = IngestSummary()
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
            guard let sid = source.id else { return summary }
            let album: Album
            if let existing = try await store.firstAlbum(sourceId: sid, title: "Local Files") {
                album = existing
            } else {
                let a = Album(id: nil, sourceId: sid, title: "Local Files", artist: nil, year: nil, artworkId: nil)
                album = try await store.insertAlbum(a)
            }
            let existingCount = (try? await store.tracks(forSource: sid).count) ?? 0
            for (i, url) in urls.enumerated() {
                let outcome = try await ingestOne(url, sourceId: sid, albumId: album.id, index: existingCount + i,
                                                  section: nil, store: store)
                summary.record(outcome)
            }
        } catch {
            print("addFiles error: \(error)")
        }
        return summary
    }

    // MARK: - Add folder as playlist (FR-1.2)

    /// Appends new files into an existing source + its (first) album, keeping the
    /// folder playlist in sync. Used by folder-watch rescans so freshly
    /// dropped files join the same source rather than the generic "Local Files".
    @discardableResult
    public func addFiles(_ urls: [URL], toSourceId sid: Int64, into store: LibraryStore) async -> IngestSummary {
        guard !urls.isEmpty else { return IngestSummary() }
        var summary = IngestSummary()
        do {
            let album = try await store.firstAlbumForSource(sid)
            let existingCount = (try? await store.tracks(forSource: sid).count) ?? 0
            let playlist = try? await store.folderPlaylist(matchingSourceId: sid)
            for (i, url) in urls.enumerated() {
                let outcome = try await ingestOne(url, sourceId: sid, albumId: album?.id,
                                                  index: existingCount + i, section: nil, store: store)
                summary.record(outcome)
                if let pid = playlist?.id, case .inserted(let trackId) = outcome {
                    try await store.addToPlaylist(playlistId: pid, trackId: trackId, sectionTitle: nil)
                }
            }
        } catch {
            print("addFiles(toSourceId:) error: \(error)")
        }
        return summary
    }
    @discardableResult
    public func addFolder(_ folderURL: URL, includeSubfolders: Bool, keepOrder: Bool,
                          watch: Bool, into store: LibraryStore) async throws -> IngestSummary {
        let files = scanFolder(folderURL, includeSubfolders: includeSubfolders)
        guard !files.isEmpty else {
            print("[IngestService] addFolder: no audio files found in \(folderURL.lastPathComponent)")
            throw IngestError.noAudioFiles
        }
        let ordered = keepOrder ? files
            : files.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }

        let folderKey = FolderImportIdentity.key(for: folderURL)
        if let existing = try await store.folderSource(path: folderKey),
           let sourceID = existing.id,
           try await store.folderPlaylist(matchingSourceId: sourceID) != nil {
            let existingPaths = try await store.localFilePaths(forSource: sourceID)
            let newURLs = ordered.map(\.url).filter {
                !existingPaths.contains(FolderImportIdentity.key(for: $0))
            }
            return await addFiles(newURLs, toSourceId: sourceID, into: store)
        }

        var source = Source(id: nil, kind: .local, iaIdentifier: nil, originalURL: nil,
                            title: folderURL.lastPathComponent, addedAt: Date(),
                            lastResolvedAt: nil, followUpdates: false,
                            licenseText: nil, memberCapHit: false,
                            localIsFolder: true, folderPath: folderKey)
        source = try await store.insertSource(source)
        guard let sid = source.id else { throw IngestError.failedToInsertSource }
        var album = Album(id: nil, sourceId: sid, title: folderURL.lastPathComponent,
                          artist: nil, year: nil, artworkId: nil)
        album = try await store.insertAlbum(album)

        let folderBookmark = BookmarkVault.makeBookmark(for: folderURL)
        var playlist = Playlist(id: nil, title: folderURL.lastPathComponent, kind: .folder,
                                sourceId: sid,
                                folderBookmark: folderBookmark, watch: watch)
        playlist = try await store.insertPlaylist(playlist)

        print("[IngestService] importing \(ordered.count) files from \(folderURL.lastPathComponent)")
        var summary = IngestSummary()
        for (i, file) in ordered.enumerated() {
            let outcome = try await ingestOne(file.url, sourceId: sid, albumId: album.id,
                                              index: i, section: file.relativeSection, store: store)
            summary.record(outcome)
            if let pid = playlist.id, case .inserted(let trackId) = outcome {
                try await store.addToPlaylist(playlistId: pid, trackId: trackId,
                                              sectionTitle: file.relativeSection)
            }
        }
        print("[IngestService] addFolder complete: \(summary.imported) imported, "
            + "\(summary.skippedDuplicates) skipped (already in library)")
        return summary
    }

    public func scanFolder(_ folderURL: URL, includeSubfolders: Bool) -> [ScannedFile] {
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

    /// `.inserted`/`.skippedDuplicate` let callers report an accurate
    /// "Imported N, skipped M already in your library" summary (CLAUDE.md
    /// "no silent/magic background work" — a duplicate-skip must never just
    /// silently produce fewer tracks than the user expected with no
    /// explanation) instead of collapsing "duplicate" into the same `nil`
    /// a genuine failure already returns.
    enum IngestOutcome {
        case inserted(Int64)
        case skippedDuplicate
        case failed
    }

    private func ingestOne(_ url: URL, sourceId: Int64, albumId: Int64?, index: Int,
                           section: String?, store: LibraryStore) async throws -> IngestOutcome {
        let bookmark = BookmarkVault.makeBookmark(for: url)
        let meta = await extractMetadata(url)
        let ext = url.pathExtension.lowercased()
        let supported = AVURLAsset(url: url)
        let unsupported = Self.audioExtensions.contains(ext) ? nil : "unsupported format"
        _ = supported

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }
            .map(Int64.init)

        // Real report: "import multiple folders locally and sometimes have
        // the same track in two different places and it shows up twice" —
        // a cheap size+duration match against every already-ingested track,
        // before doing any of the artist/album work below.
        if let fileSize, let duration = meta.durationSec {
            let existingId = (try? await store.findExistingTrackId(
                sizeBytes: fileSize, durationSec: duration)) ?? nil
            if existingId != nil { return .skippedDuplicate }
        }

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
                          genre: meta.genre, composer: meta.composer, artistId: artistRow?.id,
                          rgTrackGain: meta.rgTrackGain, rgAlbumGain: meta.rgAlbumGain,
                          rgTrackPeak: meta.rgTrackPeak, rgAlbumPeak: meta.rgAlbumPeak)
        track = try await store.insertTrack(track)
        guard let tid = track.id else { return .failed }
        let asset = Asset(id: nil, trackId: tid, kind: .localRef, bookmark: bookmark,
                          relPath: nil, remoteURL: url.absoluteString, altRemoteURL: nil,
                          sizeBytes: fileSize, unsupportedReason: unsupported)
        try await store.insertAsset(asset)
        return .inserted(tid)
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
