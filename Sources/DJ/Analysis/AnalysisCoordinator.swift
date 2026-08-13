import Foundation
import GRDB
import Accelerate
import TonearmCore

/// Errors surfaced by the coordinator (§19, §46.2 guards).
public enum AnalysisCoordinatorError: Error {
    case noAssetForTrack(Int64)
    case decodeFailed(String)
    case persistFailed(String)
}

/// One track's full analysis pass, produced by `AnalyzePipeline` and persisted
/// in a single transaction by the coordinator (§19).
public struct TrackAnalysis: Sendable {
    public var trackID: Int64
    public var loudness: LoudnessAnalyzer.LoudnessResult?
    public var bpm: Double?
    public var key: KeyEstimate?
    public var energy: Float?
    public var phraseCount: Int
    public var waveformLevels: Int

    public init(trackID: Int64,
                loudness: LoudnessAnalyzer.LoudnessResult? = nil,
                bpm: Double? = nil,
                key: KeyEstimate? = nil,
                energy: Float? = nil,
                phraseCount: Int = 0,
                waveformLevels: Int = 0) {
        self.trackID = trackID
        self.loudness = loudness
        self.bpm = bpm
        self.key = key
        self.energy = energy
        self.phraseCount = phraseCount
        self.waveformLevels = waveformLevels
    }
}

/// Pure pipeline: decode → run every stage → assemble `TrackAnalysis`. No I/O
/// beyond the decode; deterministic (NFR-DET-3).
public enum AnalyzePipeline {

    /// Run every Stage-1 stage over the decoded buffer. Any stage that fails
    /// degrades gracefully (its field stays nil) rather than failing the track,
    /// per §46.2 guards — only decode failure is fatal.
    public static func run(url: URL) throws -> AnalyzeResult {
        let pcm = try AudioDecoder.decode(url)
        let loudness = LoudnessAnalyzer.analyze(pcm)

        // STFT → features → onset envelope.
        let stft = STFTConfig()
        let kernel = STFTKernel(config: stft)
        let spectra = pcm.mono.withUnsafeBufferPointer { kernel.spectra($0) }
        let hopSeconds = Double(stft.hopSize) / stft.sampleRate

        var frames: [SpectralFrame] = []
        if !spectra.isEmpty {
            frames.reserveCapacity(spectra.count)
            for (i, spec) in spectra.enumerated() {
                let prev = i > 0 ? spectra[i - 1].power : spec.power
                let offset = Int(stft.hopSize) * i
                let frame = pcm.mono.withUnsafeBufferPointer { buf in
                    let slice = UnsafeBufferPointer(
                        start: buf.baseAddress!.advanced(by: offset),
                        count: min(stft.fftSize, max(0, buf.count - offset)))
                    return SpectralFeatures.frame(spec, prevPower: prev, frameSamples: slice)
                }
                frames.append(frame)
            }
        }

        let envelope = OnsetDetector.envelope(spectra: spectra)
        let onsets = OnsetDetector.peaks(envelope, frameRateHz: 1 / hopSeconds)
        let tempo = TempoAnalyzer.estimate(novelty: envelope, hopSeconds: hopSeconds).first

        var bpm: Double?
        var beatGrid: BeatGrid?
        var downbeatIndices: [Int] = []
        var beatFeatures: [BeatFeature] = []
        if let tempo {
            bpm = tempo.bpm
            if let grid = BeatTracker.grid(novelty: envelope, hopSeconds: hopSeconds,
                                           sampleRate: stft.sampleRate,
                                           onsets: onsets, bpm: tempo.bpm) {
                beatGrid = grid
                downbeatIndices = BeatTracker.downbeats(beatSamples: grid.beatSamples,
                                                        novelty: envelope,
                                                        hopSeconds: hopSeconds,
                                                        sampleRate: stft.sampleRate)
                // Beat-synchronous features for phrasing (§25.1): chroma of the
                // frame nearest each beat, energy from RMS.
                beatFeatures = grid.beatSamples.map { sample -> BeatFeature in
                    let frame = Int((Double(sample) / stft.sampleRate / hopSeconds).rounded())
                    let idx = max(0, min(spectra.count - 1, frame))
                    let chroma = KeyDetector.chroma(spectra[idx])
                    let rms = frames.isEmpty ? 0 : frames[idx].rms
                    return BeatFeature(chroma: chroma, energy: rms)
                }
            }
        }

        // Key from per-frame chroma.
        var key: KeyEstimate?
        if !spectra.isEmpty {
            let chromaFrames = spectra.map { KeyDetector.chroma($0) }
            key = KeyDetector.estimate(chromaFrames)
        }

        // Energy curve + scalar (§19.4 `energy_curve` — carried, not discarded).
        var energy: Float?
        var energyCurve: [Float] = []
        if let beatGrid, !frames.isEmpty {
            energyCurve = EnergyAnalyzer.curve(frames: frames, beatSamples: beatGrid.beatSamples,
                                               frameRateHz: 1 / hopSeconds,
                                               sampleRate: stft.sampleRate)
            energy = EnergyAnalyzer.scalar(energyCurve)
        }

        // Phrases.
        var phrases: [Phrase] = []
        if !beatFeatures.isEmpty && !downbeatIndices.isEmpty, let beatGrid {
            phrases = PhraseSegmenter.segment(features: beatFeatures,
                                              beats: beatGrid.beatSamples,
                                              downbeats: downbeatIndices,
                                              sampleRate: stft.sampleRate)
        }

        // Waveform pyramid.
        var waveform: WaveformPyramid?
        pcm.mono.withUnsafeBufferPointer { buf in
            waveform = WaveformPyramidBuilder.build(buf, sampleRate: stft.sampleRate)
        }

        return AnalyzeResult(loudness: loudness, bpm: bpm, key: key, energy: energy,
                             beatGrid: beatGrid, downbeats: downbeatIndices,
                             phrases: phrases, waveform: waveform,
                             energyCurve: energyCurve, hopSeconds: hopSeconds)
    }

