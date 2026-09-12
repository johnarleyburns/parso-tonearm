import AVFoundation
import Foundation
import GRDB
import TonearmCore
import TonearmDiscovery

// MARK: - FR-LIB-8 deck-readiness (§4.1, §41.9c)

/// The FR-LIB-8 gate's decision for a track. A track is **deck-ready only when
/// its audio is fully local and reachable** — the real-time render path never
/// waits on a network (§4.1). The UI MUST show the caching state and MUST NOT
/// present a partially-cached remote track as deck-ready; the gate is the single
/// place that decides, so a remote row gains the caching states here in 5.6 when
/// the genre library lands, without any caller changing.
public enum DeckReadiness: Equatable, Sendable {
    /// The track's audio is local and reachable — deck-ready.
    case ready
    /// The audio cannot be reached: a missing file, a stale bookmark, or an
    /// unsupported asset. Never rendered as deck-ready; the reason is
    /// user-facing (mockup `iphone/05b`'s dimmed "caching" row).
    case unavailable(reason: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// A decode/resolve failure — an **honest state, not a crash** (plan 5.1: "a
/// decode failure is an honest state not a crash"). The workspace reports it as
/// a message; the deck is simply never armed.
public struct DeckLoadFailure: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// The outcome of a deck-load request (§49.3a / plan decision 16).
public enum DeckLoadOutcome: Sendable {
    /// The track decoded to a `DeckSource`; the caller keeps the box alive
    /// while the deck plays it (§12.2).
    case loaded(DeckSourceBox)
    /// The FR-LIB-8 gate refused the track — it is not deck-ready.
    case refused(DeckReadiness)
    /// The track could not be decoded or resolved. Honest, recoverable.
    case failed(DeckLoadFailure)
}

/// Owns the decoded PCM and exposes the pure-value `DeckSource` the engine
/// boxes (§12.2 ownership-transfer). `DeckSource` is a descriptor — a raw
/// pointer into this box's PCM — so the caller MUST keep the box alive while
/// the deck plays the source. The `WorkspaceModel` keeps one box per deck and
/// replaces it on reload, exactly like the offline harness's `TestSource`.
public final class DeckSourceBox: @unchecked Sendable {
    public let source: DeckSource
    private let storage: UnsafeMutableBufferPointer<Float>

    /// Boxes an interleaved-float mono buffer (the §12.2 contract: a pure
    /// value the render thread reads with a plain memory load, no ARC).
    public init(samples: UnsafeMutableBufferPointer<Float>, sampleRate: Double, grid: DeckGrid) {
        storage = samples
        source = DeckSource(pcm: UnsafeRawPointer(samples.baseAddress!),
                            frameCount: Int64(samples.count),
                            channelCount: 1,
                            sampleRate: sampleRate,
                            grid: grid)
    }

    deinit {
        storage.deallocate()
    }
}

// MARK: - Stem set ownership (§35.1, plan decision 3)

/// Owns the four decoded stem voices' PCM and exposes the pure-value `StemSet`
/// the engine boxes (§12.2 ownership-transfer, the `DeckSourceBox` convention).
/// The caller MUST keep the box alive while the deck plays the set; the
/// `WorkspaceModel` keeps one box per deck alongside its `DeckSourceBox`.
///
/// Voices are downmixed to the deck's mono sample space at build time — the
/// cache stores stereo `.caf` files, and the engine's mono reader takes each
/// voice's mono sum, exactly like the full-mix decode path.
public final class StemSetBox: @unchecked Sendable {
    public let stemSet: StemSet
    private let vocalsStorage: UnsafeMutableBufferPointer<Float>
    private let drumsStorage: UnsafeMutableBufferPointer<Float>
    private let bassStorage: UnsafeMutableBufferPointer<Float>
    private let otherStorage: UnsafeMutableBufferPointer<Float>

    public init(vocals: UnsafeBufferPointer<Float>, drums: UnsafeBufferPointer<Float>,
                bass: UnsafeBufferPointer<Float>, other: UnsafeBufferPointer<Float>,
                sampleRate: Double, grid: DeckGrid) {
        vocalsStorage = Self.box(vocals)
        drumsStorage = Self.box(drums)
        bassStorage = Self.box(bass)
        otherStorage = Self.box(other)
        stemSet = StemSet(
            vocals: DeckSource(pcm: UnsafeRawPointer(vocalsStorage.baseAddress!),
                               frameCount: Int64(vocals.count), channelCount: 1,
                               sampleRate: sampleRate, grid: grid),
            drums: DeckSource(pcm: UnsafeRawPointer(drumsStorage.baseAddress!),
                              frameCount: Int64(drums.count), channelCount: 1,
                              sampleRate: sampleRate, grid: grid),
            bass: DeckSource(pcm: UnsafeRawPointer(bassStorage.baseAddress!),
                             frameCount: Int64(bass.count), channelCount: 1,
                             sampleRate: sampleRate, grid: grid),
            other: DeckSource(pcm: UnsafeRawPointer(otherStorage.baseAddress!),
                              frameCount: Int64(other.count), channelCount: 1,
                              sampleRate: sampleRate, grid: grid))
    }

    private static func box(_ buffer: UnsafeBufferPointer<Float>) -> UnsafeMutableBufferPointer<Float> {
        let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: buffer.count)
        storage.baseAddress!.update(from: buffer.baseAddress!, count: buffer.count)
        return storage
    }

    deinit {
        vocalsStorage.deallocate()
        drumsStorage.deallocate()
        bassStorage.deallocate()
        otherStorage.deallocate()
    }
}

// MARK: - The prepared-stems seam (§36.5, plan decision 3)

/// The stem seam the workspace talks to (plan 5.8, decision 3): resolve a
/// loaded track's prepared (cached, version-matched) stem set, or the honest
/// absence. `StemLoader` conforms; tests inject a fake so the model's per-deck
/// stem status and fader forwarding are exercised deterministically (§47.2).
public protocol StemProviding: Sendable {
    /// The four voices for a prepared track, or nil when none is prepared — the
    /// deck then plays the full mix (§36.5, FR-ENG-3's fallback). `grid` is the
    /// deck's authoritative grid, so the four voices share the deck's sample
    /// space and quantize/sync math (§23.3).
    func preparedStems(trackID: Int64, grid: DeckGrid) async throws -> StemSetBox?
}

/// Loads a track's prepared stem set from the content-addressed `StemCache`
/// (§36.4, plan decision 5): resolve the four `.caf` URLs → decode each to the
/// deck's mono sample space → box the set. Returns nil when no version-matched
/// set is cached — the honest absence (§36.5), never a partial set.
public struct StemLoader: StemProviding, Sendable {
    public let cache: StemCache

