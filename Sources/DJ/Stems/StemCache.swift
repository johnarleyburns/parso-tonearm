import Foundation
import AVFoundation
import GRDB

// MARK: - Errors

public enum StemCacheError: Error, LocalizedError, Equatable {
    case emptyAudio
    case formatUnavailable
    case bufferUnavailable
    case fileWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyAudio: return "Cannot cache a stem set with no audio"
        case .formatUnavailable: return "Could not create the stem CAF format"
        case .bufferUnavailable: return "Could not allocate the stem write buffer"
        case .fileWriteFailed(let detail): return "Could not write the stem file: \(detail)"
        }
    }
}

// MARK: - Row shapes

/// The four per-stem relative `.caf` paths a `stem_cache` row records (§36.4),
/// relative to the cache root — e.g. `<contentHash>/<version>/vocals.caf`.
public struct StemCachePaths: Codable, Equatable, Sendable {
    public var vocals: String
    public var drums: String
    public var bass: String
    public var other: String

    public init(vocals: String, drums: String, bass: String, other: String) {
        self.vocals = vocals
        self.drums = drums
        self.bass = bass
        self.other = other
    }

    public func path(for kind: SeparationVoice) -> String {
        switch kind {
        case .vocals: return vocals
        case .drums: return drums
        case .bass: return bass
        case .other: return other
        }
    }
}

/// One `stem_cache` row: a track's prepared, model-versioned stem set (§36.4).
/// The on-disk files live under `Stems/<contentHash>/<modelVersion>/`; the row
/// records their presence, size, sample rate and relative paths.
public struct StemCacheRecord: Codable, FetchableRecord, TableRecord, Equatable, Sendable {
    public var trackID: Int64
    public var contentHash: String
    public var modelVersion: Int
    public var sampleRate: Int
    public var channelCount: Int
    public var totalBytes: Int64
    public var pathsJSON: String
    public var createdAt: Date

    public init(trackID: Int64, contentHash: String, modelVersion: Int,
                sampleRate: Int, channelCount: Int, totalBytes: Int64,
                pathsJSON: String, createdAt: Date) {
        self.trackID = trackID
        self.contentHash = contentHash
        self.modelVersion = modelVersion
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.totalBytes = totalBytes
        self.pathsJSON = pathsJSON
        self.createdAt = createdAt
    }

    public static let databaseTableName = "stem_cache"
}

// MARK: - The cache