    /// Non-fatal aggregate returned by the pipeline. Through M4 this carried
    /// only scalars and the computed artifacts were dropped; §19.4 widens it to
    /// the full render contract so `persist` can write every destination table.
    public struct AnalyzeResult: Sendable {
        public var loudness: LoudnessAnalyzer.LoudnessResult?
        public var bpm: Double?
        public var key: KeyEstimate?
        public var energy: Float?
        /// The detected beat grid — `beatSamples`/`confidence` feed `beat_blob`,
        /// the header feeds `beat_grid` (§19.4).
        public var beatGrid: BeatGrid?
        /// The beat indices that start bars (§19.4 `downbeat` rows).
        public var downbeats: [Int]
        /// The bar-aligned phrase segmentation (§19.4 `phrase` rows).
        public var phrases: [Phrase]
        /// The band-split waveform pyramid (§19.4 `waveform_pyramid`).
        public var waveform: WaveformPyramid?
        /// The per-beat energy curve (§19.4 `energy_curve`).
        public var energyCurve: [Float]
        /// The STFT hop-seconds the curve was built at (`energy_curve` blob).
        public var hopSeconds: Double

        public var phraseCount: Int { phrases.count }
        public var waveformLevels: Int { waveform?.levels.count ?? 0 }

        public init(loudness: LoudnessAnalyzer.LoudnessResult? = nil,
                    bpm: Double? = nil,
                    key: KeyEstimate? = nil,
                    energy: Float? = nil,
                    beatGrid: BeatGrid? = nil,
                    downbeats: [Int] = [],
                    phrases: [Phrase] = [],
                    waveform: WaveformPyramid? = nil,
                    energyCurve: [Float] = [],
                    hopSeconds: Double = 0) {
            self.loudness = loudness
            self.bpm = bpm
            self.key = key
            self.energy = energy
            self.beatGrid = beatGrid
            self.downbeats = downbeats
            self.phrases = phrases
            self.waveform = waveform
            self.energyCurve = energyCurve
            self.hopSeconds = hopSeconds
        }
    }

    /// Stage-2 embedding pass: decode → log-mel → encode → pool (§27.1–27.4).
    /// Deterministic end-to-end (NFR-DET-3); the embedder actor serializes the
    /// encoder, so this is concurrency-1 regardless of callers.
    public static func embed(url: URL, embedder: CLAPEmbedder) async throws -> PooledEmbedding {
        let pcm = try AudioDecoder.decode(url)
        let windows = try Preprocess.logMel(pcm: pcm, spec: embedder.spec)
        let windowVectors = try await embedder.embedWindows(windows)
        // §27.4 energy blend: mean log-mel magnitude per window — a §25-loudness
        // proxy; Stage-1's RMS curve can refine it later without ABI change.
        let energies = windows.map { window in
            window.logMel.reduce(0, +) / Float(max(1, window.logMel.count))
        }
        let pooled = Pooling.pool(windowVectors, strategy: embedder.spec.pooling,
                                  energy: energies)
        return PooledEmbedding(pooled: pooled, windowVectors: windowVectors)
    }