    public init(cache: StemCache = StemCache(pool: DJLibraryStore.shared.pool)) {
        self.cache = cache
    }

    public func preparedStems(trackID: Int64, grid: DeckGrid) async throws -> StemSetBox? {
        guard let urls = try await cache.load(trackID: trackID,
                                              modelVersion: AnalysisVersions.stems) else {
            return nil
        }
        var voices: [SeparationVoice: (buffer: UnsafeBufferPointer<Float>, count: Int)] = [:]
        for kind in SeparationVoice.allCases {
            guard let url = urls[kind] else { return nil }
            let decoded = try AudioDecoder.decode(url)
            guard decoded.mono.baseAddress != nil, decoded.frameCount > 0 else { return nil }
            voices[kind] = (decoded.mono, decoded.frameCount)
        }
        let rate = AudioDecoder.workingSampleRate
        guard let v = voices[.vocals], let d = voices[.drums],
              let b = voices[.bass], let o = voices[.other] else { return nil }
        return StemSetBox(vocals: v.buffer, drums: d.buffer, bass: b.buffer, other: o.buffer,
                          sampleRate: rate, grid: grid)
    }
}

// MARK: - Per-deck queues (§41.9c, FR-ENG-13)

/// A selectable queue for a deck. **No new entity**: a deck's queue is an
/// ordinary `playlist` row, or the whole library browsable as a list (§41.9c).
/// Genre-library and gig-crate sources join here in 5.6 / 5.9.
public enum DeckQueueSource: Equatable, Hashable, Sendable {
    /// The whole library as a list.
    case allTracks
    /// A saved playlist (`DJPlaylist`), in its stored order.
    case playlist(id: Int64, title: String)

