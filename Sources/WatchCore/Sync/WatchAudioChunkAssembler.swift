import CryptoKit
import Foundation
import TonearmWatchProtocol

public enum WatchAudioChunkOutcome: Sendable {
    case retained(WatchTrackID)
    case assembled(URL, WatchAudioFileMetadata)
    case rejected(WatchTrackID?, WatchProtocolFault)
}

/// Validated pieces live in Application Support until the complete asset commits.
/// Files and the receipt journal are written before any acknowledgement is sent.
public actor WatchAudioChunkAssembler {
    private struct Record: Codable {
        var audio: WatchAudioFileMetadata
        var chunkBytes: Int
        var digests: [String: String]
    }
    private let directory: URL
    private let storageProvider: @Sendable () async -> WatchStorageSnapshot?
    private var records: [String: Record] = [:]
    private var loaded = false
    private var removedTrackIDs: Set<String> = []

    public init(directory: URL, storageProvider: @escaping @Sendable () async -> WatchStorageSnapshot? = { nil }) {
        self.directory = directory; self.storageProvider = storageProvider
    }

    private func key(_ audio: WatchAudioFileMetadata) -> String {
        let identity = audio.trackID.rawValue + ":" + (audio.sha256 ?? "")
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func folder(_ key: String) -> URL { directory.appendingPathComponent(key, isDirectory: true) }
    private func chunkURL(_ key: String, _ index: Int) -> URL { folder(key).appendingPathComponent("\(index).chunk") }
    private func save(_ key: String, _ record: Record) throws {
        try FileManager.default.createDirectory(at: folder(key), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: folder(key).appendingPathComponent("receipt.json"), options: .atomic)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: directory.appendingPathComponent("removed-tracks.json")),
           let removed = try? JSONDecoder().decode(Set<String>.self, from: data) { removedTrackIDs = removed }
        for folder in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("receipt.json")),
                  var record = try? JSONDecoder().decode(Record.self, from: data),
                  let digest = record.audio.sha256,
                  WatchAudioChunkMetadata(audio: record.audio, chunkBytes: record.chunkBytes, index: 0,
                    chunkSHA256: digest).isValid, folder.lastPathComponent == key(record.audio) else { continue }
            let id = folder.lastPathComponent
            // An interrupted assembly is not a checkpoint. Reclaim its scratch
            // output before rebuilding, otherwise each crash can consume another
            // whole file's worth of watch storage. Validated pieces remain intact.
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                let name = file.lastPathComponent
                if name.hasPrefix("assembled-"), UUID(uuidString: String(name.dropFirst(10))) != nil {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            // A crash between data and journal writes can leave an unacknowledged file.
            // Only pieces matching the journal survive recovery as confirmed progress.
            record.digests = record.digests.filter { entry in
                guard let index = Int(entry.key) else { return false }
                let metadata = WatchAudioChunkMetadata(audio: record.audio, chunkBytes: record.chunkBytes,
                    index: index, chunkSHA256: entry.value)
                guard metadata.isValid, let measured = try? WatchFileDigest.measure(chunkURL(id, index)) else { return false }
                return measured.bytes == metadata.expectedChunkBytes && measured.sha256 == entry.value
            }
            records[id] = record
            try? save(id, record)
        }
    }

    public func receive(stagedURL: URL, metadata: [String: String]) async -> WatchAudioChunkOutcome {
        load()
        guard let chunk = WatchAudioChunkMetadata(dictionary: metadata) else {
            try? FileManager.default.removeItem(at: stagedURL)
            return .rejected(nil, .init(code: .installationFailed))
        }
        let id = key(chunk.audio)
        guard !removedTrackIDs.contains(chunk.audio.trackID.rawValue) else {
            try? FileManager.default.removeItem(at: stagedURL)
            return .rejected(chunk.audio.trackID, .init(code: .sourceUnavailable))
        }
        do {
            let measured = try WatchFileDigest.measure(stagedURL)
            guard measured.bytes == chunk.expectedChunkBytes, measured.sha256 == chunk.chunkSHA256 else {
                throw WatchProtocolFault(code: .checksumMismatch)
            }
            if let storage = await storageProvider(), !storage.canAccept(bytes: measured.bytes) {
                throw WatchProtocolFault(code: .insufficientWatchStorage)
            }
            var record = records[id] ?? Record(audio: chunk.audio, chunkBytes: chunk.chunkBytes, digests: [:])
            guard record.chunkBytes == chunk.chunkBytes, record.audio.expectedBytes == chunk.audio.expectedBytes else {
                throw WatchProtocolFault(code: .installationFailed)
            }
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
            let destination = chunkURL(id, chunk.index)
            if let current = try? WatchFileDigest.measure(destination), current.sha256 == measured.sha256 {
                try FileManager.default.removeItem(at: stagedURL)
            } else {
                // Publish an immutable complete piece, never a partially copied destination.
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.moveItem(at: stagedURL, to: destination)
            }
            record.digests[String(chunk.index)] = measured.sha256
            try save(id, record)
            records[id] = record
            guard record.digests.count == chunk.chunkCount else { return .retained(chunk.audio.trackID) }
            return try await assemble(id, record)
        } catch let fault as WatchProtocolFault {
            try? FileManager.default.removeItem(at: stagedURL)
            return .rejected(chunk.audio.trackID, fault)
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            return .rejected(chunk.audio.trackID, .init(code: .installationFailed))
        }
    }

    private func assemble(_ id: String, _ record: Record) async throws -> WatchAudioChunkOutcome {
        if let storage = await storageProvider(), !storage.canAccept(bytes: record.audio.expectedBytes) {
            throw WatchProtocolFault(code: .insufficientWatchStorage)
        }
        let output = folder(id).appendingPathComponent("assembled-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer = try FileHandle(forWritingTo: output)
        do {
            let count = Int((record.audio.expectedBytes - 1) / Int64(record.chunkBytes) + 1)
            for index in 0..<count {
                let piece = chunkURL(id, index)
                let measured = try? WatchFileDigest.measure(piece)
                guard let measured, measured.sha256 == record.digests[String(index)] else {
                    // Keep every other good checkpoint, request only the damaged piece again.
                    var repaired = record
                    repaired.digests.removeValue(forKey: String(index))
                    try save(id, repaired); records[id] = repaired
                    throw WatchProtocolFault(code: .checksumMismatch)
                }
                let reader = try FileHandle(forReadingFrom: piece)
                do {
                    while let data = try reader.read(upToCount: 64 * 1024), !data.isEmpty { try writer.write(contentsOf: data) }
                    try reader.close()
                } catch { try? reader.close(); throw error }
            }
            try writer.synchronize(); try writer.close()
            let measured = try WatchFileDigest.measure(output)
            guard measured.bytes == record.audio.expectedBytes, measured.sha256 == record.audio.sha256 else {
                throw WatchProtocolFault(code: .checksumMismatch)
            }
            return .assembled(output, record.audio)
        } catch {
            try? writer.close(); try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    public func partialDownloads() -> [WatchPartialAudioDownload] {
        load()
        return records.values.map { record in
            WatchPartialAudioDownload(trackID: record.audio.trackID, assetSHA256: record.audio.sha256 ?? "",
                totalBytes: record.audio.expectedBytes, chunkBytes: record.chunkBytes,
                receivedChunkIndexes: record.digests.keys.compactMap(Int.init).sorted())
        }.sorted { $0.trackID.rawValue < $1.trackID.rawValue }
    }

    public func resumeCompleted() async -> [WatchAudioChunkOutcome] {
        load()
        var outcomes: [WatchAudioChunkOutcome] = []
        for (id, record) in records {
            let count = WatchAudioChunkMetadata(audio: record.audio, chunkBytes: record.chunkBytes,
                index: 0, chunkSHA256: record.audio.sha256 ?? "").chunkCount
            guard record.digests.count == count else { continue }
            do { outcomes.append(try await assemble(id, record)) }
            catch { outcomes.append(.rejected(record.audio.trackID,
                (error as? WatchProtocolFault) ?? .init(code: .installationFailed))) }
        }
        return outcomes
    }

    /// Retain the bytes, but leave one piece unconfirmed so an explicit retry also
    /// retries assembly/installation instead of getting stuck at 100% checkpoints.
    public func invalidateLastCheckpoint(trackID: WatchTrackID) {
        load()
        for id in Array(records.keys) {
            guard var record = records[id], record.audio.trackID == trackID,
                  record.digests.count == WatchAudioChunkMetadata(audio: record.audio, chunkBytes: record.chunkBytes,
                    index: 0, chunkSHA256: record.audio.sha256 ?? "").chunkCount,
                  let index = record.digests.keys.compactMap(Int.init).max() else { continue }
            record.digests.removeValue(forKey: String(index))
            records[id] = record; try? save(id, record)
        }
    }

    /// Called only after a complete local asset commits, or the user removes its download.
    public func remove(trackIDs: Set<String>, tombstone: Bool = false) {
        load()
        if tombstone { removedTrackIDs.formUnion(trackIDs); saveRemovedTracks() }
        for (id, record) in records where trackIDs.contains(record.audio.trackID.rawValue) {
            try? FileManager.default.removeItem(at: folder(id))
            records.removeValue(forKey: id)
        }
    }

    public func allow(trackIDs: Set<String>) {
        load()
        guard !removedTrackIDs.isDisjoint(with: trackIDs) else { return }
        removedTrackIDs.subtract(trackIDs); saveRemovedTracks()
    }

    private func saveRemovedTracks() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(removedTrackIDs) {
            try? data.write(to: directory.appendingPathComponent("removed-tracks.json"), options: .atomic)
        }
    }
}