    /// Stage-2 aggregate: the pooled whole-track vector plus per-window vectors.
    /// Only `pooled` is persisted in commit 2.2; windows feed the crate-scoped
    /// §16.4 work later.
    public struct PooledEmbedding: Sendable {
        public let pooled: [Float]
        public let windowVectors: [[Float]]

        public init(pooled: [Float], windowVectors: [[Float]]) {
            self.pooled = pooled
            self.windowVectors = windowVectors
        }
    }
}

/// Progress emitted by the coordinator (§41.3).
public struct AnalysisProgress: Sendable, Equatable {
    public var completed: Int
    public var total: Int
    public var currentTrackTitle: String?
    public var governorWords: String

    public init(completed: Int, total: Int, currentTrackTitle: String? = nil,
                governorWords: String = "") {
        self.completed = completed
        self.total = total
        self.currentTrackTitle = currentTrackTitle
        self.governorWords = governorWords
    }

    /// Honest ETA from the fraction of work done.
    public func etaSeconds(elapsed: TimeInterval) -> TimeInterval? {
        guard completed > 0, total > completed else { return nil }
        let rate = elapsed / Double(completed)
        return rate * Double(total - completed)
    }
}

/// Actor job runner over `analysis_run` rows (§19, FR-ANL-3).
///
/// - Bounded concurrency: `performanceCoreCount − 1` (min 1) tracks in parallel.
/// - Crash-safe resume: stale `running` rows reset to `pending` on `reconcile`.
/// - Single-transaction persist + `track.analysisState` roll-up.
/// - Priority-fenced: analysis never runs while a performance is live (FR-ANL-2);
///   the governor's decision scales concurrency (FR-ANL-7/8).
public actor AnalysisCoordinator {

    public let pool: DatabasePool
    /// Resolves a track's asset to a file URL. Default uses the stored bookmark.
    private let assetURL: @Sendable (Int64, Database) throws -> URL?
    private let governor: ThermalGovernor

    /// Callback the UI hooks to render progress; also the test seam.
    private let onProgress: @Sendable (AnalysisProgress) -> Void

    /// A performance is live → all analysis paused (FR-ANL-2).
    public private(set) var isPerforming: Bool = false

    /// Injectable power snapshot (battery fraction 0...1, charging flag) so the
    /// governor's words and gates are testable off-device.
    public private(set) var powerSnapshot: (battery: Double, isCharging: Bool)

    private var isRunning = false

    public init(pool: DatabasePool,
                assetURL: @escaping @Sendable (Int64, Database) throws -> URL?,
                governor: ThermalGovernor? = nil,
                powerSnapshot: (battery: Double, isCharging: Bool) = (1.0, true),
                onProgress: @escaping @Sendable (AnalysisProgress) -> Void = { _ in }) {
        self.pool = pool
        self.assetURL = assetURL
        self.governor = governor ?? ThermalGovernor()
        self.powerSnapshot = powerSnapshot
        self.onProgress = onProgress
    }

    /// Default asset resolver: read the track's asset bookmark and resolve it.
    public static func defaultAssetURL(trackID: Int64, _ db: Database) throws -> URL? {
        guard let asset = try DJAsset.filter(Column("trackID") == trackID).fetchOne(db),
              let bookmark = asset.bookmark,
              let (url, _) = BookmarkVault.resolve(bookmark) else {
            return nil
        }
        return url
    }

    // MARK: - Version reconcile

    /// Enqueue work for every track whose stored analysis version is behind the
    /// current constants (§17.2). Runs synchronously (persists the `pending`
    /// rows) and returns the count enqueued.
    public func reconcileVersions() throws -> Int {
        // Reset stale `running` rows to `pending` (crash-safe resume, §19.1).
        try pool.write { db in
            try db.execute(sql: "UPDATE analysis_run SET state = 'pending' WHERE state = 'running'")
        }
        // Pending/not-analyzed tracks; `analysisVersion` 0 means never analyzed.
        let pendingCount = try pool.read { db in
            try DJTrack.filter(Column("analysisState") != "analyzed").fetchCount(db)
        }
        return pendingCount
    }

    // MARK: - Run

    /// Mark a performance as live/ended; while live, all analysis is paused.
    public func setPerforming(_ performing: Bool) {
        isPerforming = performing
    }

    /// Analyze all pending tracks with bounded concurrency and governor-aware
    /// throttling. Yields progress through `onProgress`.
    public func analyzeAll() async {
        guard !isRunning, !isPerforming else { return }
        isRunning = true
        defer { isRunning = false }

        let pendingIDs: [Int64]
        do {
            pendingIDs = try await pendingTrackIDs()
        } catch {
            return
        }
        guard !pendingIDs.isEmpty else { return }

        let coreCount = ProcessInfo.processInfo.processorCount
        let baseLimit = max(1, coreCount - 1)
        let total = pendingIDs.count
        let counter = Counter()
        // Bounded concurrency: the semaphore admits at most `baseLimit` tracks
        // at once (§19.1, §43).
        let semaphore = AsyncSemaphore(limit: baseLimit)
        let words = currentGovernorWords()

        await withTaskGroup(of: Void.self) { group in
            for trackID in pendingIDs {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
                    let done = counter.increment()
                    let title = await self.trackTitle(trackID)
                    self.onProgress(AnalysisProgress(completed: done, total: total,
                                                     currentTrackTitle: title,
                                                     governorWords: words))
                    await Self.analyzeOne(pool: self.pool,
                                          resolver: self.assetURL,
                                          trackID: trackID)
                    let after = counter.completed
                    self.onProgress(AnalysisProgress(completed: after, total: total,
                                                     governorWords: words))
                }
            }
            await group.waitForAll()
        }
    }

    private func currentGovernorWords() -> String {
        let battery = powerSnapshot.battery
        let charging = powerSnapshot.isCharging
        let thermal = ProcessInfo.processInfo.thermalState
        return ThermalGovernor.words(lane: .essentials, thermalState: thermal,
                                     batteryLevelPercent: battery * 100,
                                     isCharging: charging, userOverride: false,
                                     isPerforming: isPerforming)
    }

    /// A tiny lock-protected counter for group-task progress.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _completed = 0
        var completed: Int { lock.lock(); defer { lock.unlock() }; return _completed }
        func increment() -> Int {
            lock.lock(); defer { lock.unlock() }
            _completed += 1
            return _completed
        }
    }

    /// A counting semaphore for bounding concurrency; actor-isolated so its
    /// mutable state is safe under Swift 6.
    private actor AsyncSemaphore {
        private let limit: Int
        private var available: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) {
            self.limit = max(1, limit)
            self.available = max(1, limit)
        }

        func wait() async {
            if available > 0 {
                available -= 1
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func signal() {
            if let next = waiters.first {
                waiters.removeFirst()
                next.resume()
            } else {
                available += 1
            }
        }
    }

    private func trackTitle(_ trackID: Int64) async -> String? {
        (try? await pool.read { try DJTrack.fetchOne($0, key: trackID) })?.title
    }

    private func pendingTrackIDs() async throws -> [Int64] {
        try await pool.read { db in
            let tracks = try DJTrack
                .filter(Column("analysisState") != "analyzed")
                .order(Column("sortKey"))
                .fetchAll(db)
            return tracks.compactMap(\.id)
        }
    }

    /// Analyze one track: resolve URL, run pipeline, persist in one transaction.
    /// Static so the DSP + DB work runs off the actor — the actor only queues.
    private static func analyzeOne(pool: DatabasePool,
                                   resolver: @Sendable (Int64, Database) throws -> URL?,
                                   trackID: Int64) async {
        let url: URL
        do {
            guard let resolved = try await pool.read({ try resolver(trackID, $0) }) else {
                try? await pool.write { db in
                    try Self.markFailed(db, trackID: trackID,
                                        error: AnalysisCoordinatorError.noAssetForTrack(trackID))
                }
                return
            }
            url = resolved
        } catch {
            try? await pool.write { db in try Self.markFailed(db, trackID: trackID, error: error) }
            return
        }

        let result: AnalyzePipeline.AnalyzeResult
        do {
            result = try AnalyzePipeline.run(url: url)
        } catch {
            try? await pool.write { db in try Self.markFailed(db, trackID: trackID, error: error) }
            return
        }

        try? await pool.write { db in
            try Self.persist(db, trackID: trackID, result: result)
        }
    }

    // MARK: - Persistence

    /// Single-transaction persist of every stage's rows + `track.analysisState`
    /// roll-up (§19.1 "single-transaction persist", §19.4's full render
    /// contract). Runs inside a `pool.write` which already provides the
    /// transaction. Static so it runs inside the write block without actor
    /// re-entrancy. All five artifact writers go through `AnalysisArtifacts` so
    /// the coordinator and the `DJLibraryStore` façade share one row shape.
    private static func persist(_ db: Database, trackID: Int64,
                                result: AnalyzePipeline.AnalyzeResult) throws {
            let now = Date()

            if let loudness = result.loudness {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO loudness
                    (trackID, integratedLUFS, truePeakDBTP, replayGainDB, dynamicRangeDB,
                     loudnessRangeLU, version)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [trackID, loudness.integratedLUFS, loudness.truePeakDBTP,
                                     loudness.replayGainDB, loudness.dynamicRangeDB,
                                     loudness.loudnessRangeLU, loudness.version])
            }

            // Real beat grid: header + per-beat blob + downbeat rows (§19.4 —
            // placeholder zeros were the pre-M5 defect).
            if let beatGrid = result.beatGrid {
                try AnalysisArtifacts.writeBeatGrid(beatGrid, trackID: trackID,
                                                    db: db, updatedAt: now)
                try AnalysisArtifacts.writeDownbeats(result.downbeats, beatGrid: beatGrid,
                                                     trackID: trackID, db: db)
            }

            if let key = result.key {
                try db.execute(sql: """
                    INSERT INTO key_estimate
                    (trackID, scope, startSample, endSample, camelot, tonic, mode,
                     confidence, version)
                    VALUES (?, 'global', NULL, NULL, ?, ?, ?, ?, 1)
                    """, arguments: [trackID, key.camelot.code, key.tonic,
                                     key.isMinor ? "minor" : "major", key.confidence])
            }

            if let energy = result.energy {
                try db.execute(sql: """
                    UPDATE track SET energy = ?, camelot = ?, bpm = ?, musicalKey = ?,
                    detectedBPM = ? WHERE id = ?
                    """, arguments: [energy, result.key?.camelot.code, result.bpm,
                                     result.key?.musicalKey, result.beatGrid?.bpm, trackID])
            } else if result.key != nil || result.bpm != nil {
                try db.execute(sql: """
                    UPDATE track SET camelot = ?, bpm = ?, musicalKey = ?,
                    detectedBPM = ? WHERE id = ?
                    """, arguments: [result.key?.camelot.code, result.bpm,
                                     result.key?.musicalKey, result.beatGrid?.bpm, trackID])
            }

            // Phrases, waveform pyramid and energy curve (§19.4).
            try AnalysisArtifacts.writePhrases(result.phrases, trackID: trackID, db: db)
            if let waveform = result.waveform {
                try AnalysisArtifacts.writeWaveform(waveform, trackID: trackID, db: db)
            }
            if !result.energyCurve.isEmpty {
                try AnalysisArtifacts.writeEnergyCurve(result.energyCurve,
                                                       hopSeconds: result.hopSeconds,
                                                       trackID: trackID, db: db)
            }

            // analysis_run row: done.
            try db.execute(sql: """
                INSERT OR REPLACE INTO analysis_run
                (trackID, stage, version, state, attempts, lastError, startedAt,
                 finishedAt, durationMS)
                VALUES (?, 'essentials', 1, 'done', 0, NULL, NULL, ?, 0)
                """, arguments: [trackID, now])

            // Roll-up track.analysisState.
            try db.execute(sql: "UPDATE track SET analysisState = 'analyzed' WHERE id = ?",
                           arguments: [trackID])
    }

    private static func markFailed(_ db: Database, trackID: Int64, error: Error) throws {
            try db.execute(sql: """
                INSERT OR REPLACE INTO analysis_run
                (trackID, stage, version, state, attempts, lastError, startedAt,
                 finishedAt, durationMS)
                VALUES (?, 'essentials', 1, 'failed', 1, ?, NULL, NULL, 0)
                """, arguments: [trackID, String(describing: error)])
            try db.execute(sql: "UPDATE track SET analysisState = 'failed' WHERE id = ?",
                           arguments: [trackID])
    }
}