    public var title: String {
        switch self {
        case .allTracks: return "All tracks"
        case .playlist(_, let title): return title
        }
    }
}

/// One row of a deck's queue — the crate-sheet row that was deferred in 4.7
/// ("the workspace has no library data seam yet"). Carries the FR-LIB-8
/// readiness so a track that is not deck-ready is visibly dimmed, never a
/// failure at the moment it is tapped (mockup `iphone/05b`).
public struct DeckQueueRow: Identifiable, Equatable, Sendable {
    public var id: Int64 { trackID }
    public let trackID: Int64
    public let title: String
    public let artist: String
    public let readiness: DeckReadiness

    public init(trackID: Int64, title: String, artist: String, readiness: DeckReadiness) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.readiness = readiness
    }
}

/// A deck's queue: its selected source and that source's rows. The two decks
/// may point at **different** sources at once (FR-ENG-13).
public struct DeckQueue: Equatable, Sendable {
    public let source: DeckQueueSource
    public let rows: [DeckQueueRow]

    public init(source: DeckQueueSource, rows: [DeckQueueRow]) {
        self.source = source
        self.rows = rows
    }
}

// MARK: - The seam

/// The library → deck seam the workspace talks to (plan 5.1, decision 16): the
/// selectable queues, each queue's rows, and the one gesture that loads a track
/// to a deck through the FR-LIB-8 gate and the decode path. `DeckLoader`
/// conforms; tests inject a fake so `WorkspaceModel`'s queue state and load
/// forwarding are exercised deterministically (§47.2).
public protocol DeckLibraryServicing: Sendable {
    func availableQueues() async throws -> [DeckQueueSource]
    func rows(in source: DeckQueueSource) async throws -> [DeckQueueRow]
    func load(trackID: Int64) async -> DeckLoadOutcome
}

// MARK: - DeckLoader

/// Resolves a library track to a deck-ready `DeckSource` (§49.3a, plan
/// decision 16): track + asset → **FR-LIB-8 fully-cached gate** (a partially
/// cached remote track is never deck-ready and says so) → decode off the main
/// actor → `DeckSourceBox` handed over per §12.2.
///
/// A `Sendable` value holding the single-writer store, so the blocking decode
/// runs on the cooperative executor the caller landed on — never the main
/// actor.
///
/// **C02 (IMPLEMENT_CLAP_PLAN.md) identity note.** Both queue sources are
/// fully re-pointed at the one core `LibraryStore` database: `.allTracks`
/// resolves core track rows directly, and `.playlist` (a DJ crate, from
/// `PlaylistCrateImporter`) stores core track IDs since dj_v8 dropped
/// `playlist_item.trackID`'s FK into the DJ-local `track` table — so
/// `rows(in: .playlist)` and `load(trackID:)` resolve those IDs through the
/// SAME core `LibraryStore`, the same IDs the app's import path,
/// `SearchService` and every other core-database consumer use. This is the
/// identity path the plan's C02 integration test exercises for both queue
/// sources. There is no legacy DJ-local track/asset fallback in
/// `load(trackID:)` any more — a core lookup miss is an honest
/// "not in the library" refusal.
public struct DeckLoader: DeckLibraryServicing, Sendable {
    /// The one core music catalog (plan §3).
    public let library: LibraryStore
    /// DJ-local operational data that the plan's amendment leaves
    /// intentionally un-migrated: manual beat-grid corrections (read here,
    /// keyed by whatever ID space a given track's beat-grid row happens to be
    /// under — see `authoritativeGrid`), and — until the crate-side follow-up
    /// above lands — the legacy `.playlist` catalog rows.
    public let djLibrary: DJLibraryStore

