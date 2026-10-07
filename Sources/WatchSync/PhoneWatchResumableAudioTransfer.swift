import CryptoKit
import Foundation
import TonearmWatchProtocol
import TonearmWatchCore

/// A bounded checkpoint sender. WCSession completion is NOT a checkpoint; only a
/// watch manifest acknowledging a validated piece allows the next piece to go.
public actor PhoneWatchResumableAudioTransfer {
    private struct Pending: Codable {
        var transferID: String
        var enqueuedAt: Date
        var deliveredAt: Date?
    }
    private struct Plan: Codable {
        var audio: WatchAudioFileMetadata
        var source: URL
        var chunkBytes: Int
        var received: Set<Int>
        var pending: [String: Pending]
        var active: Bool
        var createdAt: Date
    }
    private struct Journal: Codable {
        var plans: [String: Plan]
        var lastManifestAt: Date?
        var receipts: [WatchPartialAudioDownload]?
    }
    public struct Progress: Sendable {
        public var checkpoint: WatchPartialAudioDownload
        public var stage: WatchDownloadActivity.Stage
    }

    private let directory: URL
    private let transport: any WatchProtocolTransport
    private let systemTransfers: @Sendable () async -> [WatchAudioChunkMetadata]
    private let systemFractions: @Sendable () async -> [String: Double]
    private let canTransfer: @Sendable () async -> Bool
    private let cancelSystem: @Sendable (WatchTrackID) async -> Void
    private let sourceLookup: @Sendable (URL) -> URL
    private let onFailure: @Sendable (WatchTrackID, WatchProtocolErrorCode) async -> Void
    private let now: @Sendable () -> Date
    private let defaultChunkBytes: Int
    private var plans: [String: Plan] = [:]
    private var lastManifestAt: Date?
    private var receipts: [WatchPartialAudioDownload] = []
    private var loaded = false
    private var pumping = false

    public init(directory: URL, transport: any WatchProtocolTransport,
                chunkBytes: Int = WatchAudioChunkPolicy.defaultChunkBytes,
                systemTransfers: @escaping @Sendable () async -> [WatchAudioChunkMetadata] = { [] },
                systemFractions: @escaping @Sendable () async -> [String: Double] = { [:] },
                canTransfer: @escaping @Sendable () async -> Bool = { true },
                cancelSystem: @escaping @Sendable (WatchTrackID) async -> Void = { _ in },
                sourceLookup: @escaping @Sendable (URL) -> URL = { $0 },
                now: @escaping @Sendable () -> Date = { Date() },
                onFailure: @escaping @Sendable (WatchTrackID, WatchProtocolErrorCode) async -> Void = { _, _ in }) {
        self.directory = directory; self.transport = transport; self.defaultChunkBytes = chunkBytes
        self.systemTransfers = systemTransfers; self.cancelSystem = cancelSystem
        self.systemFractions = systemFractions
        self.canTransfer = canTransfer
        self.sourceLookup = sourceLookup; self.now = now; self.onFailure = onFailure
    }

    private var journalURL: URL { directory.appendingPathComponent("plans.json") }
    private func load() {
        guard !loaded else { return }; loaded = true
        if let data = try? Data(contentsOf: journalURL), let journal = try? JSONDecoder().decode(Journal.self, from: data) {
            plans = journal.plans.filter { _, plan in
                WatchAudioChunkMetadata(audio: plan.audio, chunkBytes: plan.chunkBytes, index: 0,
                    chunkSHA256: plan.audio.sha256 ?? "").isValid && plan.source.isFileURL
            }
            lastManifestAt = journal.lastManifestAt; receipts = journal.receipts ?? []
        }
    }
    private func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Journal(plans: plans, lastManifestAt: lastManifestAt, receipts: receipts)).write(to: journalURL, options: .atomic)
    }
    private func folder(_ plan: Plan) -> URL {
        folder(plan.audio)
    }
    private func folder(_ audio: WatchAudioFileMetadata) -> URL {
        let id = audio.trackID.rawValue + ":" + (audio.sha256 ?? "")
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash, isDirectory: true)
    }

    public func begin(fileURL: URL, audio: WatchAudioFileMetadata) async throws {
        load()
        let measured = try WatchFileDigest.measure(fileURL)
        guard measured.bytes > 0, measured.bytes == audio.expectedBytes,
              measured.sha256 == audio.sha256 else { throw WatchProtocolFault(code: .checksumMismatch) }
        let id = audio.trackID.rawValue
        if var existing = plans[id], existing.audio.sha256 == audio.sha256,
           existing.audio.expectedBytes == audio.expectedBytes {
            existing.source = fileURL; existing.audio = audio; existing.active = true
            plans[id] = existing
        } else {
            let candidate = WatchAudioChunkMetadata(audio: audio, chunkBytes: defaultChunkBytes,
                index: 0, chunkSHA256: measured.sha256)
            guard candidate.isValid else { throw WatchProtocolFault(code: .unsupportedAudio) }
            plans[id] = Plan(audio: audio, source: fileURL, chunkBytes: defaultChunkBytes,
                received: [], pending: [:], active: true, createdAt: now())
            if let receipt = receipts.first(where: { $0.trackID == audio.trackID && $0.assetSHA256 == audio.sha256
                && $0.totalBytes == audio.expectedBytes && $0.chunkBytes == defaultChunkBytes }) {
                plans[id]?.received = Set(receipt.receivedChunkIndexes.filter { $0 >= 0 && $0 < candidate.chunkCount })
            }
        }
        try save()
        try await pump()
    }

    public func hasPlan(trackID: String) -> Bool { load(); return plans[trackID] != nil }

    /// Pausing/restarting cancels unconfirmed system files, never validated checkpoints.
    public func suspend(trackID: WatchTrackID) async {
        load()
        if var plan = plans[trackID.rawValue] {
            plan.active = false; plan.pending.removeAll(); plans[trackID.rawValue] = plan
            try? save()
        }
        await cancelSystem(trackID)
    }

    public func ingestManifest(_ manifest: WatchManifestPayload) async throws {
        load()
        guard lastManifestAt.map({ manifest.generatedAt > $0 }) ?? true else { return }
        let ready = Set(manifest.readyTrackIDs.map(\.rawValue))
        var failures: [(WatchTrackID, WatchProtocolErrorCode)] = []
        for id in Array(plans.keys) {
            guard var plan = plans[id] else { continue }
            if ready.contains(id) {
                plans.removeValue(forKey: id)
                // Keep any still-system-owned files until the completion callback. Their
                // next begin uses a different transfer ID, so late results cannot hurt it.
                continue
            }
            if let receipt = manifest.partialAudioDownloads.first(where: {
                $0.trackID.rawValue == id && $0.assetSHA256 == plan.audio.sha256
                    && $0.totalBytes == plan.audio.expectedBytes && $0.chunkBytes == plan.chunkBytes
            }) {
                let count = Int((plan.audio.expectedBytes - 1) / Int64(plan.chunkBytes) + 1)
                plan.received = Set(receipt.receivedChunkIndexes.filter { $0 >= 0 && $0 < count })
                plan.pending = plan.pending.filter { !plan.received.contains(Int($0.key) ?? -1) }
            } else {
                // A newer authoritative report can reveal that the watch was reset or
                // that recovery rejected a damaged checkpoint. Re-send only what is absent.
                plan.received.removeAll()
            }
            plans[id] = plan
            if plan.active, let code = manifest.audioDownloadFailures[id] {
                plans[id]?.active = false
                plans[id]?.pending.removeAll()
                failures.append((plan.audio.trackID, code))
            }
        }
        lastManifestAt = manifest.generatedAt
        receipts = manifest.partialAudioDownloads
        try save()
        for (trackID, code) in failures { await cancelSystem(trackID); await onFailure(trackID, code) }
        try await pump()
    }

    /// Returns true only for the current attempt; stale cancellation results are ignored.
    @discardableResult
    public func deliveryFinished(_ chunk: WatchAudioChunkMetadata, error: WatchProtocolErrorCode?) async -> Bool {
        load()
        // WCSession has relinquished this exact immutable copy. The original cached
        // audio and the watch's checkpoints are untouched, including for stale attempts.
        if UUID(uuidString: chunk.transferID) != nil {
            try? FileManager.default.removeItem(at: folder(chunk.audio).appendingPathComponent(chunk.transferID + ".chunk"))
        }
        let id = chunk.audio.trackID.rawValue
        guard var plan = plans[id], plan.audio.sha256 == chunk.audio.sha256,
              var pending = plan.pending[String(chunk.index)], pending.transferID == chunk.transferID else { return false }
        if let error {
            plan.pending.removeValue(forKey: String(chunk.index)); plan.active = false
            plans[id] = plan; try? save()
            await onFailure(chunk.audio.trackID, error)
        } else {
            pending.deliveredAt = now(); plan.pending[String(chunk.index)] = pending
            plans[id] = plan; try? save()
        }
        return true
    }

    public func tick() async {
        load()
        do { try await pump() }
        catch { /* Per-plan errors are made visible by onFailure in pump. */ }
    }

    public func activeTrackIDs() -> [WatchTrackID] {
        load()
        return plans.values.filter { plan in
            let count = Int((plan.audio.expectedBytes - 1) / Int64(plan.chunkBytes) + 1)
            return plan.active && plan.received.count < count
        }.map { $0.audio.trackID }
    }

    public func progress() async -> [String: Progress] {
        load()
        let fractions = await systemFractions()
        return plans.mapValues { plan in
            let checkpoint = WatchPartialAudioDownload(trackID: plan.audio.trackID,
                assetSHA256: plan.audio.sha256 ?? "", totalBytes: plan.audio.expectedBytes,
                chunkBytes: plan.chunkBytes, receivedChunkIndexes: plan.received.sorted())
            let stage: WatchDownloadActivity.Stage
            if !plan.active { stage = .paused }
            else if plan.received.count == checkpoint.chunkCount { stage = .awaitingInstallation }
            else if plan.pending.isEmpty { stage = .waitingForDelivery }
            else if plan.pending.values.contains(where: { $0.deliveredAt != nil }) { stage = .awaitingChunkConfirmation }
            else if plan.pending.values.contains(where: { (fractions[$0.transferID] ?? 0) > 0 }) { stage = .transferring }
            else { stage = .waitingForDelivery }
            return Progress(checkpoint: checkpoint, stage: stage)
        }
    }

    private func pump() async throws {
        guard !pumping else { return }; pumping = true; defer { pumping = false }
        guard await canTransfer() else { return }
        let system = await systemTransfers()
        let systemIDs = Set(system.map(\.transferID))
        for id in Array(plans.keys) {
            guard var plan = plans[id], plan.active else { continue }
            plan.pending = plan.pending.filter { entry in
                systemIDs.contains(entry.value.transferID)
                    || now().timeIntervalSince(entry.value.deliveredAt ?? entry.value.enqueuedAt) < WatchAudioChunkPolicy.acknowledgementTimeout
            }
            plans[id] = plan
        }
        let pendingIDs = Set(plans.values.flatMap { $0.pending.values.map(\.transferID) }).union(systemIDs)
        // Recover copies whose completion callback was lost to process termination.
        for dir in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            guard dir.lastPathComponent.count == 64, dir.lastPathComponent.allSatisfy({ $0.isHexDigit }) else { continue }
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let id = file.deletingPathExtension().lastPathComponent
                if file.pathExtension == "chunk", UUID(uuidString: id) != nil, !pendingIDs.contains(id) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
            if (try? FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty) == true { try? FileManager.default.removeItem(at: dir) }
        }
        guard pendingIDs.count < WatchAudioChunkPolicy.maximumUnconfirmedChunks else { try save(); return }
        // Prefer a small collection over a long recording when both are waiting; the
        // whole file is already cached on the phone and no track is downloaded twice.
        let candidates = plans.filter { $0.value.active }.sorted {
            if $0.value.audio.expectedBytes != $1.value.audio.expectedBytes {
                return $0.value.audio.expectedBytes < $1.value.audio.expectedBytes
            }
            return $0.value.createdAt < $1.value.createdAt
        }
        for (id, initial) in candidates {
            let count = Int((initial.audio.expectedBytes - 1) / Int64(initial.chunkBytes) + 1)
            guard let index = (0..<count).first(where: { !initial.received.contains($0) && initial.pending[String($0)] == nil }) else { continue }
            do {
                let source = FileManager.default.fileExists(atPath: initial.source.path) ? initial.source : sourceLookup(initial.source)
                let reader = try FileHandle(forReadingFrom: source)
                let data: Data
                do {
                    try reader.seek(toOffset: UInt64(index) * UInt64(initial.chunkBytes))
                    data = try reader.read(upToCount: initial.chunkBytes) ?? Data()
                    try reader.close()
                } catch { try? reader.close(); throw error }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let metadata = WatchAudioChunkMetadata(audio: initial.audio, chunkBytes: initial.chunkBytes,
                    index: index, chunkSHA256: digest)
                guard metadata.isValid, Int64(data.count) == metadata.expectedChunkBytes else {
                    throw WatchProtocolFault(code: .checksumMismatch)
                }
                try FileManager.default.createDirectory(at: folder(initial), withIntermediateDirectories: true)
                let piece = folder(initial).appendingPathComponent("\(metadata.transferID).chunk")
                try data.write(to: piece, options: .atomic)
                // Journal before enqueue so a process death never creates an invisible
                // outstanding transfer. A failed enqueue clears this exact attempt.
                var plan = plans[id] ?? initial
                plan.pending[String(index)] = Pending(transferID: metadata.transferID, enqueuedAt: now())
                plans[id] = plan; try save()
                try await transport.transferFile(piece, metadata: metadata.dictionary)
                return // One unconfirmed chunk, across every track, not one per track.
            } catch {
                var plan = plans[id] ?? initial
                plan.pending.removeValue(forKey: String(index)); plan.active = false
                plans[id] = plan; try? save()
                let code = (error as? WatchProtocolFault)?.code ?? .transferFailed
                await onFailure(initial.audio.trackID, code)
                throw error
            }
        }
        try save()
    }
}