/// The content-addressed, model-versioned stem cache (§36.4, plan decision 5):
/// four 48 kHz stereo `.caf` files per track under
/// `Caches/TonearmDJ/Stems/<contentHash>/<stemsVersion>/`, recorded in the
/// `stem_cache` table. A model upgrade writes a **new** version row + directory
/// and invalidates cleanly, like `analysis_version`; eviction removes a set and
/// its directory only once no remaining row references it.
///
/// Actor-serialized: file + DB work happens one at a time (separation is
/// low-concurrency by design, §36.3). "Absence is a value" — a row whose files
/// are gone reads as not-cached, never as a corrupt result (FR-SEM-6, ADR-10).
public actor StemCache {
    public let pool: DatabasePool
    /// The on-disk root (defaults to `DJDatabase.cachesDirectory/Stems`,
    /// backup-excluded per §13.1); tests inject a temp directory.
    public let root: URL
    /// The current model version — the version this cache writes (§36.4).
    public let modelVersion: Int

    public init(pool: DatabasePool, root: URL? = nil,
                modelVersion: Int = AnalysisVersions.stems) {
        self.pool = pool
        self.root = root ?? StemCache.defaultRoot
        self.modelVersion = modelVersion
    }

    public static var defaultRoot: URL {
        DJDatabase.cachesDirectory.appendingPathComponent("Stems", isDirectory: true)
    }

    // MARK: - Store

    /// Write a stem set to disk and record it in one `stem_cache` transaction
    /// (plan 5.7: "`stem_cache` row in one transaction"). Re-storing the same
    /// (track, version) replaces both the files and the row — idempotent.
    @discardableResult
    public func store(_ separation: StemSeparation, trackID: Int64,
                      contentHash: String) throws -> StemCacheRecord {
        let version = modelVersion
        let directory = versionDirectory(contentHash: contentHash, version: version)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var totalBytes: Int64 = 0
        var paths = StemCachePaths(vocals: "", drums: "", bass: "", other: "")
        do {
            for (kind, audio) in separation.all {
                let relPath = "\(contentHash)/\(version)/\(kind.fileName)"
                let url = directory.appendingPathComponent(kind.fileName)
                try writeCAF(audio, to: url)
                totalBytes += Self.fileSize(url, fileManager: fileManager)
                switch kind {
                case .vocals: paths.vocals = relPath
                case .drums: paths.drums = relPath
                case .bass: paths.bass = relPath
                case .other: paths.other = relPath
                }
            }
        } catch {
            // A failed separation leaves a clean absence, never a partial cache
            // (ADR-10: fail loud; a partial stem set is a corrupt result).
            try? fileManager.removeItem(at: directory)
            throw error
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let pathsJSON = String(data: try encoder.encode(paths), encoding: .utf8) ?? "{}"

        try pool.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO stem_cache
                (trackID, contentHash, modelVersion, sampleRate, channelCount,
                 totalBytes, pathsJSON, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [trackID, contentHash, version,
                                 Int(separation.sampleRate.rounded()),
                                 2, totalBytes, pathsJSON, Date()])
        }

        return StemCacheRecord(trackID: trackID, contentHash: contentHash,
                               modelVersion: version,
                               sampleRate: Int(separation.sampleRate.rounded()),
                               channelCount: 2, totalBytes: totalBytes,
                               pathsJSON: pathsJSON, createdAt: Date())
    }

    // MARK: - Read

    /// Whether a (track, version) set is cached and its files are actually on
    /// disk. A row whose files are gone reads as not-cached — honest absence.
    public func isCached(trackID: Int64, modelVersion: Int) throws -> Bool {
        try load(trackID: trackID, modelVersion: modelVersion) != nil
    }

    /// The four on-disk `.caf` URLs for a cached (track, version) set, or nil
    /// when there is no row or a file is missing (§36.5 — the caller then plays
    /// the full mix). The URLs resolve from the row's recorded relative paths.
    public func load(trackID: Int64, modelVersion: Int) throws -> [SeparationVoice: URL]? {
        let fileManager = FileManager.default
        guard let record = try pool.read({ db in
            try StemCacheRecord.fetchOne(db, sql: """
                SELECT * FROM stem_cache WHERE trackID = ? AND modelVersion = ?
                """, arguments: [trackID, modelVersion])
        }),
        let paths = try? JSONDecoder().decode(StemCachePaths.self,
                                              from: Data(record.pathsJSON.utf8)) else {
            return nil
        }
        var urls: [SeparationVoice: URL] = [:]
        for kind in SeparationVoice.allCases {
            let url = root.appendingPathComponent(paths.path(for: kind))
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            urls[kind] = url
        }
        return urls
    }

    /// The recorded on-disk size of a cached set, for the §43.6 storage budget.
    public func bytes(onDisk trackID: Int64, modelVersion: Int) throws -> Int64 {
        try pool.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT totalBytes FROM stem_cache WHERE trackID = ? AND modelVersion = ?
                """, arguments: [trackID, modelVersion]) ?? 0
        }
    }

    // MARK: - Eviction

    /// Remove a (track, version) set: the `stem_cache` row in one transaction,
    /// then the on-disk directory — but only once no remaining row references it
    /// (content-addressing can share a directory across tracks; evicting one
    /// track must not delete the other's files).
    public func evict(trackID: Int64, modelVersion: Int) throws {
        let fileManager = FileManager.default
        guard let record = try pool.read({ db in
            try StemCacheRecord.fetchOne(db, sql: """
                SELECT * FROM stem_cache WHERE trackID = ? AND modelVersion = ?
                """, arguments: [trackID, modelVersion])
        }) else { return }

        try pool.write { db in
            try db.execute(sql: """
                DELETE FROM stem_cache WHERE trackID = ? AND modelVersion = ?
                """, arguments: [trackID, modelVersion])
        }

        let remaining = try pool.read { db in
            try StemCacheRecord
                .filter(Column("contentHash") == record.contentHash
                        && Column("modelVersion") == modelVersion)
                .fetchCount(db)
        }
        if remaining == 0 {
            let contentHashDir = root.appendingPathComponent(record.contentHash, isDirectory: true)
            try? fileManager.removeItem(at: contentHashDir.appendingPathComponent(String(modelVersion), isDirectory: true))
            try? fileManager.removeItem(at: contentHashDir)
        }
    }

    // MARK: - Helpers

    private func versionDirectory(contentHash: String, version: Int) -> URL {
        root.appendingPathComponent(contentHash, isDirectory: true)
            .appendingPathComponent(String(version), isDirectory: true)
    }

    /// Writes a stereo Float32 CAF. AVFoundation writes in block-aligned calls
    /// and drops a trailing partial block when a single write is larger than a
    /// block, so the audio is written in ≤ 4096-frame blocks — every frame is
    /// captured (verified on the macOS host: 9600 frames in three writes read
    /// back exactly).
    private func writeCAF(_ audio: StemChunk, to url: URL) throws {
        guard audio.frameCount > 0 else { throw StemCacheError.emptyAudio }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: audio.sampleRate,
                                         channels: 2, interleaved: false) else {
            throw StemCacheError.formatUnavailable
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: audio.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = 4096
        var offset = 0
        while offset < audio.frameCount {
            let count = min(block, audio.frameCount - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(count)),
                  let data = buffer.floatChannelData else {
                throw StemCacheError.bufferUnavailable
            }
            buffer.frameLength = AVAudioFrameCount(count)
            audio.left.withUnsafeBufferPointer { lp in
                data[0].update(from: lp.baseAddress!.advanced(by: offset), count: count)
            }
            audio.right.withUnsafeBufferPointer { rp in
                data[1].update(from: rp.baseAddress!.advanced(by: offset), count: count)
            }
            try file.write(from: buffer)
            offset += count
        }
    }

    private static func fileSize(_ url: URL, fileManager: FileManager) -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}
