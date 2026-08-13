import Foundation
import AVFoundation
import CryptoKit
import GRDB
import TonearmCore

public enum DJImportError: LocalizedError {
    case failedToCreateBookmark
    case failedToInsertFolder
    case noAudioFiles

    public var errorDescription: String? {
        switch self {
        case .failedToCreateBookmark: return "Could not secure access to the folder"
        case .failedToInsertFolder: return "Could not register the folder in the library"
        case .noAudioFiles: return "No audio files found in this folder"
        }
    }
}

public struct ImportSummary: Sendable, Equatable {
    public let added: Int
    public let updated: Int
    public let skipped: Int
    public let failed: [URL]

    public init(added: Int = 0, updated: Int = 0, skipped: Int = 0, failed: [URL] = []) {
        self.added = added
        self.updated = updated
        self.skipped = skipped
        self.failed = failed
    }

    public func adding(_ other: ImportSummary) -> ImportSummary {
        ImportSummary(added: added + other.added,
                      updated: updated + other.updated,
                      skipped: skipped + other.skipped,
                      failed: failed + other.failed)
    }
}

/// The single writer to the DJ database (§10.1, §18.4). Writes are serialized by
/// the actor; every import is one GRDB transaction so a crash leaves either the
/// whole folder imported or none (NFR-REL-1). Reads use GRDB's own concurrency,
/// and reactive listings go through `DJTrackRepository`.
public actor DJLibraryStore {
    public static let shared: DJLibraryStore = try! DJLibraryStore()

    public nonisolated let pool: DatabasePool
    private let repository: DJTrackRepository

    public init(pool: DatabasePool) {
        self.pool = pool
        repository = DJTrackRepository(pool: pool)
    }

    public init(path: URL) throws {
        let openedPool = try DJDatabase.open(at: path)
        pool = openedPool
        repository = DJTrackRepository(pool: openedPool)
    }

    public init() throws {
        let openedPool = try DJDatabase.open(at: DJDatabase.defaultDatabaseURL())
        pool = openedPool
        repository = DJTrackRepository(pool: openedPool)
    }

    // MARK: - Tracks & folders

    public func tracks(matching query: LibraryQuery) throws -> [DJTrackRow] {
        try repository.tracks(matching: query)
    }

    public func trackCount() throws -> Int {
        try repository.trackCount()
    }

    public func folders() throws -> [DJFolder] {
        try pool.read { db in
            try DJFolder.order(Column("addedAt")).fetchAll(db)
        }
    }

    // MARK: - Grid corrections (§14.3, FR-ANL-5, §23.3)

    /// The stored grid corrections for a track, in replay order (`appliedAt`,
    /// then `id`) — the deterministic log §23.3 replays over the detected grid.
    public func gridCorrections(trackID: Int64) throws -> [GridCorrection] {
        try pool.read { db in
            try GridCorrection
                .filter(Column("trackID") == trackID)
                .order(Column("appliedAt"), Column("id"))
                .fetchAll(db)
        }
    }

    /// Append one grid correction to the authoritative override log (FR-ANL-5,
    /// FR-PREP-5). The detected analysis is never touched — the correction
    /// replays over it (§23.3). Returns the persisted row.
    @discardableResult
    public func appendGridCorrection(trackID: Int64,
                                     op: GridCorrectionOp,
                                     valueDouble: Double? = nil,
                                     valueInt: Int64? = nil) throws -> GridCorrection {
        var correction = GridCorrection(syncID: UUID().uuidString,
                                        trackID: trackID,
                                        op: op.rawValue,
                                        valueDouble: valueDouble,
                                        valueInt: valueInt,
                                        appliedAt: Date())
        try pool.write { db in
            try correction.insert(db)
        }
        return correction
    }

    /// Pop the newest grid correction for a track — the prep surface's "undo"
    /// (FR-PREP-5's correction undo). Because the log replays over the detected
    /// grid, removing an entry restores exactly the prior authoritative grid.
    @discardableResult
    public func undoLastGridCorrection(trackID: Int64) throws -> GridCorrection? {
        try pool.write { db in
            guard let newest = try GridCorrection
                .filter(Column("trackID") == trackID)
                .order(Column("appliedAt").desc, Column("id").desc)
                .fetchOne(db) else { return nil }
            try newest.delete(db)
            return newest
        }
    }

    /// Reactive track listing (§18.3). Non-isolated because it touches only the
    /// immutable, Sendable `repository`.
    public nonisolated func observeTracks(_ query: LibraryQuery) -> AsyncStream<[DJTrackRow]> {
        repository.observeAll(query)
    }

    // MARK: - Folder import

    /// Imports a music folder by reference (§13.1, FR-LIB-1): a security-scoped
    /// bookmark is stored, files are scanned and hashed, and `folder`/`track`/
    /// `artist`/`album`/`asset`/`import_event` rows are written in one
    /// transaction. Re-importing the same folder skips files that are already
    /// tracked (keyed by folder + relative path), so folder-watch rescans never
    /// duplicate (FR-LIB-2).
    public func importFolder(_ folderURL: URL, includeSubfolders: Bool = true,
                             watch: Bool = true) async throws -> ImportSummary {
        guard let bookmark = BookmarkVault.makeBookmark(for: folderURL) else {
            throw DJImportError.failedToCreateBookmark
        }
        let scanned = IngestService().scanFolder(folderURL, includeSubfolders: includeSubfolders)
        guard !scanned.isEmpty else { throw DJImportError.noAudioFiles }

        var collected: [FolderEntry] = []
        collected.reserveCapacity(scanned.count)
        for file in scanned {
            let metadata = await extractMetadata(file.url)
            collected.append(FolderEntry(url: file.url,
                                         relPath: Self.relPath(file.url, relativeTo: folderURL),
                                         metadata: metadata,
                                         contentHash: Self.sha256(of: file.url),
                                         bookmark: BookmarkVault.makeBookmark(for: file.url),
                                         sizeBytes: Self.fileSize(of: file.url),
                                         fileModifiedAt: Self.modificationDate(of: file.url)))
        }
        let entries = collected

        return try await pool.write { db in
            let folder = try Self.upsertFolder(in: db, folderURL: folderURL,
                                               bookmark: bookmark, watch: watch)
            guard let folderID = folder.id else { throw DJImportError.failedToInsertFolder }
            var summary = ImportSummary()
            for entry in entries {
                summary = summary.adding(try Self.importEntry(entry, folderID: folderID, in: db))
            }
            return summary
        }
    }

    // MARK: - Metadata

    /// AVFoundation common-metadata with filename fallback, mirroring
    /// `IngestService` (FR-LIB-3). Never throws: an unreadable file still
    /// imports by filename. A local `Sendable` shape so the whole folder
    /// import can run through one `DatabasePool.write` transaction.
    private struct ImportMetadata: Sendable {
        var title: String?
        var artist: String?
        var albumTitle: String?
        var albumArtist: String?
        var durationSec: Double?
    }

    private func extractMetadata(_ url: URL) async -> ImportMetadata {
        let asset = AVURLAsset(url: url)
        var meta = ImportMetadata()
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let value = try? await item.load(.stringValue), !value.isEmpty else { continue }
                if item.commonKey == .commonKeyTitle, meta.title == nil {
                    meta.title = value
                } else if item.commonKey == .commonKeyArtist, meta.artist == nil {
                    meta.artist = value
                } else if item.commonKey == .commonKeyAlbumName, meta.albumTitle == nil {
                    meta.albumTitle = value
                }
            }
        }
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite, seconds > 0 { meta.durationSec = seconds }
        }
        return meta
    }

    // MARK: - Import transaction (pure DB work)

    private struct FolderEntry: Sendable {
        let url: URL
        let relPath: String
        let metadata: ImportMetadata
        let contentHash: String?
        let bookmark: Data?
        let sizeBytes: Int64?
        let fileModifiedAt: Date?
    }

    private static func upsertFolder(in db: Database, folderURL: URL,
                                     bookmark: Data, watch: Bool) throws -> DJFolder {
        let standardizedPath = folderURL.standardizedFileURL.path
        let now = Date()
        if let existing = try DJFolder.filter(Column("displayPath") == standardizedPath).fetchOne(db) {
            var updated = existing
            updated.watching = watch
            updated.bookmark = bookmark
            updated.lastScanAt = now
            try updated.update(db)
            return updated
        }
        var folder = DJFolder(syncID: UUID().uuidString,
                              displayPath: standardizedPath,
                              bookmark: bookmark,
                              watching: watch,
                              addedAt: now,
                              lastScanAt: now)
        try folder.insert(db)
        return folder
    }

    private static func importEntry(_ entry: FolderEntry, folderID: Int64,
                                    in db: Database) throws -> ImportSummary {
        let alreadyTracked = try DJAsset
            .filter(Column("folderID") == folderID && Column("relPath") == entry.relPath)
            .fetchCount(db) > 0
        if alreadyTracked {
            return ImportSummary(added: 0, updated: 0, skipped: 1, failed: [])
        }

        let now = Date()
        let trackID: Int64
        if let hash = entry.contentHash,
           let existing = try DJTrack.filter(Column("contentHash") == hash).fetchOne(db),
           let id = existing.id {
            trackID = id
        } else {
            var track = DJTrack(
                syncID: UUID().uuidString,
                title: entry.metadata.title ?? entry.url.deletingPathExtension().lastPathComponent,
                durationSec: entry.metadata.durationSec,
                codec: entry.url.pathExtension.uppercased(),
                contentHash: entry.contentHash ?? "missing",
                sortKey: entry.url.lastPathComponent,
                addedAt: now,
                updatedAt: now)
            track.albumID = try albumID(for: entry, in: db)
            try track.insert(db)
            guard let id = track.id else { return ImportSummary(failed: [entry.url]) }
            trackID = id
            try attachArtists(to: trackID, metadata: entry.metadata, in: db)
            var event = DJImportEvent(trackID: trackID, kind: "import", detail: "folder", at: now)
            try event.insert(db)
        }

        var asset = DJAsset(trackID: trackID,
                            folderID: folderID,
                            bookmark: entry.bookmark,
                            relPath: entry.relPath,
                            sizeBytes: entry.sizeBytes,
                            fileModifiedAt: entry.fileModifiedAt,
                            unsupportedReason: nil)
        try asset.insert(db)
        return ImportSummary(added: 1, updated: 0, skipped: 0, failed: [])
    }

    /// Find-or-create album; returns nil when the file carries no album tag.
    private static func albumID(for entry: FolderEntry, in db: Database) throws -> Int64? {
        guard let raw = entry.metadata.albumTitle else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        if let existing = try DJAlbum.filter(Column("title") == title).fetchOne(db) {
            return existing.id
        }
        var album = DJAlbum(syncID: UUID().uuidString,
                            title: title,
                            albumArtist: entry.metadata.albumArtist,
                            createdAt: Date())
        try album.insert(db)
        return album.id
    }

    /// Attaches ordered primary artists from the metadata's artist list.
    private static func attachArtists(to trackID: Int64, metadata: ImportMetadata,
                                      in db: Database) throws {
        let names = ArtistNamePolicy.artistNames(from: metadata.artist)
        for (index, rawName) in names.enumerated() {
            guard let name = ArtistNamePolicy.normalize(rawName) else { continue }
            let artistID: Int64
            if let existing = try DJArtist.filter(Column("name") == name).fetchOne(db),
               let id = existing.id {
                artistID = id
            } else {
                var artist = DJArtist(syncID: UUID().uuidString,
                                      name: name,
                                      sortName: ArtistNamePolicy.sortName(for: name),
                                      createdAt: Date())
                try artist.insert(db)
                artistID = artist.id!
            }
            try db.execute(sql: """
                INSERT INTO track_artist (trackID, artistID, role, position)
                VALUES (?, ?, 'primary', ?)
                """, arguments: [trackID, artistID, index])
        }
    }

    // MARK: - File helpers

    private static func relPath(_ url: URL, relativeTo folder: URL) -> String {
        let root = folder.standardizedFileURL.path
        let file = url.standardizedFileURL.path
        if file.hasPrefix(root + "/") {
            return String(file.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }

    /// Streaming SHA-256 of file bytes, used as the change-detection identity
    /// (NFR-DET-2: no Swift `Hasher` for identity).
    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(of url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    private static func modificationDate(of url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attrs[.modificationDate] as? Date
    }
}
