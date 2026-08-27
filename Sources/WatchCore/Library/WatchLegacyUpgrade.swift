import Foundation

/// The one-time upgrade from the old GRDB watch database into the SwiftData store.
///
/// The reader is injected as a closure so `TonearmWatchCore` never links GRDB — the legacy product
/// supplies the snapshot, the boundary guard in `scripts/check-ci-guards.sh` keeps it that way.
///
/// The governing rule from the plan is: *never discard validated user audio merely because the old
/// metadata store is unreadable.* When the reader fails, the upgrade still succeeds — it records the
/// audio it kept and asks for phone reconciliation instead of deleting anything.
public enum WatchLegacyUpgradeOutcome: Equatable, Sendable {
    /// The upgrade already ran against this store; nothing was touched.
    case alreadyCompleted
    case completed(tracks: Int, playlists: Int, adoptedAssets: Int)
    /// The old database could not be read. Audio on disk was retained and the phone must reconcile.
    case legacyUnreadable(retainedFiles: [WatchRecoverableFileSnapshot])

    public var requiresPhoneReconciliation: Bool {
        if case .legacyUnreadable = self { return true }
        return false
    }
}

public struct WatchLegacyUpgrade: Sendable {
    /// Bumping this key re-runs the upgrade; the value records how it finished.
    public static let completionKey = "legacyUpgrade.v1"

    private let repository: WatchLibraryRepository

    public init(repository: WatchLibraryRepository) { self.repository = repository }

    /// Runs at most once per store. `reader` is only invoked when the upgrade has not already run,
    /// so an unreadable legacy database costs nothing on subsequent launches.
    @discardableResult
    public func run(reader: @Sendable () async throws -> WatchLegacyLibrarySnapshot) async throws -> WatchLegacyUpgradeOutcome {
        if try await repository.metadata(Self.completionKey) != nil { return .alreadyCompleted }
        let snapshot: WatchLegacyLibrarySnapshot
        do {
            snapshot = try await reader()
        } catch {
            let retained = await repository.recoverableFiles()
            try await repository.setMetadata(Self.completionKey, to: "legacyUnreadable")
            return .legacyUnreadable(retainedFiles: retained)
        }
        let adopted = try await repository.migrateLegacy(snapshot)
        try await repository.setMetadata(Self.completionKey, to: "completed")
        return .completed(tracks: snapshot.tracks.count, playlists: snapshot.playlists.count, adoptedAssets: adopted)
    }
}