    public init(library: LibraryStore = .shared, djLibrary: DJLibraryStore = .shared) {
        self.library = library
        self.djLibrary = djLibrary
    }

    // MARK: DeckLibraryServicing

    public func availableQueues() async throws -> [DeckQueueSource] {
        let pool = djLibrary.pool
        let playlists = try await pool.read { db in
            try DJPlaylist.order(Column("updatedAt").desc).fetchAll(db)
        }
        var sources: [DeckQueueSource] = [.allTracks]
        sources += playlists.compactMap { playlist in
            playlist.id.map { .playlist(id: $0, title: playlist.title) }
        }
        return sources
    }

    public func rows(in source: DeckQueueSource) async throws -> [DeckQueueRow] {
        switch source {
        case .allTracks:
            let rows = try await library.allTrackRows()
            return rows.map { row in
                DeckQueueRow(trackID: row.id,
                             title: row.track.title,
                             artist: row.artist?.name ?? row.album?.artist ?? "",
                             readiness: readiness(forCore: row.asset))
            }
        case .playlist(let id, _):
            // C02: playlist_item.trackID is a CORE LibraryStore track id
            // (dj_v8) — resolve it through the same core library as
            // .allTracks, not a DJ-local track/asset lookup.
            let pool = djLibrary.pool
            let trackIDs = try await pool.read { db in
                try DJPlaylistItem
                    .filter(Column("playlistID") == id)
                    .order(Column("position"))
                    .fetchAll(db)
                    .compactMap(\.trackID)
            }
            var rows: [DeckQueueRow] = []
            rows.reserveCapacity(trackIDs.count)
            for trackID in trackIDs {
                guard let row = try? await library.trackRow(id: trackID) else { continue }
                rows.append(DeckQueueRow(trackID: row.id,
                                         title: row.track.title,
                                         artist: row.artist?.name ?? row.album?.artist ?? "",
                                         readiness: readiness(forCore: row.asset)))
            }
            return rows
        }
    }

    public func load(trackID: Int64) async -> DeckLoadOutcome {
        guard let row = try? await library.trackRow(id: trackID) else {
            return .refused(.unavailable(reason: "This track is no longer in the library"))
        }
        return await loadCore(row)
    }

    // MARK: - Core-identity load path (C02)

    private func loadCore(_ row: TrackRow) async -> DeckLoadOutcome {
        let readiness = readiness(forCore: row.asset)
        guard readiness.isReady else {
            return .refused(readiness)
        }
        guard let asset = row.asset, let url = Self.resolveAudioURL(for: asset) else {
            return .refused(.unavailable(reason: "This track's file is no longer reachable"))
        }

        // Decode off the main actor: this method is nonisolated on a Sendable
        // value, so the blocking AVFoundation decode runs on the cooperative
        // executor, not the UI thread (plan decision 16).
        do {
            let decoded = try AudioDecoder.decode(url)
            guard let mono = decoded.mono.baseAddress, decoded.frameCount > 0 else {
                return .failed(DeckLoadFailure("The decoded audio was empty"))
            }
            let count = decoded.frameCount
            let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
            storage.baseAddress!.update(from: mono, count: count)
            let grid = await authoritativeGrid(trackID: row.id)
            return .loaded(DeckSourceBox(samples: storage,
                                         sampleRate: AudioDecoder.workingSampleRate,
                                         grid: grid))
        } catch {
            return .failed(DeckLoadFailure(error.localizedDescription))
        }
    }

    // MARK: - Grid

