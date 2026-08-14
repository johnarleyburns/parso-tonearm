import Foundation

/// The mixes read/write seam the finish and Mixes surfaces talk to (§41.11,
/// §41.12; plan 5.12). `MixRepository` conforms; tests inject a fake so the
/// models' states are exercised deterministically (§47.2).
public protocol MixServicing: Sendable {
    /// Every finished mix (`complete` + honestly-`corrupt`), newest first.
    func completedMixes() async throws -> [DJMix]
    /// A mix's §37.4 timeline rows in `position` order.
    func mixTrackEvents(mixID: Int64) async throws -> [DJMixTrackEvent]
    /// The mix's local M4A URL, or nil when the file is gone (absence is a
    /// value, never corruption).
    func mixAssetURL(mixID: Int64) async throws -> URL?
    /// FR-REC-1: title + notes on the finished mix.
    func updateMix(mixID: Int64, title: String, notes: String?) async throws
    /// Delete the mix row and its user-content audio file.
    func deleteMix(mixID: Int64) async throws
    /// The total on-device size of finished mixes (§41.12's storage readout).
    func mixStorageBytes() async throws -> Int64
}

/// The §41.12 mixes data layer: the single-writer `DJLibraryStore` plus the
/// user-content root the recorded audio lives under
/// (`DJDatabase.mixesDirectory`; never a cache, never evicted, §43.6).
public struct MixRepository: MixServicing, Sendable {
    public let store: DJLibraryStore
    public let mixesRoot: URL

    public init(store: DJLibraryStore = .shared,
                mixesRoot: URL = DJDatabase.mixesDirectory) {
        self.store = store
        self.mixesRoot = mixesRoot
    }

    public func completedMixes() async throws -> [DJMix] {
        try await store.completedMixes()
    }

    public func mixTrackEvents(mixID: Int64) async throws -> [DJMixTrackEvent] {
        try await store.mixTrackEvents(mixID: mixID)
    }

    public func mixAssetURL(mixID: Int64) async throws -> URL? {
        guard let asset = try await store.mixAsset(mixID: mixID) else { return nil }
        let url = mixesRoot.appendingPathComponent(asset.localRelPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func updateMix(mixID: Int64, title: String, notes: String?) async throws {
        try await store.updateMix(mixID: mixID, title: title, notes: notes)
    }

    public func deleteMix(mixID: Int64) async throws {
        let localRelPath = try await store.deleteMix(mixID: mixID)
        guard let localRelPath else { return }
        let url = mixesRoot.appendingPathComponent(localRelPath)
        // The session directory + its file — recordings are user content, so
        // deletion is deliberate and complete (§43.6's "the app asks").
        let directory = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.removeItem(at: directory)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func mixStorageBytes() async throws -> Int64 {
        try await store.mixStorageBytes()
    }
}
