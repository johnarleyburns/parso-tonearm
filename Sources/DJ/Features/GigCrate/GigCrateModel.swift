import Combine
import Foundation
import GRDB

// MARK: - Seams (§41.17 View ▸ VM ▸ data)

/// The gig-crate data seam the view model talks to. `GigCrateRepository`
/// conforms; tests inject a fake so promotion, detail and readiness are
/// exercised deterministically (§47.2).
public protocol GigCrateRepositing: Sendable {
    /// Every crate with its roll-up, most-recently-performed first.
    func crates() async throws -> [GigCrateRow]
    /// One crate's detail (crate + ordered track rows).
    func detail(crateID: Int64) async throws -> GigCrateDetail?
    /// Promote a static playlist to a gig crate (FR-PLIST-9).
    func promote(playlistID: Int64, name: String,
                 storageBudgetBytes: Int64) async throws -> Int64
    /// Stamp `lastPerformedAt` — the LRU clock (FR-ANL-9).
    func markPerformed(crateID: Int64) async throws
    /// The promotable playlists, most-recently-updated first.
    func playlists() async throws -> [DJPlaylist]
}

/// The §36.3 lane seam the view model drives. `StemService` conforms; tests
/// inject a controllable fake so the preparing state and the eviction preview
/// are deterministic.
public protocol StemLaneRunning: Sendable {
    /// The lane's live progress stream (newest-1).
    func observeProgress() async -> AsyncStream<StemProgress>
    /// The eviction preview for preparing a crate — shown before any eviction.
    func planPreparation(crateID: Int64, budget: Int64,
                         protectedIDs: Set<Int64>) async throws -> StorageBudgetService.StemPlan
    /// Run the crate's separation lane.
    func runCrateLane(crateID: Int64, budget: Int64,
                      protectedIDs: Set<Int64>) async
}

extension GigCrateRepository: GigCrateRepositing {
    public func playlists() async throws -> [DJPlaylist] {
        try await pool.read { db in
            try DJPlaylist.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    public func markPerformed(crateID: Int64) async throws {
        try markPerformed(crateID: crateID, at: Date())
    }
}

extension StemService: StemLaneRunning {}

// MARK: - Model

/// View model for the gig crate surface (mockup `ipad/14`, §41.17,
/// FR-PLIST-9, FR-ANL-9): the crate list, one crate's detail with its
/// per-track readiness, the storage the crate will consume against the §43.6
/// budget, the **eviction preview** shown before any eviction happens, and the
/// stem lane that prepares the crate.
///
/// The bridge between free and Pro: any playlist — including one the auto-
/// playlist generator made — promotes to a gig crate, which caches audio and
/// queues stage-3 stems for its tracks. The stem lane respects the budget,
/// evicts least-recently-performed crates first, pauses while a performance is
/// live (FR-ANL-2) and abandons at `.serious` (§43.7).
@MainActor
public final class GigCrateModel: ObservableObject {

    public let repository: any GigCrateRepositing
    public let stemService: any StemLaneRunning
    /// The §43.6 global stem budget this model plans against.
    public let budget: Int64

    @Published public private(set) var crates: [GigCrateRow] = []
    @Published public private(set) var detail: GigCrateDetail?
    @Published public private(set) var availablePlaylists: [DJPlaylist] = []
    /// The lane's latest progress step.
    @Published public private(set) var stemsProgress: StemProgress?
    /// The eviction preview for the open crate — what would be dropped to make
    /// room. Shown, never silently performed.
    @Published public private(set) var evictionPreview: StorageBudgetService.StemPlan?
    @Published public private(set) var isPreparing = false
    @Published public private(set) var lastError: String?

    private var openCrateID: Int64?
    private var progressTask: Task<Void, Never>?

    public init(repository: any GigCrateRepositing,
                stemService: any StemLaneRunning,
                budget: Int64 = StorageBudgetService.defaultStemBudget(
                    deviceClass: .other)) {
        self.repository = repository
        self.stemService = stemService
        self.budget = budget
    }

    // MARK: - List / detail

    /// The crates + the promotable playlists.
    public func refresh() async {
        crates = (try? await repository.crates()) ?? []
        availablePlaylists = (try? await repository.playlists()) ?? []
    }

    /// Open a crate's detail and compute its eviction preview.
    public func open(crateID: Int64) async {
        openCrateID = crateID
        await reloadDetail()
        await previewEviction()
    }

    private func reloadDetail() async {
        guard let crateID = openCrateID else { return }
        detail = try? await repository.detail(crateID: crateID)
    }

    /// Promote a playlist (FR-PLIST-9) and open the new crate.
    @discardableResult
    public func promote(playlistID: Int64, name: String) async -> Int64? {
        do {
            let crateID = try await repository.promote(playlistID: playlistID,
                                                       name: name,
                                                       storageBudgetBytes: budget)
            lastError = nil
            await refresh()
            await open(crateID: crateID)
            return crateID
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Mark the open crate performed — the LRU clock.
    public func markPerformed() async {
        guard let crateID = openCrateID else { return }
        try? await repository.markPerformed(crateID: crateID)
        await refresh()
    }

    // MARK: - Budget & eviction preview (FR-ANL-9, AT-STEM-*)

    /// Recompute the open crate's eviction preview (§41.17 "Making room").
    public func previewEviction() async {
        guard let crateID = openCrateID else { return }
        evictionPreview = try? await stemService.planPreparation(crateID: crateID,
                                                                 budget: budget,
                                                                 protectedIDs: [])
    }

    // MARK: - The §36.3 lane

    /// Start consuming the lane's progress onto the model.
    public func startObservingProgress() async {
        guard progressTask == nil else { return }
        let stream = await stemService.observeProgress()
        progressTask = Task { [weak self] in
            for await progress in stream {
                self?.stemsProgress = progress
            }
        }
    }

    /// Prepare the open crate: show the eviction preview, then run the lane.
    public func prepare() async {
        guard let crateID = openCrateID, !isPreparing else { return }
        await startObservingProgress()
        await previewEviction()
        isPreparing = true
        lastError = nil
        await stemService.runCrateLane(crateID: crateID, budget: budget,
                                       protectedIDs: [])
        isPreparing = false
        await reloadDetail()
        await refresh()
    }

    /// Honest governor words for the preparing panel (§43.7, NFR-THERM-4).
    public var governorWords: String {
        stemsProgress?.governorWords ?? ""
    }

    /// Whether the open crate's audio is fully cached — FR-PLIST-9 readiness.
    public var isReady: Bool { detail?.cachedCount == detail?.trackCount && (detail?.trackCount ?? 0) > 0 }

    /// The "Storage for this crate" readout: projected bytes of the free space.
    public var storageReadoutText: String {
        guard let detail else { return "—" }
        let projected = detail.projectedStemBytes
        return "\(StorageBudgetService.bytesText(projected)) of \(StorageBudgetService.bytesText(evictionPreview?.freeBytes ?? 0)) free"
    }
}