    /// The deck's grid at the decode sample rate: the authoritative grid when
    /// the track has a DJ-local `beat_grid` row for this core track ID
    /// (detected + stored corrections replayed, §23.3), else an honest
    /// default at the discovery-analyzed BPM (falling back to 120). The
    /// reference sample is re-anchored to the 48 kHz decode space, because
    /// that is the sample space the `DeckSource` the deck actually plays is
    /// in.
    ///
    /// C02 note: `beat_grid`/`grid_correction` are still DJ-local tables keyed
    /// by whatever ID they were written under; a core track ID that was never
    /// analyzed by the (still un-migrated) DJ analysis pipeline simply has no
    /// row here, which is the honest, expected state for every track until
    /// that pipeline's own C02 follow-up re-keys it onto core IDs — not a
    /// bug in this read path.
    private func authoritativeGrid(trackID: Int64) async -> DeckGrid {
        let pool = djLibrary.pool
        let decodeRate = AudioDecoder.workingSampleRate
        let corrections = (try? await djLibrary.gridCorrections(trackID: trackID)) ?? []
        var detectedBPM: Double?
        var firstBeatSample: Int64 = 0
        if let row = try? pool.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT bpm, firstBeatSample FROM beat_grid WHERE trackID = ?
                """, arguments: [trackID])
        }) {
            detectedBPM = row["bpm"] as? Double
            firstBeatSample = row["firstBeatSample"] as? Int64 ?? 0
        }

        if let detectedBPM {
            let base = DeckGrid(referenceSample: Double(firstBeatSample),
                                bpm: detectedBPM,
                                beatsPerBar: 4,
                                sampleRate: decodeRate)
            if let authoritative = GridReplay.authoritativeGridIfAnalyzed(base: base,
                                                                          corrections: corrections) {
                return DeckGrid(referenceSample: authoritative.referenceSample,
                                bpm: authoritative.bpm,
                                beatsPerBar: authoritative.beatsPerBar,
                                sampleRate: decodeRate)
            }
        }
        let discoveredBPM = (try? await library.dbQueue.read { db in
            try DiscoveryTrackAnalysis.fetchOne(db, key: trackID)?.bpm
        }) ?? nil
        return DeckGrid(bpm: discoveredBPM ?? 120, sampleRate: decodeRate)
    }

    // MARK: - Readiness (core)

    /// The FR-LIB-8 decision for a core asset: fully local and reachable is
    /// ready; anything else is an honest unavailable state with a
    /// user-facing reason.
    private func readiness(forCore asset: Asset?) -> DeckReadiness {
        guard let asset else {
            return .unavailable(reason: "This track has no audio on file")
        }
        guard let url = Self.resolveAudioURL(for: asset) else {
            return .unavailable(reason: "This track's file is no longer reachable")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .unavailable(reason: "Audio is not on this device yet")
        }
        return .ready
    }

    /// Resolves a core `Asset` to its local audio URL: a per-file bookmark, a
    /// direct file:// remote URL, an app-relative path, or — for a fully
    /// cached remote track — the complete stream-cache entry. Mirrors
    /// `PhoneWatchLibraryAudioResolver.localURL(for:)` and
    /// `PlaylistCrateImporter.localURL(for:)`, the other core-`Asset`
    /// resolvers in this codebase.
    private static func resolveAudioURL(for asset: Asset) -> URL? {
        if let bookmark = asset.bookmark, let (url, _) = BookmarkVault.resolve(bookmark) {
            return url
        }
        if let remote = asset.remoteURL.flatMap(URL.init(string:)), remote.isFileURL {
            return remote
        }
        if let relPath = asset.relPath,
           let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil,
                                                    create: false) {
            let url = base.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        if let remote = asset.remoteURL.flatMap(URL.init(string:)),
           AudioCache.completeCacheExists(for: remote) {
            return AudioCache.fileURL(for: AudioCache.key(for: remote))
        }
        return nil
    }

}
